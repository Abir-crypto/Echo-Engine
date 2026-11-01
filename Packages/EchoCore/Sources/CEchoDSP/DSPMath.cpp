#include "DSPMath.hpp"

#include <algorithm>
#include <cmath>

namespace echo::dsp {

float dbToLinear(float db) noexcept {
    return std::pow(10.0f, db / 20.0f);
}

float linearToDb(float linear) noexcept {
    return linear > 1e-6f ? 20.0f * std::log10(linear) : -120.0f;
}

float onePoleCoefficient(double milliseconds, double sampleRate) noexcept {
    const double frames = std::max(milliseconds, 0.01) * 0.001 * sampleRate;
    return static_cast<float>(1.0 - std::exp(-1.0 / frames));
}

int rampFrames(double sampleRate) noexcept {
    return std::max(1, static_cast<int>(kRampSeconds * sampleRate));
}

} // namespace echo::dsp
