// SPDX-License-Identifier: GPL-3.0-only
#include <napi/native_api.h>
#include "native_audio.h"
#include <asset/asset_api.h>
#include <hilog/log.h>
#include <mutex>
#include <string>
#include <cstring>
#include <memory>
#include <cstdint>
extern "C" {
char* s3a_call(const char*); char* s3a_export(unsigned); int s3a_import(unsigned,const char*);
void s3a_free(char*); void s3a_clear();
bool s3a_validate_restore(bool expected);
int s5_unlock_binding(char*,size_t,uint64_t*);
int s5_unlock_validate(const char*,uint64_t);
int s5_unlock_permitted(const char*,uint64_t);
int s5_unlock_observed_unlocked(const char*,uint64_t);
char* s5_unlock_send(const char*,uint64_t,const uint8_t*,size_t);
}
void S4VideoExports(napi_env,napi_value);
namespace {
std::mutex gate;
bool loaded=false;
std::string saved[3];
// Unknown state forces a removal even for an empty export (expired/corrupt pending QR).
bool savedKnown[3]={false,false,false};
void Wipe(std::string& s){volatile char* p=s.empty()?nullptr:&s[0];for(size_t i=0;i<s.size();++i)p[i]=0;s.clear();}
Asset_Attr Blob(uint32_t tag,const std::string& s){Asset_Attr a{};a.tag=tag;a.value.blob={static_cast<uint32_t>(s.size()),reinterpret_cast<uint8_t*>(const_cast<char*>(s.data()))};return a;}
Asset_Attr Number(uint32_t tag,uint32_t n){Asset_Attr a{};a.tag=tag;a.value.u32=n;return a;}
std::string Alias(unsigned slot) {
  return slot == 0   ? "uus3c.identity.v1"
         : slot == 1 ? "uus3c.account.v1"
                     : "uus5.pending_qr.v1";
}
int Remove(unsigned slot) {
  std::string alias = Alias(slot);
  Asset_Attr q = Blob(ASSET_TAG_ALIAS, alias);
  int rc = OH_Asset_Remove(&q, 1);
  if (rc == ASSET_NOT_FOUND)
    rc = 0;
  if (rc == 0) {
    Wipe(saved[slot]);
    savedKnown[slot] = true;
  }
  return rc;
}
int Read(unsigned slot) {
  std::string alias = Alias(slot);
  Asset_Attr q[] = {Blob(ASSET_TAG_ALIAS, alias),
                    Number(ASSET_TAG_RETURN_TYPE, ASSET_RETURN_ALL)};
  Asset_ResultSet rs{};
  int rc = OH_Asset_Query(q, 2, &rs);
  if (rc == ASSET_NOT_FOUND) {
    savedKnown[slot] = true;
    return 0;
  }
  if (rc != 0)
    return rc;
  int result = slot == 2 ? 2 : 401;
  if (rs.count == 1) {
    Asset_Attr *a = OH_Asset_ParseAttr(&rs.results[0], ASSET_TAG_SECRET);
    if (a && a->value.blob.size > 0 && a->value.blob.size <= 1024) {
      std::string text(reinterpret_cast<char *>(a->value.blob.data),
                       a->value.blob.size);
      result = text.find('\0') == std::string::npos
                   ? s3a_import(slot, text.c_str())
                   : (slot == 2 ? 2 : 401);
      if (result == 0) {
        saved[slot] = text;
        savedKnown[slot] = true;
      }
      Wipe(text);
    }
  }
  OH_Asset_FreeResultSet(&rs);
  if (slot == 2 && result == 2)
    return Remove(2);
  return result;
}
int Save(unsigned slot) {
  char *p = s3a_export(slot);
  std::string text(p);
  s3a_free(p);
  if (slot == 0 && text.empty())
    return 0;
  if (savedKnown[slot] && text == saved[slot]) {
    Wipe(text);
    return 0;
  }
  std::string alias = Alias(slot);
  Asset_Attr query = Blob(ASSET_TAG_ALIAS, alias);
  int rc = 0;
  if (text.empty()) {
    rc = Remove(slot);
  } else if (text.size() > 1024) {
    rc = 401;
  } else {
    Asset_Attr secret = Blob(ASSET_TAG_SECRET, text);
    rc = OH_Asset_Update(&query, 1, &secret, 1);
    if (rc == ASSET_NOT_FOUND) {
      Asset_Attr attrs[] = {
          query, secret,
          Number(ASSET_TAG_ACCESSIBILITY, ASSET_ACCESSIBILITY_DEVICE_UNLOCKED),
          Number(ASSET_TAG_SYNC_TYPE, ASSET_SYNC_TYPE_NEVER)};
      rc = OH_Asset_Add(attrs, 4);
    }
  }
  if (rc == 0) {
    Wipe(saved[slot]);
    saved[slot] = text;
    savedKnown[slot] = true;
  }
  Wipe(text);
  return rc;
}
struct Work {
  napi_async_work work{};
  napi_deferred deferred{};
  std::string input, output, binding;
  uint64_t generation = 0;
  int error = 0;
  int vault = 0;
  bool enabled = false;
  bool expectRegisteredIdentity = false;
  ~Work() {
    Wipe(input);
    Wipe(output);
  }
};
// Dedicated secret boundary. No record or retrieved password ever crosses NAPI.
struct UnlockRecord {
  std::string bytes;
  ~UnlockRecord() { Wipe(bytes); }
};
// The cloud account + owned device ID selects the saved credential. DTLS pins
// authenticate a single connection and rotate on stock UU reconnects.
bool SameUnlockDevice(const std::string &saved, const std::string &current) {
  return saved.size() == 129 && current.size() == 129 && saved[64] == '.' &&
         current[64] == '.' && saved.compare(0, 64, current, 0, 64) == 0;
}
bool ValidRecord(const std::string &s) {
  return s.size() > 134 && s.size() <= 4230 && s[0] == '1' && s[1] == 'P' &&
         s[2] == '0' && s[3] == ':' && s[133] == ':' &&
         s.find('\0') == std::string::npos;
}
int ReadUnlock(const std::string &alias, UnlockRecord &record) {
  Asset_Attr q[] = {Blob(ASSET_TAG_ALIAS, alias),
                    Number(ASSET_TAG_RETURN_TYPE, ASSET_RETURN_ALL)};
  Asset_ResultSet rs{};
  int rc = OH_Asset_Query(q, 2, &rs);
  if (rc != 0)
    return rc;
  rc = -1;
  if (rs.count == 1) {
    Asset_Attr *a = OH_Asset_ParseAttr(&rs.results[0], ASSET_TAG_SECRET);
    if (a && a->value.blob.size <= 4230 && a->value.blob.size > 134) {
      record.bytes.assign(reinterpret_cast<char *>(a->value.blob.data),
                          a->value.blob.size);
      if (ValidRecord(record.bytes))
        rc = 0;
    }
  }
  for (uint32_t item = 0; item < rs.count; ++item) {
    Asset_Attr *a = OH_Asset_ParseAttr(&rs.results[item], ASSET_TAG_SECRET);
    if (a && a->value.blob.data) {
      volatile uint8_t *secret = a->value.blob.data;
      for (uint32_t i = 0; i < a->value.blob.size; ++i) secret[i] = 0;
    }
  }
  OH_Asset_FreeResultSet(&rs);
  return rc;
}
int WriteUnlock(const std::string &alias, const std::string &bytes) {
  Asset_Attr q = Blob(ASSET_TAG_ALIAS, alias);
  std::string label = bytes.substr(0, 133) + ":0";
  Asset_Attr update[] = {Blob(ASSET_TAG_SECRET, bytes),
                         Blob(ASSET_TAG_DATA_LABEL_NORMAL_LOCAL_1, label)};
  int rc = OH_Asset_Update(&q, 1, update, 2);
  if (rc == ASSET_NOT_FOUND) {
    Asset_Attr attrs[] = {
        q, update[0], update[1],
        Number(ASSET_TAG_ACCESSIBILITY, ASSET_ACCESSIBILITY_DEVICE_UNLOCKED),
        Number(ASSET_TAG_SYNC_TYPE, ASSET_SYNC_TYPE_NEVER)};
    rc = OH_Asset_Add(attrs, sizeof(attrs) / sizeof(attrs[0]));
  }
  return rc;
}
void ExecuteVault(Work *w) {
  const char *identity = w->binding.c_str();
  uint64_t generation = w->generation;
  if (s5_unlock_validate(identity, generation) != 0) {
    w->output = "{\"available\":false,\"enrolled\":false,\"enabled\":false,"
                "\"reason\":\"authenticated_owned_peer_required\"}";
    return;
  }
  const size_t length = w->binding.size();
  if (length != 129) {
    w->error = -1;
    return;
  }
  std::string alias = "uus5.windows.password.v1." + std::string(identity, 64);
  UnlockRecord record;
  int rc = 0;
  bool identityMismatch = false;
  if (w->vault == 2 || w->vault == 3 || w->vault == 5) {
    Asset_Attr q[] = {Blob(ASSET_TAG_ALIAS, alias),
                      Number(ASSET_TAG_RETURN_TYPE, ASSET_RETURN_ATTRIBUTES)};
    Asset_ResultSet rs{};
    rc = OH_Asset_Query(q, 2, &rs);
    if (rc == 0) {
      rc = -1;
      if (rs.count == 1) {
        Asset_Attr *a = OH_Asset_ParseAttr(&rs.results[0],
                                           ASSET_TAG_DATA_LABEL_NORMAL_LOCAL_1);
        if (a && a->value.blob.size == 135) {
          const std::string label(reinterpret_cast<char *>(a->value.blob.data),
                                  135);
          if ((label.substr(0, 4) == "1P0:" || label.substr(0, 4) == "1P1:") &&
              label[133] == ':' && (label[134] == '0' || label[134] == '1')) {
            if (SameUnlockDevice(label.substr(4,129), w->binding)) {
              record.bytes = label;
              rc = 0;
            } else {
              // An inconsistent account/device record is never used.
              identityMismatch = true;
              record.bytes = label;
              rc = -1;
            }
          }
        }
      }
      OH_Asset_FreeResultSet(&rs);
    }
  }
  if (w->vault == 2 && identityMismatch) {
    w->output = std::string("{\"available\":true,\"enrolled\":true,\"enabled\":") +
                (record.bytes[2] == '1' ? "true" : "false") +
                ",\"submissionAllowed\":false,\"reenrollmentRequired\":true,\"reason\":\"peer_identity_changed\"}";
    return;
  }
  // A persisted unresolved attempt survives peer/process replacement. Only a
  // current authenticated unlocked observation or explicit user action rearms.
  if (w->vault == 2 && rc == 0 && record.bytes[134] == '1' &&
      s5_unlock_observed_unlocked(identity, generation) == 0) {
    record.bytes[134] = '0';
    Asset_Attr query = Blob(ASSET_TAG_ALIAS, alias);
    Asset_Attr label = Blob(ASSET_TAG_DATA_LABEL_NORMAL_LOCAL_1, record.bytes);
    rc = OH_Asset_Update(&query, 1, &label, 1);
  }
  if (w->vault == 4) {
    Asset_Attr q = Blob(ASSET_TAG_ALIAS, alias);
    rc = OH_Asset_Remove(&q, 1);
    if (rc == ASSET_NOT_FOUND)
      rc = 0;
  } else if (w->vault == 1) {
    record.bytes = "1P0:" + w->binding + ":" + w->input;
    rc = WriteUnlock(alias, record.bytes);
  } else if (w->vault == 3) {
    // Disable the preference without replacing the saved recipient identity.
    if (identityMismatch && !w->enabled) rc = 0;
    if (rc == 0 && w->enabled && !SameUnlockDevice(record.bytes.substr(4, 129), w->binding))
      rc = -1;
    if (rc == 0) {
      record.bytes[2] = w->enabled ? '1' : '0';
      if (!identityMismatch) record.bytes[134] = '0';
      Asset_Attr query = Blob(ASSET_TAG_ALIAS, alias);
      Asset_Attr label = Blob(ASSET_TAG_DATA_LABEL_NORMAL_LOCAL_1, record.bytes);
      rc = OH_Asset_Update(&query, 1, &label, 1);
    }
  } else if (w->vault == 5) {
    if (rc == 0 && record.bytes[134] == '1') {
      w->output = "{\"ok\":false,\"reason\":\"awaiting_unlocked_observation\"}";
      return;
    }
    if (rc == 0 && record.bytes[2] == '1' &&
        s5_unlock_permitted(identity, generation) == 0) {
      // Commit before retrieval/send. Uncertain failure remains disarmed.
      record.bytes[134] = '1';
      Asset_Attr query = Blob(ASSET_TAG_ALIAS, alias);
      Asset_Attr label = Blob(ASSET_TAG_DATA_LABEL_NORMAL_LOCAL_1, record.bytes);
      rc = OH_Asset_Update(&query, 1, &label, 1);
      if (rc != 0) { w->error = rc; return; }
      Wipe(record.bytes);
      rc = ReadUnlock(alias, record);
    } else {
      w->output = "{\"ok\":false,\"reason\":\"credential_disabled_or_absent\"}";
      return;
    }
    if (rc == 0 &&
        SameUnlockDevice(record.bytes.substr(4, 129), w->binding)) {
      char *result = s5_unlock_send(
          identity, generation,
          reinterpret_cast<const uint8_t *>(record.bytes.data() + 134),
          record.bytes.size() - 134);
      if (result) {
        w->output = result;
        s3a_free(result);
      } else
        w->error = -1;
      return;
    }
    w->output = "{\"ok\":false,\"reason\":\"credential_disabled_or_absent\"}";
    return;
  }
  if (w->vault == 2 && rc == ASSET_NOT_FOUND) {
    w->output = "{\"available\":true,\"enrolled\":false,\"enabled\":false}";
    return;
  }
  if (rc != 0) {
    w->error = rc;
    return;
  }
  if (identityMismatch && w->vault == 3) {
    w->output = "{\"ok\":true,\"available\":true,\"enrolled\":true,\"enabled\":false,\"submissionAllowed\":false,\"reenrollmentRequired\":true,\"reason\":\"peer_identity_changed\"}";
    return;
  }
  if (w->vault == 2)
    w->output =
        std::string("{\"available\":true,\"enrolled\":true,\"enabled\":") +
        (record.bytes[2] == '1' ? "true,\"submissionAllowed\":true}" : "false,\"submissionAllowed\":false}");
  else
    w->output =
        std::string("{\"ok\":true,\"available\":true,\"enrolled\":") +
        (w->vault == 4 ? "false,\"enabled\":false}"
                       : (record.bytes[2] == '1' ? "true,\"enabled\":true}"
                                                 : "true,\"enabled\":false}"));
}
void Execute(napi_env, void *data) {
  auto *w = static_cast<Work *>(data);
  std::lock_guard<std::mutex> lock(gate);
  if (!loaded) {
    w->error = Read(0);
    if (!w->error)
      w->error = Read(1);
    if (!w->error && !s3a_validate_restore(w->expectRegisteredIdentity))
      w->error = 10001; // An existing account or installation is missing its registered identity.
    OH_LOG_Print(LOG_APP, w->error ? LOG_WARN : LOG_INFO, 0x0303, "UUAuthStore",
                 "restore code=%{public}d expected=%{public}d identity=%{public}d account=%{public}d",
                 w->error, w->expectRegisteredIdentity ? 1 : 0,
                 savedKnown[0] && !saved[0].empty() ? 1 : 0,
                 savedKnown[1] && !saved[1].empty() ? 1 : 0);
    if (!w->error)
      w->error = Read(2);
    if (!w->error)
      loaded = true;
  }
  if (!w->error && w->vault) {
    ExecuteVault(w);
    Wipe(w->input);
    return;
  }
  if (!w->error) {
    char *out = s3a_call(w->input.c_str());
    w->output = out;
    s3a_free(out);
    w->error = Save(0);
    if (!w->error)
      w->error = Save(1);
    if (!w->error)
      w->error = Save(2);
  }
  if (w->error) {
    s3a_clear();
    for (unsigned slot = 0; slot < 3; ++slot) {
      Wipe(saved[slot]);
      savedKnown[slot] = false;
    }
    loaded = false;
    Wipe(w->output);
  }
  Wipe(w->input);
}
void Complete(napi_env env, napi_status status, void *data) {
  std::unique_ptr<Work> w(static_cast<Work *>(data));
  if (status != napi_ok || w->error) {
    napi_value msg, err;
    napi_create_string_utf8(
        env,
        ("secure_store_or_worker_error:" + std::to_string(w->error)).c_str(),
        NAPI_AUTO_LENGTH, &msg);
    napi_create_error(env, nullptr, msg, &err);
    napi_reject_deferred(env, w->deferred, err);
  } else {
    napi_value result;
    napi_create_string_utf8(env, w->output.data(), w->output.size(), &result);
    napi_resolve_deferred(env, w->deferred, result);
  }
  Wipe(w->output);
  napi_delete_async_work(env, w->work);
}
napi_value Invoke(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2];
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  size_t size = 0;
  if (argc == 0 ||
      napi_get_value_string_utf8(env, args[0], nullptr, 0, &size) != napi_ok ||
      size > 1100000) {
    napi_throw_type_error(env, nullptr, "bounded JSON input required");
    return nullptr;
  }
  auto w = std::make_unique<Work>();
  if (argc == 2 &&
      napi_get_value_bool(env, args[1], &w->expectRegisteredIdentity) != napi_ok) {
    napi_throw_type_error(env, nullptr, "registered identity expectation must be a boolean");
    return nullptr;
  }
  w->input.resize(size + 1);
  napi_get_value_string_utf8(env, args[0], w->input.data(), size + 1, &size);
  w->input.resize(size);
  napi_value promise, name;
  napi_create_promise(env, &w->deferred, &promise);
  napi_create_string_utf8(env, "S3cCoreWorker", NAPI_AUTO_LENGTH, &name);
  if (napi_create_async_work(env, nullptr, name, Execute, Complete, w.get(),
                             &w->work) != napi_ok) {
    napi_throw_error(env, nullptr, "worker_create_failed");
    return nullptr;
  }
  if (napi_queue_async_work(env, w->work) != napi_ok) {
    napi_delete_async_work(env, w->work);
    napi_throw_error(env, nullptr, "worker_queue_failed");
    return nullptr;
  }
  w.release();
  return promise;
}
napi_value VaultInvoke(napi_env env,napi_callback_info info){size_t argc=1;napi_value args[1];void* operation=nullptr;napi_get_cb_info(env,info,&argc,args,nullptr,&operation);auto w=std::make_unique<Work>();w->vault=static_cast<int>(reinterpret_cast<intptr_t>(operation));char binding[513]{};{std::lock_guard<std::mutex> lock(gate);if(s5_unlock_binding(binding,sizeof(binding),&w->generation)!=0){if(w->vault==2){napi_value promise,result;napi_create_promise(env,&w->deferred,&promise);napi_create_string_utf8(env,"{\"available\":false,\"enrolled\":false,\"enabled\":false,\"reason\":\"authenticated_owned_peer_required\"}",NAPI_AUTO_LENGTH,&result);napi_resolve_deferred(env,w->deferred,result);return promise;}napi_throw_error(env,nullptr,"authenticated_owned_peer_required");return nullptr;}}size_t length=strnlen(binding,sizeof(binding));if(!length||length==sizeof(binding)){napi_throw_error(env,nullptr,"invalid_native_binding");return nullptr;}w->binding.assign(binding,length);
if(w->vault==1){size_t size=0;if(argc!=1||napi_get_value_string_utf8(env,args[0],nullptr,0,&size)!=napi_ok||size==0||size>4096){napi_throw_type_error(env,nullptr,"bounded Windows password required");return nullptr;}w->input.resize(size+1);if(napi_get_value_string_utf8(env,args[0],w->input.data(),size+1,&size)!=napi_ok){napi_throw_type_error(env,nullptr,"password_input_failed");return nullptr;}w->input.resize(size);if(w->input.find('\0')!=std::string::npos){napi_throw_type_error(env,nullptr,"invalid_password");return nullptr;}}
else if(w->vault==3){if(argc!=1||napi_get_value_bool(env,args[0],&w->enabled)!=napi_ok){napi_throw_type_error(env,nullptr,"explicit boolean required");return nullptr;}}
napi_value promise,name;if(napi_create_promise(env,&w->deferred,&promise)!=napi_ok)return nullptr;napi_create_string_utf8(env,"WindowsPasswordVault",NAPI_AUTO_LENGTH,&name);if(napi_create_async_work(env,nullptr,name,Execute,Complete,w.get(),&w->work)!=napi_ok){napi_throw_error(env,nullptr,"worker_create_failed");return nullptr;}if(napi_queue_async_work(env,w->work)!=napi_ok){napi_delete_async_work(env,w->work);napi_throw_error(env,nullptr,"worker_queue_failed");return nullptr;}w.release();return promise;}
void Cleanup(void*){s5_audio_stop();std::lock_guard<std::mutex> lock(gate);s3a_clear();for(unsigned slot=0;slot<3;++slot){Wipe(saved[slot]);savedKnown[slot]=false;}loaded=false;}
napi_value Init(napi_env env,napi_value exports){napi_property_descriptor p[]={ {"invoke",nullptr,Invoke,nullptr,nullptr,nullptr,napi_default,nullptr} };napi_define_properties(env,exports,1,p);napi_property_descriptor vault[]={ {"windowsUnlockEnroll",nullptr,VaultInvoke,nullptr,nullptr,nullptr,napi_default,reinterpret_cast<void*>(1)}, {"windowsUnlockStatus",nullptr,VaultInvoke,nullptr,nullptr,nullptr,napi_default,reinterpret_cast<void*>(2)}, {"windowsUnlockSetEnabled",nullptr,VaultInvoke,nullptr,nullptr,nullptr,napi_default,reinterpret_cast<void*>(3)}, {"windowsUnlockDelete",nullptr,VaultInvoke,nullptr,nullptr,nullptr,napi_default,reinterpret_cast<void*>(4)}, {"windowsUnlockUse",nullptr,VaultInvoke,nullptr,nullptr,nullptr,napi_default,reinterpret_cast<void*>(5)} };napi_define_properties(env,exports,5,vault);S4VideoExports(env,exports);InitAdvancedAudio(env,exports);napi_add_env_cleanup_hook(env,Cleanup,nullptr);return exports;}
napi_module module={1,0,nullptr,Init,"s3c",nullptr,{0}};
}
extern "C" __attribute__((constructor)) void Register(){napi_module_register(&module);}
