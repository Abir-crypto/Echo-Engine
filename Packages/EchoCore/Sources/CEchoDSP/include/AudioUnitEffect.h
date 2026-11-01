#pragma once

// The real-time side of the Echo Engine Audio Units (SPEC § 4.5), for `EchoAudioUnits`: an opaque effect that owns
// the DSP kernels, a lock-free parameter mailbox (any thread → render thread) and an Objective-C++ render block that
// touches no Swift or Objective-C objects. Objective-C++ only; Swift imports it with C++ interop.

#import <AudioToolbox/AudioToolbox.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef CF_ENUM(int32_t, EEEffectKind) {
    /// Input gain → gate → EQ → de-esser → compressor → pitch shift → reverb (SPEC § 8).
    EEEffectKindManualChain = 0,
    /// Auto Level gain, then the final look-ahead true-peak limiter (SPEC § 6.6, § 6.7).
    EEEffectKindOutputLimiter = 1,
};

/// Parameter addresses of `EEEffectKindManualChain`. Booleans are 0/1; EQ band kinds are `EEEQBandKind`.
typedef CF_ENUM(uint64_t, EEManualChainParameter) {
    EEManualChainParameterInputGain = 0,
    EEManualChainParameterGateEnabled = 1,
    EEManualChainParameterGateThreshold = 2,
    EEManualChainParameterGateRange = 3,
    EEManualChainParameterGateAttack = 4,
    EEManualChainParameterGateRelease = 5,
    EEManualChainParameterDeEsserEnabled = 6,
    EEManualChainParameterDeEsserFrequency = 7,
    EEManualChainParameterDeEsserAmount = 8,
    EEManualChainParameterCompressorEnabled = 9,
    EEManualChainParameterCompressorThreshold = 10,
    EEManualChainParameterCompressorRatio = 11,
    EEManualChainParameterCompressorAttack = 12,
    EEManualChainParameterCompressorRelease = 13,
    EEManualChainParameterCompressorMakeup = 14,
    EEManualChainParameterPitchSemitones = 15,
    EEManualChainParameterReverbEnabled = 16,
    EEManualChainParameterReverbRoomSize = 17,
    EEManualChainParameterReverbDamping = 18,
    EEManualChainParameterReverbMix = 19,
    /// Band `b` field `f` is at `EQFirst + b × EQStride + f` (fields: `EEEQBandField`).
    EEManualChainParameterEQFirst = 20,
    EEManualChainParameterEQStride = 4,
    EEManualChainParameterEQBandCount = 6,
    /// 0/1: "Hold for original" (SPEC § 6.6). Crossfades to the dry input, delayed by the same latency.
    EEManualChainParameterBypass = 44,
    EEManualChainParameterCount = 45,
};

typedef CF_ENUM(uint64_t, EEEQBandField) {
    EEEQBandFieldKind = 0,
    EEEQBandFieldFrequency = 1,
    EEEQBandFieldGain = 2,
    EEEQBandFieldQ = 3,
};

typedef CF_ENUM(int32_t, EEEQBandKind) {
    EEEQBandKindLowShelf = 0,
    EEEQBandKindPeaking = 1,
    EEEQBandKindHighShelf = 2,
    /// Shapes this version doesn't know are bypassed.
    EEEQBandKindBypass = 3,
};

typedef CF_ENUM(uint64_t, EEOutputLimiterParameter) {
    EEOutputLimiterParameterCeiling = 0,
    /// 0/1, as `EEManualChainParameterBypass`.
    EEOutputLimiterParameterBypass = 1,
    /// Auto Level's static gain in dB (−20…+20), before the limiter.
    EEOutputLimiterParameterGain = 2,
    EEOutputLimiterParameterCount = 3,
};

typedef struct EEEffect EEEffect;

/// Allocates; parameters start at the neutral defaults (SPEC § 8).
EEEffect *EEEffectCreate(EEEffectKind kind);
void EEEffectDestroy(EEEffect *effect);
/// Sizes buffers for the stream (allocates; never on the render thread) and applies the current parameters at once.
void EEEffectPrepare(EEEffect *effect, double sampleRate, int32_t channelCount, int32_t maximumFrames);
/// Any thread. The render thread picks the value up at its next cycle; the kernel ramps to it.
void EEEffectSetParameter(EEEffect *effect, uint64_t address, float value);
float EEEffectParameter(const EEEffect *effect, uint64_t address);
uint64_t EEEffectParameterCount(const EEEffect *effect);
/// Any thread: the render thread clears delay lines and envelopes at its next cycle (after a seek or stop).
void EEEffectRequestReset(EEEffect *effect);
/// Frames the effect delays audio by, once prepared.
int32_t EEEffectLatencyFrames(const EEEffect *effect);
AUInternalRenderBlock EEEffectRenderBlock(EEEffect *effect);
/// Offline (analysis, export): applies pending parameters, then processes `channels` in place. Call after
/// `EEEffectPrepare`, from one thread, with at most `maximumFrames` frames.
void EEEffectProcess(EEEffect *effect, float *const *channels, int32_t channelCount, int32_t frameCount);

#ifdef __cplusplus
}
#endif
