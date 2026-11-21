#include "exclusive_file.h"
#include <napi/native_api.h>
#include <cstdio>
#include <dirent.h>
#include <linux/fs.h>
#include <strings.h>
#include <string>
static napi_value Create(napi_env env, napi_callback_info info) {
  napi_value args[2]; size_t count = 2; int32_t directory = -1; size_t length = 0;
  napi_get_cb_info(env, info, &count, args, nullptr, nullptr);
  if (count != 2 || napi_get_value_int32(env, args[0], &directory) != napi_ok ||
      napi_get_value_string_utf8(env, args[1], nullptr, 0, &length) != napi_ok || length == 0 || length > 255) {
    napi_throw_error(env, nullptr, "invalid_download_destination"); return nullptr;
  }
  char name[256] {}; size_t copied = 0;
  if (napi_get_value_string_utf8(env, args[1], name, sizeof(name), &copied) != napi_ok || copied != length || std::strlen(name) != length) {
    napi_throw_error(env, nullptr, "invalid_download_name"); return nullptr;
  }
  int fd = uu_create_exclusive(directory, name);
  if (fd < 0) {
    napi_throw_error(env, nullptr, errno == EEXIST ? "download_name_exists_no_overwrite" : "download_exclusive_create_unavailable"); return nullptr;
  }
  napi_value result; napi_create_int32(env, fd, &result); return result;
}
static bool ReadName(napi_env env, napi_value value, char (&name)[256]) {
  size_t bytes = 0, copied = 0;
  return napi_get_value_string_utf8(env, value, nullptr, 0, &bytes) == napi_ok && bytes < sizeof(name) &&
      napi_get_value_string_utf8(env, value, name, sizeof(name), &copied) == napi_ok &&
      bytes == copied && std::strlen(name) == bytes && uu_safe_file_name(name);
}
static std::string Fingerprint(const struct stat& info) {
  return std::to_string(info.st_dev) + ":" + std::to_string(info.st_ino) + ":" +
      std::to_string(info.st_size) + ":" + std::to_string(info.st_mtim.tv_sec) + ":" +
      std::to_string(info.st_mtim.tv_nsec);
}
static napi_value InspectReceived(napi_env env, napi_callback_info info) {
  napi_value args[2]; size_t count = 2; int32_t directory = -1;
  char name[256] {};
  napi_get_cb_info(env, info, &count, args, nullptr, nullptr);
  if (count != 2 || napi_get_value_int32(env, args[0], &directory) != napi_ok ||
      !ReadName(env, args[1], name)) {
    napi_throw_error(env, nullptr, "invalid_history_file"); return nullptr;
  }
  struct stat current {};
  const std::string fingerprint = fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0 &&
      S_ISREG(current.st_mode) ? Fingerprint(current) : "";
  napi_value result;
  napi_create_string_utf8(env, fingerprint.c_str(), fingerprint.size(), &result);
  return result;
}
static napi_value FinishTemporary(napi_env env, napi_callback_info info) {
  napi_value args[3]; size_t count = 3; int32_t directory = -1;
  char part[256] {}, destination[256] {};
  napi_get_cb_info(env, info, &count, args, nullptr, nullptr);
  if (count < 2 || napi_get_value_int32(env, args[0], &directory) != napi_ok ||
      !ReadName(env, args[1], part) || std::strncmp(part, ".uu-partial-", 12) != 0 ||
      (count == 3 && !ReadName(env, args[2], destination))) {
    napi_throw_error(env, nullptr, "invalid_download_destination"); return nullptr;
  }
  int code;
  std::string fingerprint;
  if (count == 3) {
    struct stat pending {};
    if (fstatat(directory, part, &pending, AT_SYMLINK_NOFOLLOW) != 0 || !S_ISREG(pending.st_mode)) {
      napi_throw_error(env, nullptr, "download_publish_failed"); return nullptr;
    }
    fingerprint = Fingerprint(pending);
    code = renameat2(directory, part, directory, destination, RENAME_NOREPLACE);
    if (code < 0 && (errno == ENOSYS || errno == EINVAL || errno == EOPNOTSUPP)) {
      code = linkat(directory, part, directory, destination, 0);
      if (code == 0) unlinkat(directory, part, 0);
    }
  } else {
    code = unlinkat(directory, part, 0);
    if (code < 0 && errno == ENOENT) code = 0;
  }
  if (code < 0) {
    napi_throw_error(env, nullptr, errno == EEXIST ? "download_name_exists_no_overwrite" : "download_publish_failed");
    return nullptr;
  }
  napi_value result; napi_create_string_utf8(env, fingerprint.c_str(), fingerprint.size(), &result); return result;
}
static napi_value RemoveReceived(napi_env env, napi_callback_info info) {
  napi_value args[3]; size_t count = 3; int32_t directory = -1;
  char name[256] {}, fingerprint[256] {};
  napi_get_cb_info(env, info, &count, args, nullptr, nullptr);
  if (count != 3 || napi_get_value_int32(env, args[0], &directory) != napi_ok ||
      !ReadName(env, args[1], name) || !ReadName(env, args[2], fingerprint)) {
    napi_throw_error(env, nullptr, "invalid_transfer_history_entry"); return nullptr;
  }
  struct stat current {};
  int status = 0;
  if (fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) != 0) {
    status = errno == ENOENT ? 0 : -1;
  } else if (!S_ISREG(current.st_mode) || Fingerprint(current) != fingerprint) {
    status = 1;
  } else if (unlinkat(directory, name, 0) != 0 && errno != ENOENT) {
    status = -1;
  }
  napi_value result; napi_create_int32(env, status, &result); return result;
}
static napi_value ListDirectory(napi_env env, napi_callback_info info) {
  size_t count = 1;
  napi_value arg = nullptr;
  int32_t directory = -1;
  napi_get_cb_info(env, info, &count, &arg, nullptr, nullptr);
  if (count != 1 || napi_get_value_int32(env, arg, &directory) != napi_ok) {
    napi_throw_error(env, nullptr, "invalid_local_directory"); return nullptr;
  }
  const int fd = openat(directory, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  DIR* stream = fd < 0 ? nullptr : fdopendir(fd);
  if (!stream) {
    if (fd >= 0) close(fd);
    napi_throw_error(env, nullptr, "local_directory_read_failed"); return nullptr;
  }
  napi_value result;
  napi_create_array(env, &result);
  uint32_t position = 0;
  while (position < 1024) {
    errno = 0;
    const dirent* item = readdir(stream);
    if (!item) {
      if (errno) {
        closedir(stream);
        napi_throw_error(env, nullptr, "local_directory_read_failed"); return nullptr;
      }
      break;
    }
    const char* name = item->d_name;
    if (!uu_safe_file_name(name) || strncasecmp(name, ".uu-partial-", 12) == 0) continue;
    struct stat entry {};
    if (fstatat(fd, name, &entry, AT_SYMLINK_NOFOLLOW) != 0 ||
        (!S_ISDIR(entry.st_mode) && !S_ISREG(entry.st_mode))) continue;
    if (entry.st_size < 0 || entry.st_size > 9007199254740991LL) continue;
    napi_value row, field;
    napi_create_object(env, &row);
    if (napi_create_string_utf8(env, name, NAPI_AUTO_LENGTH, &field) != napi_ok) continue;
    napi_set_named_property(env, row, "name", field);
    napi_create_int32(env, S_ISDIR(entry.st_mode) ? 0 : 4, &field);
    napi_set_named_property(env, row, "kind", field);
    napi_create_double(env, static_cast<double>(entry.st_size), &field);
    napi_set_named_property(env, row, "size", field);
    napi_create_double(env, static_cast<double>(entry.st_mtime), &field);
    napi_set_named_property(env, row, "modified", field);
    napi_set_element(env, result, position++, row);
  }
  closedir(stream);
  return result;
}
static napi_value Init(napi_env env, napi_value exports) {
  const napi_property_descriptor properties[] = {
    {"createExclusive", nullptr, Create, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"finishTemporary", nullptr, FinishTemporary, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"listDirectory", nullptr, ListDirectory, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"removeReceived", nullptr, RemoveReceived, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"inspectReceived", nullptr, InspectReceived, nullptr, nullptr, nullptr, napi_default, nullptr},
  };
  napi_define_properties(env, exports, sizeof(properties)/sizeof(properties[0]), properties); return exports;
}
static napi_module module = {1, 0, nullptr, Init, "uufiles", nullptr, {0}};
extern "C" __attribute__((constructor)) void RegisterFiles() { napi_module_register(&module); }
