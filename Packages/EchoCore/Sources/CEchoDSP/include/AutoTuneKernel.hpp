#pragma once

#include "PitchShiftKernel.hpp"

namespace echo::dsp {

/// Live auto-tune (SPEC § 13.5): every 5 ms the detected pitch (confidence > 0.8, else no correction) is snapped to the
/// nearest note allowed by the key and scale (chromatic: every note), the correction glides there at the retune speed
/// (100 ms natural … 0 ms robotic), sustained notes keep some of their own wobble (humanize), and PSOLA shifts the
/// voice by the correction, keeping its formants unless told otherwise. From G2 (98 Hz) up (user decision); latency
/// `latencyFrames()`. `prepare` allocates; the rest is real-time safe.
class AutoTuneKernel {
public:
    static constexpr float kMinimumFrequency = 98;

    void prepare(double sampleRate);
    /// −1 chromatic, else 0 (C) … 11 (B).
    void setKey(int key) noexcept { key_ = key; }
    void setMinor(bool isMinor) noexcept { isMinor_ = isMinor; }
    /// 0 (robotic) … 100 ms (natural).
    void setRetuneMs(float ms) noexcept;
    /// 0…1: how much of a sustained note's own pitch movement (vibrato, drift around its centre) is kept, up to 35 cents;
    /// the centre itself is still corrected.
    void setHumanize(float amount) noexcept;
    void setPreservesFormants(bool preserves) noexcept { shift_.setPreservesFormants(preserves); }
    void process(float* const* channels, int channelCount, int frameCount) noexcept;
    void reset() noexcept;
    int latencyFrames() const noexcept { return shift_.latencyFrames(); }
    /// The correction being applied, in semitones.
    float correction() const noexcept { return correction_; }

    /// The note (MIDI number) `midi` snaps to with this key and scale.
    static int nearestNote(float midi, int key, bool isMinor) noexcept;

private:
    PitchShiftKernel shift_;
    double sampleRate_ = 48'000;
    int hop_ = 240;
    int key_ = -1;
    bool isMinor_ = false;
    float retuneMs_ = 100;
    float humanize_ = 0.5f;
    float correction_ = 0;
    int heldNote_ = -1;
    int heldFrames_ = 0;
    /// The held note's slowly followed centre (MIDI).
    float heldCenter_ = 0;
};

} // namespace echo::dsp
