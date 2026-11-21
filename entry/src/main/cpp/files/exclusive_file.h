#pragma once
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

// Accept only an already authorized directory descriptor and one leaf name.
// Never resolve a picker URI or construct an absolute path in native code.
inline bool uu_safe_file_name(const char* name) {
  if (!name || !*name || std::strlen(name) > 255 || !std::strcmp(name, ".") || !std::strcmp(name, "..")) return false;
  for (const unsigned char* p = reinterpret_cast<const unsigned char*>(name); *p; ++p) {
    if (*p < 32 || *p == 127 || *p == '/' || *p == '\\') return false;
  }
  return true;
}

inline int uu_create_exclusive(int directory, const char* name) {
  if (!uu_safe_file_name(name)) { errno = EINVAL; return -1; }
  struct stat st {};
  if (fstat(directory, &st) != 0) return -1;
  if (!S_ISDIR(st.st_mode)) { errno = ENOTDIR; return -1; }
  return openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
}
