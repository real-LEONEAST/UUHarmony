#include <algorithm>
#include <asset/asset_api.h>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <sstream>
#include <string>

namespace {
constexpr size_t kChunk = 1024, kMax = 32 * 1024;
std::mutex gate;
std::string cached;
bool loaded = false;
unsigned bank = 0;
void Wipe(std::string &text) {
  volatile char *p = text.data();
  for (size_t i = 0; i < text.size(); i++)
    p[i] = 0;
  text.clear();
}
Asset_Attr Blob(uint32_t tag, const std::string &value) {
  Asset_Attr a{};
  a.tag = tag;
  a.value.blob = {
      static_cast<uint32_t>(value.size()),
      reinterpret_cast<uint8_t *>(const_cast<char *>(value.data()))};
  return a;
}
Asset_Attr Number(uint32_t tag, uint32_t value) {
  Asset_Attr a{};
  a.tag = tag;
  a.value.u32 = value;
  return a;
}
std::string Alias(const std::string &suffix) {
  return "UUHarmony.PCHost.Config.v1." + suffix;
}
int Read(const std::string &suffix, std::string &value) {
  const auto alias = Alias(suffix);
  Asset_Attr query[] = {Blob(ASSET_TAG_ALIAS, alias),
                        Number(ASSET_TAG_RETURN_TYPE, ASSET_RETURN_ALL)};
  Asset_ResultSet rows{};
  const int code = OH_Asset_Query(query, 2, &rows);
  if (code == ASSET_NOT_FOUND)
    return 1;
  if (code != 0)
    return -1;
  int result = -1;
  if (rows.count == 1) {
    auto *item = OH_Asset_ParseAttr(&rows.results[0], ASSET_TAG_SECRET);
    if (item && item->value.blob.size > 0 && item->value.blob.size <= kChunk) {
      value.assign(reinterpret_cast<char *>(item->value.blob.data),
                   item->value.blob.size);
      result = 0;
    }
  }
  OH_Asset_FreeResultSet(&rows);
  return result;
}
int Put(const std::string &suffix, const std::string &value) {
  const auto alias = Alias(suffix);
  Asset_Attr query = Blob(ASSET_TAG_ALIAS, alias),
             secret = Blob(ASSET_TAG_SECRET, value);
  int code = OH_Asset_Update(&query, 1, &secret, 1);
  if (code == ASSET_NOT_FOUND) {
    Asset_Attr attrs[] = {
        query, secret,
        Number(ASSET_TAG_ACCESSIBILITY, ASSET_ACCESSIBILITY_DEVICE_UNLOCKED),
        Number(ASSET_TAG_SYNC_TYPE, ASSET_SYNC_TYPE_NEVER)};
    code = OH_Asset_Add(attrs, 4);
  }
  return code == 0 ? 0 : -1;
}
uint64_t Check(const std::string &value) {
  uint64_t hash = 14695981039346656037ull;
  for (unsigned char byte : value) {
    hash ^= byte;
    hash *= 1099511628211ull;
  }
  return hash;
}
int Load() {
  if (loaded)
    return 0;
  std::string meta;
  const int code = Read("active", meta);
  if (code == 1) {
    loaded = true;
    return 0;
  }
  if (code != 0)
    return -1;
  unsigned version = 0, next = 0;
  size_t size = 0;
  uint64_t expected = 0;
  std::istringstream in(meta);
  if (!(in >> version >> next >> size >> expected) || version != 1 ||
      next > 1 || size == 0 || size > kMax)
    return -1;
  std::string value;
  value.reserve(size);
  for (size_t at = 0; at < size; at += kChunk) {
    std::string part;
    if (Read(std::to_string(next) + "." + std::to_string(at / kChunk), part) !=
            0 ||
        part.size() != std::min(kChunk, size - at)) {
      Wipe(part);
      Wipe(value);
      return -1;
    }
    value += part;
    Wipe(part);
  }
  if (Check(value) != expected) {
    Wipe(value);
    return -1;
  }
  bank = next;
  cached.swap(value);
  Wipe(value);
  loaded = true;
  return 0;
}
struct Cleaner {
  ~Cleaner() { Wipe(cached); }
} cleaner;
} // namespace
extern "C" int uu_host_config_read(uint8_t *data, size_t capacity) {
  std::lock_guard<std::mutex> lock(gate);
  if (Load() != 0 || cached.size() > capacity || (!data && !cached.empty()))
    return -1;
  if (!cached.empty())
    std::memcpy(data, cached.data(), cached.size());
  return static_cast<int>(cached.size());
}
extern "C" int uu_host_config_write(const uint8_t *data, size_t length) {
  std::lock_guard<std::mutex> lock(gate);
  if (!data || length == 0 || length > kMax || Load() != 0)
    return -1;
  std::string value(reinterpret_cast<const char *>(data), length);
  if (value == cached) {
    Wipe(value);
    return 0;
  }
  const unsigned next = 1 - bank;
  for (size_t at = 0; at < length; at += kChunk) {
    std::string part = value.substr(at, kChunk);
    const int code =
        Put(std::to_string(next) + "." + std::to_string(at / kChunk), part);
    Wipe(part);
    if (code != 0) {
      Wipe(value);
      return -1;
    }
  }
  const std::string meta = "1 " + std::to_string(next) + " " +
                           std::to_string(length) + " " +
                           std::to_string(Check(value));
  if (Put("active", meta) != 0) {
    Wipe(value);
    return -1;
  }
  Wipe(cached);
  cached.swap(value);
  bank = next;
  loaded = true;
  Wipe(value);
  return 0;
}
