#pragma once

#include "DSPMath.hpp"
#include "PitchDetector.hpp"
#include "SmoothedValue.hpp"

#include <cstdint>
#include <vector>

namespace echo::dsp {

/// Formant-preserving pitch shift by TD-PSOLA (SPEC § 8), −12…+12 semitones, 0 by default. Shared with auto-tune.
///
/// Analysis marks sit on the pitch pulses (one period apart, from `PitchDetector`); each output grain is the input
/// around a mark under a Hann window two periods long, so it keeps the pulse shape (the formants). Grains are laid
/// out `period / ratio` apart, which sets the new pitch. Unvoiced input uses short, jittered pseudo-periods.
///
/// The output is always delayed by `latencyFrames()`, also at 0 semitones (then it is exactly the delayed input), so
/// the chain's latency never jumps. `prepare` allocates; everything else is real-time safe.
class PitchShiftKernel {
public:
    /// `minimumFrequency` sets the lowest pitch it follows, and with it the latency (2.5 of its periods); lower pitch
    /// counts as unvoiced. Auto-tune uses a higher one than the manual shift (SPEC § 13.5).
    void prepare(double sampleRate, float minimumFrequency = PitchDetector::kMinimumFrequency);
    void setSemitones(float semitones) noexcept;
    /// Auto-tune: shifts by `semitones` reached over `rampFrames`, and stays shifting (wet) even at 0 so corrections
    /// glide without crossfading to the dry input.
    void setControlledShift(float semitones, int rampFrames) noexcept;
    /// Off: each grain is resampled by the pitch ratio, so formants move with the pitch.
    void setPreservesFormants(bool preserves) noexcept { preservesFormants_ = preserves; }
    /// The latest pitch estimate of the input being analysed (period 0: unvoiced or below the minimum).
    PitchEstimate lastEstimate() const noexcept { return lastEstimate_; }
    void process(float* const* channels, int channelCount, int frameCount) noexcept;
    /// Clears the signal state (envelopes, delay lines) and finishes parameter ramps; keeps the settings. Real-time safe.
    void reset() noexcept;
    int latencyFrames() const noexcept { return latency_; }

private:
    void engage(int64_t now) noexcept;
    void updatePeriod() noexcept;
    void addGrains(int64_t now, double ratio, int channelCount) noexcept;
    /// The latest analysis mark at or before `center`.
    int64_t markBefore(int64_t center) noexcept;
    int64_t searchPeak(int64_t from, int64_t to, bool setsPolarity) noexcept;
    int unvoicedPeriod() noexcept;

    float sample(const std::vector<float>& ring, int channel, int64_t position) const noexcept {
        return ring[static_cast<size_t>(channel) * ringSize_ + static_cast<size_t>(position & mask_)];
    }

    PitchDetector detector_;
    SmoothedValue semitones_, wet_;
    /// Rings of `ringSize_` frames per channel: input, overlap-added grains; one mono copy and the summed windows.
    std::vector<float> input_, output_, mono_, weight_;
    size_t ringSize_ = 0;
    int64_t mask_ = 0;
    int64_t written_ = 0;
    int latency_ = 0, maxPeriod_ = 0, minPeriod_ = 0, baseUnvoicedPeriod_ = 0;
    int hop_ = 0, hopCounter_ = 0, rampFrames_ = 0;
    int period_ = 0;
    bool isVoiced_ = false, isMarkAligned_ = false, isActive_ = false, needsEngage_ = false;
    float polarity_ = 1;
    /// The next grain's centre (output timeline, fractional) and the current analysis mark.
    double synthesisMark_ = 0;
    int64_t analysisMark_ = 0;
    uint32_t noise_ = 0x9E3779B9u;
    PitchEstimate lastEstimate_;
    bool preservesFormants_ = true;
};

} // namespace echo::dsp
