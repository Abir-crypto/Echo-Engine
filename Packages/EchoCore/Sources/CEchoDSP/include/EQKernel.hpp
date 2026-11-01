#pragma once

#include "Biquad.hpp"
#include "SmoothedValue.hpp"

namespace echo::dsp {

/// Six-band equalizer: low shelf, four peaking, high shelf (SPEC § 8). Bands start bypassed (flat).
class EQKernel {
public:
    static constexpr int kBands = 6;

    void prepare(double sampleRate) noexcept;
    /// Frequency 20 Hz–20 kHz, gain ±18 dB, Q 0.3–8. Parameter changes glide; a shape change applies at once.
    void setBand(int band, FilterShape shape, float frequency, float gainDB, float q) noexcept;
    void process(float* const* channels, int channelCount, int frameCount) noexcept;
    /// Clears the signal state (envelopes, delay lines) and finishes parameter ramps; keeps the settings. Real-time safe.
    void reset() noexcept;
    /// Combined response of all bands at `frequency`, from the target parameters (for the EQ curve).
    double magnitudeDB(double frequency) const noexcept;

private:
    /// Coefficients follow gliding parameters at this block size.
    static constexpr int kCoefficientBlock = 32;

    struct Band {
        FilterShape shape = FilterShape::bypass;
        SmoothedValue log2Frequency;
        SmoothedValue gainDB;
        SmoothedValue q;
        BiquadCoefficients coefficients;
        BiquadState state;
    };

    void updateCoefficients(Band& band) noexcept;

    Band bands_[kBands];
    double sampleRate_ = 48000;
    int rampFrames_ = 0;
};

} // namespace echo::dsp
