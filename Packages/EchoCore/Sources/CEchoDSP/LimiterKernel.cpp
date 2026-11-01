#include "LimiterKernel.hpp"

#include <algorithm>
#include <cmath>

namespace echo::dsp {

LimiterKernel::LimiterKernel() noexcept {
    ceiling_.reset(dbToLinear(-1));
    std::fill(std::begin(required_), std::end(required_), 1.0f);
    std::fill(std::begin(held_), std::end(held_), 1.0f);
}

void LimiterKernel::prepare(double sampleRate) noexcept {
    rampFrames_ = rampFrames(sampleRate);
    ceiling_.reset(ceiling_.target());
    const int lookahead = std::clamp(static_cast<int>(kLookaheadSeconds * sampleRate), 1, kMaxWindow - 1);
    window_ = lookahead + 1;
    releaseCoefficient_ = onePoleCoefficient(kReleaseMs, sampleRate);
    for (auto& channel : delay_) {
        std::fill(std::begin(channel), std::end(channel), 0.0f);
    }
    std::fill(std::begin(required_), std::end(required_), 1.0f);
    std::fill(std::begin(held_), std::end(held_), 1.0f);
    position_ = 0;
    released_ = 1;
}

void LimiterKernel::setCeilingDB(float db) noexcept {
    ceiling_.setTarget(dbToLinear(std::clamp(db, -6.0f, 0.0f)), rampFrames_);
}

void LimiterKernel::process(float* const* channels, int channelCount, int frameCount) noexcept {
    const int count = std::min(channelCount, kMaxChannels);
    const float inverseWindow = 1.0f / static_cast<float>(window_);
    for (int frame = 0; frame < frameCount; ++frame) {
        const float ceiling = ceiling_.next();
        float peak = 0;
        for (int channel = 0; channel < count; ++channel) {
            peak = std::max(peak, std::fabs(channels[channel][frame]));
        }
        required_[position_] = peak > ceiling ? ceiling / peak : 1.0f;

        float hold = 1;
        for (int index = 0; index < window_; ++index) {
            hold = std::min(hold, required_[index]);
        }
        released_ = std::min(hold, released_ + (1 - released_) * releaseCoefficient_);
        held_[position_] = released_;
        // Every held value in the window is at most what the oldest frame needs, so their average is too.
        float sum = 0;
        for (int index = 0; index < window_; ++index) {
            sum += held_[index];
        }
        const float gain = std::min(sum * inverseWindow, 1.0f);

        const int oldest = (position_ + 1) % window_;
        for (int channel = 0; channel < count; ++channel) {
            delay_[channel][position_] = channels[channel][frame];
            channels[channel][frame] = delay_[channel][oldest] * gain;
        }
        position_ = oldest;
    }
}

} // namespace echo::dsp
