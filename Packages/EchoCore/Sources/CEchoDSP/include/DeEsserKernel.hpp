#pragma once

#include "Biquad.hpp"
#include "SmoothedValue.hpp"

namespace echo::dsp {

/// De-esser (SPEC § 8): a dynamic high shelf. A band-pass detector at `frequency` follows the sibilance; while it is
/// above `kThresholdDB`, a high shelf with its midpoint at `frequency` turns the highs down by the overshoot × amount,
/// up to `kMaxReductionDB`. At 0 dB the shelf is exactly flat. Off by default.
class DeEsserKernel {
public:
    static constexpr float kThresholdDB = -30;
    static constexpr float kMaxReductionDB = 12;

    DeEsserKernel() noexcept;

    void prepare(double sampleRate) noexcept;
    void setEnabled(bool enabled) noexcept;
    /// 4–10 kHz.
    void setFrequency(float hz) noexcept;
    /// 0…1.
    void setAmount(float amount) noexcept;
    void process(float* const* channels, int channelCount, int frameCount) noexcept;

private:
    /// The shelf follows the detector at this block size (0.33 ms at 48 kHz).
    static constexpr int kCoefficientBlock = 16;

    void updateDetector() noexcept;

    SmoothedValue mix_, amount_, log2Frequency_;
    BiquadCoefficients detector_, shelf_;
    BiquadState detectorState_, shelfState_;
    float attackCoefficient_ = 1, releaseCoefficient_ = 1;
    float envelope_ = 0;
    double sampleRate_ = 48000;
    int rampFrames_ = 0;
};

} // namespace echo::dsp
