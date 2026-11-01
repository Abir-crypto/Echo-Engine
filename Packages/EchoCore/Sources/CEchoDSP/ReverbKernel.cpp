#include "ReverbKernel.hpp"

#include <algorithm>
#include <cmath>

namespace echo::dsp {

namespace {

// Freeverb tuning (Jezar at Dreampoint, public domain), in samples at 44.1 kHz.
constexpr int kCombTuning[ReverbKernel::kCombs] = {1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617};
constexpr int kAllpassTuning[ReverbKernel::kAllpasses] = {556, 441, 341, 225};
constexpr int kStereoSpread = 23;
constexpr float kInputGain = 0.015f;
constexpr float kAllpassFeedback = 0.5f;
constexpr float kRoomScale = 0.28f, kRoomOffset = 0.7f;
constexpr float kDampScale = 0.4f;
/// Freeverb's default wet level (1/3 × its wet scale of 3).
constexpr float kWetGain = 1;

} // namespace

ReverbKernel::ReverbKernel() noexcept {
    enabled_.reset(0);
    roomSize_.reset(0.5f);
    damping_.reset(0.5f);
    mix_.reset(0.2f);
}

void ReverbKernel::prepare(double sampleRate) {
    rampFrames_ = rampFrames(sampleRate);
    for (SmoothedValue* value : {&enabled_, &roomSize_, &damping_, &mix_}) {
        value->reset(value->target());
    }
    const double scale = sampleRate / 44'100.0;
    int total = 0;
    for (int channel = 0; channel < kMaxChannels; ++channel) {
        const int spread = channel * kStereoSpread;
        for (int comb = 0; comb < kCombs; ++comb) {
            combOffset_[channel][comb] = total;
            combLength_[channel][comb] = std::max(1, static_cast<int>(std::lround((kCombTuning[comb] + spread) * scale)));
            total += combLength_[channel][comb];
        }
        for (int allpass = 0; allpass < kAllpasses; ++allpass) {
            allpassOffset_[channel][allpass] = total;
            allpassLength_[channel][allpass] = std::max(1, static_cast<int>(std::lround((kAllpassTuning[allpass] + spread) * scale)));
            total += allpassLength_[channel][allpass];
        }
    }
    lines_.assign(static_cast<size_t>(total), 0.0f);
    clear();
}

void ReverbKernel::clear() noexcept {
    std::fill(lines_.begin(), lines_.end(), 0.0f);
    for (int channel = 0; channel < kMaxChannels; ++channel) {
        std::fill(std::begin(combIndex_[channel]), std::end(combIndex_[channel]), 0);
        std::fill(std::begin(combStore_[channel]), std::end(combStore_[channel]), 0.0f);
        std::fill(std::begin(allpassIndex_[channel]), std::end(allpassIndex_[channel]), 0);
    }
    needsClear_ = false;
}

void ReverbKernel::reset() noexcept {
    for (SmoothedValue* value : {&enabled_, &roomSize_, &damping_, &mix_}) {
        value->reset(value->target());
    }
    clear();
}

void ReverbKernel::setEnabled(bool enabled) noexcept { enabled_.setTarget(enabled ? 1 : 0, rampFrames_); }
void ReverbKernel::setRoomSize(float roomSize) noexcept { roomSize_.setTarget(std::clamp(roomSize, 0.0f, 1.0f), rampFrames_); }
void ReverbKernel::setDamping(float damping) noexcept { damping_.setTarget(std::clamp(damping, 0.0f, 1.0f), rampFrames_); }
void ReverbKernel::setMix(float mix) noexcept { mix_.setTarget(std::clamp(mix, 0.0f, 1.0f), rampFrames_); }

void ReverbKernel::process(float* const* channels, int channelCount, int frameCount) noexcept {
    if (!enabled_.isSmoothing() && enabled_.current() == 0) {
        // Fully off: untouched, and the next start begins without an old tail.
        needsClear_ = true;
        return;
    }
    if (needsClear_) { clear(); }
    const int count = std::min(channelCount, kMaxChannels);
    if (count == 0 || lines_.empty()) { return; }
    float* lines = lines_.data();
    for (int frame = 0; frame < frameCount; ++frame) {
        const float feedback = roomSize_.next() * kRoomScale + kRoomOffset;
        const float damp = damping_.next() * kDampScale;
        const float mix = mix_.next() * enabled_.next();
        float input = 0;
        for (int channel = 0; channel < count; ++channel) { input += channels[channel][frame]; }
        // Freeverb feeds L + R; a mono source counts twice.
        input *= kInputGain * 2 / static_cast<float>(count);

        for (int channel = 0; channel < count; ++channel) {
            float wet = 0;
            for (int comb = 0; comb < kCombs; ++comb) {
                float* line = lines + combOffset_[channel][comb];
                int& index = combIndex_[channel][comb];
                float& store = combStore_[channel][comb];
                const float delayed = line[index];
                store = delayed * (1 - damp) + store * damp;
                line[index] = input + store * feedback;
                if (++index >= combLength_[channel][comb]) { index = 0; }
                wet += delayed;
            }
            for (int allpass = 0; allpass < kAllpasses; ++allpass) {
                float* line = lines + allpassOffset_[channel][allpass];
                int& index = allpassIndex_[channel][allpass];
                const float delayed = line[index];
                line[index] = wet + delayed * kAllpassFeedback;
                wet = delayed - wet;
                if (++index >= allpassLength_[channel][allpass]) { index = 0; }
            }
            const float dry = channels[channel][frame];
            channels[channel][frame] = dry + (wet * kWetGain - dry) * mix;
        }
    }
}

} // namespace echo::dsp
