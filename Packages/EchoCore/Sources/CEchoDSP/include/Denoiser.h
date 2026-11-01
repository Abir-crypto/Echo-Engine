#pragma once

// RNNoise noise suppression (vendored v0.2 in `rnnoise/`, BSD-3; SPEC § 7) for one mono channel at 48 kHz, in frames
// of `EEDenoiserFrameSize` samples, floats in −1…1.

#ifdef __cplusplus
extern "C" {
#endif

enum {
    /// Samples per `EEDenoiserProcess` call (10 ms at 48 kHz).
    EEDenoiserFrameSize = 480,
};

typedef struct EEDenoiser EEDenoiser;

/// Allocates (not on a real-time thread).
EEDenoiser *EEDenoiserCreate(void);
void EEDenoiserDestroy(EEDenoiser *denoiser);
/// Denoises one frame (`output` may be `input`). Returns the probability that the frame is voice, 0…1. Real-time safe.
float EEDenoiserProcess(EEDenoiser *denoiser, float *output, const float *input);

#ifdef __cplusplus
}
#endif
