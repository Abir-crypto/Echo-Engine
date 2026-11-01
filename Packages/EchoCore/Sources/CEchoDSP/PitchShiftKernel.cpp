#include "PitchShiftKernel.hpp"

#include <algorithm>
#include <cmath>

namespace echo::dsp {

/// Pitch is re-estimated this often.
constexpr double kHopSeconds = 0.005;
/// Unvoiced input is cut into grains of about this length (jittered ±25 % so it doesn't buzz).
constexpr double kUnvoicedPeriodSeconds = 0.006;

void PitchShiftKernel::prepare(double sampleRate) {
    detector_.prepare(sampleRate);
    rampFrames_ = rampFrames(sampleRate);
    semitones_.reset(semitones_.target());
    wet_.reset(wet_.target());
    maxPeriod_ = static_cast<int>(std::ceil(sampleRate / PitchDetector::kMinimumFrequency));
    minPeriod_ = static_cast<int>(sampleRate / PitchDetector::kMaximumFrequency);
    baseUnvoicedPeriod_ = static_cast<int>(kUnvoicedPeriodSeconds * sampleRate);
    // A grain reaches one period past its mark, and the next mark is searched up to 1.3 periods ahead.
    latency_ = maxPeriod_ * 5 / 2;
    hop_ = std::max(1, static_cast<int>(kHopSeconds * sampleRate));

    size_t size = 1;
    while (size < static_cast<size_t>(latency_ + maxPeriod_ * 3)) { size <<= 1; }
    ringSize_ = size;
    mask_ = static_cast<int64_t>(size) - 1;
    input_.assign(kMaxChannels * size, 0.0f);
    output_.assign(kMaxChannels * size, 0.0f);
    mono_.assign(size, 0.0f);
    weight_.assign(size, 0.0f);
    written_ = 0;
    hopCounter_ = 0;
    period_ = baseUnvoicedPeriod_;
    isVoiced_ = isMarkAligned_ = false;
    isActive_ = wet_.target() > 0;
    needsEngage_ = isActive_;
}

void PitchShiftKernel::setSemitones(float semitones) noexcept {
    const float clamped = std::clamp(semitones, -12.0f, 12.0f);
    semitones_.setTarget(clamped, rampFrames_);
    wet_.setTarget(clamped != 0 ? 1 : 0, rampFrames_);
    if (clamped != 0 && !isActive_) {
        isActive_ = true;
        needsEngage_ = true;
    }
}

void PitchShiftKernel::engage(int64_t now) noexcept {
    std::fill(output_.begin(), output_.end(), 0.0f);
    std::fill(weight_.begin(), weight_.end(), 0.0f);
    synthesisMark_ = static_cast<double>(now);
    analysisMark_ = now;
    isMarkAligned_ = false;
    updatePeriod();
    needsEngage_ = false;
}

void PitchShiftKernel::updatePeriod() noexcept {
    const PitchEstimate estimate = detector_.detect();
    const bool wasVoiced = isVoiced_;
    isVoiced_ = estimate.period > 0;
    if (isVoiced_) {
        period_ = std::clamp(static_cast<int>(std::lround(estimate.period)), minPeriod_, maxPeriod_);
    } else {
        period_ = baseUnvoicedPeriod_;
    }
    if (isVoiced_ != wasVoiced) { isMarkAligned_ = false; }
}

int PitchShiftKernel::unvoicedPeriod() noexcept {
    noise_ = noise_ * 1'664'525u + 1'013'904'223u;
    const float jitter = 0.75f + 0.5f * static_cast<float>(noise_ >> 8) / static_cast<float>(1u << 24);
    return std::max(1, static_cast<int>(static_cast<float>(baseUnvoicedPeriod_) * jitter));
}

int64_t PitchShiftKernel::searchPeak(int64_t from, int64_t to, bool setsPolarity) noexcept {
    int64_t best = from;
    float bestValue = -1e30f;
    for (int64_t position = from; position <= to; ++position) {
        const float value = mono_[static_cast<size_t>(position & mask_)];
        const float score = setsPolarity ? std::fabs(value) : value * polarity_;
        if (score > bestValue) {
            bestValue = score;
            best = position;
        }
    }
    if (setsPolarity) { polarity_ = mono_[static_cast<size_t>(best & mask_)] < 0 ? -1.0f : 1.0f; }
    return best;
}

int64_t PitchShiftKernel::markBefore(int64_t center) noexcept {
    while (true) {
        int64_t candidate;
        if (!isVoiced_) {
            candidate = analysisMark_ + unvoicedPeriod();
        } else if (!isMarkAligned_) {
            // Snap onto the strongest pulse of the next period, and follow its polarity from now on.
            candidate = searchPeak(analysisMark_ + period_ / 2, analysisMark_ + period_ * 3 / 2, true);
            isMarkAligned_ = true;
        } else {
            candidate = searchPeak(analysisMark_ + period_ * 7 / 10, analysisMark_ + period_ * 13 / 10, false);
        }
        if (candidate > center) { return analysisMark_; }
        analysisMark_ = candidate;
    }
}

void PitchShiftKernel::addGrains(int64_t now, double ratio, int channelCount) noexcept {
    while (true) {
        const int half = period_;
        const int64_t center = std::llround(synthesisMark_);
        if (center - half > now) { return; }
        const int64_t mark = markBefore(center);
        const float step = static_cast<float>(M_PI) / static_cast<float>(half);
        for (int64_t offset = std::max<int64_t>(-half, now - center); offset < half; ++offset) {
            const float window = 0.5f * (1 + std::cos(static_cast<float>(offset) * step));
            const size_t out = static_cast<size_t>((center + offset) & mask_);
            for (int channel = 0; channel < channelCount; ++channel) {
                output_[static_cast<size_t>(channel) * ringSize_ + out] += window * sample(input_, channel, mark + offset);
            }
            weight_[out] += window;
        }
        synthesisMark_ += static_cast<double>(half) / ratio;
    }
}

void PitchShiftKernel::process(float* const* channels, int channelCount, int frameCount) noexcept {
    const int count = std::min(channelCount, kMaxChannels);
    for (int frame = 0; frame < frameCount; ++frame) {
        const int64_t position = written_++;
        float mono = 0;
        for (int channel = 0; channel < count; ++channel) {
            const float input = channels[channel][frame];
            input_[static_cast<size_t>(channel) * ringSize_ + static_cast<size_t>(position & mask_)] = input;
            mono += input;
        }
        mono_[static_cast<size_t>(position & mask_)] = mono / static_cast<float>(std::max(count, 1));
        // The detector looks at input around the analysis marks, which trail the newest input.
        detector_.push(mono_[static_cast<size_t>((position - maxPeriod_) & mask_)]);

        const int64_t now = position - latency_;
        const double ratio = std::exp2(static_cast<double>(semitones_.next()) / 12.0);
        const float wet = wet_.next();
        // Lower pitch has fewer pulses per second; this keeps the loudness.
        const float sparseGain = ratio < 1 ? static_cast<float>(1 / std::sqrt(ratio)) : 1.0f;
        if (isActive_) {
            if (needsEngage_) { engage(now); }
            if (++hopCounter_ >= hop_) {
                hopCounter_ = 0;
                updatePeriod();
            }
            addGrains(now, ratio, count);
        }
        const size_t index = static_cast<size_t>(now & mask_);
        for (int channel = 0; channel < count; ++channel) {
            const float dry = sample(input_, channel, now);
            float result = dry;
            if (isActive_) {
                float& shifted = output_[static_cast<size_t>(channel) * ringSize_ + index];
                // Overlapping grains (higher pitch) don't add up in phase, so they are scaled to keep the energy.
                const float grains = shifted / std::sqrt(std::max(weight_[index], 1.0f)) * sparseGain;
                result = dry + (grains - dry) * wet;
                shifted = 0;
            }
            channels[channel][frame] = result;
        }
        weight_[index] = 0;
        if (isActive_ && wet == 0 && wet_.target() == 0) { isActive_ = false; }
    }
}

} // namespace echo::dsp
