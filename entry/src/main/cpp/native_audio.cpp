// SPDX-License-Identifier: GPL-3.0-only
#include "native_audio.h"
#include "audio_core.h"
#include <ohaudio/native_audiostreambuilder.h>
#include <ohaudio/native_audiorenderer.h>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <climits>
#include <cstring>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
namespace {
std::atomic<bool> accepting{false};
uint64_t NowMs() {
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());
}
struct Settings {
    bool enabled = false, muted = false, paused = false, background = false;
    float volume = 1.0f;
    s5audio::Config buffers{};
};
class Audio {
public:
    ~Audio() { Stop(); }
    static Audio& Instance() { static Audio audio; return audio; }
    Settings Choice() { std::lock_guard<std::mutex> lock(control_); return settings_; }
    std::string Configure(const Settings& settings, bool explicitEnable) {
        std::lock_guard<std::mutex> lock(control_);
        const bool changed = settings.buffers.jitterMs != settings_.buffers.jitterMs ||
            settings.buffers.ringMs != settings_.buffers.ringMs;
        settings_ = settings;
        volume_.store(settings.volume, std::memory_order_relaxed);
        muted_.store(settings.muted, std::memory_order_relaxed);
        const bool wanted = settings.enabled && !settings.paused && !settings.background;
        if (!wanted) StopLocked();
        else if (changed || (explicitEnable && (!running_.load() || focus_.load() == 2)) ||
                 (!worker_.joinable() && focus_.load() != 2)) {
            StopLocked();
            StartLocked();
        }
        return StatusLocked();
    }
    void Stop() {
        std::lock_guard<std::mutex> lock(control_);
        settings_.enabled = false;
        StopLocked();
    }
    void Background() {
        std::lock_guard<std::mutex> lock(control_);
        settings_.background = true;
        StopLocked();
    }
    std::string Status() { std::lock_guard<std::mutex> lock(control_); return StatusLocked(); }
    void Push(uint16_t seq, uint32_t timestamp, const uint8_t* payload, size_t size) {
        if (!accepting.load(std::memory_order_acquire)) return;
        std::unique_lock<std::mutex> lock(coreMutex_, std::try_to_lock);
        if (!lock.owns_lock()) { busyDrops_.fetch_add(1, std::memory_order_relaxed); return; }
        if (accepting.load(std::memory_order_acquire)) core_.Push(seq, timestamp, payload, size, NowMs());
    }
private:
    static OH_AudioData_Callback_Result Write(OH_AudioRenderer*, void* user, void* data, int32_t bytes) {
        if (!data || bytes <= 0) return AUDIO_DATA_CALLBACK_RESULT_INVALID;
        auto& self = *static_cast<Audio*>(user);
        std::memset(data, 0, static_cast<size_t>(bytes));
        if (!accepting.load(std::memory_order_acquire)) return AUDIO_DATA_CALLBACK_RESULT_VALID;
        const float gain = (self.muted_.load(std::memory_order_relaxed) ||
            self.focusMuted_.load(std::memory_order_relaxed)) ? 0.0f :
            self.volume_.load(std::memory_order_relaxed) * self.duck_.load(std::memory_order_relaxed);
        self.core_.Read(static_cast<int16_t*>(data), static_cast<size_t>(bytes) / 4, gain);
        self.callbackFrames_.fetch_add(static_cast<uint64_t>(bytes / 4), std::memory_order_relaxed);
        return AUDIO_DATA_CALLBACK_RESULT_VALID;
    }
    static void Interrupt(OH_AudioRenderer*, void* user, OH_AudioInterrupt_ForceType type,
                          OH_AudioInterrupt_Hint hint) {
        auto& self = *static_cast<Audio*>(user);
        self.lastInterrupt_.store(static_cast<int>(hint), std::memory_order_relaxed);
        self.interruptForce_.store(static_cast<int>(type), std::memory_order_relaxed);
        switch (hint) {
        case AUDIOSTREAM_INTERRUPT_HINT_PAUSE:
            accepting.store(false, std::memory_order_release); self.focus_.store(1); break;
        case AUDIOSTREAM_INTERRUPT_HINT_STOP:
            accepting.store(false, std::memory_order_release); self.focus_.store(2); break;
        case AUDIOSTREAM_INTERRUPT_HINT_RESUME:
            if (self.focus_.load() != 2) self.focus_.store(0); break;
        case AUDIOSTREAM_INTERRUPT_HINT_DUCK: self.duck_.store(0.2f); break;
        case AUDIOSTREAM_INTERRUPT_HINT_UNDUCK: self.duck_.store(1.0f); break;
        case AUDIOSTREAM_INTERRUPT_HINT_MUTE: self.focusMuted_.store(true); break;
        case AUDIOSTREAM_INTERRUPT_HINT_UNMUTE: self.focusMuted_.store(false); break;
        default: break;
        }
        self.wake_.notify_one(); // Lifecycle API calls are deferred off the audio callback.
    }
    static void Error(OH_AudioRenderer*, void* user, OH_AudioStream_Result error) {
        auto& self = *static_cast<Audio*>(user);
        self.lastError_.store(static_cast<int>(error));
        accepting.store(false, std::memory_order_release);
        self.focus_.store(2);
        self.wake_.notify_one();
    }
    bool Check(OH_AudioStream_Result result) {
        if (result == AUDIOSTREAM_SUCCESS) return true;
        lastError_.store(static_cast<int>(result));
        return false;
    }
    bool CreateRenderer() {
        if (!Check(OH_AudioStreamBuilder_Create(&builder_, AUDIOSTREAM_TYPE_RENDERER))) return false;
        if (!Check(OH_AudioStreamBuilder_SetSamplingRate(builder_, 48000)) ||
            !Check(OH_AudioStreamBuilder_SetChannelCount(builder_, 2)) ||
            !Check(OH_AudioStreamBuilder_SetSampleFormat(builder_, AUDIOSTREAM_SAMPLE_S16LE)) ||
            !Check(OH_AudioStreamBuilder_SetEncodingType(builder_, AUDIOSTREAM_ENCODING_TYPE_RAW)) ||
            !Check(OH_AudioStreamBuilder_SetLatencyMode(builder_, AUDIOSTREAM_LATENCY_MODE_NORMAL)) ||
            !Check(OH_AudioStreamBuilder_SetRendererInfo(builder_, AUDIOSTREAM_USAGE_MOVIE)) ||
            !Check(OH_AudioStreamBuilder_SetRendererInterruptMode(builder_, AUDIOSTREAM_INTERRUPT_MODE_INDEPENDENT)) ||
            !Check(OH_AudioStreamBuilder_SetRendererWriteDataCallback(builder_, Write, this)) ||
            !Check(OH_AudioStreamBuilder_SetRendererInterruptCallback(builder_, Interrupt, this)) ||
            !Check(OH_AudioStreamBuilder_SetRendererErrorCallback(builder_, Error, this)) ||
            !Check(OH_AudioStreamBuilder_GenerateRenderer(builder_, &renderer_))) return false;
        rendererAllocated_.store(true);
        // Gain/mute/duck are applied to PCM in Write, once; hardware gain stays unity.
        return Check(OH_AudioRenderer_SetVolume(renderer_, 1.0f));
    }
    void ReleaseRenderer() {
        accepting.store(false, std::memory_order_release);
        if (renderer_) {
            lastStop_.store(static_cast<int>(OH_AudioRenderer_Stop(renderer_)));
            const auto release = OH_AudioRenderer_Release(renderer_);
            lastRelease_.store(static_cast<int>(release));
            if (release == AUDIOSTREAM_SUCCESS) renderer_ = nullptr;
            else { lastError_.store(static_cast<int>(release)); state_.store(5); }
        }
        if (builder_ && !renderer_) {
            const auto destroy = OH_AudioStreamBuilder_Destroy(builder_);
            lastBuilderDestroy_.store(static_cast<int>(destroy));
            if (destroy == AUDIOSTREAM_SUCCESS) builder_ = nullptr;
            else { lastError_.store(static_cast<int>(destroy)); state_.store(5); }
        }
        rendererAllocated_.store(renderer_ != nullptr);
    }
    void StartLocked() {
        // A failed release keeps the handle for a later explicit stop retry.
        if (renderer_ || builder_) { state_.store(5); return; }
        lastError_.store(0); focus_.store(0); lastInterrupt_.store(0); interruptForce_.store(-1);
        lastStop_.store(INT_MIN); lastRelease_.store(INT_MIN); lastBuilderDestroy_.store(INT_MIN);
        duck_.store(1); focusMuted_.store(false); busyDrops_.store(0); callbackFrames_.store(0);
        { std::lock_guard<std::mutex> lock(coreMutex_);
          if (!core_.Start(settings_.buffers)) { state_.store(5); lastError_.store(-1001); return; } }
        state_.store(1); // starting
        if (!CreateRenderer()) {
            ReleaseRenderer();
            std::lock_guard<std::mutex> lock(coreMutex_); core_.Stop(); state_.store(5); return;
        }
        if (!Check(OH_AudioRenderer_Start(renderer_))) {
            ReleaseRenderer();
            std::lock_guard<std::mutex> lock(coreMutex_); core_.Stop(); state_.store(5); return;
        }
        running_.store(true);
        state_.store(2);
        accepting.store(focus_.load() == 0, std::memory_order_release);
        try { worker_ = std::thread([this] { Run(); }); }
        catch (...) {
            running_.store(false); ReleaseRenderer();
            std::lock_guard<std::mutex> lock(coreMutex_); core_.Stop(); state_.store(5); lastError_.store(-1002);
        }
    }
    void Run() {
        bool paused = false;
        while (running_.load()) {
            const int focus = focus_.load();
            if (focus == 2) { state_.store(lastError_.load() ? 5 : 4); break; }
            if (focus == 1 && !paused) {
                accepting.store(false, std::memory_order_release);
                // In FORCE mode the system already paused it; a repeated pause may return illegal state.
                if (interruptForce_.load() == AUDIOSTREAM_INTERRUPT_SHARE)
                    Check(OH_AudioRenderer_Pause(renderer_));
                { std::lock_guard<std::mutex> lock(coreMutex_); core_.Reset(); }
                paused = true; state_.store(3);
            } else if (focus == 0 && paused) {
                { std::lock_guard<std::mutex> lock(coreMutex_); core_.Reset(); }
                if (!Check(OH_AudioRenderer_Start(renderer_))) { state_.store(5); break; }
                paused = false; state_.store(2);
                if (focus_.load() == 0 && running_.load()) accepting.store(true, std::memory_order_release);
            }
            if (!paused) { std::lock_guard<std::mutex> lock(coreMutex_); core_.Tick(NowMs()); }
            std::unique_lock<std::mutex> wait(waitMutex_);
            wake_.wait_for(wait, std::chrono::milliseconds(2));
        }
        // Release synchronizes renderer callbacks before the PCM/decoder are reclaimed.
        ReleaseRenderer();
        { std::lock_guard<std::mutex> lock(coreMutex_); core_.Stop(); }
        running_.store(false);
    }
    void StopLocked() {
        accepting.store(false, std::memory_order_release);
        running_.store(false); wake_.notify_one();
        if (worker_.joinable()) worker_.join();
        else {
            ReleaseRenderer();
            std::lock_guard<std::mutex> lock(coreMutex_); core_.Stop();
        }
        state_.store((renderer_ || builder_) ? 5 : 0);
    }
    std::string StatusLocked() {
        s5audio::Stats stats;
        { std::lock_guard<std::mutex> lock(coreMutex_); stats = core_.Snapshot(); }
        static const char* names[] = {"stopped", "starting", "running", "focus_paused", "focus_stopped", "error"};
        const int state = state_.load();
        const auto result = [](int value) { return value == INT_MIN ? std::string("null") : std::to_string(value); };
        std::ostringstream out;
        out << std::boolalpha << "{\"ok\":" << (lastError_.load() == 0)
            << ",\"codec\":\"libopus-1.5.2\",\"sampleRate\":48000,\"channels\":2,\"pcmFormat\":\"s16le\""
            << ",\"enabled\":" << settings_.enabled << ",\"volume\":" << settings_.volume
            << ",\"muted\":" << settings_.muted << ",\"paused\":" << settings_.paused
            << ",\"background\":" << settings_.background << ",\"jitterMs\":" << settings_.buffers.jitterMs
            << ",\"ringMs\":" << settings_.buffers.ringMs << ",\"state\":\"" << names[state] << "\""
            << ",\"accepting\":" << accepting.load() << ",\"rendererAllocated\":" << rendererAllocated_.load()
            << ",\"lastError\":" << lastError_.load() << ",\"lastStopResult\":" << result(lastStop_.load())
            << ",\"lastReleaseResult\":" << result(lastRelease_.load()) << ",\"lastBuilderDestroyResult\":" << result(lastBuilderDestroy_.load())
            << ",\"interruptHint\":" << lastInterrupt_.load() << ",\"interruptForce\":"
            << (interruptForce_.load() < 0 ? std::string("null") : std::to_string(interruptForce_.load()))
            << ",\"duckGain\":" << duck_.load() << ",\"focusMuted\":" << focusMuted_.load()
            << ",\"receivedPackets\":" << stats.received << ",\"decodedPackets\":" << stats.decoded
            << ",\"invalidPackets\":" << stats.invalid << ",\"duplicatePackets\":" << stats.duplicate
            << ",\"latePackets\":" << stats.late << ",\"queueDrops\":" << stats.queueDrops
            << ",\"busyDrops\":" << busyDrops_.load() << ",\"resyncs\":" << stats.resyncs
            << ",\"timestampResyncs\":" << stats.timestampResyncs << ",\"plcPackets\":" << stats.plc
            << ",\"decodeErrors\":" << stats.decodeErrors << ",\"decodedPcmFrames\":" << stats.pcmFrames
            << ",\"callbackFrames\":" << callbackFrames_.load() << ",\"underrunFrames\":" << stats.underrunFrames
            << ",\"queuedPackets\":" << stats.queuedPackets << ",\"maxQueuedPackets\":" << stats.maxQueuedPackets
            << ",\"pcmRingFrames\":" << stats.ringFrames << ",\"pcmRingCapacityFrames\":" << stats.ringCapacityFrames
            << ",\"pcmRingDroppedFrames\":" << stats.ringDrops
            << ",\"remoteAck\":null,\"actualAudibility\":null}";
        return out.str();
    }
    std::mutex control_, coreMutex_, waitMutex_;
    std::condition_variable wake_;
    Settings settings_{};
    s5audio::Engine core_;
    std::thread worker_;
    OH_AudioStreamBuilder* builder_ = nullptr;
    OH_AudioRenderer* renderer_ = nullptr;
    std::atomic<bool> running_{false}, rendererAllocated_{false}, muted_{false}, focusMuted_{false};
    std::atomic<float> volume_{1}, duck_{1};
    std::atomic<int> focus_{0}, state_{0}, lastError_{0}, lastInterrupt_{0}, interruptForce_{-1};
    std::atomic<int> lastStop_{INT_MIN}, lastRelease_{INT_MIN}, lastBuilderDestroy_{INT_MIN};
    std::atomic<uint64_t> busyDrops_{0}, callbackFrames_{0};
};
napi_value Json(napi_env env, const std::string& text) {
    napi_value result = nullptr;
    napi_create_string_utf8(env, text.c_str(), text.size(), &result);
    return result;
}
bool Bool(napi_env env, napi_value object, const char* key, bool& value, bool* present = nullptr) {
    bool exists = false;
    if (napi_has_named_property(env, object, key, &exists) != napi_ok) return false;
    if (present) *present = exists;
    if (!exists) return true;
    napi_value property;
    return napi_get_named_property(env, object, key, &property) == napi_ok &&
        napi_get_value_bool(env, property, &value) == napi_ok;
}
bool Number(napi_env env, napi_value object, const char* key, double& value) {
    bool exists = false;
    if (napi_has_named_property(env, object, key, &exists) != napi_ok) return false;
    if (!exists) return true;
    napi_value property;
    return napi_get_named_property(env, object, key, &property) == napi_ok &&
        napi_get_value_double(env, property, &value) == napi_ok && std::isfinite(value);
}
napi_value Configure(napi_env env, napi_callback_info info) {
    size_t argc = 1, size = 0;
    napi_value args[1], global, json, parse, object;
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 1 ||
        napi_get_value_string_utf8(env, args[0], nullptr, 0, &size) != napi_ok || size > 2048)
        return Json(env, "{\"ok\":false,\"error\":\"bounded_json_string_required\"}");
    if (napi_get_global(env, &global) != napi_ok || napi_get_named_property(env, global, "JSON", &json) != napi_ok ||
        napi_get_named_property(env, json, "parse", &parse) != napi_ok ||
        napi_call_function(env, json, parse, 1, args, &object) != napi_ok) {
        bool pending = false; napi_is_exception_pending(env, &pending);
        if (pending) { napi_value ignored; napi_get_and_clear_last_exception(env, &ignored); }
        return Json(env, "{\"ok\":false,\"error\":\"invalid_json\"}");
    }
    napi_valuetype type;
    bool array = false;
    napi_value nullValue; bool isNull = false;
    napi_get_null(env, &nullValue); napi_strict_equals(env, object, nullValue, &isNull);
    if (napi_typeof(env, object, &type) != napi_ok || type != napi_object || isNull ||
        napi_is_array(env, object, &array) != napi_ok || array)
        return Json(env, "{\"ok\":false,\"error\":\"configuration_object_required\"}");
    auto settings = Audio::Instance().Choice();
    bool explicitEnable = false;
    double volume = settings.volume, jitter = settings.buffers.jitterMs, ring = settings.buffers.ringMs;
    if (!Bool(env, object, "enabled", settings.enabled, &explicitEnable) ||
        !Bool(env, object, "muted", settings.muted) || !Bool(env, object, "paused", settings.paused) ||
        !Bool(env, object, "background", settings.background) || !Number(env, object, "volume", volume) ||
        !Number(env, object, "jitterMs", jitter) || !Number(env, object, "ringMs", ring) ||
        volume < 0 || volume > 1 || jitter < 10 || jitter > 120 || std::floor(jitter) != jitter ||
        ring < 40 || ring > 400 || std::floor(ring) != ring)
        return Json(env, "{\"ok\":false,\"error\":\"invalid_configuration\"}");
    settings.volume = static_cast<float>(volume);
    settings.buffers.jitterMs = static_cast<uint32_t>(jitter);
    settings.buffers.ringMs = static_cast<uint32_t>(ring);
    return Json(env, Audio::Instance().Configure(settings, explicitEnable && settings.enabled));
}
napi_value Status(napi_env env, napi_callback_info) { return Json(env, Audio::Instance().Status()); }
napi_value Stop(napi_env env, napi_callback_info) { Audio::Instance().Stop(); return Json(env, Audio::Instance().Status()); }
void Cleanup(void*) { Audio::Instance().Stop(); }
} // namespace
extern "C" void s5_audio_push(uint16_t seq, uint32_t timestamp, const uint8_t* payload, size_t size) {
    if (!accepting.load(std::memory_order_acquire)) return;
    Audio::Instance().Push(seq, timestamp, payload, size);
}
extern "C" void s5_audio_stop(void) { Audio::Instance().Stop(); }
extern "C" void s5_audio_background(void) { Audio::Instance().Background(); }
napi_value InitAdvancedAudio(napi_env env, napi_value exports) {
    napi_property_descriptor props[] = {
        {"audioConfigure", nullptr, Configure, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"audioStatus", nullptr, Status, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"audioStop", nullptr, Stop, nullptr, nullptr, nullptr, napi_default, nullptr}
    };
    napi_define_properties(env, exports, sizeof(props) / sizeof(props[0]), props);
    napi_add_env_cleanup_hook(env, Cleanup, nullptr);
    return exports;
}
