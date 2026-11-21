#include <napi/native_api.h>
#include <hilog/log.h>
#include <multimedia/player_framework/native_avcodec_videodecoder.h>
#include <multimedia/player_framework/native_avcapability.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avformat.h>
#include <native_window/external_window.h>
#include "video_policy.h"
#include "video_orientation.h"
#include <dlfcn.h>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <deque>
#include <mutex>
#include <string>
#include <vector>
#include <algorithm>
#include <array>
#include <cmath>
#include <memory>

namespace {
using Clock = std::chrono::steady_clock;
int64_t NowMs() { return std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now().time_since_epoch()).count(); }
const std::string kIdleStatus = R"({"ready":false,"running":false,"phase":"idle","error":0,"failureStage":null,"systemCode":null})";
void Log(const char *fmt, ...)
{
    char line[2048]; va_list args; va_start(args, fmt); vsnprintf(line, sizeof(line), fmt, args); va_end(args);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xA26, "UUS4VIDEO", "%{public}s", line);
}
std::string Bool(bool value) { return value ? "true" : "false"; }
std::string Quote(const std::string &text)
{
    std::string result = "\"";
    for (unsigned char ch : text) {
        if (ch == '\\' || ch == '"') { result += '\\'; result += static_cast<char>(ch); }
        else if (ch < 32) { char escaped[7]; snprintf(escaped, sizeof(escaped), "\\u%04x", ch); result += escaped; }
        else result += static_cast<char>(ch);
    }
    return result + "\"";
}
std::string IntArray(const int32_t *items, uint32_t count)
{
    std::string result = "[";
    if (items) for (uint32_t i = 0; i < std::min(count, 64u); ++i) { if (i) result += ','; result += std::to_string(items[i]); }
    return result + "]";
}
struct Capability {
    OH_AVCapability *cap = nullptr;
    bool hardware = false, sizeSupported = false, rgba = false;
    int pixelCode = -1;
    std::string name, json;
};
Capability QueryCapability(OH_AVCodecCategory category, int codec = 1)
{
    Capability c;
    c.cap = OH_AVCodec_GetCapabilityByCategory(codec == 2 ? OH_AVCODEC_MIMETYPE_VIDEO_HEVC : OH_AVCODEC_MIMETYPE_VIDEO_AVC, false, category);
    if (!c.cap) { c.json = "{\"category\":" + Quote(category == HARDWARE ? "hardware" : "software") + ",\"available\":false}"; return c; }
    const char *name = OH_AVCapability_GetName(c.cap);
    c.name = name ? name : ""; c.hardware = OH_AVCapability_IsHardware(c.cap);
    c.sizeSupported = OH_AVCapability_IsVideoSizeSupported(c.cap, s5video::kInitialWidth, s5video::kInitialHeight);
    const int32_t *pixels = nullptr, *profiles = nullptr; uint32_t pixelCount = 0, profileCount = 0;
    c.pixelCode = OH_AVCapability_GetVideoSupportedPixelFormats(c.cap, &pixels, &pixelCount);
    const int profileCode = OH_AVCapability_GetSupportedProfiles(c.cap, &profiles, &profileCount);
    if (c.pixelCode == AV_ERR_OK && pixels) for (uint32_t i = 0; i < std::min(pixelCount, 64u); ++i) c.rgba |= pixels[i] == AV_PIXEL_FORMAT_RGBA;
    OH_AVRange widths{}, heights{}, rates{}; int32_t wa = 0, ha = 0;
    const int wc = OH_AVCapability_GetVideoWidthRange(c.cap, &widths), hc = OH_AVCapability_GetVideoHeightRange(c.cap, &heights);
    const int rc = OH_AVCapability_GetVideoFrameRateRangeForSize(c.cap, s5video::kInitialWidth, s5video::kInitialHeight, &rates);
    const int wac = OH_AVCapability_GetVideoWidthAlignment(c.cap, &wa), hac = OH_AVCapability_GetVideoHeightAlignment(c.cap, &ha);
    auto range = [](int code, const OH_AVRange &r) { return code == AV_ERR_OK ? "[" + std::to_string(r.minVal) + "," + std::to_string(r.maxVal) + "]" : "null"; };
    c.json = "{\"category\":" + Quote(category == HARDWARE ? "hardware" : "software") + ",\"available\":true,\"name\":" + Quote(c.name) +
        ",\"hardware\":" + Bool(c.hardware) + ",\"supports720p\":" + Bool(c.sizeSupported) +
        ",\"pixelQueryCode\":" + std::to_string(c.pixelCode) + ",\"pixelFormats\":" + (c.pixelCode == AV_ERR_OK ? IntArray(pixels, pixelCount) : "null") +
        ",\"profileQueryCode\":" + std::to_string(profileCode) + ",\"profiles\":" + (profileCode == AV_ERR_OK ? IntArray(profiles, profileCount) : "null") +
        ",\"listsTruncated\":" + Bool(pixelCount > 64 || profileCount > 64) +
        ",\"widthRangeCode\":" + std::to_string(wc) + ",\"widthRange\":" + range(wc, widths) +
        ",\"heightRangeCode\":" + std::to_string(hc) + ",\"heightRange\":" + range(hc, heights) +
        ",\"frameRateCode\":" + std::to_string(rc) + ",\"frameRate720\":" + range(rc, rates) +
        ",\"widthAlignment\":" + (wac == AV_ERR_OK ? std::to_string(wa) : "null") +
        ",\"heightAlignment\":" + (hac == AV_ERR_OK ? std::to_string(ha) : "null") + "}";
    return c;
}
struct Buffer { uint32_t index; OH_AVBuffer *buffer; Clock::time_point queued = Clock::now(); };
struct Frame { std::vector<uint8_t> bytes; uint32_t ts, flags; Clock::time_point arrival; uint64_t epoch; uint32_t orientation = 0; };
struct Pending { int64_t pts; Clock::time_point arrival, submitted; uint64_t epoch; uint32_t orientation = 0; };
struct Envelope { int width = 1280, height = 720, level = 31; };
Envelope DecodeEnvelope(OH_AVCapability *cap, int codec = 1)
{
    // A supported square reserves both landscape and portrait without inventing a rectangle
    // from independent maximum width/height ranges. Bound per-session allocation to 4096².
    if (codec == 2) {
        struct Candidate { int side, level, generalLevelIdc; };
        for (auto c : {Candidate{4096, HEVC_LEVEL_6, 180}, {3072, HEVC_LEVEL_6, 180},
                       {2560, HEVC_LEVEL_5, 150}, {2160, HEVC_LEVEL_5, 150},
                       {1920, HEVC_LEVEL_5, 150}, {1280, HEVC_LEVEL_4, 120}}) {
            OH_AVRange rate{};
            if (cap && OH_AVCapability_IsVideoSizeSupported(cap, c.side, c.side) &&
                OH_AVCapability_AreProfileAndLevelSupported(cap, HEVC_PROFILE_MAIN, c.level) &&
                OH_AVCapability_GetVideoFrameRateRangeForSize(cap, c.side, c.side, &rate) == AV_ERR_OK &&
                rate.minVal <= 30 && rate.maxVal >= 30) return {c.side, c.side, c.generalLevelIdc};
        }
        OH_AVRange rate{};
        if (cap && OH_AVCapability_IsVideoSizeSupported(cap, 1280, 720) &&
            OH_AVCapability_AreProfileAndLevelSupported(cap, HEVC_PROFILE_MAIN, HEVC_LEVEL_4) &&
            OH_AVCapability_GetVideoFrameRateRangeForSize(cap, 1280, 720, &rate) == AV_ERR_OK &&
            rate.minVal <= 30 && rate.maxVal >= 30) return {1280, 720, 120};
        return {0, 0, 0};
    }
    struct Candidate { int side, sdkLevel, sdpLevel; };
    for (auto c : {Candidate{4096, AVC_LEVEL_6, 60}, {3072, AVC_LEVEL_52, 52},
                   {2880, AVC_LEVEL_51, 51}, {2560, AVC_LEVEL_51, 51},
                   {2160, AVC_LEVEL_5, 50}, {1920, AVC_LEVEL_5, 50}, {1280, AVC_LEVEL_4, 40}}) {
        if (cap && OH_AVCapability_IsVideoSizeSupported(cap, c.side, c.side) &&
            OH_AVCapability_AreProfileAndLevelSupported(cap, AVC_PROFILE_BASELINE, c.sdkLevel))
            return {c.side, c.side, c.sdpLevel};
    }
    return {};
}
uint32_t DecoderFpsLimit(OH_AVCapability *cap, int width, int height)
{
    OH_AVRange rates{};
    if (!cap || OH_AVCapability_GetVideoFrameRateRangeForSize(cap, width, height, &rates) != AV_ERR_OK) {
        return 30;
    }
    return static_cast<uint32_t>(std::clamp(rates.maxVal, 1, 60));
}
struct Request {
    const uint32_t renderSlot, generation;
    const bool legacyMode;
    // A reservation is published before work is queued. Only the registry mutex
    // mutates startConsumed/surfaceId, and surfaceId is immutable once consumed.
    bool startConsumed = false;
    int requestedCodec = 0; // 0 auto, 1 AVC, 2 HEVC; immutable after start.
    std::atomic_int codecType{0}; // Published only after successful decoder start.
    std::atomic_bool running{true}, cancel{false}, finish{false}, nativeBlocked{false};
    std::atomic_int64_t stopAt{0};
    std::atomic_uint64_t sampleMs{0}, rtpQueueMs{0}, rtpQueueMaxMs{0};
    std::atomic_uint64_t videoEpoch{0}, renderedEpoch{0};
    // Epoch transitions must never wait on codec calls: a driver can block while
    // rendering or submitting, and the caller may be the session command thread.
    std::atomic_uint renderedOrientation{0};
    uint32_t appliedOrientation = 0; // Only the render worker mutates codec parameters.
    std::atomic_int orientationApplyCode{0};
    std::atomic_int renderedWidth{0}, renderedHeight{0}, configWidth{1280}, configHeight{720}, sdpLevel{31};
    std::atomic_uint decoderFpsLimit{30};
    std::mutex statusMutex;
    std::string status = kIdleStatus;
    Request(uint32_t slot, uint32_t gen, bool legacy) : renderSlot(slot), generation(gen), legacyMode(legacy) {}
    void SetStatus(const std::string &text) { std::lock_guard<std::mutex> lock(statusMutex); status = text; }
    std::string Status() { std::lock_guard<std::mutex> lock(statusMutex); return status; }
    napi_async_work work = nullptr; napi_deferred deferred = nullptr;
    uint64_t surfaceId = 0;
    std::deque<Frame> frames; size_t queueBytes = 0, peakFrames = 0, peakBytes = 0;
    std::atomic_bool needIdr{true}, accepting{false};
    std::atomic_uint rejected{0}, au{0}, accepted{0}, submitted{0}, decoded{0}, rendered{0}, callbackErrors{0};
    std::atomic_uint64_t queueMs{0}, queueMaxMs{0}, decoderMs{0}, decoderMaxMs{0}, arrivalToRenderMs{0}, arrivalToRenderMaxMs{0}, outputToRenderMs{0}, outputToRenderMaxMs{0};
    std::atomic_uint64_t discarded{0};
    std::deque<Pending> pending;
    uint32_t previousTs = 0; int64_t ticks = 0, maxTicks = 0; uint64_t timestampEpoch = 0; bool haveTs = false;
    OH_AVCodec *codec = nullptr; OHNativeWindow *window = nullptr;
    bool started = false, safeToDelete = true;
    std::mutex mutex, diagnosticMutex; std::condition_variable cv;
    uint64_t epochAuCount = 0; // Protected by mutex, reset on each media epoch.
    std::deque<Buffer> inputs, outputs;
    std::atomic_int error{0}, width{0}, height{0};
    std::atomic_bool firstAu{false}, firstSps{false}, firstPps{false}, firstIdr{false};
    std::atomic_int streamProfile{-1}, streamLevel{-1};
    std::atomic_bool eosInput{false}, eosOutput{false}, cleaning{false};
    std::atomic_int cleanupCallbackCode{0};
    // Only diagnosticMutex protects the fields below. Never hold it across SDK calls or queue locks.
    std::string phase = "queued", name, pixelPolicy = "surface_default", capabilities = "[]", stages = "", attempts = "";
    s5video::FirstFailure first;
    int pixelFormat = -1, windowWidth = 0, windowHeight = 0;
    int stopCode = 0, destroyCode = 0; unsigned attemptCount = 0, stageCount = 0;
    bool hardware = false, ready = false, released = false, windowCreated = false, workerDone = false;
    bool windowReleased = false, stopCalled = false, destroyCalled = false, cleanupComplete = false, recovered = false;
    std::string report;
    std::string SnapshotLocked() const {
        const auto &failureStage = first.stage, &failureKind = first.kind;
        const int firstError = first.error, firstSystemCode = first.systemCode;
        const bool firstHasSystemCode = first.hasSystemCode;
        const bool stopping = finish.load() || cancel.load();
        return "{\"ready\":" + Bool(ready && !stopping && !error.load()) + ",\"starting\":" + Bool(!ready && !workerDone && !error.load() && !stopping) +
            ",\"renderSlot\":" + std::to_string(renderSlot) + ",\"generation\":" + std::to_string(generation) + ",\"legacyMode\":" + Bool(legacyMode) + ",\"codec\":" + std::to_string(codecType.load()) +
            ",\"running\":" + Bool(!workerDone) + ",\"released\":" + Bool(released) + ",\"phase\":" + Quote(phase) +
            ",\"error\":" + std::to_string(error.load()) + ",\"failureStage\":" + (failureStage.empty() ? "null" : Quote(failureStage)) +
            ",\"firstError\":" + (failureStage.empty() ? "null" : std::to_string(firstError)) +
            ",\"systemCode\":" + (firstHasSystemCode ? std::to_string(firstSystemCode) : "null") +
            ",\"failureKind\":" + (failureKind.empty() ? "null" : Quote(failureKind)) + ",\"recovered\":" + Bool(recovered) +
            ",\"cancelled\":" + Bool(cancel.load()) + ",\"stopRequested\":" + Bool(stopping) +
            ",\"windowCreated\":" + Bool(windowCreated) + ",\"windowWidth\":" + std::to_string(windowWidth) + ",\"windowHeight\":" + std::to_string(windowHeight) +
            ",\"codecName\":" + (name.empty() ? "null" : Quote(name)) + ",\"hardware\":" + (name.empty() ? "null" : Bool(hardware)) +
            ",\"pixelPolicy\":" + Quote(pixelPolicy) + ",\"pixelFormat\":" + (pixelFormat < 0 ? "null" : std::to_string(pixelFormat)) +
            ",\"attemptCount\":" + std::to_string(attemptCount) + ",\"attempts\":[" + attempts + "],\"stages\":[" + stages + "],\"capabilities\":" + capabilities +
            ",\"au\":" + std::to_string(au.load()) + ",\"accepted\":" + std::to_string(accepted.load()) + ",\"submitted\":" + std::to_string(submitted.load()) +
            ",\"decoded\":" + std::to_string(decoded.load()) + ",\"rendered\":" + std::to_string(rendered.load()) +
            ",\"queueMs\":" + std::to_string(queueMs.load()) + ",\"queueMaxMs\":" + std::to_string(queueMaxMs.load()) +
            ",\"decoderMs\":" + std::to_string(decoderMs.load()) + ",\"decoderMaxMs\":" + std::to_string(decoderMaxMs.load()) +
            ",\"arrivalToRenderMs\":" + std::to_string(arrivalToRenderMs.load()) + ",\"arrivalToRenderMaxMs\":" + std::to_string(arrivalToRenderMaxMs.load()) +
            ",\"width\":" + std::to_string(width.load()) + ",\"height\":" + std::to_string(height.load()) +
            ",\"firstAccessUnit\":" + Bool(firstAu.load()) + ",\"firstSps\":" + Bool(firstSps.load()) + ",\"firstPps\":" + Bool(firstPps.load()) +
            ",\"firstIdr\":" + Bool(firstIdr.load()) + ",\"firstDecode\":" + Bool(decoded.load() > 0) + ",\"firstRender\":" + Bool(rendered.load() > 0) +
            ",\"streamProfileIdc\":" + (streamProfile.load() < 0 ? "null" : std::to_string(streamProfile.load())) +
            ",\"streamLevelIdc\":" + (streamLevel.load() < 0 ? "null" : std::to_string(streamLevel.load())) +
            ",\"eos\":" + Bool(eosOutput) + ",\"cleanup\":{\"stopCode\":" + (stopCalled ? std::to_string(stopCode) : "null") +
            ",\"destroyCode\":" + (destroyCalled ? std::to_string(destroyCode) : "null") + ",\"callbackCode\":" + (cleanupCallbackCode.load() ? std::to_string(cleanupCallbackCode.load()) : "null") + ",\"windowReleased\":" + Bool(windowReleased) +
            ",\"complete\":" + Bool(cleanupComplete) + "},\"reusable\":" + Bool(!nativeBlocked.load()) + "}";
    }
    void Publish() { std::lock_guard<std::mutex> lock(diagnosticMutex); SetStatus(SnapshotLocked()); }
    void Phase(const char *value) { std::lock_guard<std::mutex> lock(diagnosticMutex); phase = value; SetStatus(SnapshotLocked()); }
    void Record(int code, const char *operation, bool system = true) {
        std::lock_guard<std::mutex> lock(diagnosticMutex);
        if (stageCount < 64) {
            if (stageCount++) stages += ',';
            stages += "{\"stage\":" + Quote(operation) + ",\"code\":" + (system ? std::to_string(code) : "null") + ",\"atMs\":" + std::to_string(NowMs()) + "}";
        }
        first.Observe(code, operation, system);
        SetStatus(SnapshotLocked());
    }
    void Fail(int code, const char *operation, bool system = false) {
        Record(code == 0 ? -1 : code, operation, system);
        int expected = 0; error.compare_exchange_strong(expected, code == 0 ? -1 : code);
        Log("FAIL slot=%u gen=%u stage=%s code=%d source=%s", renderSlot, generation, operation, code, system ? "system" : "local"); Publish(); cv.notify_all();
    }
    bool Check(OH_AVErrCode code, const char *operation) {
        if (code == AV_ERR_OK) return true;
        Fail(static_cast<int>(code), operation, true); return false;
    }
    bool Step(OH_AVErrCode code, const char *operation) {
        Record(static_cast<int>(code), operation); Log("API stage=%s code=%d", operation, static_cast<int>(code));
        return code == AV_ERR_OK;
    }
    bool Stopping() const { return cancel.load() || finish.load(); }
};
using RequestPtr = std::shared_ptr<Request>;
std::mutex gRegistryMutex;
std::array<RequestPtr, s5video::kRendererSlots> gSlots;
uint32_t gGeneration = 0; // Registry-locked, process lifetime, never wraps or resets.
// Intentionally never destructed: failed Destroy cannot prove callbacks ended.
auto *const gQuarantine = new std::array<RequestPtr, s5video::kRendererSlots>;
std::string gLegacyIdleStatus = kIdleStatus;
RequestPtr Lookup(uint32_t slot, uint32_t generation)
{
    if (slot >= gSlots.size() || generation == 0) return {};
    std::lock_guard<std::mutex> lock(gRegistryMutex);
    const auto &r = gSlots[slot];
    return r && !r->legacyMode && r->generation == generation ? r : RequestPtr{};
}
RequestPtr Legacy()
{
    std::lock_guard<std::mutex> lock(gRegistryMutex);
    return gSlots[0] && gSlots[0]->legacyMode ? gSlots[0] : RequestPtr{};
}
RequestPtr Reserve(uint32_t slot, bool legacy, const char *&failure)
{
    std::lock_guard<std::mutex> lock(gRegistryMutex);
    if (slot >= gSlots.size()) { failure = "Invalid renderer slot"; return {}; }
    const auto &current = gSlots[slot];
    if (current && current->nativeBlocked.load()) { failure = "Video cleanup incomplete; slot requires process restart"; return {}; }
    if (current && current->running.load()) { failure = "Session already running"; return {}; }
    if (gGeneration == UINT32_MAX) { failure = "Video generation exhausted; process restart required"; return {}; }
    auto r = std::make_shared<Request>(slot, ++gGeneration, legacy);
    r->phase = "reserved"; r->Publish(); gSlots[slot] = r;
    return r;
}
struct Work { RequestPtr request; };
void Quarantine(const RequestPtr &r)
{
    std::lock_guard<std::mutex> lock(gRegistryMutex);
    (*gQuarantine)[r->renderSlot] = r;
}
void OnError(OH_AVCodec *, int32_t code, void *data)
{
    auto &r = *static_cast<Request *>(data); ++r.callbackErrors;
    if (r.cleaning.load()) { int expected = 0; r.cleanupCallbackCode.compare_exchange_strong(expected, code); r.Publish(); }
    else r.Fail(code, "OnError", true);
}
void OnStreamChanged(OH_AVCodec *, OH_AVFormat *format, void *data)
{
    auto &r = *static_cast<Request *>(data); int32_t w = 0, h = 0, cw = 0, ch = 0, pixel = -1;
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_WIDTH, &cw); OH_AVFormat_GetIntValue(format, OH_MD_KEY_HEIGHT, &ch);
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_VIDEO_PIC_WIDTH, &w); OH_AVFormat_GetIntValue(format, OH_MD_KEY_VIDEO_PIC_HEIGHT, &h);
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_PIXEL_FORMAT, &pixel);
    r.width.store(w ? w : cw); r.height.store(h ? h : ch);
    Log("STREAM_CHANGED picture=%dx%d coded=%dx%d pixel=%d", w, h, cw, ch, pixel); r.Publish();
}
void OnInput(OH_AVCodec *, uint32_t index, OH_AVBuffer *buffer, void *data)
{
    auto &r = *static_cast<Request *>(data); bool overflow = false;
    { std::lock_guard<std::mutex> lock(r.mutex); if (r.inputs.size() < 64) r.inputs.push_back({index, buffer}); else overflow = true; }
    if (overflow) r.Fail(-30, "InputCallbackBound"); r.cv.notify_all();
}
void OnOutput(OH_AVCodec *, uint32_t index, OH_AVBuffer *buffer, void *data)
{
    auto &r = *static_cast<Request *>(data); bool overflow = false;
    { std::lock_guard<std::mutex> lock(r.mutex); if (r.outputs.size() < 64) r.outputs.push_back({index, buffer}); else overflow = true; }
    if (overflow) r.Fail(-31, "OutputCallbackBound"); r.cv.notify_all();
}
bool Pop(Request &r, bool output, Buffer &buffer)
{
    std::lock_guard<std::mutex> lock(r.mutex); auto &queue = output ? r.outputs : r.inputs;
    if (queue.empty()) return false; buffer = queue.front(); queue.pop_front(); return true;
}
bool Initialize(Request &r)
{
    if (r.Stopping()) return false;
    r.Phase("native_window");
    const int nc = OH_NativeWindow_CreateNativeWindowFromSurfaceId(r.surfaceId, &r.window);
    r.Record(nc, "CreateNativeWindow"); Log("NATIVE_WINDOW create_code=%d created=%d", nc, r.window != nullptr);
    if (nc || !r.window) { r.Fail(nc ? nc : -5, "CreateNativeWindow", nc != 0); return false; }
    { std::lock_guard<std::mutex> lock(r.diagnosticMutex); r.windowCreated = true; }
    if (r.Stopping()) return false;
    r.Phase("surface_geometry");
    int32_t ww = 0, wh = 0;
    // SDK vararg contract: height pointer first, then width pointer.
    const int gc = OH_NativeWindow_NativeWindowHandleOpt(r.window, GET_BUFFER_GEOMETRY, &wh, &ww);
    { std::lock_guard<std::mutex> lock(r.diagnosticMutex); r.windowWidth = ww; r.windowHeight = wh; }
    r.Record(gc, "GetWindowGeometry"); Log("SURFACE_GEOMETRY code=%d width=%d height=%d", gc, ww, wh);
    if (gc) { r.Fail(gc, "GetWindowGeometry", true); return false; }
    if (ww <= 0 || wh <= 0) { r.Fail(-40, "SurfaceDimensions"); return false; }
    // ArkUI contains the full frame; never crop decoder output to the Surface.
    const int scaleCode = OH_NativeWindow_NativeWindowSetScalingModeV2(r.window, OH_SCALING_MODE_SCALE_FIT_V2);
    // The ArkUI Surface already has the frame's aspect ratio. Drivers that do not
    // accept this optional hint can still decode into the correctly sized window.
    Log("SURFACE_SCALE_FIT code=%d", scaleCode);
    if (r.Stopping()) return false;
    r.Phase("capability");
    const std::vector<int> codecs = r.requestedCodec == 0 ? std::vector<int>{2, 1} : std::vector<int>{r.requestedCodec};
    for (const int codec : codecs) {
    const auto hw = QueryCapability(HARDWARE, codec), sw = QueryCapability(SOFTWARE, codec);
    Log("CAPABILITY codec=%d hardware=%s", codec, hw.json.c_str()); Log("CAPABILITY codec=%d software=%s", codec, sw.json.c_str());
    { std::lock_guard<std::mutex> lock(r.diagnosticMutex); r.capabilities = "[" + hw.json + "," + sw.json + "]"; }
    r.Record(0, "QueryCapabilities");
    const bool swEligible = sw.cap && !sw.hardware && sw.sizeSupported && !sw.name.empty() && sw.name != hw.name && DecodeEnvelope(sw.cap, codec).width > 0;
    const Capability *selected = hw.cap && hw.hardware && hw.sizeSupported && !hw.name.empty() && DecodeEnvelope(hw.cap, codec).width > 0 ? &hw : (swEligible ? &sw : nullptr);
    if (!selected) {
        Log("CODEC_UNAVAILABLE codec=%d hw_present=%d sw_present=%d hw_720=%d sw_720=%d hw_envelope=%d sw_envelope=%d", codec, hw.cap != nullptr, sw.cap != nullptr, hw.sizeSupported, sw.sizeSupported, DecodeEnvelope(hw.cap, codec).width, DecodeEnvelope(sw.cap, codec).width);
        if (codec == 2 && r.requestedCodec == 0) { Log("FALLBACK codec=HEVC reason=capability next=AVC"); continue; }
        r.Fail(-2, codec == 2 ? "NoHEVCCapabilityFor1280x720" : "NoH264CapabilityFor1280x720"); return false;
    }
    for (unsigned attempt = 1; attempt <= 2 && selected; ++attempt) {
        if (r.Stopping() || r.error.load()) return false;
        const bool rgba = s5video::UseSoftwareRgba(selected->hardware, selected->pixelCode == AV_ERR_OK, selected->rgba);
        const auto envelope = DecodeEnvelope(selected->cap, codec);
        {
            std::lock_guard<std::mutex> lock(r.diagnosticMutex); r.attemptCount = attempt; r.hardware = selected->hardware; r.name = selected->name;
            r.pixelFormat = rgba ? AV_PIXEL_FORMAT_RGBA : -1; r.pixelPolicy = rgba ? "system_software_rgba" : "surface_default";
            if (!r.attempts.empty()) r.attempts += ',';
            r.attempts += "{\"name\":" + Quote(r.name) + ",\"hardware\":" + Bool(r.hardware) + ",\"pixelPolicy\":" + Quote(r.pixelPolicy) + "}";
        }
        Log("DECODER_SELECTION codec=%d attempt=%u name=%s hardware=%d pixel_policy=%s", codec, attempt, selected->name.c_str(), selected->hardware, rgba ? "system_software_rgba" : "surface_default");
        r.Phase("create_decoder"); r.codec = OH_VideoDecoder_CreateByName(selected->name.c_str());
        const bool createUnavailable = !r.codec;
        bool configureUnsupported = false;
        if (createUnavailable) r.Record(-3, "CreateByName", false);
        else {
            r.Record(0, "CreateByName"); if (r.Stopping()) return false;
            r.Phase("register_callback"); OH_AVCodecCallback callbacks{OnError, OnStreamChanged, OnInput, OnOutput};
            const auto cb = OH_VideoDecoder_RegisterCallback(r.codec, callbacks, &r);
            if (!r.Step(cb, "RegisterCallback")) { r.Fail(cb, "RegisterCallback", true); return false; }
            if (r.Stopping() || r.error.load()) return false;
            r.Phase("configure"); OH_AVFormat *format = OH_AVFormat_Create();
            if (!format) { r.Fail(-4, "AVFormatCreate"); return false; }
            const bool values = OH_AVFormat_SetIntValue(format, OH_MD_KEY_WIDTH, envelope.width) &&
                OH_AVFormat_SetIntValue(format, OH_MD_KEY_HEIGHT, envelope.height) &&
                OH_AVFormat_SetIntValue(format, OH_MD_KEY_MAX_INPUT_SIZE, 1024 * 1024) &&
                (!rgba || OH_AVFormat_SetIntValue(format, OH_MD_KEY_PIXEL_FORMAT, AV_PIXEL_FORMAT_RGBA)) &&
                OH_AVFormat_SetIntValue(format, OH_MD_KEY_ROTATION, 0);
            if (!values) { OH_AVFormat_Destroy(format); r.Fail(-41, "SetFormatValues"); return false; }
            const bool lowLatencySupported = OH_AVCapability_IsFeatureSupported(selected->cap, VIDEO_LOW_LATENCY);
            const bool lowLatencySet = lowLatencySupported && OH_AVFormat_SetIntValue(format, OH_MD_KEY_VIDEO_ENABLE_LOW_LATENCY, 1);
            // In Surface mode the pixel key is optional (SDK Configure table). Hardware keeps the system default.
            const auto cc = OH_VideoDecoder_Configure(r.codec, format); OH_AVFormat_Destroy(format);
            // A successful Configure does not prove the decoder applied the optional setting.
            Log("LOW_LATENCY supported=%d set=%d configure=%d effective=-1", lowLatencySupported, lowLatencySet, static_cast<int>(cc));
            r.Step(cc, "Configure"); configureUnsupported = cc == AV_ERR_UNSUPPORT;
            if (cc == AV_ERR_OK) {
                if (r.Stopping() || r.error.load()) return false;
                r.Phase("set_surface"); const auto sc = OH_VideoDecoder_SetSurface(r.codec, r.window);
                if (!r.Step(sc, "SetSurface")) { r.Fail(sc, "SetSurface", true); return false; }
                if (r.Stopping() || r.error.load()) return false;
                r.Phase("prepare"); const auto pc = OH_VideoDecoder_Prepare(r.codec);
                if (!r.Step(pc, "Prepare")) { r.Fail(pc, "Prepare", true); return false; }
                if (r.Stopping() || r.error.load()) return false;
                r.Phase("start"); const auto st = OH_VideoDecoder_Start(r.codec);
                if (!r.Step(st, "Start")) { r.Fail(st, "Start", true); return false; }
                r.started = true;
                r.configWidth.store(envelope.width); r.configHeight.store(envelope.height); r.sdpLevel.store(envelope.level);
                r.decoderFpsLimit.store(DecoderFpsLimit(selected->cap, envelope.width, envelope.height));
                r.codecType.store(codec);
                Log("DECODER_READY codec=%d width=%d height=%d level=%d hardware=%d fps_limit=%u", codec, envelope.width, envelope.height, envelope.level, selected->hardware, r.decoderFpsLimit.load());
                if (r.Stopping() || r.error.load()) return false;
                { std::lock_guard<std::mutex> lock(r.diagnosticMutex); r.ready = true; r.recovered = !r.first.stage.empty(); }
                r.accepting.store(true); r.Phase("waiting_media"); return true;
            }
            if (!configureUnsupported) { r.Fail(cc, "Configure", true); return false; }
        }
        const bool fallback = s5video::CanFallback(selected->hardware, attempt, swEligible, createUnavailable, configureUnsupported, r.Stopping() || r.error.load());
        const bool nextCodec = codec == 2 && r.requestedCodec == 0 && !fallback && (createUnavailable || configureUnsupported) && !r.Stopping() && !r.error.load();
        if (!fallback && !nextCodec) { r.Fail(createUnavailable ? -3 : AV_ERR_UNSUPPORT, createUnavailable ? "CreateByName" : "Configure", !createUnavailable); return false; }
        if (r.codec) {
            r.Phase("fallback_destroy"); const auto dc = OH_VideoDecoder_Destroy(r.codec); r.Record(dc, "FallbackDestroy");
            if (dc != AV_ERR_OK) { r.safeToDelete = false; r.nativeBlocked.store(true); r.Fail(dc, "FallbackDestroy", true); return false; }
            r.codec = nullptr;
            { std::lock_guard<std::mutex> lock(r.mutex); r.inputs.clear(); r.outputs.clear(); }
        }
        if (nextCodec) { Log("FALLBACK codec=HEVC reason=%s next=AVC", createUnavailable ? "create_unavailable" : "configure_unsupported"); break; }
        Log("FALLBACK reason=%s next=system_software attempts_max=2", createUnavailable ? "hardware_create_unavailable" : "configure_unsupported");
        selected = &sw;
    }
    }
    return false;
}
// Apply only the transform belonging to the output PTS being rendered. HEVC
// reordering must not use the orientation of the newest submitted packet.
bool ApplyOrientation(Request &r, uint32_t orientation)
{
    if (!s5video::ValidOrientation(orientation)) { r.Fail(-46, "InvalidVideoOrientation"); return false; }
    if (r.appliedOrientation == orientation) return true;
    OH_AVFormat *format = OH_AVFormat_Create();
    if (!format) { r.Fail(-4, "OrientationFormatCreate"); return false; }
    // API 22 adds flip+rotation. Resolve the optional key without introducing a
    // hard runtime dependency on that symbol for older supported phone systems.
    static const auto transformKey = static_cast<const char **>(dlsym(RTLD_DEFAULT, "OH_MD_KEY_VIDEO_TRANSFORM_TYPE"));
    bool configured = false;
    if ((orientation & 4) == 0) configured = OH_AVFormat_SetIntValue(format, OH_MD_KEY_ROTATION, s5video::PresentationDegrees(orientation));
    else if (transformKey && *transformKey) configured = OH_AVFormat_SetIntValue(format, *transformKey, s5video::NativeTransform(orientation));
    if (!configured) { OH_AVFormat_Destroy(format); r.Fail(-46, "VideoOrientationUnsupported"); return false; }
    const auto code = OH_VideoDecoder_SetParameter(r.codec, format); OH_AVFormat_Destroy(format);
    r.orientationApplyCode.store(code);
    int transform = -1;
    const int readCode = OH_NativeWindow_NativeWindowHandleOpt(r.window, GET_TRANSFORM, &transform);
    Log("ORIENTATION_APPLY slot=%u gen=%u orientation=%u rotation=%u flip=%u code=%d transform=%d readCode=%d", r.renderSlot, r.generation, orientation, s5video::PresentationDegrees(orientation), (orientation >> 2) & 1, code, transform, readCode);
    if (!r.Check(code, "SetVideoOrientation")) return false;
    r.appliedOrientation = orientation;
    return true;
}
void BeginEpoch(const RequestPtr &r, uint64_t epoch)
{
    if (!r || r->Stopping() || !r->running.load()) return;
    std::lock_guard<std::mutex> lock(r->mutex);
    if (r->Stopping() || !r->running.load()) return;
    // Epochs are monotonically allocated by the media owner. A delayed lane
    // transition must never revive older compressed frames or output.
    if (epoch <= r->videoEpoch.load()) return;
    r->videoEpoch.store(epoch, std::memory_order_release);
    r->epochAuCount = 0;
    r->frames.clear(); r->queueBytes = 0; r->needIdr.store(true); r->cv.notify_all();
}
bool BeginEpochIfNoAu(const RequestPtr &r, uint64_t previous, uint64_t next)
{
    if (!r || r->Stopping() || !r->running.load()) return false;
    std::lock_guard<std::mutex> lock(r->mutex);
    if (r->Stopping() || !r->running.load() || r->videoEpoch.load() != previous ||
        next <= previous || r->epochAuCount != 0) return false;
    r->videoEpoch.store(next, std::memory_order_release);
    r->epochAuCount = 0;
    r->frames.clear(); r->queueBytes = 0; r->needIdr.store(true); r->cv.notify_all();
    return true;
}
bool Observed(const RequestPtr &r, uint64_t epoch, uint32_t width, uint32_t height)
{
    return r && r->rendered.load() > 0 && r->renderedEpoch.load(std::memory_order_acquire) == epoch && r->videoEpoch.load() == epoch &&
        r->renderedWidth.load() > 0 && r->renderedHeight.load() > 0 &&
        (!width || (r->renderedWidth.load() == static_cast<int>(width) && r->renderedHeight.load() == static_cast<int>(height)));
}
bool ObservedSize(const RequestPtr &r, uint64_t epoch, uint32_t *width, uint32_t *height)
{
    if (!r || !width || !height || r->rendered.load() == 0 ||
        r->renderedEpoch.load(std::memory_order_acquire) != epoch || r->videoEpoch.load() != epoch) return false;
    const int w = r->renderedWidth.load(), h = r->renderedHeight.load();
    if (w <= 0 || h <= 0 || r->renderedEpoch.load(std::memory_order_acquire) != epoch || r->videoEpoch.load() != epoch) return false;
    *width = static_cast<uint32_t>(w); *height = static_cast<uint32_t>(h);
    return true;
}
bool SizeSupported(const RequestPtr &r, uint32_t width, uint32_t height)
{
    if (width < 2 || height < 2 || width > 8192 || height > 8192 || width % 2 || height % 2) return false;
    if (!r || !r->accepting.load()) return false;
    bool hardware = false;
    { std::lock_guard<std::mutex> lock(r->diagnosticMutex); hardware = r->hardware; }
    auto *cap = OH_AVCodec_GetCapabilityByCategory(r->codecType.load() == 2 ? OH_AVCODEC_MIMETYPE_VIDEO_HEVC : OH_AVCODEC_MIMETYPE_VIDEO_AVC, false, hardware ? HARDWARE : SOFTWARE);
    return cap && width <= static_cast<uint32_t>(r->configWidth.load()) && height <= static_cast<uint32_t>(r->configHeight.load()) &&
        OH_AVCapability_IsVideoSizeSupported(cap, width, height);
}
int Submit(const RequestPtr &r, const uint8_t *bytes, size_t size, uint32_t ts, uint32_t flags, uint64_t epoch, uint32_t orientation = 0)
{
    if (!s5video::ValidOrientation(orientation)) return 1;
    if (!r || epoch != r->videoEpoch.load() || !r->accepting.load() || r->Stopping() || r->error.load()) return 2;
    if (!bytes || size == 0 || size > 1024 * 1024) { ++r->rejected; r->needIdr.store(true); return 1; }
    ++r->au; r->firstAu.store(true);
    const auto nal = s5video::ObserveAnnexB(bytes, size, r->codecType.load());
    if (nal.sps) r->firstSps.store(true); if (nal.pps) r->firstPps.store(true); if (nal.idr) r->firstIdr.store(true);
    if (nal.profileIdc >= 0) { const int prior = r->streamProfile.exchange(nal.profileIdc); r->streamLevel.store(nal.levelIdc); if (prior < 0) Log("STREAM_SPS profile_idc=%d level_idc=%d", nal.profileIdc, nal.levelIdc); }
    if (r->au.load() == 1) Log("FIRST_AU bytes=%zu sps=%d pps=%d idr=%d", size, nal.sps, nal.pps, nal.idr);
    std::unique_lock<std::mutex> lock(r->mutex, std::try_to_lock);
    if (!lock.owns_lock()) { ++r->rejected; r->needIdr.store(true); return 1; }
    // BeginEpoch uses this same lock. Never admit an old AU after it cleared the queue.
    if (epoch != r->videoEpoch.load() || !r->accepting.load() || r->Stopping()) return 2;
    const auto now = Clock::now();
    if (r->frames.size() >= 8 || r->queueBytes + size > 2 * 1024 * 1024 ||
        (!r->frames.empty() && now - r->frames.front().arrival > std::chrono::milliseconds(300))) r->needIdr.store(true);
    if (r->needIdr.load()) {
        r->discarded += r->frames.size(); r->frames.clear(); r->queueBytes = 0;
        // Preserve the existing SPS/PPS+IDR admission contract; observations above come from actual NALs.
        if ((flags & 10) != 10 || !nal.sps || !nal.pps || !nal.idr || (r->codecType.load() == 2 && !nal.vps)) { ++r->rejected; return 1; }
        r->needIdr.store(false); Log("RESYNC SPS_PPS_IDR timestamp=%u", ts);
    }
    r->frames.push_back(Frame{std::vector<uint8_t>(bytes, bytes + size), ts, flags, now, epoch, orientation}); r->queueBytes += size; ++r->accepted;
    r->peakFrames = std::max(r->peakFrames, r->frames.size()); r->peakBytes = std::max(r->peakBytes, r->queueBytes);
    lock.unlock(); r->cv.notify_all(); return 0;
}
void QueueSample(const RequestPtr &r, uint64_t ms)
{
    if (!r || !r->running.load() || r->Stopping()) return;
    r->rtpQueueMs.store(ms, std::memory_order_relaxed);
    auto peak = r->rtpQueueMaxMs.load(std::memory_order_relaxed);
    while (peak < ms && !r->rtpQueueMaxMs.compare_exchange_weak(peak, ms, std::memory_order_relaxed)) {}
}
void RequestStop(const RequestPtr &r, bool hard);
extern "C" bool s26_cancelled() { auto r = Legacy(); return r && r->cancel.load(); }
extern "C" void s26_discontinuity() { if (auto r = Legacy()) r->needIdr.store(true); }
extern "C" void s5_video_begin_epoch(uint64_t epoch) { BeginEpoch(Legacy(), epoch); }
extern "C" uint32_t s5_video_limit_width() { auto r = Legacy(); return r ? r->configWidth.load() : 1280; }
extern "C" uint32_t s5_video_limit_height() { auto r = Legacy(); return r ? r->configHeight.load() : 720; }
extern "C" uint32_t s5_video_sdp_level() { auto r = Legacy(); return r ? r->sdpLevel.load() : 31; }
extern "C" uint32_t s5_video_ready_codec() { auto r = Legacy(); return r && r->accepting.load() && !r->Stopping() && !r->error.load() ? r->codecType.load() : 0; }
extern "C" bool s5_video_ready_details(uint32_t *width, uint32_t *height, uint32_t *codec, uint32_t *level, uint32_t *fps)
{
    auto r = Legacy();
    if (!width || !height || !codec || !level || !fps || !r || !r->accepting.load() || r->Stopping() || r->error.load()) return false;
    *width = r->configWidth.load(); *height = r->configHeight.load(); *codec = r->codecType.load(); *level = r->sdpLevel.load(); *fps = r->decoderFpsLimit.load();
    return *width >= 2 && *height >= 2 && (*codec == 1 || *codec == 2) && *level > 0;
}
extern "C" bool s5_video_observed(uint64_t epoch, uint32_t w, uint32_t h) { return Observed(Legacy(), epoch, w, h); }
extern "C" bool s5_video_observed_size(uint64_t epoch, uint32_t *w, uint32_t *h) { return ObservedSize(Legacy(), epoch, w, h); }
extern "C" bool s5_video_size_supported(uint32_t w, uint32_t h) { return SizeSupported(Legacy(), w, h); }
extern "C" int s5_submit_epoch(const uint8_t *bytes, size_t size, uint32_t ts, uint32_t flags, uint64_t epoch)
{ return Submit(Legacy(), bytes, size, ts, flags, epoch); }
extern "C" int s5_submit_oriented_epoch(const uint8_t *bytes, size_t size, uint32_t ts, uint32_t flags, uint64_t epoch, uint32_t orientation)
{ return Submit(Legacy(), bytes, size, ts, flags, epoch, orientation); }
extern "C" int s5_submit_slot_oriented_epoch(uint32_t slot, uint32_t generation, const uint8_t *bytes, size_t size, uint32_t ts, uint32_t flags, uint64_t epoch, uint32_t orientation)
{ return Submit(Lookup(slot, generation), bytes, size, ts, flags, epoch, orientation); }
extern "C" int s26_submit(const uint8_t *bytes, size_t size, uint32_t ts, uint32_t flags)
{ auto r = Legacy(); return Submit(r, bytes, size, ts, flags, r ? r->videoEpoch.load() : 0); }
extern "C" void s5_video_rtp_queue_sample(uint64_t ms) { QueueSample(Legacy(), ms); }
extern "C" int s5_submit_slot_epoch(uint32_t slot, uint32_t gen, const uint8_t *bytes, size_t size, uint32_t ts, uint32_t flags, uint64_t epoch)
{ return Submit(Lookup(slot, gen), bytes, size, ts, flags, epoch); }
extern "C" void s5_video_slot_begin_epoch(uint32_t slot, uint32_t gen, uint64_t epoch) { BeginEpoch(Lookup(slot, gen), epoch); }
extern "C" void s5_video_slot_discontinuity(uint32_t slot, uint32_t gen) { if (auto r = Lookup(slot, gen)) r->needIdr.store(true); }
extern "C" bool s5_video_slot_cancelled(uint32_t slot, uint32_t gen) { auto r = Lookup(slot, gen); return !r || !r->running.load() || r->Stopping(); }
extern "C" uint32_t s5_video_slot_limit_width(uint32_t slot, uint32_t gen) { auto r = Lookup(slot, gen); return r ? r->configWidth.load() : 0; }
extern "C" uint32_t s5_video_slot_limit_height(uint32_t slot, uint32_t gen) { auto r = Lookup(slot, gen); return r ? r->configHeight.load() : 0; }
extern "C" bool s5_video_slot_ready_envelope(uint32_t slot, uint32_t gen, uint32_t *width, uint32_t *height)
{
    auto r = Lookup(slot, gen);
    if (!width || !height || !r || !r->running.load() || !r->accepting.load() || r->Stopping() || r->error.load()) return false;
    *width = r->configWidth.load(); *height = r->configHeight.load();
    if (*width < 2 || *height < 2) return false;
    Log("ENVELOPE slot=%u gen=%u width=%u height=%u", slot, gen, *width, *height);
    return true;
}
extern "C" uint32_t s5_video_slot_sdp_level(uint32_t slot, uint32_t gen) { auto r = Lookup(slot, gen); return r ? r->sdpLevel.load() : 0; }
extern "C" uint32_t s5_video_slot_ready_codec(uint32_t slot, uint32_t gen) { auto r = Lookup(slot, gen); return r && r->accepting.load() && !r->Stopping() && !r->error.load() ? r->codecType.load() : 0; }
extern "C" bool s5_video_slot_ready_details(uint32_t slot, uint32_t gen, uint32_t *width, uint32_t *height, uint32_t *codec, uint32_t *level, uint32_t *fps)
{
    auto r = Lookup(slot, gen);
    if (!width || !height || !codec || !level || !fps || !r || !r->accepting.load() || r->Stopping() || r->error.load()) return false;
    *width = r->configWidth.load(); *height = r->configHeight.load(); *codec = r->codecType.load(); *level = r->sdpLevel.load(); *fps = r->decoderFpsLimit.load();
    return *width >= 2 && *height >= 2 && (*codec == 1 || *codec == 2) && *level > 0;
}
extern "C" bool s5_video_slot_size_supported(uint32_t slot, uint32_t gen, uint32_t w, uint32_t h) { return SizeSupported(Lookup(slot, gen), w, h); }
extern "C" bool s5_video_slot_observed(uint32_t slot, uint32_t gen, uint64_t epoch, uint32_t w, uint32_t h) { return Observed(Lookup(slot, gen), epoch, w, h); }
extern "C" bool s5_video_slot_observed_size(uint32_t slot, uint32_t gen, uint64_t epoch, uint32_t *w, uint32_t *h) { return ObservedSize(Lookup(slot, gen), epoch, w, h); }
void NoteEpochAu(const RequestPtr &r, uint64_t epoch)
{
    if (!r) return;
    std::lock_guard<std::mutex> lock(r->mutex);
    if (r->videoEpoch.load() == epoch && r->running.load() && !r->Stopping()) ++r->epochAuCount;
}
uint64_t EpochAus(const RequestPtr &r, uint64_t epoch)
{
    if (!r) return UINT64_MAX;
    std::lock_guard<std::mutex> lock(r->mutex);
    return r->videoEpoch.load() == epoch && r->running.load() && !r->Stopping() ? r->epochAuCount : UINT64_MAX;
}
extern "C" void s5_video_note_epoch_au(uint64_t epoch) { NoteEpochAu(Legacy(), epoch); }
extern "C" void s5_video_slot_note_epoch_au(uint32_t slot, uint32_t gen, uint64_t epoch) { NoteEpochAu(Lookup(slot, gen), epoch); }
extern "C" uint64_t s5_video_epoch_aus(uint64_t epoch) { return EpochAus(Legacy(), epoch); }
extern "C" uint64_t s5_video_slot_epoch_aus(uint32_t slot, uint32_t gen, uint64_t epoch) { return EpochAus(Lookup(slot, gen), epoch); }
extern "C" bool s5_video_begin_epoch_if_no_au(uint64_t previous, uint64_t next) { return BeginEpochIfNoAu(Legacy(), previous, next); }
extern "C" bool s5_video_slot_begin_epoch_if_no_au(uint32_t slot, uint32_t gen, uint64_t previous, uint64_t next) { return BeginEpochIfNoAu(Lookup(slot, gen), previous, next); }
extern "C" void s5_video_slot_rtp_queue_sample(uint32_t slot, uint32_t gen, uint64_t ms) { QueueSample(Lookup(slot, gen), ms); }
extern "C" void s5_video_slot_stop(uint32_t slot, uint32_t gen, bool hard) { RequestStop(Lookup(slot, gen), hard); }
extern "C" void s5_video_stop_all(bool hard)
{
    std::array<RequestPtr, s5video::kRendererSlots> requests;
    { std::lock_guard<std::mutex> lock(gRegistryMutex); requests = gSlots; }
    for (const auto &r : requests) RequestStop(r, hard);
}
void Decode(Request &r)
{
    auto measure = [](Clock::time_point start, std::atomic_uint64_t &latest, std::atomic_uint64_t &peak) {
        const auto ms = static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - start).count());
        latest.store(ms); peak.store(std::max(peak.load(), ms));
    };
    int64_t publishAt = 0, metricsAt = NowMs(), lastOutputMs = 0, lastSubmitMs = 0;
    uint64_t intervalCompleted = 0, intervalPendingPeak = 0, intervalSubmitGapMax = 0;
    uint64_t intervalSubmitCallbackMax = 0, intervalCallbackWorkerMax = 0, intervalRenderCallMax = 0;
    while (!r.error.load() && !r.cancel.load() && !r.eosOutput) {
        if (s5video::DrainExpired(NowMs(), r.stopAt.load())) { r.Phase("drain_timeout"); break; }
        Buffer b{}; bool processedOutput = false;
        while (!r.error.load() && !r.cancel.load() && Pop(r, true, b)) {
            processedOutput = true;
            const auto outputAt = b.queued;
            OH_AVCodecBufferAttr attr{};
            if (!r.Check(OH_AVBuffer_GetBufferAttr(b.buffer, &attr), "GetOutputAttr")) break;
            if (attr.flags & AVCODEC_BUFFER_FLAGS_EOS) { r.eosOutput = true; r.Check(OH_VideoDecoder_FreeOutputBuffer(r.codec, b.index), "FreeEOS"); break; }
            ++r.decoded;
            auto pendingIt = r.pending.begin();
            if (r.codecType.load() == 2) {
                // HEVC B/RADL pictures may be output in presentation order,
                // which can differ from their compressed submission order.
                pendingIt = std::find_if(r.pending.begin(), r.pending.end(), [&](const Pending &p) { return p.pts == attr.pts; });
            }
            if (pendingIt == r.pending.end() || pendingIt->pts != attr.pts) { r.Fail(-7, "OutputPtsOrder"); OH_VideoDecoder_FreeOutputBuffer(r.codec, b.index); break; }
            const auto pending = *pendingIt; r.pending.erase(pendingIt);
            const auto outputEpoch = pending.epoch;
            const auto workerAt = Clock::now();
            const auto elapsedMs = [](Clock::duration duration) -> uint64_t {
                return static_cast<uint64_t>(std::max<int64_t>(0, std::chrono::duration_cast<std::chrono::milliseconds>(duration).count()));
            };
            intervalSubmitCallbackMax = std::max(intervalSubmitCallbackMax, elapsedMs(outputAt - pending.submitted));
            intervalCallbackWorkerMax = std::max(intervalCallbackWorkerMax, elapsedMs(workerAt - outputAt));
            measure(pending.submitted, r.decoderMs, r.decoderMaxMs);
            if (outputEpoch != r.videoEpoch.load()) { r.Check(OH_VideoDecoder_FreeOutputBuffer(r.codec, b.index), "FreePreviousDisplay"); continue; }
            if (!ApplyOrientation(r, pending.orientation)) { OH_VideoDecoder_FreeOutputBuffer(r.codec, b.index); break; }
            const auto renderAt = Clock::now();
            if (!r.Check(OH_VideoDecoder_RenderOutputBuffer(r.codec, b.index), "RenderOutputBuffer")) break;
            intervalRenderCallMax = std::max(intervalRenderCallMax, elapsedMs(Clock::now() - renderAt));
            ++intervalCompleted; lastOutputMs = NowMs();
            measure(outputAt, r.outputToRenderMs, r.outputToRenderMaxMs);
            measure(pending.arrival, r.arrivalToRenderMs, r.arrivalToRenderMaxMs);
            ++r.rendered; r.sampleMs.store(NowMs());
            // A transition may have occurred while the driver was rendering. Such
            // an output must never acknowledge the newly selected screen.
            if (outputEpoch == r.videoEpoch.load()) {
                r.renderedWidth.store(s5video::DisplayWidth(r.width.load(), r.height.load(), pending.orientation));
                r.renderedHeight.store(s5video::DisplayHeight(r.width.load(), r.height.load(), pending.orientation));
                r.renderedOrientation.store(pending.orientation); r.renderedEpoch.store(outputEpoch, std::memory_order_release);
            }
            if (r.rendered.load() == 1) { Log("FIRST_RENDER decoded=%u rendered=1", r.decoded.load()); r.Phase("rendering"); }
        }
        if (r.error.load() || r.eosOutput || r.cancel.load()) break;
        Frame frame; bool have = false, eos = false;
        {
            std::lock_guard<std::mutex> lock(r.mutex);
            if (!r.frames.empty() && Clock::now() - r.frames.front().arrival > std::chrono::milliseconds(300)) r.needIdr.store(true);
            if (r.needIdr.load() && !r.frames.empty()) { r.discarded += r.frames.size(); r.frames.clear(); r.queueBytes = 0; }
            if (!r.inputs.empty() && !r.eosInput) {
                if (!r.frames.empty()) { b = r.inputs.front(); r.inputs.pop_front(); frame = std::move(r.frames.front()); r.frames.pop_front(); r.queueBytes -= frame.bytes.size(); have = true; }
                else if (r.finish.load()) { b = r.inputs.front(); r.inputs.pop_front(); eos = true; }
            }
        }
        if (have || eos) {
            // The worker may have popped a frame just before an epoch transition.
            // Return its input buffer to the local queue instead of submitting it.
            if (have && frame.epoch != r.videoEpoch.load()) {
                std::lock_guard<std::mutex> lock(r.mutex);
                if (r.inputs.size() < 64) r.inputs.push_front(b);
                else { r.Fail(-30, "InputCallbackBound"); }
                ++r.discarded;
                continue;
            }
            OH_AVCodecBufferAttr attr{};
            if (have) {
                if (!r.haveTs) { r.haveTs = true; r.previousTs = frame.ts; r.timestampEpoch = frame.epoch; if (r.codecType.load() == 2) r.ticks = 90000 * 6; }
                else if (r.timestampEpoch != frame.epoch) {
                    // RTP bases from different screens are unrelated. Preserve FIFO
                    // decoder PTS without interpreting that jump as elapsed time.
                    r.ticks = r.codecType.load() == 2 ? r.maxTicks + 90000 * 6 : r.ticks + 3000;
                    r.previousTs = frame.ts; r.timestampEpoch = frame.epoch;
                } else {
                    const uint32_t rawDelta = frame.ts - r.previousTs;
                    r.ticks += r.codecType.load() == 2 ? static_cast<int32_t>(rawDelta) : static_cast<int64_t>(rawDelta);
                    r.previousTs = frame.ts;
                }
                if (r.ticks < 0) { r.Fail(-45, "InvalidPresentationTimestamp"); break; }
                r.maxTicks = std::max(r.maxTicks, r.ticks);
                auto *addr = OH_AVBuffer_GetAddr(b.buffer);
                if (!addr || OH_AVBuffer_GetCapacity(b.buffer) < static_cast<int32_t>(frame.bytes.size())) { r.Fail(-8, "InputCapacity"); break; }
                memcpy(addr, frame.bytes.data(), frame.bytes.size()); attr.size = frame.bytes.size(); attr.pts = r.ticks * 1000000 / 90000; attr.flags = frame.flags;
                if (r.pending.size() >= 64) { r.Fail(-32, "PendingDecoderBound"); break; }
                measure(frame.arrival, r.queueMs, r.queueMaxMs);
                r.pending.push_back({attr.pts, frame.arrival, Clock::now(), frame.epoch, frame.orientation});
                intervalPendingPeak = std::max(intervalPendingPeak, static_cast<uint64_t>(r.pending.size()));
                const auto submitMs = NowMs();
                if (lastSubmitMs) intervalSubmitGapMax = std::max(intervalSubmitGapMax, static_cast<uint64_t>(submitMs - lastSubmitMs));
                lastSubmitMs = submitMs;
            } else { attr.flags = AVCODEC_BUFFER_FLAGS_EOS; attr.pts = r.ticks * 1000000 / 90000 + 66667; }
            if (!r.Check(OH_AVBuffer_SetBufferAttr(b.buffer, &attr), "SetInputAttr") || !r.Check(OH_VideoDecoder_PushInputBuffer(r.codec, b.index), "PushInputBuffer")) break;
            if (have) { if (++r.submitted == 1) { Log("FIRST_SUBMIT bytes=%d flags=%u", attr.size, attr.flags); r.Phase("decoding"); } }
            else { r.eosInput = true; r.Phase("draining"); }
        }
        if (NowMs() - publishAt >= 25) { publishAt = NowMs(); r.Publish(); }
        if (NowMs() - metricsAt >= 5000) {
            metricsAt = NowMs();
            Log("LATENCY_MS rtp_queue=%llu rtp_queue_max=%llu native_queue=%llu native_queue_max=%llu decoder=%llu decoder_max=%llu output_render=%llu output_render_max=%llu arrival_render=%llu arrival_render_max=%llu completed=%llu output_age_ms=%lld pending=%llu pending_peak=%llu submit_gap_max_ms=%llu submit_callback_max_ms=%llu callback_worker_max_ms=%llu render_call_max_ms=%llu",
                static_cast<unsigned long long>(r.rtpQueueMs.load()), static_cast<unsigned long long>(r.rtpQueueMaxMs.load()),
                static_cast<unsigned long long>(r.queueMs.load()), static_cast<unsigned long long>(r.queueMaxMs.load()),
                static_cast<unsigned long long>(r.decoderMs.load()), static_cast<unsigned long long>(r.decoderMaxMs.load()),
                static_cast<unsigned long long>(r.outputToRenderMs.load()), static_cast<unsigned long long>(r.outputToRenderMaxMs.load()),
                static_cast<unsigned long long>(r.arrivalToRenderMs.load()), static_cast<unsigned long long>(r.arrivalToRenderMaxMs.load()),
                static_cast<unsigned long long>(intervalCompleted), static_cast<long long>(lastOutputMs ? metricsAt - lastOutputMs : -1),
                static_cast<unsigned long long>(r.pending.size()), static_cast<unsigned long long>(intervalPendingPeak),
                static_cast<unsigned long long>(intervalSubmitGapMax), static_cast<unsigned long long>(intervalSubmitCallbackMax),
                static_cast<unsigned long long>(intervalCallbackWorkerMax), static_cast<unsigned long long>(intervalRenderCallMax));
            intervalCompleted = 0; intervalPendingPeak = r.pending.size(); intervalSubmitGapMax = 0;
            intervalSubmitCallbackMax = 0; intervalCallbackWorkerMax = 0; intervalRenderCallMax = 0;
        }
        // Drain available work before sleeping; preserve every compressed frame in order.
        if (processedOutput || have || eos) continue;
        std::unique_lock<std::mutex> lock(r.mutex); r.cv.wait_for(lock, std::chrono::milliseconds(3));
    }
    // Intentional stop/SurfaceDestroyed is a lifecycle outcome, never a decoder failure.
}
void Execute(napi_env, void *data)
{
    const auto request = static_cast<Work *>(data)->request;
    auto &r = *request;
    Log("BEGIN slot=%u gen=%u bounded_AU_frames=8 bytes=2097152 age_ms=300 init=1280x720 surface_first=true", r.renderSlot, r.generation);
    if (Initialize(r)) Decode(r);
    r.accepting.store(false);
    r.cleaning.store(true); r.Phase("cleanup");
    // SDK Stop/Destroy wait for callbacks: no pointer, queue or diagnostic mutex is held here.
    if (r.started) {
        const int sc = OH_VideoDecoder_Stop(r.codec);
        { std::lock_guard<std::mutex> lock(r.diagnosticMutex); r.stopCalled = true; r.stopCode = sc; }
        Log("CLEANUP stage=Stop code=%d", sc); r.Publish();
    }
    if (r.codec && r.safeToDelete) {
        const int dc = OH_VideoDecoder_Destroy(r.codec);
        { std::lock_guard<std::mutex> lock(r.diagnosticMutex); r.destroyCalled = true; r.destroyCode = dc; }
        Log("CLEANUP stage=Destroy code=%d", dc);
        if (dc == AV_ERR_OK) r.codec = nullptr;
        else { r.safeToDelete = false; r.nativeBlocked.store(true); }
    }
    // Failed Destroy cannot prove callbacks ended. Retain one quarantined context/window and block reuse.
    if (r.safeToDelete) {
        { std::lock_guard<std::mutex> lock(r.mutex); r.inputs.clear(); r.outputs.clear(); r.frames.clear(); r.queueBytes = 0; }
        if (r.window) { OH_NativeWindow_DestroyNativeWindow(r.window); r.window = nullptr; }
    }
    {
        std::lock_guard<std::mutex> lock(r.diagnosticMutex); r.ready = false; r.workerDone = true; r.released = r.safeToDelete;
        r.windowReleased = r.safeToDelete && r.windowCreated; r.cleanupComplete = r.safeToDelete;
        r.phase = !r.safeToDelete ? "cleanup_failed" : (r.error.load() ? "failed" : (r.cancel.load() ? "cancelled" : "released"));
        r.report = r.SnapshotLocked(); r.SetStatus(r.report);
    }
    if (!r.safeToDelete) Quarantine(request);
    Log("RELEASE slot=%u gen=%u au=%u submitted=%u decoded=%u rendered=%u error=%d cleanup_complete=%d", r.renderSlot, r.generation, r.au.load(), r.submitted.load(), r.decoded.load(), r.rendered.load(), r.error.load(), r.safeToDelete);
}
void Complete(napi_env env, napi_status status, void *data)
{
    auto *holder = static_cast<Work *>(data); const auto r = holder->request;
    if (r->report.empty()) {
        { std::lock_guard<std::mutex> lock(r->diagnosticMutex); r->workerDone = true; r->released = true; r->cleanupComplete = true; r->phase = "cancelled"; }
        r->cancel.store(true); r->Publish(); r->report = r->Status();
    }
    napi_value result; napi_create_string_utf8(env, r->report.c_str(), r->report.size(), &result);
    // Only this Request is completed. It never clears a successor or sibling slot.
    r->running.store(false);
    if (status == napi_ok) napi_resolve_deferred(env, r->deferred, result);
    else { napi_value e; napi_create_error(env, nullptr, result, &e); napi_reject_deferred(env, r->deferred, e); }
    napi_delete_async_work(env, r->work); r->work = nullptr; delete holder;
}
bool Uint32(napi_env env, napi_value value, uint32_t &result)
{
    double number = 0;
    if (napi_get_value_double(env, value, &number) != napi_ok || !std::isfinite(number) || number < 0 || number > UINT32_MAX || std::floor(number) != number) return false;
    result = static_cast<uint32_t>(number); return true;
}
bool Identity(napi_env env, napi_value slotValue, napi_value generationValue, uint32_t &slot, uint32_t &gen)
{
    return Uint32(env, slotValue, slot) && slot < s5video::kRendererSlots && Uint32(env, generationValue, gen) && gen != 0;
}
bool Surface(napi_env env, napi_value value, uint64_t &sid)
{
    char surface[32]{}; size_t len = 0;
    return napi_get_value_string_utf8(env, value, surface, sizeof(surface), &len) == napi_ok && s5video::ParseSurfaceId(surface, len, sid);
}
napi_value StartRequest(napi_env env, const RequestPtr &r, uint64_t sid, uint32_t codec)
{
    const char *failure = nullptr;
    {
        std::lock_guard<std::mutex> lock(gRegistryMutex);
        if (!r || gSlots[r->renderSlot] != r || !r->running.load() || r->Stopping() || r->startConsumed) failure = "Video reservation is stale or already started";
        else {
            for (const auto &other : gSlots) {
                if (other && other != r && other->surfaceId == sid && (other->running.load() || other->nativeBlocked.load())) { failure = "Surface is already leased by another renderer"; break; }
            }
            if (!failure) { r->surfaceId = sid; r->requestedCodec = static_cast<int>(codec); r->startConsumed = true; }
        }
    }
    if (failure) { napi_throw_error(env, nullptr, failure); return nullptr; }
    r->Phase("queued");
    auto *holder = new Work{r};
    napi_value promise = nullptr, name = nullptr;
    auto ret = napi_create_promise(env, &r->deferred, &promise);
    if (ret == napi_ok) ret = napi_create_string_utf8(env, "S5LiveVideo", NAPI_AUTO_LENGTH, &name);
    if (ret == napi_ok) ret = napi_create_async_work(env, nullptr, name, Execute, Complete, holder, &r->work);
    if (ret == napi_ok) ret = napi_queue_async_work(env, r->work);
    if (ret != napi_ok) {
        { std::lock_guard<std::mutex> lock(r->diagnosticMutex); r->phase = "failed"; r->workerDone = true; r->released = true; r->cleanupComplete = true; }
        r->Fail(-43, "QueueVideoWorker"); if (r->work) napi_delete_async_work(env, r->work); r->work = nullptr;
        r->running.store(false); delete holder;
        napi_throw_error(env, nullptr, "Cannot queue live video worker"); return nullptr;
    }
    return promise;
}
napi_value Play(napi_env env, napi_callback_info info)
{
    size_t argc = 2; napi_value argv[2]; napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    {
        std::lock_guard<std::mutex> lock(gRegistryMutex);
        if (gSlots[0] && (gSlots[0]->nativeBlocked.load() || gSlots[0]->running.load())) {
            napi_throw_error(env, nullptr, "Session already running or cleanup incomplete"); return nullptr;
        }
    }
    uint64_t sid = 0;
    uint32_t codec = 0;
    if (argc < 1 || argc > 2 || !Surface(env, argv[0], sid) || (argc == 2 && (!Uint32(env, argv[1], codec) || codec > 2))) {
        const std::string text = R"({"ready":false,"starting":false,"running":false,"phase":"failed","error":-42,"failureStage":"SurfaceId","firstError":-42,"systemCode":null,"failureKind":"local"})";
        if (auto r = Legacy()) r->SetStatus(text);
        else { std::lock_guard<std::mutex> lock(gRegistryMutex); gLegacyIdleStatus = text; }
        napi_throw_error(env, nullptr, "Expected a positive decimal uint64 live Surface ID"); return nullptr;
    }
    const char *failure = nullptr; const auto r = Reserve(0, true, failure);
    if (!r) { napi_throw_error(env, nullptr, failure); return nullptr; }
    napi_value result = StartRequest(env, r, sid, codec);
    // Legacy callers have no reservation handle to cancel after a failed start.
    if (!result) RequestStop(r, true);
    return result;
}
napi_value ReserveSlot(napi_env env, napi_callback_info info)
{
    size_t argc = 1; napi_value argv[1]; napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr); uint32_t slot = 0;
    if (argc != 1 || !Uint32(env, argv[0], slot) || slot >= s5video::kRendererSlots) { napi_throw_error(env, nullptr, "Expected renderer slot 0 or 1"); return nullptr; }
    const char *failure = nullptr; auto r = Reserve(slot, false, failure);
    if (!r) { napi_throw_error(env, nullptr, failure); return nullptr; }
    napi_value result; napi_create_uint32(env, r->generation, &result); return result;
}
napi_value PlaySlot(napi_env env, napi_callback_info info)
{
    size_t argc = 4; napi_value argv[4]; napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr); uint32_t slot = 0, gen = 0, codec = 0; uint64_t sid = 0;
    if (argc < 3 || argc > 4 || !Identity(env, argv[0], argv[1], slot, gen) || !Surface(env, argv[2], sid) || (argc == 4 && (!Uint32(env, argv[3], codec) || codec > 2))) { napi_throw_error(env, nullptr, "Expected slot, native generation, Surface ID and optional codec"); return nullptr; }
    return StartRequest(env, Lookup(slot, gen), sid, codec);
}
napi_value Capabilities(napi_env env, napi_callback_info)
{
    const auto hw = QueryCapability(HARDWARE), sw = QueryCapability(SOFTWARE);
    auto *cap = hw.cap && hw.hardware && hw.sizeSupported ? hw.cap : (sw.cap && !sw.hardware && sw.sizeSupported ? sw.cap : nullptr); OH_AVRange rate720{}, rate1080{};
    const bool p720 = cap && OH_AVCapability_IsVideoSizeSupported(cap, 1280, 720), p1080 = cap && OH_AVCapability_IsVideoSizeSupported(cap, 1920, 1080);
    const bool r720 = p720 && OH_AVCapability_GetVideoFrameRateRangeForSize(cap, 1280, 720, &rate720) == AV_ERR_OK;
    const bool r1080 = p1080 && OH_AVCapability_GetVideoFrameRateRangeForSize(cap, 1920, 1080, &rate1080) == AV_ERR_OK;
    const std::string text = "{\"available\":" + Bool(cap) + ",\"hardware\":" + Bool(cap && OH_AVCapability_IsHardware(cap)) +
        ",\"supports720p\":" + Bool(p720) + ",\"supports1080p\":" + Bool(p1080) + ",\"max720Fps\":" + (r720 ? std::to_string(rate720.maxVal) : "null") +
        ",\"max1080Fps\":" + (r1080 ? std::to_string(rate1080.maxVal) : "null") + ",\"sessionFpsLimit\":60,\"decoders\":[" + hw.json + "," + sw.json + "]}";
    napi_value v; napi_create_string_utf8(env, text.c_str(), text.size(), &v); return v;
}
napi_value SizeSupport(napi_env env, napi_callback_info info)
{
    size_t argc = 2; napi_value argv[2]; napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    uint32_t w = 0, h = 0;
    const bool valid = argc == 2 && napi_get_value_uint32(env, argv[0], &w) == napi_ok && napi_get_value_uint32(env, argv[1], &h) == napi_ok;
    const auto r = Legacy(); const bool supported = valid && SizeSupported(r, w, h);
    const std::string text = "{\"supported\":" + Bool(supported) + ",\"maxWidth\":" + std::to_string(r ? r->configWidth.load() : 1280) +
        ",\"maxHeight\":" + std::to_string(r ? r->configHeight.load() : 720) + ",\"error\":" + (supported ? "null" : Quote("active_decoder_size_unsupported")) + "}";
    napi_value v; napi_create_string_utf8(env, text.c_str(), text.size(), &v); return v;
}
std::string MetricsText(const RequestPtr &r)
{
    return "{\"nowMs\":" + std::to_string(NowMs()) + ",\"lastFrameMs\":" + std::to_string(r ? r->sampleMs.load() : 0) +
        ",\"decoded\":" + std::to_string(r ? r->decoded.load() : 0) + ",\"rendered\":" + std::to_string(r ? r->rendered.load() : 0) +
        ",\"videoEpoch\":" + std::to_string(r ? r->videoEpoch.load(std::memory_order_acquire) : 0) +
        ",\"renderedEpoch\":" + std::to_string(r ? r->renderedEpoch.load(std::memory_order_acquire) : 0) +
        ",\"received\":" + std::to_string(r ? r->au.load() : 0) +
        ",\"codedWidth\":" + std::to_string(r ? r->width.load() : 0) + ",\"codedHeight\":" + std::to_string(r ? r->height.load() : 0) +
        ",\"rotation\":" + std::to_string(r ? (r->renderedOrientation.load() & 3) * 90 : 0) + ",\"flipped\":" + Bool(r && (r->renderedOrientation.load() & 4)) +
        ",\"orientationApplyCode\":" + std::to_string(r ? r->orientationApplyCode.load() : 0) +
        ",\"width\":" + std::to_string(r ? r->renderedWidth.load() : 0) + ",\"height\":" + std::to_string(r ? r->renderedHeight.load() : 0) +
        ",\"codec\":" + std::to_string(r ? r->codecType.load() : 0) +
        ",\"queueMs\":" + std::to_string(r ? r->queueMs.load() : 0) +
        ",\"rtpQueueMs\":" + std::to_string(r ? r->rtpQueueMs.load() : 0) +
        ",\"decoderMs\":" + std::to_string(r ? r->decoderMs.load() : 0) +
        ",\"arrivalToRenderMs\":" + std::to_string(r ? r->arrivalToRenderMs.load() : 0) +
        ",\"discarded\":" + std::to_string(r ? r->discarded.load() : 0) +
        ",\"running\":" + Bool(r && r->running.load()) +
        (r ? ",\"renderSlot\":" + std::to_string(r->renderSlot) + ",\"generation\":" + std::to_string(r->generation) : "") + "}";
}
napi_value Text(napi_env env, const std::string &text) { napi_value v; napi_create_string_utf8(env, text.c_str(), text.size(), &v); return v; }
napi_value Metrics(napi_env env, napi_callback_info) { return Text(env, MetricsText(Legacy())); }
napi_value Status(napi_env env, napi_callback_info)
{
    if (auto r = Legacy()) return Text(env, r->Status());
    std::string text;
    { std::lock_guard<std::mutex> lock(gRegistryMutex); text = gSlots[0] && !gSlots[0]->legacyMode ? kIdleStatus : gLegacyIdleStatus; }
    return Text(env, text);
}
void RequestStop(const RequestPtr &r, bool hard)
{
    if (!r) return;
    bool unstarted = false;
    {
        std::lock_guard<std::mutex> lock(gRegistryMutex);
        if (!r->running.load()) return;
        int64_t expected = 0; r->stopAt.compare_exchange_strong(expected, NowMs());
        r->finish.store(true); if (hard) r->cancel.store(true); r->accepting.store(false);
        unstarted = !r->startConsumed;
        if (unstarted) r->running.store(false);
    }
    if (unstarted) {
        std::lock_guard<std::mutex> lock(r->diagnosticMutex);
        r->workerDone = true; r->ready = false; r->released = true; r->cleanupComplete = true;
        r->phase = hard ? "cancelled" : "released"; r->SetStatus(r->SnapshotLocked());
    }
    r->cv.notify_all();
}
napi_value Undefined(napi_env env) { napi_value v; napi_get_undefined(env, &v); return v; }
napi_value Stop(napi_env env, napi_callback_info) { RequestStop(Legacy(), false); return Undefined(env); }
napi_value HardStop(napi_env env, napi_callback_info) { RequestStop(Legacy(), true); return Undefined(env); }
bool ReadIdentity(napi_env env, napi_callback_info info, uint32_t &slot, uint32_t &gen)
{
    size_t argc = 2; napi_value argv[2]; napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc == 2 && Identity(env, argv[0], argv[1], slot, gen)) return true;
    napi_throw_error(env, nullptr, "Expected renderer slot and positive native generation"); return false;
}
std::string Stale(uint32_t slot, uint32_t gen)
{
    return "{\"ready\":false,\"starting\":false,\"running\":false,\"phase\":\"stale\",\"error\":0,\"renderSlot\":" + std::to_string(slot) + ",\"generation\":" + std::to_string(gen) + "}";
}
napi_value SlotStatus(napi_env env, napi_callback_info info)
{
    uint32_t slot = 0, gen = 0; if (!ReadIdentity(env, info, slot, gen)) return nullptr;
    auto r = Lookup(slot, gen); return Text(env, r ? r->Status() : Stale(slot, gen));
}
napi_value SlotMetrics(napi_env env, napi_callback_info info)
{
    uint32_t slot = 0, gen = 0; if (!ReadIdentity(env, info, slot, gen)) return nullptr;
    auto r = Lookup(slot, gen); return Text(env, r ? MetricsText(r) : Stale(slot, gen));
}
napi_value SlotSizeSupport(napi_env env, napi_callback_info info)
{
    size_t argc = 4; napi_value argv[4]; napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    uint32_t slot = 0, gen = 0, w = 0, h = 0;
    if (argc != 4 || !Identity(env, argv[0], argv[1], slot, gen) || !Uint32(env, argv[2], w) || !Uint32(env, argv[3], h)) { napi_throw_error(env, nullptr, "Expected slot, generation, width and height"); return nullptr; }
    const auto r = Lookup(slot, gen); const bool supported = SizeSupported(r, w, h);
    return Text(env, "{\"supported\":" + Bool(supported) + ",\"renderSlot\":" + std::to_string(slot) + ",\"generation\":" + std::to_string(gen) +
        ",\"maxWidth\":" + std::to_string(r ? r->configWidth.load() : 0) + ",\"maxHeight\":" + std::to_string(r ? r->configHeight.load() : 0) +
        ",\"error\":" + (supported ? "null" : Quote(r ? "active_decoder_size_unsupported" : "stale_video_generation")) + "}");
}
napi_value StopSlot(napi_env env, napi_callback_info info)
{
    uint32_t slot = 0, gen = 0; if (!ReadIdentity(env, info, slot, gen)) return nullptr;
    RequestStop(Lookup(slot, gen), false); return Undefined(env);
}
napi_value HardStopSlot(napi_env env, napi_callback_info info)
{
    uint32_t slot = 0, gen = 0; if (!ReadIdentity(env, info, slot, gen)) return nullptr;
    RequestStop(Lookup(slot, gen), true); return Undefined(env);
}
napi_value StopAll(napi_env env, napi_callback_info info)
{
    size_t argc = 1; napi_value argv[1]; napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr); bool hard = false;
    if (argc != 1 || napi_get_value_bool(env, argv[0], &hard) != napi_ok) { napi_throw_error(env, nullptr, "Expected hard-stop boolean"); return nullptr; }
    s5_video_stop_all(hard); return Undefined(env);
}
} // namespace
void S4VideoExports(napi_env env, napi_value exports)
{
    napi_property_descriptor p[] = {
        {"videoCapabilities", nullptr, Capabilities, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"videoSizeSupport", nullptr, SizeSupport, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"videoMetrics", nullptr, Metrics, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startVideo", nullptr, Play, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"videoStatus", nullptr, Status, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopVideo", nullptr, Stop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"hardStopVideo", nullptr, HardStop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"reserveVideoSlot", nullptr, ReserveSlot, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startVideoSlot", nullptr, PlaySlot, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"videoSlotStatus", nullptr, SlotStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"videoSlotMetrics", nullptr, SlotMetrics, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"videoSlotSizeSupport", nullptr, SlotSizeSupport, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopVideoSlot", nullptr, StopSlot, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"hardStopVideoSlot", nullptr, HardStopSlot, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopAllVideos", nullptr, StopAll, nullptr, nullptr, nullptr, napi_default, nullptr}
    };
    napi_define_properties(env, exports, sizeof(p) / sizeof(p[0]), p);
}
