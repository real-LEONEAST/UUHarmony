#include <multimedia/player_framework/native_avcapability.h>
#include <napi/native_api.h>
#include <multimodalinput/oh_input_manager.h>
#include <cstdint>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <vector>
#include <fcntl.h>
#include <unistd.h>
#include "share_size.h"
extern "C" {
int uu_host_init(const char*, uint32_t, uint32_t, const char*);
int uu_host_login();
bool uu_unified_running();
bool uu_host_logged_in();
bool uu_host_online();
int uu_host_publish_cover(const uint8_t*, size_t);
bool uu_host_receiving_files();
uint64_t uu_host_receive_command();
int uu_host_set_receiving_files(bool, uint64_t, int, const char*);
uint32_t uu_host_capture_requests();
bool uu_host_wants_embedded_cursor();
int uu_host_start();
void uu_host_stop();
int x11_release_all();
int uu_media_start_options_for_pc(int, int, bool, int, bool, bool);
int uu_host_set_dimensions(uint32_t, uint32_t);
int uu_host_set_display(uint32_t, uint32_t, uint32_t, uint32_t);
uint64_t uu_host_stream_size();
void uu_input_set_display(int, int, int);
void uu_media_stop();
int uu_media_state();
uint64_t uu_media_frame_count();
uint64_t uu_media_output_size();
uint64_t uu_host_audio_frames();
int uu_assist_set_enabled(bool);
int uu_assist_reset_code();
}
void UnifiedAccountExports(napi_env,napi_value);
namespace steamsir::ohos {
extern std::mutex ui_mutex;
extern std::string message;
extern std::vector<uint8_t> qr;
extern int qr_edge;
extern uint32_t qr_version;
extern bool refresh;
extern std::string assistance_id;
extern std::string assistance_code;
extern bool assistance_allowed;

napi_value Integer(napi_env env, int64_t value) {
  napi_value result; napi_create_int64(env, value, &result); return result;
}
napi_value Initialize(napi_env env, napi_callback_info info) {
  napi_value args[4]; size_t count = 4;
  napi_get_cb_info(env, info, &count, args, nullptr, nullptr);
  if (count != 4) { napi_throw_type_error(env, nullptr, "Expected config path, display dimensions and language"); return nullptr; }
  size_t length = 0;
  if (napi_get_value_string_utf8(env, args[0], nullptr, 0, &length) != napi_ok || length > 4096) return Integer(env, -1);
  std::vector<char> path(length + 1);
  uint32_t width = 0, height = 0;
  char language[3] = {};
  size_t language_length = 0;
  if (napi_get_value_string_utf8(env, args[0], path.data(), path.size(), &length) != napi_ok ||
      napi_get_value_uint32(env, args[1], &width) != napi_ok || napi_get_value_uint32(env, args[2], &height) != napi_ok ||
      napi_get_value_string_utf8(env, args[3], nullptr, 0, &language_length) != napi_ok || language_length != 2 ||
      napi_get_value_string_utf8(env, args[3], language, sizeof(language), &language_length) != napi_ok) return Integer(env, -1);
  return Integer(env, uu_host_init(path.data(), width, height, language));
}
napi_value Login(napi_env env, napi_callback_info) { return Integer(env, uu_host_login()); }
napi_value StartHost(napi_env env, napi_callback_info) { return Integer(env, uu_host_start()); }
void ReleaseCapture() {
  uu_media_stop();
  x11_release_all();
}
napi_value StopCapture(napi_env env, napi_callback_info) { ReleaseCapture(); return Integer(env, 0); }
napi_value ConfigureDisplay(napi_env env,napi_callback_info info) {
  napi_value args[4];size_t count=4;napi_get_cb_info(env,info,&count,args,nullptr,nullptr);
  int32_t w=0,h=0,id=-1;
  bool smooth = false;
  if (count < 3 || (count == 4 && napi_get_value_bool(env, args[3], &smooth) != napi_ok) ||
      napi_get_value_int32(env,args[0],&w)!=napi_ok||napi_get_value_int32(env,args[1],&h)!=napi_ok||
      napi_get_value_int32(env,args[2],&id)!=napi_ok||id<0||w<1||h<1||w>8192||h>8192) return Integer(env,-1);
  uu::pc::ShareSize stream{0, 0};
  if (smooth) {
    auto* capability = OH_AVCodec_GetCapability("video/avc", true);
    int32_t width_alignment = 0, height_alignment = 0;
    if (!capability || OH_AVCapability_GetVideoWidthAlignment(capability, &width_alignment) != AV_ERR_OK ||
        OH_AVCapability_GetVideoHeightAlignment(capability, &height_alignment) != AV_ERR_OK ||
        width_alignment < 1 || height_alignment < 1 || width_alignment > w || height_alignment > h) return Integer(env, -2);
    stream = uu::pc::SmoothShareSize(w, h, width_alignment, height_alignment);
    if (stream.width < 1 || stream.height < 1 ||
        !OH_AVCapability_AreVideoSizeAndFrameRateSupported(capability, stream.width, stream.height, 30)) return Integer(env, -2);
  }
  if (uu_host_set_display(w, h, stream.width, stream.height) != 0) return Integer(env,-1);
  uu_input_set_display(id,w,h);return Integer(env,0);
}
napi_value Stop(napi_env env, napi_callback_info) {
  uu_host_stop();
  ReleaseCapture();
  // Ending a sharing session releases input without revoking the user's grant.
  return Integer(env, 0);
}
struct CaptureStopWork {
  napi_deferred deferred = nullptr;
  napi_async_work work = nullptr;
  bool stop_host = false;
};
napi_value QueueCaptureStop(napi_env env, bool stop_host) {
  auto task = std::make_unique<CaptureStopWork>();
  task->stop_host = stop_host;
  napi_value promise = nullptr, name = nullptr;
  if (napi_create_promise(env, &task->deferred, &promise) != napi_ok) return nullptr;
  auto status = napi_create_string_utf8(env, "UUHostCaptureStop", NAPI_AUTO_LENGTH, &name);
  if (status == napi_ok) {
    status = napi_create_async_work(env, nullptr, name,
      [](napi_env, void* data) {
        auto* work = static_cast<CaptureStopWork*>(data);
        if (work->stop_host) uu_host_stop();
        ReleaseCapture();
      },
      [](napi_env complete_env, napi_status result, void* data) {
        std::unique_ptr<CaptureStopWork> work(static_cast<CaptureStopWork*>(data));
        napi_resolve_deferred(complete_env, work->deferred, Integer(complete_env, result == napi_ok ? 0 : -1));
        napi_delete_async_work(complete_env, work->work);
      }, task.get(), &task->work);
  }
  if (status == napi_ok) status = napi_queue_async_work(env, task->work);
  if (status != napi_ok) {
    if (task->work) napi_delete_async_work(env, task->work);
    napi_resolve_deferred(env, task->deferred, Integer(env, -1));
  } else {
    task.release();
  }
  return promise;
}
napi_value StopAsync(napi_env env, napi_callback_info) { return QueueCaptureStop(env, true); }
napi_value StopCaptureAsync(napi_env env, napi_callback_info) { return QueueCaptureStop(env, false); }
napi_value StartCapture(napi_env env, napi_callback_info info) {
  napi_value args[5]; size_t count = 5; napi_get_cb_info(env, info, &count, args, nullptr, nullptr);
  int32_t width = 0, height = 0, display_id = 0;
  bool sound = false, primary = false;
  if (count < 3 || (count >= 4 && napi_get_value_bool(env,args[3],&sound)!=napi_ok) ||
      (count >= 5 && napi_get_value_bool(env,args[4],&primary)!=napi_ok) || napi_get_value_int32(env, args[0], &width) != napi_ok ||
      napi_get_value_int32(env, args[1], &height) != napi_ok ||
      napi_get_value_int32(env, args[2], &display_id) != napi_ok || display_id < 0 || width < 1 || height < 1 || width > 8192 || height > 8192) return Integer(env, -1);
  if (!uu_unified_running() && uu_host_set_dimensions(width, height) != 0) return Integer(env, -1);
  uu_input_set_display(display_id, width, height);
  const uint64_t size = uu_host_stream_size();
  const int stream_width = size ? static_cast<int>(size >> 32) : width;
  const int stream_height = size ? static_cast<int>(uint32_t(size)) : height;
  const bool show_cursor = !primary && (uu_host_capture_requests() == 0 || uu_host_wants_embedded_cursor());
  return Integer(env, uu_media_start_options_for_pc(stream_width, stream_height, sound, size ? 30 : 60, show_cursor, primary));
}
void OnAuthorized(Input_InjectionStatus) {}
napi_value RequestInput(napi_env env, napi_callback_info) {
  Input_InjectionStatus authorization = UNAUTHORIZED;
  Input_Result result = OH_Input_QueryAuthorizedStatus(&authorization);
  if (result != INPUT_SUCCESS) return Integer(env, result);
  if (authorization == AUTHORIZED || authorization == AUTHORIZING) {
    return Integer(env, INPUT_SUCCESS);
  }
  result = OH_Input_RequestInjection(OnAuthorized);
  if (result == INPUT_INJECTION_AUTHORIZED ||
      result == INPUT_INJECTION_AUTHORIZING) {
    return Integer(env, INPUT_SUCCESS);
  }
  return Integer(env, result);
}
napi_value Refresh(napi_env env, napi_callback_info) {
  std::lock_guard<std::mutex> lock(ui_mutex); refresh = true; return Integer(env, 0);
}
napi_value IsReceivingFiles(napi_env env, napi_callback_info) {
  napi_value result;
  napi_get_boolean(env, uu_host_receiving_files(), &result);
  return result;
}
struct ReceiveFilesWork {
  napi_deferred deferred = nullptr;
  napi_async_work work = nullptr;
  bool enabled = false;
  uint64_t ticket = 0;
  int descriptor = -1;
  std::string root;
  int result = -1;
  ~ReceiveFilesWork() { if (descriptor >= 0) close(descriptor); }
};
napi_value SetReceivingFiles(napi_env env, napi_callback_info info) {
  auto task = std::make_unique<ReceiveFilesWork>();
  napi_value args[3] {}, promise = nullptr, name = nullptr;
  size_t count = 3;
  if (napi_create_promise(env, &task->deferred, &promise) != napi_ok) return nullptr;
  auto status = napi_get_cb_info(env, info, &count, args, nullptr, nullptr);
  if (status == napi_ok && count < 1) status = napi_invalid_arg;
  if (status == napi_ok) status = napi_get_value_bool(env, args[0], &task->enabled);
  if (status == napi_ok && task->enabled) {
    char root[4096] {};
    size_t copied = 0;
    int32_t descriptor = -1;
    if (count != 3 || napi_get_value_int32(env, args[1], &descriptor) != napi_ok || descriptor < 0 ||
        napi_get_value_string_utf8(env, args[2], root, sizeof(root), &copied) != napi_ok ||
        copied == 0 || copied >= sizeof(root) - 1 || std::strlen(root) != copied) {
      status = napi_invalid_arg;
    } else {
      task->root.assign(root, copied);
      task->descriptor = fcntl(descriptor, F_DUPFD_CLOEXEC, 0);
      if (task->descriptor < 0) status = napi_invalid_arg;
    }
  }
  if (status == napi_ok) status = napi_create_string_utf8(env, "UUHostReceiveFiles", NAPI_AUTO_LENGTH, &name);
  if (status == napi_ok) {
    task->ticket = uu_host_receive_command();
    status = napi_create_async_work(env, nullptr, name,
      [](napi_env, void* data) {
        auto* job = static_cast<ReceiveFilesWork*>(data);
        job->result = uu_host_set_receiving_files(job->enabled, job->ticket, job->descriptor, job->root.c_str());
      },
      [](napi_env complete_env, napi_status outcome, void* data) {
        std::unique_ptr<ReceiveFilesWork> job(static_cast<ReceiveFilesWork*>(data));
        napi_resolve_deferred(complete_env, job->deferred, Integer(complete_env, outcome == napi_ok ? job->result : -1));
        napi_delete_async_work(complete_env, job->work);
      }, task.get(), &task->work);
  }
  if (status == napi_ok) status = napi_queue_async_work(env, task->work);
  if (status != napi_ok) {
    if (task->work) napi_delete_async_work(env, task->work);
    napi_resolve_deferred(env, task->deferred, Integer(env, -1));
  } else {
    task.release();
  }
  return promise;
}
napi_value State(napi_env env, napi_callback_info) {
  napi_value out, value; napi_create_object(env, &out);
  { std::lock_guard<std::mutex> lock(ui_mutex);
    napi_create_string_utf8(env, message.c_str(), message.size(), &value); napi_set_named_property(env, out, "message", value);
    napi_set_named_property(env, out, "qrVersion", Integer(env, qr_version));
    napi_set_named_property(env, out, "qrEdge", Integer(env, qr_edge));
    napi_create_string_utf8(env, assistance_id.c_str(), assistance_id.size(), &value);
    napi_set_named_property(env, out, "assistanceDeviceId", value);
    napi_create_string_utf8(env, assistance_code.c_str(), assistance_code.size(), &value);
    napi_set_named_property(env, out, "assistanceCode", value);
    napi_get_boolean(env, assistance_allowed, &value);
    napi_set_named_property(env, out, "assistanceEnabled", value);
  }
  napi_get_boolean(env, uu_host_logged_in(), &value); napi_set_named_property(env, out, "loggedIn", value);
  napi_get_boolean(env, uu_unified_running(), &value); napi_set_named_property(env,out,"serverRunning",value);
  napi_get_boolean(env, uu_host_online(), &value); napi_set_named_property(env,out,"online",value);
  napi_set_named_property(env,out,"captureRequests",Integer(env,uu_host_capture_requests()));
  const bool encoder = OH_AVCodec_GetCapabilityByCategory("video/avc",true,HARDWARE) || OH_AVCodec_GetCapabilityByCategory("video/avc",true,SOFTWARE);
  napi_get_boolean(env,encoder,&value); napi_set_named_property(env,out,"encoderAvailable",value);
  napi_set_named_property(env, out, "captureState", Integer(env, uu_media_state()));
  const uint64_t size = uu_host_stream_size();
  napi_set_named_property(env, out, "streamWidth", Integer(env, size >> 32));
  napi_set_named_property(env, out, "streamHeight", Integer(env, uint32_t(size)));
  const uint64_t output = uu_media_output_size();
  napi_set_named_property(env, out, "encodedWidth", Integer(env, output >> 32));
  napi_set_named_property(env, out, "encodedHeight", Integer(env, uint32_t(output)));
  napi_set_named_property(env, out, "frames", Integer(env, uu_media_frame_count()));
  napi_set_named_property(env, out, "audioFrames", Integer(env, uu_host_audio_frames()));
  Input_InjectionStatus permission = UNAUTHORIZED;
  OH_Input_QueryAuthorizedStatus(&permission);
  napi_set_named_property(env, out, "inputState", Integer(env, permission));
  return out;
}
napi_value Qr(napi_env env, napi_callback_info) {
  std::lock_guard<std::mutex> lock(ui_mutex);
  napi_value result; void* data = nullptr;
  if (napi_create_arraybuffer(env, qr.size(), &data, &result) != napi_ok) return nullptr;
  if (!qr.empty()) std::memcpy(data, qr.data(), qr.size()); return result;
}
napi_value SetAssistanceEnabled(napi_env env, napi_callback_info info) {
  napi_value argument;
  size_t count = 1;
  bool enabled = false;
  napi_get_cb_info(env, info, &count, &argument, nullptr, nullptr);
  if (count != 1 || napi_get_value_bool(env, argument, &enabled) != napi_ok) return Integer(env, -1);
  return Integer(env, uu_assist_set_enabled(enabled));
}
napi_value ResetAssistanceCode(napi_env env, napi_callback_info) {
  return Integer(env, uu_assist_reset_code());
}
struct CoverWork {
  napi_deferred deferred = nullptr;
  napi_async_work work = nullptr;
  std::vector<uint8_t> data;
  int result = -1;
};
napi_value PublishCover(napi_env env, napi_callback_info info) {
  napi_value arg = nullptr, promise = nullptr, name = nullptr;
  size_t argc = 1, size = 0;
  void* bytes = nullptr;
  if (napi_get_cb_info(env, info, &argc, &arg, nullptr, nullptr) != napi_ok || argc != 1 ||
      napi_get_arraybuffer_info(env, arg, &bytes, &size) != napi_ok || !bytes || !size || size > 2 * 1024 * 1024) {
    napi_throw_error(env, nullptr, "invalid_cover"); return nullptr;
  }
  auto task = std::make_unique<CoverWork>();
  if (napi_create_promise(env, &task->deferred, &promise) != napi_ok) return nullptr;
  const auto* start = static_cast<const uint8_t*>(bytes);
  task->data.assign(start, start + size);
  auto status = napi_create_string_utf8(env, "UUHostPublishCover", NAPI_AUTO_LENGTH, &name);
  if (status == napi_ok) {
    status = napi_create_async_work(env, nullptr, name, [](napi_env, void* opaque) {
      auto* job = static_cast<CoverWork*>(opaque);
      job->result = uu_host_publish_cover(job->data.data(), job->data.size());
    }, [](napi_env current, napi_status outcome, void* opaque) {
      std::unique_ptr<CoverWork> job(static_cast<CoverWork*>(opaque));
      napi_resolve_deferred(current, job->deferred, Integer(current, outcome == napi_ok ? job->result : -1));
      napi_delete_async_work(current, job->work);
    }, task.get(), &task->work);
  }
  if (status == napi_ok) status = napi_queue_async_work(env, task->work);
  if (status == napi_ok) task.release();
  else {
    if (task->work) napi_delete_async_work(env, task->work);
    napi_resolve_deferred(env, task->deferred, Integer(env, -1));
  }
  return promise;
}

napi_value Register(napi_env env, napi_value exports) {
  napi_property_descriptor properties[] = {
    {"initialize", nullptr, Initialize, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"beginLogin", nullptr, Login, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"refreshQr", nullptr, Refresh, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"startHost", nullptr, StartHost, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"configureDisplay", nullptr, ConfigureDisplay, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"stopCapture", nullptr, StopCapture, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"stopCaptureAsync", nullptr, StopCaptureAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"startCapture", nullptr, StartCapture, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"stop", nullptr, Stop, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"stopAsync", nullptr, StopAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"requestInput", nullptr, RequestInput, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"getState", nullptr, State, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"setAssistanceEnabled", nullptr, SetAssistanceEnabled, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"isReceivingFiles", nullptr, IsReceivingFiles, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"setReceivingFiles", nullptr, SetReceivingFiles, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"publishDeviceCover", nullptr, PublishCover, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"resetAssistanceCode", nullptr, ResetAssistanceCode, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"getQrPixels", nullptr, Qr, nullptr, nullptr, nullptr, napi_default, nullptr},
  };
  napi_define_properties(env, exports, sizeof(properties) / sizeof(properties[0]), properties); UnifiedAccountExports(env,exports); return exports;
}
}  // namespace steamsir::ohos
static napi_module module = {1, 0, nullptr, steamsir::ohos::Register, "uuhost", nullptr, {0}};
extern "C" __attribute__((constructor)) void RegisterEntry() { napi_module_register(&module); }
