#include "AutoTuneKernel.hpp"

#include <algorithm>
#include <cmath>

namespace echo::dsp {

namespace {
/// Pitch classes of the major and natural minor scales, from the key.
constexpr bool kMajor[12] = {true, false, true, false, true, true, false, true, false, true, false, true};
constexpr bool kMinor[12] = {true, false, true, true, false, true, false, true, true, false, true, false};
/// A note counts as sustained after this long; then humanize lets some of its movement through.
constexpr double kSustainSeconds = 0.15;
constexpr float kMaxHumanizeSemitones = 0.35f;
/// A held note's centre follows its pitch this slowly, so vibrato moves around it.
constexpr double kCenterMs = 300;
/// Without a pitch the correction fades back to none this fast.
constexpr double kReleaseMs = 30;
}

void AutoTuneKernel::prepare(double sampleRate) {
    sampleRate_ = sampleRate;
    hop_ = std::max(1, static_cast<int>(0.005 * sampleRate));
    shift_.prepare(sampleRate, kMinimumFrequency);
    shift_.setControlledShift(0, 1);
    reset();
}

void AutoTuneKernel::reset() noexcept {
    shift_.reset();
    shift_.setControlledShift(0, 1);
    correction_ = 0;
    heldNote_ = -1;
    heldFrames_ = 0;
}

void AutoTuneKernel::setRetuneMs(float ms) noexcept { retuneMs_ = std::clamp(ms, 0.0f, 100.0f); }

void AutoTuneKernel::setHumanize(float amount) noexcept { humanize_ = std::clamp(amount, 0.0f, 1.0f); }

int AutoTuneKernel::nearestNote(float midi, int key, bool isMinor) noexcept {
    const int rounded = static_cast<int>(std::lround(midi));
    if (key < 0) { return rounded; }
    const bool* scale = isMinor ? kMinor : kMajor;
    int best = rounded;
    float bestDistance = 1e9f;
    for (int note = rounded - 2; note <= rounded + 2; ++note) {
        const int degree = ((note - key) % 12 + 12) % 12;
        const float distance = std::fabs(static_cast<float>(note) - midi);
        if (scale[degree] && distance < bestDistance) {
            best = note;
            bestDistance = distance;
        }
    }
    return best;
}

void AutoTuneKernel::process(float* const* channels, int channelCount, int frameCount) noexcept {
    for (int start = 0; start < frameCount; start += hop_) {
        const int frames = std::min(hop_, frameCount - start);
        const PitchEstimate estimate = shift_.lastEstimate();
        float wanted = 0;
        double timeConstantMs = kReleaseMs;
        if (estimate.period > 0) {
            const float frequency = static_cast<float>(sampleRate_) / estimate.period;
            const float midi = 69 + 12 * std::log2(frequency / 440);
            const int note = nearestNote(midi, key_, isMinor_);
            if (note == heldNote_) {
                heldFrames_ += frames;
                heldCenter_ += (midi - heldCenter_) * static_cast<float>(1 - std::exp(-frames / (kCenterMs * 0.001 * sampleRate_)));
            } else {
                heldNote_ = note;
                heldFrames_ = 0;
                heldCenter_ = midi;
            }
            // A held note keeps up to this much of its movement around its centre; the centre lands on the note.
            const float allowance = heldFrames_ > kSustainSeconds * sampleRate_ ? humanize_ * kMaxHumanizeSemitones : 0;
            const float movement = midi - heldCenter_;
            wanted = static_cast<float>(note) + std::clamp(movement, -allowance, allowance) - midi;
            timeConstantMs = retuneMs_;
        } else {
            heldNote_ = -1;
            heldFrames_ = 0;
        }
        const float coefficient = timeConstantMs <= 0
            ? 1.0f
            : static_cast<float>(1 - std::exp(-static_cast<double>(frames) / (timeConstantMs * 0.001 * sampleRate_)));
        correction_ += (wanted - correction_) * coefficient;
        if (estimate.period <= 0 && std::fabs(correction_) < 0.005f) {
            // No pitch to correct (breath, consonants, notes below G2): the exactly delayed input, crossfaded.
            correction_ = 0;
            shift_.setSemitones(0);
        } else {
            shift_.setControlledShift(correction_, frames);
        }

        float* block[kMaxChannels] = {};
        const int count = std::min(channelCount, kMaxChannels);
        for (int channel = 0; channel < count; ++channel) { block[channel] = channels[channel] + start; }
        shift_.process(block, count, frames);
    }
}

} // namespace echo::dsp
