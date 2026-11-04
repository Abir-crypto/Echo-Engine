#include "LiveLevelerKernel.hpp"

#include <algorithm>
#include <cmath>

namespace echo::dsp {

void LiveLevelerKernel::prepare(double sampleRate) noexcept {
    detectorCoefficient_ = onePoleCoefficient(400, sampleRate);
    // The gain moves once per block.
    const double blockRate = sampleRate / kBlockFrames;
    lowerCoefficient_ = onePoleCoefficient(1'000, blockRate);
    raiseCoefficient_ = onePoleCoefficient(3'000, blockRate);
    reset();
}

void LiveLevelerKernel::reset() noexcept {
    meanSquare_ = 0;
    gainDB_ = 0;
    gainLinear_ = 1;
    step_ = 0;
    blockPosition_ = 0;
}

void LiveLevelerKernel::process(float* const* channels, int channelCount, int frameCount) noexcept {
    const int count = std::min(channelCount, kMaxChannels);
    for (int frame = 0; frame < frameCount; ++frame) {
        float square = 0;
        for (int channel = 0; channel < count; ++channel) {
            const float sample = channels[channel][frame];
            square = std::max(square, sample * sample);
        }
        meanSquare_ += (square - meanSquare_) * detectorCoefficient_;

        if (blockPosition_ == 0) {
            const float levelDB = 10 * std::log10(meanSquare_ + 1e-12f);
            if (levelDB > kSpeechFloorDB) {
                const float wanted = std::clamp(kTargetDB - levelDB, -kMaxGainDB, kMaxGainDB);
                gainDB_ += (wanted - gainDB_) * (wanted < gainDB_ ? lowerCoefficient_ : raiseCoefficient_);
            }
            // Glide to the block's gain sample by sample.
            step_ = (dbToLinear(gainDB_) - gainLinear_) / kBlockFrames;
        }
        if (++blockPosition_ == kBlockFrames) { blockPosition_ = 0; }
        gainLinear_ += step_;
        for (int channel = 0; channel < count; ++channel) { channels[channel][frame] *= gainLinear_; }
    }
}

} // namespace echo::dsp
