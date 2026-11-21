#pragma once
#include <cstddef>
#include <cstdint>
#include <limits>
#include <string>

namespace s5video {
constexpr int kInitialWidth = 1280;
constexpr int kInitialHeight = 720;
constexpr int kDrainMs = 1000;
constexpr size_t kRendererSlots = 3;

struct FirstFailure {
    std::string stage, kind;
    int error = 0, systemCode = 0;
    bool hasSystemCode = false;
    void Observe(int code, const char *operation, bool system) {
        if (code == 0 || !stage.empty()) return;
        stage = operation; error = code; hasSystemCode = system; systemCode = code;
        kind = system ? "system" : "local";
    }
};

// Decimal uint64 Surface IDs only; no sign, whitespace, suffix or overflow.
inline bool ParseSurfaceId(const char *text, size_t size, uint64_t &result)
{
    if (!text || size == 0 || size > 20) return false;
    uint64_t value = 0;
    for (size_t i = 0; i < size; ++i) {
        if (text[i] < '0' || text[i] > '9') return false;
        const unsigned digit = static_cast<unsigned>(text[i] - '0');
        if (value > (std::numeric_limits<uint64_t>::max() - digit) / 10) return false;
        value = value * 10 + digit;
    }
    if (value == 0) return false;
    result = value;
    return true;
}

struct NalObservation {
    bool vps = false, sps = false, pps = false, idr = false;
    int profileIdc = -1, levelIdc = -1;
};
// Inspect bounded Annex B bytes, never retain or log the media payload.
inline NalObservation ObserveAnnexB(const uint8_t *bytes, size_t size, int codec = 1)
{
    NalObservation result;
    if (!bytes) return result;
    for (size_t i = 0; i + 3 < size; ++i) {
        if (bytes[i] != 0 || bytes[i + 1] != 0) continue;
        size_t header = 0;
        if (bytes[i + 2] == 1) header = i + 3;
        else if (i + 4 < size && bytes[i + 2] == 0 && bytes[i + 3] == 1) header = i + 4;
        if (!header || header >= size) continue;
        const unsigned type = codec == 2 ? (bytes[header] >> 1) & 63 : bytes[header] & 31;
        result.vps |= codec == 2 && type == 32;
        result.sps |= codec == 2 ? type == 33 : type == 7;
        result.pps |= codec == 2 ? type == 34 : type == 8;
        result.idr |= codec == 2 ? (type >= 16 && type <= 21) : type == 5;
        if (codec == 1 && type == 7 && header + 3 < size) {
            result.profileIdc = bytes[header + 1];
            result.levelIdc = bytes[header + 3];
        }
        i = header;
    }
    return result;
}

inline bool UseSoftwareRgba(bool hardware, bool pixelQueryOk, bool hasRgba)
{
    return !hardware && pixelQueryOk && hasRgba;
}
inline bool CanFallback(bool hardware, unsigned attempts, bool softwareEligible,
                        bool createUnavailable, bool configureUnsupported, bool stopping)
{
    return hardware && attempts == 1 && softwareEligible && !stopping &&
        (createUnavailable || configureUnsupported);
}
inline bool DrainExpired(int64_t nowMs, int64_t requestedMs)
{
    return requestedMs > 0 && nowMs - requestedMs >= kDrainMs;
}
} // namespace s5video
