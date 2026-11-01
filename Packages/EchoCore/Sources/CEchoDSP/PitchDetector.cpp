#include "PitchDetector.hpp"

#include <algorithm>
#include <cmath>

namespace echo::dsp {

/// The analysis runs at about this rate: enough for 1 kHz, cheap enough for every 5 ms.
constexpr double kAnalysisRate = 12'000;
/// Quieter input (about −80 dBFS RMS) is unvoiced.
constexpr float kSilenceRMS = 1e-4f;

void PitchDetector::prepare(double sampleRate) {
    decimation_ = std::max(1, static_cast<int>(std::lround(sampleRate / kAnalysisRate)));
    const double rate = sampleRate / decimation_;
    minLag_ = std::max(2, static_cast<int>(rate / kMaximumFrequency));
    maxLag_ = static_cast<int>(std::ceil(rate / kMinimumFrequency));
    window_ = maxLag_;
    antiAlias_ = makeBiquad(FilterShape::lowPass, sampleRate, std::min(2'500.0, 0.4 * rate), 0, 0.707);
    for (BiquadState& stage : antiAliasStages_) { stage.reset(); }

    int64_t size = 1;
    while (size < window_ + maxLag_ + 1) { size <<= 1; }
    history_.assign(static_cast<size_t>(size), 0.0f);
    mask_ = size - 1;
    scratch_.assign(static_cast<size_t>(window_ + maxLag_), 0.0f);
    difference_.assign(static_cast<size_t>(maxLag_ + 1), 0.0f);
    written_ = 0;
    phase_ = 0;
}

void PitchDetector::reset() noexcept {
    for (BiquadState& stage : antiAliasStages_) { stage.reset(); }
    std::fill(history_.begin(), history_.end(), 0.0f);
    written_ = 0;
    phase_ = 0;
}

void PitchDetector::push(float sample) noexcept {
    const float filtered = antiAliasStages_[1].process(antiAlias_, antiAliasStages_[0].process(antiAlias_, sample, 0), 0);
    if (++phase_ < decimation_) { return; }
    phase_ = 0;
    history_[static_cast<size_t>(written_ & mask_)] = filtered;
    ++written_;
}

PitchEstimate PitchDetector::detect() noexcept {
    const int span = window_ + maxLag_;
    if (written_ < span) { return {}; }
    float energy = 0;
    for (int index = 0; index < span; ++index) {
        const float sample = history_[static_cast<size_t>((written_ - span + index) & mask_)];
        scratch_[static_cast<size_t>(index)] = sample;
        energy += sample * sample;
    }
    if (std::sqrt(energy / static_cast<float>(span)) < kSilenceRMS) { return {}; }

    const float* x = scratch_.data();
    float* d = difference_.data();
    d[0] = 1;
    float running = 0;
    for (int lag = 1; lag <= maxLag_; ++lag) {
        float sum = 0;
        for (int index = 0; index < window_; ++index) {
            const float delta = x[index] - x[index + lag];
            sum += delta * delta;
        }
        running += sum;
        // Cumulative mean normalised difference: 0 at a perfect period, about 1 where there is none.
        d[lag] = running > 0 ? sum * static_cast<float>(lag) / running : 1;
    }

    const float threshold = 1 - kMinimumConfidence;
    for (int lag = minLag_; lag < maxLag_; ++lag) {
        if (d[lag] >= threshold) { continue; }
        while (lag + 1 < maxLag_ && d[lag + 1] < d[lag]) { ++lag; }
        const float before = d[lag - 1], at = d[lag], after = d[lag + 1];
        const float curvature = before + after - 2 * at;
        const float offset = curvature > 0 ? 0.5f * (before - after) / curvature : 0;
        return {(static_cast<float>(lag) + offset) * static_cast<float>(decimation_), 1 - at};
    }
    return {};
}

} // namespace echo::dsp
