#pragma once

#include "DSPMath.hpp"
#include "SmoothedValue.hpp"

#include <vector>

namespace echo::dsp {

/// Reverb (SPEC § 8): the public-domain Freeverb design, 8 damped feedback combs into 4 allpasses per channel, the
/// right channel slightly detuned for width. Room size, damping and mix are 0…1. Off by default; while fully off it
/// passes audio untouched and skips the work. `prepare` allocates; everything else is real-time safe.
class ReverbKernel {
public:
    static constexpr int kCombs = 8;
    static constexpr int kAllpasses = 4;

    ReverbKernel() noexcept;

    void prepare(double sampleRate);
    void setEnabled(bool enabled) noexcept;
    void setRoomSize(float roomSize) noexcept;
    void setDamping(float damping) noexcept;
    void setMix(float mix) noexcept;
    void process(float* const* channels, int channelCount, int frameCount) noexcept;

private:
    void clear() noexcept;

    SmoothedValue enabled_, roomSize_, damping_, mix_;
    /// All delay lines; each comb and allpass is a range of it (offsets survive copies of the kernel).
    std::vector<float> lines_;
    int combOffset_[kMaxChannels][kCombs] = {}, combLength_[kMaxChannels][kCombs] = {}, combIndex_[kMaxChannels][kCombs] = {};
    int allpassOffset_[kMaxChannels][kAllpasses] = {}, allpassLength_[kMaxChannels][kAllpasses] = {};
    int allpassIndex_[kMaxChannels][kAllpasses] = {};
    float combStore_[kMaxChannels][kCombs] = {};
    bool needsClear_ = false;
    int rampFrames_ = 0;
};

} // namespace echo::dsp
