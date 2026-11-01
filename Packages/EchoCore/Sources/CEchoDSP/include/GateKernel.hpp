#pragma once

#include "SmoothedValue.hpp"

namespace echo::dsp {

/// Noise gate (SPEC § 8): closes to `range` below the threshold. Off by default.
class GateKernel {
public:
    GateKernel() noexcept;

    void prepare(double sampleRate) noexcept;
    void setEnabled(bool enabled) noexcept;
    /// −80…0 dB.
    void setThresholdDB(float db) noexcept;
    /// Attenuation while closed, −80…0 dB.
    void setRangeDB(float db) noexcept;
    /// Opening time.
    void setAttackMs(float ms) noexcept;
    /// Closing time.
    void setReleaseMs(float ms) noexcept;
    void process(float* const* channels, int channelCount, int frameCount) noexcept;
    /// Clears the signal state (envelopes, delay lines) and finishes parameter ramps; keeps the settings. Real-time safe.
    void reset() noexcept;

private:
    SmoothedValue mix_;
    SmoothedValue threshold_;
    float rangeLinear_;
    float attackMs_ = 2, releaseMs_ = 150;
    float attackCoefficient_ = 1, releaseCoefficient_ = 1, detectorCoefficient_ = 1;
    float envelope_ = 0, gain_ = 1;
    double sampleRate_ = 48000;
    int rampFrames_ = 0;
};

} // namespace echo::dsp
