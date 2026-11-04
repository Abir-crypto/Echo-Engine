#pragma once

#include "DSPMath.hpp"

namespace echo::dsp {

/// The gentle live leveler of a recording (SPEC § 13.4): a slow automatic gain toward −20 dBFS RMS, at most ±6 dB. It
/// adapts only while there is speech-level audio, so pauses and room noise are never raised; it lowers within about a
/// second and raises within about three.
class LiveLevelerKernel {
public:
    static constexpr float kTargetDB = -20;
    static constexpr float kMaxGainDB = 6;
    /// Below this the gain holds.
    static constexpr float kSpeechFloorDB = -50;

    void prepare(double sampleRate) noexcept;
    void process(float* const* channels, int channelCount, int frameCount) noexcept;
    void reset() noexcept;
    /// The gain applied now.
    float gainDB() const noexcept { return gainDB_; }

private:
    static constexpr int kBlockFrames = 32;

    float detectorCoefficient_ = 1;
    float lowerCoefficient_ = 1;
    float raiseCoefficient_ = 1;
    float meanSquare_ = 0;
    float gainDB_ = 0;
    float gainLinear_ = 1;
    float step_ = 0;
    int blockPosition_ = 0;
};

} // namespace echo::dsp
