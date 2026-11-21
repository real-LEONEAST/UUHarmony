// SPDX-License-Identifier: GPL-3.0-only
#include "audio_core.h"
#include <opus.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <numeric>
#include <thread>
#include <vector>
namespace {
void Check(bool condition, const char* message) {
    if (!condition) { std::cerr << "FAIL: " << message << '\n'; std::exit(1); }
}
using Packet = std::vector<uint8_t>;
using Pcm = std::vector<int16_t>;
std::vector<Packet> Encode(size_t count, int frames = 960, bool silence = false) {
    int error = 0;
    OpusEncoder* encoder = opus_encoder_create(48000, 2, OPUS_APPLICATION_AUDIO, &error);
    Check(encoder && error == OPUS_OK, "encoder create");
    Check(opus_encoder_ctl(encoder, OPUS_SET_BITRATE(96000)) == OPUS_OK, "encoder bitrate");
    Check(opus_encoder_ctl(encoder, OPUS_SET_COMPLEXITY(2)) == OPUS_OK, "encoder complexity");
    std::vector<Packet> packets;
    Pcm pcm(static_cast<size_t>(frames) * 2);
    for (size_t packet = 0; packet < count; ++packet) {
        for (int i = 0; i < frames; ++i) {
            const double t = static_cast<double>(packet * frames + i) / 48000;
            pcm[static_cast<size_t>(i) * 2] = silence ? 0 : static_cast<int16_t>(12000 * std::sin(t * 440 * 6.283185307179586));
            pcm[static_cast<size_t>(i) * 2 + 1] = silence ? 0 : static_cast<int16_t>(8000 * std::sin(t * 660 * 6.283185307179586));
        }
        Packet bytes(s5audio::kMaxPayload);
        const int size = opus_encode(encoder, pcm.data(), frames, bytes.data(), static_cast<opus_int32>(bytes.size()));
        Check(size > 0, "tone/silence encode");
        bytes.resize(static_cast<size_t>(size)); packets.push_back(std::move(bytes));
    }
    opus_encoder_destroy(encoder);
    return packets;
}
Pcm Direct(const std::vector<Packet>& packets, int frames = 960) {
    int error = 0;
    OpusDecoder* decoder = opus_decoder_create(48000, 2, &error);
    Check(decoder && error == OPUS_OK, "direct decoder create");
    Pcm result;
    std::array<int16_t, s5audio::kMaxFrames * 2> pcm{};
    for (const auto& packet : packets) {
        int size = opus_decode(decoder, packet.data(), static_cast<opus_int32>(packet.size()), pcm.data(), frames, 0);
        Check(size == frames, "direct decoded duration");
        result.insert(result.end(), pcm.begin(), pcm.begin() + frames * 2);
    }
    opus_decoder_destroy(decoder);
    return result;
}
std::unique_ptr<s5audio::Engine> Engine(uint32_t jitter = 20, uint32_t ring = 160) {
    auto engine = std::make_unique<s5audio::Engine>();
    Check(engine->Start({jitter, ring}), "engine start");
    return engine;
}
void Push(s5audio::Engine& engine, uint16_t seq, uint32_t ts, const Packet& packet, uint64_t now) {
    Check(engine.Push(seq, ts, packet.data(), packet.size(), now), "valid payload admitted");
}
void ToneAndSilence() {
    for (bool silence : {false, true}) {
        const auto packets = Encode(12, 960, silence);
        const auto expected = Direct(packets);
        auto engine = Engine();
        Pcm actual;
        for (size_t i = 0; i < packets.size(); ++i) {
            Push(*engine, static_cast<uint16_t>(i), static_cast<uint32_t>(i * 960), packets[i], i * 20);
            engine->Tick(i * 20 + 20);
            Pcm pcm(1920);
            Check(engine->Read(pcm.data(), 960, 1) == 960, "20 ms PCM available");
            actual.insert(actual.end(), pcm.begin(), pcm.end());
        }
        Check(actual == expected, "portable pipeline equals direct libopus PCM");
        const double energy = std::inner_product(actual.begin(), actual.end(), actual.begin(), 0.0);
        Check(silence ? energy < 100000 : energy > 1e10, "silence/tone decoded PCM energy");
        Check(engine->Snapshot().decoded == packets.size(), "tone/silence packet accounting");
    }
    std::cout << "PASS tone/silence encoder-to-decoder PCM\n";
}
void ReorderAndWrap() {
    const auto packets = Encode(3);
    auto engine = Engine();
    Push(*engine, 65535, 0xfffffc40u, packets[1], 0);
    Push(*engine, 65534, 0xfffff880u, packets[0], 1); // Earlier startup packet is still accepted.
    Push(*engine, 0, 0, packets[2], 2);
    Check(!engine->Push(0, 0, packets[2].data(), packets[2].size(), 3), "duplicate rejected");
    engine->Tick(19); Check(engine->Snapshot().pcmFrames == 0, "jitter prebuffer deadline");
    engine->Tick(20); engine->Tick(40); engine->Tick(60);
    Pcm pcm(5760);
    Check(engine->Read(pcm.data(), 2880, 1) == 2880, "reordered PCM duration");
    Check(pcm == Direct(packets), "reordered sequence/timestamp wrap matches direct decode");
    Check(!engine->Push(65535, 0xfffffc40u, packets[1].data(), packets[1].size(), 61), "played packet rejected as late");
    const auto stats = engine->Snapshot();
    Check(stats.decoded == 3 && stats.plc == 0 && stats.duplicate == 1 && stats.late == 1, "reorder/drop metrics");
    std::cout << "PASS startup reorder, duplicate, late and RTP wrap\n";
}
void LossAndStarvation() {
    const auto packets = Encode(3);
    auto engine = Engine();
    Push(*engine, 10, 0, packets[0], 0);
    Push(*engine, 12, 1920, packets[2], 1);
    engine->Tick(20); engine->Tick(40); engine->Tick(60);
    auto stats = engine->Snapshot();
    Check(stats.decoded == 2 && stats.plc == 1 && stats.pcmFrames == 2880, "single loss yields one 20ms PLC");
    for (uint64_t now = 80; now <= 1000; now += 20) engine->Tick(now);
    stats = engine->Snapshot();
    Check(stats.plc == 7, "starvation PLC capped at additional 120ms");
    Check(stats.ringFrames <= stats.ringCapacityFrames && stats.ringDrops > 0, "starvation ring remains bounded");
    Push(*engine, 500, 48000, packets[0], 1001);
    engine->Tick(1021);
    Check(engine->Snapshot().decoded == 3, "new stream reprimes after starvation");
    std::cout << "PASS loss PLC bound and starvation recovery\n";
}
void QueueAndDiscontinuity() {
    const auto packet = Encode(1)[0];
    auto engine = Engine();
    for (uint16_t i = 0; i < 64; ++i) Push(*engine, i, static_cast<uint32_t>(i) * 960, packet, 0);
    Check(engine->Snapshot().queuedPackets == 64, "fixed packet queue capacity");
    Push(*engine, 64, 64 * 960, packet, 1);
    auto stats = engine->Snapshot();
    Check(stats.queuedPackets == 1 && stats.queueDrops == 64 && stats.resyncs == 1 && stats.maxQueuedPackets == 64,
        "large seq jump discards backlog in bounded work");
    engine->Tick(1000);
    Check(engine->Snapshot().pcmFrames == 0, "late worker reprimes rather than decoding stale backlog");
    engine->Tick(1020);
    Check(engine->Snapshot().decoded == 1, "reprimed payload decodes");
    Push(*engine, 65, 0x70000000, packet, 1021);
    engine->Tick(1040);
    Check(engine->Snapshot().timestampResyncs > 0, "large timestamp discontinuity observed");
    std::cout << "PASS queue bound, stalled worker, timestamp discontinuity\n";
}
void DurationAndValidation() {
    for (int frames : {120, 480, 1920, 2880, 5760}) {
        const auto packet = Encode(1, frames)[0];
        auto engine = Engine(10, 400);
        Push(*engine, 1, 0, packet, 0); engine->Tick(10);
        Check(engine->Snapshot().pcmFrames == static_cast<uint64_t>(frames), "Opus legal duration respected");
    }
    const auto packet = Encode(1)[0];
    auto engine = Engine();
    Check(!engine->Push(1, 0, nullptr, 1, 0), "null rejected");
    Check(!engine->Push(1, 0, packet.data(), 0, 0), "empty rejected");
    Check(!engine->Push(1, 0, packet.data(), s5audio::kMaxPayload + 1, 0), "oversize rejected before read");
    const uint8_t malformed = 0xff;
    Check(!engine->Push(1, 0, &malformed, 1, 0), "malformed packet rejected");
    Check(engine->Snapshot().invalid == 4, "validation accounting");
    std::cout << "PASS legal Opus durations and malformed bounds\n";
}
void RingGainMuteAndStop() {
    s5audio::PcmRing ring;
    ring.Configure(4);
    std::array<int16_t, 16> samples{};
    for (size_t i = 0; i < samples.size(); ++i) samples[i] = static_cast<int16_t>(i * 100);
    ring.Write(samples.data(), 8);
    std::array<int16_t, 12> out;
    Check(ring.Read(out.data(), 6, 0.5f) == 4, "ring length bounded with zero-filled shortage");
    Check(out[0] == 400 && out[7] == 750 && out[8] == 0 && out[11] == 0, "ring keeps fresh PCM and scales gain");
    ring.Write(samples.data(), 4);
    Check(ring.Read(out.data(), 4, 0) == 4 && std::all_of(out.begin(), out.begin() + 8, [](int16_t n){return n == 0;}),
        "mute drains PCM as silence");
    const auto packet = Encode(1)[0]; auto engine = Engine();
    Push(*engine, 1, 0, packet, 0); engine->Tick(20); engine->Stop(); engine->Stop();
    Check(!engine->Running() && !engine->Push(2, 960, packet.data(), packet.size(), 21), "stop is idempotent and rejects data");
    Check(engine->Read(out.data(), 6, 1) == 0 && std::all_of(out.begin(), out.end(), [](int16_t n){return n == 0;}), "stop flushes PCM");
    Check(engine->Snapshot().queuedPackets == 0 && engine->Snapshot().ringCapacityFrames == 0, "stop reclaims bounded buffers");
    Check(engine->Start({20, 160}), "restart after stop");
    Push(*engine, 50, 100000, packet, 22); engine->Tick(42);
    Check(engine->Snapshot().decoded == 1, "restart has clean codec sequence");
    std::cout << "PASS freshest ring, volume/mute, stop/restart\n";
}
void RingConcurrency() {
    s5audio::PcmRing ring; ring.Configure(1920);
    std::array<int16_t, 960> pcm{};
    std::atomic<bool> finished{false};
    std::thread producer([&] { for (size_t i = 0; i < 2000; ++i) ring.Write(pcm.data(), 480); finished.store(true); });
    std::array<int16_t, 960> out{};
    do { Check(ring.Read(out.data(), 480, 1) <= 480, "concurrent read bounded"); } while (!finished.load());
    producer.join(); s5audio::Stats stats; ring.Snapshot(stats);
    Check(stats.ringFrames <= 1920 && stats.ringCapacityFrames == 1920, "concurrent producer/renderer ring bound");
    std::cout << "PASS concurrent PCM producer/renderer bound\n";
}
}
int main() {
    ToneAndSilence(); ReorderAndWrap(); LossAndStarvation(); QueueAndDiscontinuity();
    DurationAndValidation(); RingGainMuteAndStop(); RingConcurrency();
    std::cout << "PASS all offline audio tests (no audio device opened)\n";
}
