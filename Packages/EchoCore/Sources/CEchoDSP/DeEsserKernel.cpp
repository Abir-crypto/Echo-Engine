#include "DeEsserKernel.hpp"

#include "DSPMath.hpp"

#include <algorithm>
#include <cmath>

namespace echo::dsp {

constexpr double kDetectorAttackMs = 1;
constexpr double kDetectorReleaseMs = 60;
/// Detector band-pass width and shelf slope.
constexpr double kDetectorQ = 2;
constexpr double kShelfQ = 0.707;

DeEsserKernel::DeEsserKernel() noexcept {
    mix_.reset(0);
    amount_.reset(0.5f);
    log2Frequency_.reset(std::log2(6'500.0f));
    updateDetector();
}

void DeEsserKernel::prepare(double sampleRate) noexcept {
    sampleRate_ = sampleRate;
    rampFrames_ = rampFrames(sampleRate);
    for (SmoothedValue* value : {&mix_, &amount_, &log2Frequency_}) {
        value->reset(value->target());
    }
    attackCoefficient_ = onePoleCoefficient(kDetectorAttackMs, sampleRate);
    releaseCoefficient_ = onePoleCoefficient(kDetectorReleaseMs, sampleRate);
    detectorState_.reset();
    shelfState_.reset();
    envelope_ = 0;
    updateDetector();
}

void DeEsserKernel::setEnabled(bool enabled) noexcept { mix_.setTarget(enabled ? 1 : 0, rampFrames_); }
void DeEsserKernel::setAmount(float amount) noexcept { amount_.setTarget(std::clamp(amount, 0.0f, 1.0f), rampFrames_); }

void DeEsserKernel::setFrequency(float hz) noexcept {
    log2Frequency_.setTarget(std::log2(std::clamp(hz, 4'000.0f, 10'000.0f)), rampFrames_);
    if (!log2Frequency_.isSmoothing()) { updateDetector(); }
}

void DeEsserKernel::updateDetector() noexcept {
    detector_ = makeBiquad(FilterShape::bandPass, sampleRate_, std::exp2(log2Frequency_.current()), 0, kDetectorQ);
}

void DeEsserKernel::process(float* const* channels, int channelCount, int frameCount) noexcept {
    const int count = std::min(channelCount, kMaxChannels);
    for (int start = 0; start < frameCount; start += kCoefficientBlock) {
        const int length = std::min(kCoefficientBlock, frameCount - start);
        if (log2Frequency_.isSmoothing()) {
            log2Frequency_.advance(length);
            updateDetector();
        }
        amount_.advance(length);
        mix_.advance(length);
        const float over = linearToDb(envelope_) - kThresholdDB;
        const float reductionDB = over > 0 ? std::min(over, kMaxReductionDB) * amount_.current() * mix_.current() : 0.0f;
        shelf_ = makeBiquad(FilterShape::highShelf, sampleRate_, std::exp2(log2Frequency_.current()), -reductionDB, kShelfQ);

        for (int frame = start; frame < start + length; ++frame) {
            float level = 0;
            for (int channel = 0; channel < count; ++channel) {
                const float input = channels[channel][frame];
                level = std::max(level, std::fabs(detectorState_.process(detector_, input, channel)));
                channels[channel][frame] = shelfState_.process(shelf_, input, channel);
            }
            envelope_ += (level - envelope_) * (level > envelope_ ? attackCoefficient_ : releaseCoefficient_);
        }
    }
}

} // namespace echo::dsp
