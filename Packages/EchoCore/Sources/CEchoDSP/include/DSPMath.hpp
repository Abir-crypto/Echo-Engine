#pragma once

namespace echo::dsp {

/// Kernels hold fixed-size state for up to this many channels (working audio is mono or stereo, SPEC § 6.2).
constexpr int kMaxChannels = 2;
/// Every parameter change and enable/disable ramps over this long (SPEC § 4.5: 20–50 ms).
constexpr double kRampSeconds = 0.03;

/// Converts a level in decibels to a linear amplitude factor. Real-time safe.
float dbToLinear(float db) noexcept;
/// Converts a linear amplitude to decibels, floored at -120 dB. Real-time safe.
float linearToDb(float linear) noexcept;
/// One-pole smoothing coefficient for a time constant in milliseconds.
float onePoleCoefficient(double milliseconds, double sampleRate) noexcept;
/// Frames a parameter ramp lasts at `sampleRate`.
int rampFrames(double sampleRate) noexcept;

} // namespace echo::dsp
