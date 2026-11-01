#pragma once

#include "SmoothedValue.hpp"

namespace echo::dsp {

/// Input gain, −24…+24 dB (SPEC § 8).
class GainKernel {
public:
    GainKernel() noexcept { gain_.reset(1); }

    void prepare(double sampleRate) noexcept;
    void setGainDB(float db) noexcept;
    void process(float* const* channels, int channelCount, int frameCount) noexcept;
    /// Clears the signal state (envelopes, delay lines) and finishes parameter ramps; keeps the settings. Real-time safe.
    void reset() noexcept;

private:
    SmoothedValue gain_;
    int rampFrames_ = 0;
};

} // namespace echo::dsp
