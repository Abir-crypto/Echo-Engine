#pragma once

#include "DSPMath.hpp"

namespace echo::dsp {

enum class FilterShape : int {
    lowShelf = 0,
    peaking = 1,
    highShelf = 2,
    bandPass = 3,
    lowPass = 4,
    bypass = 5,
};

/// Normalized biquad coefficients (a0 = 1).
struct BiquadCoefficients {
    float b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
};

/// RBJ "Audio EQ Cookbook" coefficients. Frequency is clamped to 10 Hz…0.49 × sample rate.
BiquadCoefficients makeBiquad(FilterShape shape, double sampleRate, double frequency, double gainDB, double q) noexcept;

/// Magnitude response in dB at `frequency` (for tests and the EQ curve).
double biquadMagnitudeDB(const BiquadCoefficients& c, double sampleRate, double frequency) noexcept;

/// Transposed direct form II state, one pair per channel.
struct BiquadState {
    float z1[kMaxChannels] = {};
    float z2[kMaxChannels] = {};

    float process(const BiquadCoefficients& c, float x, int channel) noexcept {
        const float y = c.b0 * x + z1[channel];
        z1[channel] = c.b1 * x - c.a1 * y + z2[channel];
        z2[channel] = c.b2 * x - c.a2 * y;
        return y;
    }

    void reset() noexcept {
        for (int channel = 0; channel < kMaxChannels; ++channel) {
            z1[channel] = 0;
            z2[channel] = 0;
        }
    }
};

} // namespace echo::dsp
