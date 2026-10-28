#include "DSPMath.hpp"

#include <cmath>

namespace echo::dsp {

float dbToLinear(float db) noexcept {
    return std::pow(10.0f, db / 20.0f);
}

} // namespace echo::dsp
