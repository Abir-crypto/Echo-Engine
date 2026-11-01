#include "CompressorKernel.hpp"

#include "DSPMath.hpp"

#include <algorithm>
#include <cmath>

namespace echo::dsp {

CompressorKernel::CompressorKernel() noexcept {
    mix_.reset(0);
    thresholdDB_.reset(-18);
    ratio_.reset(3);
    makeupDB_.reset(0);
}

void CompressorKernel::prepare(double sampleRate) noexcept {
    sampleRate_ = sampleRate;
    rampFrames_ = rampFrames(sampleRate);
    for (SmoothedValue* value : {&mix_, &thresholdDB_, &ratio_, &makeupDB_}) {
        value->reset(value->target());
    }
    attackCoefficient_ = onePoleCoefficient(attackMs_, sampleRate);
    releaseCoefficient_ = onePoleCoefficient(releaseMs_, sampleRate);
    envelope_ = 0;
}

void CompressorKernel::setEnabled(bool enabled) noexcept { mix_.setTarget(enabled ? 1 : 0, rampFrames_); }
void CompressorKernel::setThresholdDB(float db) noexcept { thresholdDB_.setTarget(std::clamp(db, -60.0f, 0.0f), rampFrames_); }
void CompressorKernel::setRatio(float ratio) noexcept { ratio_.setTarget(std::clamp(ratio, 1.0f, 20.0f), rampFrames_); }
void CompressorKernel::setMakeupDB(float db) noexcept { makeupDB_.setTarget(std::clamp(db, 0.0f, 24.0f), rampFrames_); }

void CompressorKernel::setAttackMs(float ms) noexcept {
    attackMs_ = ms;
    attackCoefficient_ = onePoleCoefficient(ms, sampleRate_);
}

void CompressorKernel::setReleaseMs(float ms) noexcept {
    releaseMs_ = ms;
    releaseCoefficient_ = onePoleCoefficient(ms, sampleRate_);
}

void CompressorKernel::process(float* const* channels, int channelCount, int frameCount) noexcept {
    const int count = std::min(channelCount, kMaxChannels);
    for (int frame = 0; frame < frameCount; ++frame) {
        float level = 0;
        for (int channel = 0; channel < count; ++channel) {
            level = std::max(level, std::fabs(channels[channel][frame]));
        }
        envelope_ += (level - envelope_) * (level > envelope_ ? attackCoefficient_ : releaseCoefficient_);
        const float over = linearToDb(envelope_) - thresholdDB_.next();
        const float ratio = ratio_.next();
        const float reductionDB = over > 0 ? -over * (1 - 1 / ratio) : 0;
        const float wet = dbToLinear(reductionDB + makeupDB_.next());
        const float gain = 1 + (wet - 1) * mix_.next();
        for (int channel = 0; channel < count; ++channel) {
            channels[channel][frame] *= gain;
        }
    }
}

} // namespace echo::dsp
