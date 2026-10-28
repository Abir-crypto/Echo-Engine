#pragma once

namespace echo::dsp {

/// Converts a level in decibels to a linear amplitude factor. Real-time safe.
float dbToLinear(float db) noexcept;

} // namespace echo::dsp
