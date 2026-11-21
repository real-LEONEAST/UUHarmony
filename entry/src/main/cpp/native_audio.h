// SPDX-License-Identifier: GPL-3.0-only
#ifndef S5_NATIVE_AUDIO_H
#define S5_NATIVE_AUDIO_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// Payload only (RTP headers stripped), 48 kHz Opus clock, stereo output.
// Copies at most 8192 bytes; disabled or busy -> immediate drop. Never calls N-API.
void s5_audio_push(uint16_t seq, uint32_t timestamp, const uint8_t* payload, size_t size);
// Idempotent session teardown; disables future pushes until explicitly enabled.
void s5_audio_stop(void);
// These release the renderer/decoder. Resume needs audioConfigure on foreground.
void s5_audio_background(void);
#ifdef __cplusplus
}
#include <napi/native_api.h>
napi_value InitAdvancedAudio(napi_env env, napi_value exports);
#endif
#endif
