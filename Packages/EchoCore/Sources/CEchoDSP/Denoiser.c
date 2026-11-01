#include "Denoiser.h"

#include "rnnoise/rnnoise.h"

#include <stdlib.h>

/// RNNoise works on floats in the 16-bit sample range.
static const float kPCMScale = 32768.0f;

struct EEDenoiser {
    DenoiseState *state;
    float frame[EEDenoiserFrameSize];
};

EEDenoiser *EEDenoiserCreate(void) {
    EEDenoiser *denoiser = calloc(1, sizeof(EEDenoiser));
    if (denoiser == NULL) { return NULL; }
    denoiser->state = rnnoise_create(NULL);
    if (denoiser->state == NULL) {
        free(denoiser);
        return NULL;
    }
    return denoiser;
}

void EEDenoiserDestroy(EEDenoiser *denoiser) {
    if (denoiser == NULL) { return; }
    rnnoise_destroy(denoiser->state);
    free(denoiser);
}

float EEDenoiserProcess(EEDenoiser *denoiser, float *output, const float *input) {
    for (int index = 0; index < EEDenoiserFrameSize; ++index) {
        denoiser->frame[index] = input[index] * kPCMScale;
    }
    const float voice = rnnoise_process_frame(denoiser->state, denoiser->frame, denoiser->frame);
    for (int index = 0; index < EEDenoiserFrameSize; ++index) {
        output[index] = denoiser->frame[index] / kPCMScale;
    }
    return voice;
}
