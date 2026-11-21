// SPDX-License-Identifier: GPL-3.0-only
#ifndef S5_AUDIO_CORE_H
#define S5_AUDIO_CORE_H
#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <vector>
struct OpusDecoder;
namespace s5audio {
constexpr uint32_t kRate = 48000;
constexpr size_t kChannels = 2;
constexpr size_t kMaxFrames = 5760; // RFC 6716: 120 ms at 48 kHz.
constexpr size_t kMaxPayload = 8192;
constexpr size_t kPacketSlots = 64;
struct Config { uint32_t jitterMs = 40; uint32_t ringMs = 160; };
struct Stats {
    uint64_t received = 0, decoded = 0, invalid = 0, duplicate = 0, late = 0;
    uint64_t queueDrops = 0, resyncs = 0, timestampResyncs = 0, plc = 0, decodeErrors = 0;
    uint64_t pcmFrames = 0, ringDrops = 0, underrunFrames = 0;
    size_t queuedPackets = 0, ringFrames = 0, ringCapacityFrames = 0, maxQueuedPackets = 0;
};
// A bounded ring; the renderer uses try_lock and emits silence on contention.
// No Opus decoding, allocation, waiting or N-API calls run on its callback.
class PcmRing {
public:
    void Configure(size_t frames);
    void Clear();
    void Write(const int16_t* pcm, size_t frames);
    size_t Read(int16_t* pcm, size_t frames, float gain);
    void Snapshot(Stats& stats) const;
private:
    mutable std::mutex mutex_;
    std::vector<int16_t> samples_;
    size_t read_ = 0, size_ = 0;
    uint64_t dropped_ = 0;
};
// Push/Tick/Stop/Snapshot are externally serialized. Read is independently safe.
// Tick's explicit monotonic milliseconds make loss/reorder tests deterministic.
class Engine {
public:
    Engine() = default;
    ~Engine();
    Engine(const Engine&) = delete;
    Engine& operator=(const Engine&) = delete;
    bool Start(Config config);
    void Stop();
    void Reset(); // flush discontinuity/focus; retain configured capacities/stats.
    bool Push(uint16_t seq, uint32_t timestamp, const uint8_t* data, size_t size, uint64_t nowMs);
    void Tick(uint64_t nowMs);
    size_t Read(int16_t* pcm, size_t frames, float gain);
    Stats Snapshot() const;
    bool Running() const { return decoder_ != nullptr; }
private:
    struct Packet {
        bool used = false;
        uint16_t seq = 0;
        uint32_t timestamp = 0;
        uint64_t arrival = 0;
        int frames = 0;
        size_t size = 0;
        std::array<uint8_t, kMaxPayload> bytes{};
    };
    Packet* Find(uint16_t seq);
    Packet* Nearest();
    void ClearPackets();
    void Decode(Packet* packet, int frames);
    void Rebase(Packet& packet, uint64_t nowMs);
    OpusDecoder* decoder_ = nullptr;
    Config config_{};
    Stats stats_{};
    std::array<Packet, kPacketSlots> packets_{};
    std::array<int16_t, kMaxFrames * kChannels> decoded_{};
    PcmRing ring_;
    bool haveSequence_ = false, primed_ = false;
    uint16_t nextSeq_ = 0;
    uint32_t nextTimestamp_ = 0;
    int lastFrames_ = 960;
    uint64_t firstArrival_ = 0, deadlineUs_ = 0;
    uint32_t consecutivePlc_ = 0;
    // Read-side counter is atomic so status and renderer never share engine lock.
    std::atomic<uint64_t> underrunFrames_{0};
};
} // namespace s5audio
#endif
