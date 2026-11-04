#include "LiveChain.hpp"

#include "Denoiser.h"

#include <algorithm>
#include <cstring>

namespace echo::dsp {

namespace {
/// Fade before and after a change to or from High.
constexpr double kTransitionFadeSeconds = 0.01;
}

LiveChain::LiveChain() noexcept {
    fade_.reset(1);
    gate_.setThresholdDB(-50);
    gate_.setRangeDB(-20);
    gate_.setAttackMs(2);
    gate_.setReleaseMs(200);
    limiter_.setCeilingDB(-1);
}

LiveChain::~LiveChain() {
    for (auto*& denoiser : denoisers_) {
        if (denoiser != nullptr) { EEDenoiserDestroy(denoiser); }
    }
}

void LiveChain::prepare(double sampleRate, int channelCount, int maximumFrames) {
    channelCount_ = std::clamp(channelCount, 1, kMaxChannels);
    maximumFrames_ = std::max(1, maximumFrames);
    supportsHigh_ = sampleRate >= 44'100;
    gain_.prepare(sampleRate);
    gate_.prepare(sampleRate);
    leveler_.prepare(sampleRate);
    limiter_.prepare(sampleRate);
    for (int channel = 0; channel < kMaxChannels; ++channel) {
        if (denoisers_[channel] == nullptr && channel < channelCount_ && supportsHigh_) {
            denoisers_[channel] = EEDenoiserCreate();
        }
        delay_[channel].assign(kHighLatencyFrames, 0.0f);
    }
    scratch_.assign(static_cast<size_t>(kMaxChannels) * static_cast<size_t>(maximumFrames_), 0.0f);
    fadeFrames_ = std::max(1, static_cast<int>(kTransitionFadeSeconds * sampleRate));
    reset();
}

void LiveChain::reset() noexcept {
    gain_.reset();
    gate_.reset();
    leveler_.reset();
    limiter_.reset();
    std::memset(frameIn_, 0, sizeof(frameIn_));
    std::memset(frameOut_, 0, sizeof(frameOut_));
    framePosition_ = 0;
    for (auto& line : delay_) { std::fill(line.begin(), line.end(), 0.0f); }
    delayPosition_ = 0;
    active_ = target_;
    phase_ = Phase::steady;
    fade_.reset(1);
}

void LiveChain::setTier(SuppressionTier tier) noexcept {
    if (tier == SuppressionTier::high && !supportsHigh_) { tier = SuppressionTier::standard; }
    if (tier == target_) { return; }
    target_ = tier;
    gate_.setEnabled(tier == SuppressionTier::standard);
    if (tier == SuppressionTier::high || active_ == SuppressionTier::high) {
        beginTransition();
    } else {
        active_ = tier;   // Off ↔ Standard: the gate's own ramp is enough.
    }
}

void LiveChain::beginTransition() noexcept {
    if (phase_ == Phase::steady || phase_ == Phase::fadingIn) {
        phase_ = Phase::fadingOut;
        fade_.setTarget(0, fadeFrames_);
    }
}

float LiveChain::nextFade() noexcept {
    switch (phase_) {
    case Phase::steady:
        return 1;
    case Phase::fadingOut: {
        const float value = fade_.next();
        if (!fade_.isSmoothing()) {
            // Silent now: switch, and let RNNoise and the delay line fill before fading in.
            active_ = target_;
            phase_ = Phase::holding;
            holdRemaining_ = kHighLatencyFrames + 480;
        }
        return value;
    }
    case Phase::holding:
        if (active_ != target_) {
            // The tier changed again while silent: wait for the newest one.
            active_ = target_;
            holdRemaining_ = kHighLatencyFrames + 480;
        }
        if (--holdRemaining_ <= 0) {
            phase_ = Phase::fadingIn;
            fade_.setTarget(1, fadeFrames_);
        }
        return 0;
    case Phase::fadingIn: {
        const float value = fade_.next();
        if (!fade_.isSmoothing()) { phase_ = Phase::steady; }
        return value;
    }
    }
    return 1;
}

void LiveChain::runHigh(float* samples, int channel, int frameCount) noexcept {
    EEDenoiser* denoiser = denoisers_[channel];
    int position = framePosition_;
    for (int frame = 0; frame < frameCount; ++frame) {
        frameIn_[channel][position] = samples[frame];
        samples[frame] = frameOut_[channel][position];
        if (++position == 480) {
            position = 0;
            if (denoiser != nullptr) { EEDenoiserProcess(denoiser, frameOut_[channel], frameIn_[channel]); }
        }
    }
}

void LiveChain::process(float* const* channels, float* const* recorded, int channelCount, int frameCount) noexcept {
    const int count = std::min(channelCount, channelCount_);
    const bool isHigh = active_ == SuppressionTier::high;
    gain_.process(channels, count, frameCount);
    if (isHigh) {
        for (int channel = 0; channel < count; ++channel) { runHigh(channels[channel], channel, frameCount); }
        framePosition_ = (framePosition_ + frameCount) % 480;
    } else {
        gate_.process(channels, count, frameCount);
    }
    leveler_.process(channels, count, frameCount);
    limiter_.process(channels, count, frameCount);
    // One fade for every channel; the recorded signal fades with the monitor.
    for (int frame = 0; frame < frameCount; ++frame) {
        const float fade = nextFade();
        if (fade != 1) {
            for (int channel = 0; channel < count; ++channel) { channels[channel][frame] *= fade; }
        }
    }
    for (int channel = 0; channel < count; ++channel) {
        float* line = delay_[channel].data();
        int position = delayPosition_;
        for (int frame = 0; frame < frameCount; ++frame) {
            const float sample = channels[channel][frame];
            // High is already this late; the other tiers go through the delay line.
            recorded[channel][frame] = isHigh ? sample : line[position];
            line[position] = sample;
            if (++position == kHighLatencyFrames) { position = 0; }
        }
    }
    delayPosition_ = (delayPosition_ + frameCount) % kHighLatencyFrames;
}

} // namespace echo::dsp
