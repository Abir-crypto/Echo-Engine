#pragma once

namespace echo::dsp {

/// True-peak estimate of one channel (ITU-R BS.1770-4 annex 2): the largest of the sample and the values between it
/// and its neighbours, by 4× (2× at 96 kHz, none at 192 kHz) windowed-sinc oversampling. Fixed size, real-time safe
/// after `prepare`. The estimate trails the input by about half the filter (6 samples).
class TruePeakDetector {
public:
    static constexpr int kTapsPerPhase = 12;
    static constexpr int kMaxPhases = 4;

    void prepare(double sampleRate) noexcept;
    void reset() noexcept;
    /// Feeds one sample; returns the largest magnitude around it, between samples included.
    float next(float sample) noexcept;

private:
    float coefficients_[kMaxPhases][kTapsPerPhase] = {};
    float history_[kTapsPerPhase] = {};
    int phases_ = 4;
    int position_ = 0;
};

} // namespace echo::dsp
