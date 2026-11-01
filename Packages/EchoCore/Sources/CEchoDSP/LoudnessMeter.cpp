#include "LoudnessMeter.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <numeric>

namespace echo::dsp {

namespace {
constexpr double kAbsoluteGateLUFS = -70;
constexpr double kRelativeGateLU = -10;
constexpr double kLoudnessOffset = -0.691;

double loudness(double meanSquare) { return kLoudnessOffset + 10 * std::log10(meanSquare); }
} // namespace

// BS.1770's two stages from their analogue prototypes (as in libebur128), so any sample rate works; at 48 kHz they
// equal the standard's coefficient table.
LoudnessMeter::KWeighting LoudnessMeter::preFilter(double sampleRate) {
    const double f0 = 1681.974450955533, gain = 3.999843853973347, q = 0.7071752369554196;
    const double k = std::tan(M_PI * f0 / sampleRate);
    const double vh = std::pow(10.0, gain / 20.0), vb = std::pow(vh, 0.4996667741545416);
    const double a0 = 1 + k / q + k * k;
    return {(vh + vb * k / q + k * k) / a0, 2 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0,
            2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0};
}

LoudnessMeter::KWeighting LoudnessMeter::highPass(double sampleRate) {
    const double f0 = 38.13547087602444, q = 0.5003270373238773;
    const double k = std::tan(M_PI * f0 / sampleRate);
    const double a0 = 1 + k / q + k * k;
    return {1, -2, 1, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0};
}

void LoudnessMeter::prepare(double sampleRate, int channelCount, bool measuresTruePeak) {
    channelCount_ = std::max(channelCount, 1);
    pre_.assign(static_cast<size_t>(channelCount_), Filter{preFilter(sampleRate)});
    rlb_.assign(static_cast<size_t>(channelCount_), Filter{highPass(sampleRate)});
    subBlockFrames_ = std::max(1, static_cast<int>(std::lround(sampleRate * 0.1)));
    subBlockFill_ = 0;
    subBlockSum_ = 0;
    recentSubBlocks_.clear();
    blocks_.clear();

    measuresTruePeak_ = measuresTruePeak;
    oversampling_ = sampleRate < 96'000 ? 4 : sampleRate < 192'000 ? 2 : 1;
    // Windowed-sinc interpolator, `kTapsPerPhase` taps per phase; each phase sums to 1.
    const int taps = oversampling_ * kTapsPerPhase;
    phases_.assign(static_cast<size_t>(taps), 0.0f);
    for (int phase = 0; phase < oversampling_; ++phase) {
        double sum = 0;
        std::vector<double> coefficients(kTapsPerPhase);
        for (int tap = 0; tap < kTapsPerPhase; ++tap) {
            const int n = tap * oversampling_ + phase;
            const double x = (n - (taps - 1) / 2.0) / oversampling_;
            const double sinc = x == 0 ? 1 : std::sin(M_PI * x) / (M_PI * x);
            const double window = 0.42 - 0.5 * std::cos(2 * M_PI * (n + 0.5) / taps) + 0.08 * std::cos(4 * M_PI * (n + 0.5) / taps);
            coefficients[static_cast<size_t>(tap)] = sinc * window;
            sum += coefficients[static_cast<size_t>(tap)];
        }
        for (int tap = 0; tap < kTapsPerPhase; ++tap) {
            phases_[static_cast<size_t>(phase * kTapsPerPhase + tap)] = static_cast<float>(coefficients[static_cast<size_t>(tap)] / sum);
        }
    }
    history_.assign(static_cast<size_t>(channelCount_ * kTapsPerPhase), 0.0f);
    historyPosition_ = 0;
    peak_ = 0;
}

void LoudnessMeter::process(const float* const* channels, int channelCount, int frameCount) {
    const int count = std::min(channelCount, channelCount_);
    for (int frame = 0; frame < frameCount; ++frame) {
        for (int channel = 0; channel < count; ++channel) {
            const double weighted = rlb_[static_cast<size_t>(channel)].process(pre_[static_cast<size_t>(channel)].process(channels[channel][frame]));
            subBlockSum_ += weighted * weighted;
        }
        if (++subBlockFill_ == subBlockFrames_) { finishSubBlock(); }
    }
    if (measuresTruePeak_) { measurePeak(channels, count, frameCount); }
}

void LoudnessMeter::finishSubBlock() {
    recentSubBlocks_.push_back(subBlockSum_);
    subBlockSum_ = 0;
    subBlockFill_ = 0;
    if (recentSubBlocks_.size() > 4) { recentSubBlocks_.erase(recentSubBlocks_.begin()); }
    if (recentSubBlocks_.size() == 4) {
        const double sum = std::accumulate(recentSubBlocks_.begin(), recentSubBlocks_.end(), 0.0);
        blocks_.push_back(sum / (4.0 * subBlockFrames_));
    }
}

void LoudnessMeter::measurePeak(const float* const* channels, int channelCount, int frameCount) {
    for (int frame = 0; frame < frameCount; ++frame) {
        for (int channel = 0; channel < channelCount; ++channel) {
            float* history = history_.data() + channel * kTapsPerPhase;
            history[historyPosition_] = channels[channel][frame];
            for (int phase = 0; phase < oversampling_; ++phase) {
                const float* coefficients = phases_.data() + phase * kTapsPerPhase;
                float sum = 0;
                for (int tap = 0; tap < kTapsPerPhase; ++tap) {
                    // Newest sample first.
                    const int index = (historyPosition_ - tap + kTapsPerPhase) % kTapsPerPhase;
                    sum += coefficients[tap] * history[index];
                }
                peak_ = std::max(peak_, std::fabs(sum));
            }
            peak_ = std::max(peak_, std::fabs(channels[channel][frame]));
        }
        historyPosition_ = (historyPosition_ + 1) % kTapsPerPhase;
    }
}

double LoudnessMeter::integratedLUFS() const {
    double sum = 0;
    int count = 0;
    for (double block : blocks_) {
        if (block > 0 && loudness(block) > kAbsoluteGateLUFS) {
            sum += block;
            ++count;
        }
    }
    if (count == 0) { return std::numeric_limits<double>::quiet_NaN(); }
    const double relativeGate = loudness(sum / count) + kRelativeGateLU;
    sum = 0;
    count = 0;
    for (double block : blocks_) {
        if (block > 0 && loudness(block) > kAbsoluteGateLUFS && loudness(block) > relativeGate) {
            sum += block;
            ++count;
        }
    }
    return count == 0 ? std::numeric_limits<double>::quiet_NaN() : loudness(sum / count);
}

double LoudnessMeter::truePeakDBTP() const {
    return peak_ > 0 ? 20 * std::log10(static_cast<double>(peak_)) : -std::numeric_limits<double>::infinity();
}

} // namespace echo::dsp
