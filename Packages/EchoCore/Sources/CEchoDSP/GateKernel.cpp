#include "GateKernel.hpp"

#include "DSPMath.hpp"

#include <algorithm>
#include <cmath>

namespace echo::dsp {

/// The level detector falls this fast once the signal drops, so short dips don't chatter the gate.
constexpr double kDetectorReleaseMs = 20;

GateKernel::GateKernel() noexcept : rangeLinear_(dbToLinear(-40)) {
    mix_.reset(0);
    threshold_.reset(dbToLinear(-50));
}

void GateKernel::prepare(double sampleRate) noexcept {
    sampleRate_ = sampleRate;
    rampFrames_ = rampFrames(sampleRate);
    mix_.reset(mix_.target());
    threshold_.reset(threshold_.target());
    attackCoefficient_ = onePoleCoefficient(attackMs_, sampleRate);
    releaseCoefficient_ = onePoleCoefficient(releaseMs_, sampleRate);
    detectorCoefficient_ = onePoleCoefficient(kDetectorReleaseMs, sampleRate);
    envelope_ = 0;
    gain_ = 1;
}

void GateKernel::reset() noexcept {
    mix_.reset(mix_.target());
    threshold_.reset(threshold_.target());
    envelope_ = 0;
    gain_ = 1;
}

void GateKernel::setEnabled(bool enabled) noexcept { mix_.setTarget(enabled ? 1 : 0, rampFrames_); }

void GateKernel::setThresholdDB(float db) noexcept {
    threshold_.setTarget(dbToLinear(std::clamp(db, -80.0f, 0.0f)), rampFrames_);
}

void GateKernel::setRangeDB(float db) noexcept { rangeLinear_ = dbToLinear(std::clamp(db, -80.0f, 0.0f)); }

void GateKernel::setAttackMs(float ms) noexcept {
    attackMs_ = ms;
    attackCoefficient_ = onePoleCoefficient(ms, sampleRate_);
}

void GateKernel::setReleaseMs(float ms) noexcept {
    releaseMs_ = ms;
    releaseCoefficient_ = onePoleCoefficient(ms, sampleRate_);
}

void GateKernel::process(float* const* channels, int channelCount, int frameCount) noexcept {
    const int count = std::min(channelCount, kMaxChannels);
    for (int frame = 0; frame < frameCount; ++frame) {
        float level = 0;
        for (int channel = 0; channel < count; ++channel) {
            level = std::max(level, std::fabs(channels[channel][frame]));
        }
        envelope_ = level > envelope_ ? level : envelope_ + (level - envelope_) * detectorCoefficient_;
        const float target = envelope_ >= threshold_.next() ? 1.0f : rangeLinear_;
        gain_ += (target - gain_) * (target > gain_ ? attackCoefficient_ : releaseCoefficient_);
        const float gain = 1 + (gain_ - 1) * mix_.next();
        for (int channel = 0; channel < count; ++channel) {
            channels[channel][frame] *= gain;
        }
    }
}

} // namespace echo::dsp
