#include "GainKernel.hpp"

#include "DSPMath.hpp"

#include <algorithm>

namespace echo::dsp {

void GainKernel::prepare(double sampleRate) noexcept {
    rampFrames_ = rampFrames(sampleRate);
    gain_.reset(gain_.target());
}

void GainKernel::reset() noexcept { gain_.reset(gain_.target()); }

void GainKernel::setGainDB(float db) noexcept {
    gain_.setTarget(dbToLinear(std::clamp(db, -24.0f, 24.0f)), rampFrames_);
}

void GainKernel::process(float* const* channels, int channelCount, int frameCount) noexcept {
    const int count = std::min(channelCount, kMaxChannels);
    for (int frame = 0; frame < frameCount; ++frame) {
        const float gain = gain_.next();
        for (int channel = 0; channel < count; ++channel) {
            channels[channel][frame] *= gain;
        }
    }
}

} // namespace echo::dsp
