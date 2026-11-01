#include "EQKernel.hpp"

#include <algorithm>
#include <cmath>

namespace echo::dsp {

void EQKernel::prepare(double sampleRate) noexcept {
    sampleRate_ = sampleRate;
    rampFrames_ = rampFrames(sampleRate);
    for (Band& band : bands_) {
        band.log2Frequency.reset(band.log2Frequency.target());
        band.gainDB.reset(band.gainDB.target());
        band.q.reset(band.q.target());
        band.state.reset();
        updateCoefficients(band);
    }
}

void EQKernel::setBand(int index, FilterShape shape, float frequency, float gainDB, float q) noexcept {
    if (index < 0 || index >= kBands) { return; }
    Band& band = bands_[index];
    const bool shapeChanged = band.shape != shape;
    band.shape = shape;
    const int ramp = shapeChanged ? 0 : rampFrames_;
    band.log2Frequency.setTarget(std::log2(std::clamp(frequency, 20.0f, 20'000.0f)), ramp);
    band.gainDB.setTarget(std::clamp(gainDB, -18.0f, 18.0f), ramp);
    band.q.setTarget(std::clamp(q, 0.3f, 8.0f), ramp);
    if (shapeChanged) {
        band.state.reset();
    }
    updateCoefficients(band);
}

void EQKernel::updateCoefficients(Band& band) noexcept {
    band.coefficients = makeBiquad(
        band.shape, sampleRate_, std::exp2(band.log2Frequency.current()), band.gainDB.current(), band.q.current()
    );
}

void EQKernel::process(float* const* channels, int channelCount, int frameCount) noexcept {
    const int count = std::min(channelCount, kMaxChannels);
    for (int start = 0; start < frameCount; start += kCoefficientBlock) {
        const int length = std::min(kCoefficientBlock, frameCount - start);
        for (Band& band : bands_) {
            if (band.shape == FilterShape::bypass) { continue; }
            if (band.log2Frequency.isSmoothing() || band.gainDB.isSmoothing() || band.q.isSmoothing()) {
                band.log2Frequency.advance(length);
                band.gainDB.advance(length);
                band.q.advance(length);
                updateCoefficients(band);
            }
            for (int channel = 0; channel < count; ++channel) {
                float* samples = channels[channel] + start;
                for (int frame = 0; frame < length; ++frame) {
                    samples[frame] = band.state.process(band.coefficients, samples[frame], channel);
                }
            }
        }
    }
}

void EQKernel::reset() noexcept {
    for (Band& band : bands_) {
        band.state.reset();
    }
}

double EQKernel::magnitudeDB(double frequency) const noexcept {
    double total = 0;
    for (const Band& band : bands_) {
        if (band.shape == FilterShape::bypass) { continue; }
        const BiquadCoefficients target = makeBiquad(
            band.shape, sampleRate_, std::exp2(band.log2Frequency.target()), band.gainDB.target(), band.q.target()
        );
        total += biquadMagnitudeDB(target, sampleRate_, frequency);
    }
    return total;
}

} // namespace echo::dsp
