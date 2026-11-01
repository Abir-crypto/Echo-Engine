#include "TruePeakDetector.hpp"

#include <algorithm>
#include <cmath>

namespace echo::dsp {

void TruePeakDetector::prepare(double sampleRate) noexcept {
    phases_ = sampleRate < 96'000 ? 4 : sampleRate < 192'000 ? 2 : 1;
    const int taps = phases_ * kTapsPerPhase;
    for (int phase = 0; phase < phases_; ++phase) {
        double sum = 0;
        double values[kTapsPerPhase];
        for (int tap = 0; tap < kTapsPerPhase; ++tap) {
            const int n = tap * phases_ + phase;
            const double x = (n - (taps - 1) / 2.0) / phases_;
            const double sinc = x == 0 ? 1 : std::sin(M_PI * x) / (M_PI * x);
            const double window = 0.42 - 0.5 * std::cos(2 * M_PI * (n + 0.5) / taps) + 0.08 * std::cos(4 * M_PI * (n + 0.5) / taps);
            values[tap] = sinc * window;
            sum += values[tap];
        }
        // Each phase sums to 1, so a constant reads as itself.
        for (int tap = 0; tap < kTapsPerPhase; ++tap) {
            coefficients_[phase][tap] = static_cast<float>(values[tap] / sum);
        }
    }
    reset();
}

void TruePeakDetector::reset() noexcept {
    std::fill(std::begin(history_), std::end(history_), 0.0f);
    position_ = 0;
}

float TruePeakDetector::next(float sample) noexcept {
    history_[position_] = sample;
    float peak = std::fabs(sample);
    for (int phase = 0; phase < phases_; ++phase) {
        float sum = 0;
        for (int tap = 0; tap < kTapsPerPhase; ++tap) {
            // Newest sample first.
            sum += coefficients_[phase][tap] * history_[(position_ - tap + kTapsPerPhase) % kTapsPerPhase];
        }
        peak = std::max(peak, std::fabs(sum));
    }
    position_ = (position_ + 1) % kTapsPerPhase;
    return peak;
}

} // namespace echo::dsp
