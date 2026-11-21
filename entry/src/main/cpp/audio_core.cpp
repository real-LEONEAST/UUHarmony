// SPDX-License-Identifier: GPL-3.0-only
#include "audio_core.h"
#include <opus.h>
#include <algorithm>
#include <cmath>
#include <cstring>
namespace s5audio {
namespace {
int SeqDiff(uint16_t a, uint16_t b) {
    const uint16_t d = static_cast<uint16_t>(a - b);
    return d < 0x8000 ? d : static_cast<int>(d) - 0x10000;
}
int64_t TimestampDiff(uint32_t a, uint32_t b) {
    const uint32_t d = a - b;
    return d < 0x80000000u ? d : static_cast<int64_t>(d) - 0x100000000ll;
}
}
void PcmRing::Configure(size_t frames) {
    std::lock_guard<std::mutex> lock(mutex_);
    samples_.assign(frames * kChannels, 0);
    read_ = size_ = 0;
    dropped_ = 0;
}
void PcmRing::Clear() {
    std::lock_guard<std::mutex> lock(mutex_);
    read_ = size_ = 0;
}
void PcmRing::Write(const int16_t* pcm, size_t frames) {
    std::lock_guard<std::mutex> lock(mutex_);
    const size_t capacity = samples_.size() / kChannels;
    if (!capacity) return;
    if (frames > capacity) {
        dropped_ += frames - capacity;
        pcm += (frames - capacity) * kChannels;
        frames = capacity;
    }
    if (size_ + frames > capacity) {
        const size_t skip = size_ + frames - capacity;
        read_ = (read_ + skip) % capacity;
        size_ -= skip;
        dropped_ += skip;
    }
    for (size_t i = 0; i < frames; ++i) {
        const size_t at = (read_ + size_ + i) % capacity;
        samples_[at * 2] = pcm[i * 2];
        samples_[at * 2 + 1] = pcm[i * 2 + 1];
    }
    size_ += frames;
}
size_t PcmRing::Read(int16_t* pcm, size_t frames, float gain) {
    if (!pcm || !frames) return 0;
    std::memset(pcm, 0, frames * kChannels * sizeof(int16_t));
    std::unique_lock<std::mutex> lock(mutex_, std::try_to_lock);
    if (!lock.owns_lock()) return 0;
    const size_t count = std::min(frames, size_);
    const size_t capacity = samples_.size() / kChannels;
    gain = std::isfinite(gain) ? std::clamp(gain, 0.0f, 1.0f) : 0.0f;
    for (size_t i = 0; i < count; ++i) {
        const size_t at = (read_ + i) % capacity;
        pcm[i * 2] = static_cast<int16_t>(samples_[at * 2] * gain);
        pcm[i * 2 + 1] = static_cast<int16_t>(samples_[at * 2 + 1] * gain);
    }
    if (capacity) read_ = (read_ + count) % capacity;
    size_ -= count;
    return count;
}
void PcmRing::Snapshot(Stats& stats) const {
    std::lock_guard<std::mutex> lock(mutex_);
    stats.ringFrames = size_;
    stats.ringCapacityFrames = samples_.size() / kChannels;
    stats.ringDrops = dropped_;
}
Engine::~Engine() { Stop(); }
bool Engine::Start(Config config) {
    Stop();
    config_.jitterMs = std::clamp(config.jitterMs, 10u, 120u);
    config_.ringMs = std::clamp(config.ringMs, 40u, 400u);
    stats_ = {};
    underrunFrames_.store(0, std::memory_order_relaxed);
    int error = 0;
    decoder_ = opus_decoder_create(kRate, kChannels, &error);
    if (!decoder_ || error != OPUS_OK) { Stop(); return false; }
    ring_.Configure(static_cast<size_t>(kRate) * config_.ringMs / 1000);
    Reset();
    return true;
}
void Engine::ClearPackets() {
    for (auto& packet : packets_) packet.used = false;
    stats_.queuedPackets = 0;
}
void Engine::Reset() {
    ClearPackets();
    ring_.Clear();
    haveSequence_ = primed_ = false;
    consecutivePlc_ = 0;
    lastFrames_ = 960;
    deadlineUs_ = 0;
    if (decoder_) opus_decoder_ctl(decoder_, OPUS_RESET_STATE);
}
void Engine::Stop() {
    if (decoder_) opus_decoder_destroy(decoder_);
    decoder_ = nullptr;
    Reset();
    ring_.Configure(0);
}
Engine::Packet* Engine::Find(uint16_t seq) {
    for (auto& packet : packets_) if (packet.used && packet.seq == seq) return &packet;
    return nullptr;
}
Engine::Packet* Engine::Nearest() {
    Packet* best = nullptr;
    for (auto& packet : packets_) {
        if (packet.used && SeqDiff(packet.seq, nextSeq_) >= 0 &&
            (!best || SeqDiff(packet.seq, nextSeq_) < SeqDiff(best->seq, nextSeq_))) best = &packet;
    }
    return best;
}
bool Engine::Push(uint16_t seq, uint32_t timestamp, const uint8_t* data, size_t size, uint64_t nowMs) {
    if (!decoder_) return false;
    ++stats_.received;
    if (!data || !size || size > kMaxPayload) { ++stats_.invalid; return false; }
    const int frames = opus_packet_get_nb_samples(data, static_cast<opus_int32>(size), kRate);
    if (frames < 120 || frames > static_cast<int>(kMaxFrames) || frames % 120) {
        ++stats_.invalid; return false;
    }
    if (Find(seq)) { ++stats_.duplicate; return false; }
    if (haveSequence_) {
        const int distance = SeqDiff(seq, nextSeq_);
        if (distance < 0) {
            if (!primed_ && distance > -static_cast<int>(kPacketSlots)) {
                nextSeq_ = seq;
                nextTimestamp_ = timestamp;
            } else { ++stats_.late; return false; }
        } else if (distance >= static_cast<int>(kPacketSlots)) {
            ++stats_.resyncs;
            stats_.queueDrops += stats_.queuedPackets;
            Reset(); // finite discontinuity: never loop through an unbounded seq gap.
        }
    }
    if (!haveSequence_) {
        haveSequence_ = true;
        nextSeq_ = seq;
        nextTimestamp_ = timestamp;
        firstArrival_ = nowMs;
        deadlineUs_ = (nowMs + config_.jitterMs) * 1000;
    }
    for (auto& packet : packets_) {
        if (packet.used) continue;
        packet.used = true;
        packet.seq = seq;
        packet.timestamp = timestamp;
        packet.arrival = nowMs;
        packet.size = size;
        packet.frames = frames;
        std::memcpy(packet.bytes.data(), data, size);
        ++stats_.queuedPackets;
        stats_.maxQueuedPackets = std::max(stats_.maxQueuedPackets, stats_.queuedPackets);
        return true;
    }
    ++stats_.queueDrops;
    return false;
}
void Engine::Decode(Packet* packet, int frames) {
    int count = opus_decode(decoder_, packet ? packet->bytes.data() : nullptr,
        packet ? static_cast<opus_int32>(packet->size) : 0, decoded_.data(), frames, 0);
    if (count < 0) {
        ++stats_.decodeErrors;
        count = opus_decode(decoder_, nullptr, 0, decoded_.data(), frames, 0);
        ++stats_.plc;
    } else if (!packet) ++stats_.plc;
    else ++stats_.decoded;
    if (count > 0) {
        ring_.Write(decoded_.data(), static_cast<size_t>(count));
        stats_.pcmFrames += static_cast<uint64_t>(count);
    }
}
void Engine::Rebase(Packet& packet, uint64_t nowMs) {
    nextSeq_ = packet.seq;
    nextTimestamp_ = packet.timestamp;
    deadlineUs_ = (nowMs + config_.jitterMs) * 1000;
    primed_ = false;
    consecutivePlc_ = 0;
    ring_.Clear();
    opus_decoder_ctl(decoder_, OPUS_RESET_STATE);
    ++stats_.resyncs;
}
void Engine::Tick(uint64_t nowMs) {
    if (!decoder_ || !haveSequence_) return;
    const uint64_t nowUs = nowMs * 1000;
    if (nowUs < deadlineUs_) return;
    if (nowUs > deadlineUs_ + 200000) {
        if (auto* packet = Nearest()) { Rebase(*packet, nowMs); return; }
        haveSequence_ = primed_ = false;
        return;
    }
    // At most 6 frames per tick, including PLC: a burst cannot monopolize the worker.
    for (unsigned work = 0; work < 6 && haveSequence_ && nowUs >= deadlineUs_; ++work) {
        primed_ = true;
        Packet* packet = Find(nextSeq_);
        int frames = packet ? packet->frames : lastFrames_;
        if (packet) {
            const int64_t delta = TimestampDiff(packet->timestamp, nextTimestamp_);
            if (delta != 0) {
                ++stats_.timestampResyncs;
                if (std::abs(delta) > kRate / 2) {
                    ring_.Clear();
                    opus_decoder_ctl(decoder_, OPUS_RESET_STATE);
                }
                nextTimestamp_ = packet->timestamp; // DTX may advance timestamp without a seq gap.
            }
            consecutivePlc_ = 0;
        } else {
            if (auto* next = Nearest()) {
                const int gap = SeqDiff(next->seq, nextSeq_);
                const int64_t samples = TimestampDiff(next->timestamp, nextTimestamp_);
                if (gap > 0 && samples > 0 && samples % gap == 0) {
                    const int64_t inferred = samples / gap;
                    if (inferred >= 120 && inferred <= static_cast<int64_t>(kMaxFrames) && inferred % 120 == 0)
                        frames = static_cast<int>(inferred);
                }
            }
            if (consecutivePlc_ + static_cast<uint32_t>(frames) > kMaxFrames) {
                if (auto* next = Nearest()) Rebase(*next, nowMs);
                else { haveSequence_ = primed_ = false; opus_decoder_ctl(decoder_, OPUS_RESET_STATE); }
                break;
            }
            consecutivePlc_ += static_cast<uint32_t>(frames);
        }
        Decode(packet, frames);
        if (packet) { packet->used = false; --stats_.queuedPackets; }
        lastFrames_ = frames;
        ++nextSeq_;
        nextTimestamp_ += static_cast<uint32_t>(frames);
        deadlineUs_ += static_cast<uint64_t>(frames) * 1000000 / kRate;
    }
}
size_t Engine::Read(int16_t* pcm, size_t frames, float gain) {
    const size_t count = ring_.Read(pcm, frames, gain);
    underrunFrames_.fetch_add(frames - count, std::memory_order_relaxed);
    return count;
}
Stats Engine::Snapshot() const {
    Stats result = stats_;
    result.underrunFrames = underrunFrames_.load(std::memory_order_relaxed);
    ring_.Snapshot(result);
    return result;
}
} // namespace s5audio
