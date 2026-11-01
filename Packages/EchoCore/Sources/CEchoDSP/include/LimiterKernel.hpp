#pragma once

#include "DSPMath.hpp"
#include "SmoothedValue.hpp"
#include "TruePeakDetector.hpp"

namespace echo::dsp {

/// Look-ahead true-peak limiter, always on (SPEC § 6.7, § 8): the output's true peak (between samples too) stays at
/// the ceiling. Delays audio by `latencyFrames()`; the look-ahead also covers the true-peak estimate's own delay.
///
/// Each frame needs `ceiling / peak` gain (or 1). The gain is the minimum of that over the look-ahead window, released
/// towards 1 over `kReleaseMs`, then averaged over the same window, so it ramps down across the look-ahead instead of
/// stepping and reaches the needed value exactly when the peak leaves the delay line.
class LimiterKernel {
public:
    static constexpr double kLookaheadSeconds = 0.0015;
    static constexpr double kReleaseMs = 50;
    /// Enough look-ahead for 192 kHz.
    static constexpr int kMaxWindow = 512;

    LimiterKernel() noexcept;

    void prepare(double sampleRate) noexcept;
    /// −6…0 dB.
    void setCeilingDB(float db) noexcept;
    void process(float* const* channels, int channelCount, int frameCount) noexcept;
    /// Clears the signal state (envelopes, delay lines) and finishes parameter ramps; keeps the settings. Real-time safe.
    void reset() noexcept;
    int latencyFrames() const noexcept { return window_ - 1; }

private:
    SmoothedValue ceiling_;
    TruePeakDetector peaks_[kMaxChannels];
    /// Ring buffers of `window_` frames: the delayed audio, the gain each frame needs, and the held, released gain.
    float delay_[kMaxChannels][kMaxWindow] = {};
    float required_[kMaxWindow] = {};
    float held_[kMaxWindow] = {};
    int window_ = 73;
    int position_ = 0;
    float released_ = 1;
    float releaseCoefficient_ = 1;
    int rampFrames_ = 0;
};

} // namespace echo::dsp
