#pragma once

#include "Biquad.hpp"

#include <cstdint>
#include <vector>

namespace echo::dsp {

struct PitchEstimate {
    /// The pitch period in input frames; 0 when unvoiced (no clear pitch).
    float period = 0;
    /// 0…1; estimates below `PitchDetector::kMinimumConfidence` are unvoiced.
    float confidence = 0;
};

/// YIN pitch detection (SPEC § 13.5) on a copy of the input low-passed and decimated to about 12 kHz. Shared by the
/// pitch shifter and auto-tune. `prepare` allocates; `push` and `detect` are real-time safe.
class PitchDetector {
public:
    static constexpr float kMinimumFrequency = 70;
    static constexpr float kMaximumFrequency = 1000;
    /// Below this the input counts as unvoiced (SPEC § 13.5: confidence > 0.8).
    static constexpr float kMinimumConfidence = 0.8f;

    void prepare(double sampleRate);
    /// Feeds one mono input frame.
    void push(float sample) noexcept;
    /// Forgets the input so far. Real-time safe.
    void reset() noexcept;
    /// Analyses the most recent `windowFrames()` frames.
    PitchEstimate detect() noexcept;
    /// Input frames one analysis covers.
    int windowFrames() const noexcept { return (window_ + maxLag_) * decimation_; }

private:
    BiquadCoefficients antiAlias_;
    BiquadState antiAliasStages_[2];
    /// Decimated input, a ring of `mask_ + 1` samples.
    std::vector<float> history_;
    /// The analysed span, unrolled.
    std::vector<float> scratch_;
    /// YIN difference function, then its cumulative mean normalised form.
    std::vector<float> difference_;
    int decimation_ = 4;
    int phase_ = 0;
    int window_ = 0, minLag_ = 0, maxLag_ = 0;
    int64_t written_ = 0;
    int64_t mask_ = 0;
};

} // namespace echo::dsp
