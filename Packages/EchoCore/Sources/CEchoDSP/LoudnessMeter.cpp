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
    peakDetectors_.assign(static_cast<size_t>(channelCount_), TruePeakDetector());
    for (TruePeakDetector& detector : peakDetectors_) { detector.prepare(sampleRate); }
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
    for (int channel = 0; channel < channelCount; ++channel) {
        TruePeakDetector& detector = peakDetectors_[static_cast<size_t>(channel)];
        for (int frame = 0; frame < frameCount; ++frame) {
            peak_ = std::max(peak_, detector.next(channels[channel][frame]));
        }
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
