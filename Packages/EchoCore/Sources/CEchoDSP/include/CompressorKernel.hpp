#pragma once

#include "SmoothedValue.hpp"

namespace echo::dsp {

/// Feed-forward compressor with linked channels (SPEC § 8). Off by default.
class CompressorKernel {
public:
    CompressorKernel() noexcept;

    void prepare(double sampleRate) noexcept;
    void setEnabled(bool enabled) noexcept;
    void setThresholdDB(float db) noexcept;
    /// 1…20.
    void setRatio(float ratio) noexcept;
    void setAttackMs(float ms) noexcept;
    void setReleaseMs(float ms) noexcept;
    void setMakeupDB(float db) noexcept;
    void process(float* const* channels, int channelCount, int frameCount) noexcept;

private:
    SmoothedValue mix_, thresholdDB_, ratio_, makeupDB_;
    float attackMs_ = 10, releaseMs_ = 120;
    float attackCoefficient_ = 1, releaseCoefficient_ = 1;
    float envelope_ = 0;
    double sampleRate_ = 48000;
    int rampFrames_ = 0;
};

} // namespace echo::dsp
