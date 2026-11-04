#pragma once

#include "DSPMath.hpp"
#include "GainKernel.hpp"
#include "GateKernel.hpp"
#include "LimiterKernel.hpp"
#include "LiveLevelerKernel.hpp"
#include "SmoothedValue.hpp"

#include <vector>

struct EEDenoiser;

namespace echo::dsp {

/// Noise reduction while recording (SPEC § 13.4), for the mono or stereo mixdown.
enum class SuppressionTier : int {
    off = 0,
    /// The noise gate; Apple voice processing on the input node is the engine's part.
    standard = 1,
    /// RNNoise per channel in 480-sample frames.
    high = 2,
};

/// The live processing chain of a recording (SPEC § 13.4): input gain → suppression tier → gentle leveler → clip limiter
/// (−1 dBFS, fast). It has two outputs: the monitor signal, as
/// early as the tier allows, and the recorded signal, always `recordedLatencyFrames()` behind the input whatever the
/// tier, so the processed take keeps one timeline when the tier changes. Changing to or from High fades out, waits for
/// RNNoise to fill, and fades back in.
class LiveChain {
public:
    /// RNNoise's 480-sample framing plus its own two-frame delay.
    static constexpr int kHighLatencyFrames = 3 * 480;

    LiveChain() noexcept;
    ~LiveChain();
    LiveChain(const LiveChain&) = delete;
    LiveChain& operator=(const LiveChain&) = delete;

    /// Allocates (never on the render thread). RNNoise needs 44.1 kHz or more; below, High acts as Standard.
    void prepare(double sampleRate, int channelCount, int maximumFrames);
    /// Render thread.
    void setTier(SuppressionTier tier) noexcept;
    /// −24…+24 dB, ramped. Render thread.
    void setInputGainDB(float db) noexcept { gain_.setGainDB(db); }
    float levelerGainDB() const noexcept { return leveler_.gainDB(); }
    SuppressionTier tier() const noexcept { return target_; }
    bool supportsHigh() const noexcept { return supportsHigh_; }

    /// Processes `channels` in place into the monitor signal and writes the recorded signal into `recorded`.
    void process(float* const* channels, float* const* recorded, int channelCount, int frameCount) noexcept;
    /// How far the recorded signal is behind the input, in frames: constant for the session.
    int recordedLatencyFrames() const noexcept { return kHighLatencyFrames + limiter_.latencyFrames(); }
    void reset() noexcept;

private:
    enum class Phase { steady, fadingOut, holding, fadingIn };

    void runHigh(float* samples, int channel, int frameCount) noexcept;
    void beginTransition() noexcept;
    float nextFade() noexcept;

    GainKernel gain_;
    GateKernel gate_;
    LiveLevelerKernel leveler_;
    LimiterKernel limiter_;
    EEDenoiser* denoisers_[kMaxChannels] = {};
    float frameIn_[kMaxChannels][480] = {};
    float frameOut_[kMaxChannels][480] = {};
    int framePosition_ = 0;
    /// The recorded signal of the tiers without RNNoise, delayed to High's latency.
    std::vector<float> delay_[kMaxChannels];
    int delayPosition_ = 0;
    std::vector<float> scratch_;

    SuppressionTier target_ = SuppressionTier::off;
    /// The tier the output follows; changes to or from High wait for the fade.
    SuppressionTier active_ = SuppressionTier::off;
    Phase phase_ = Phase::steady;
    SmoothedValue fade_;
    int holdRemaining_ = 0;
    int fadeFrames_ = 1;
    int channelCount_ = 0;
    int maximumFrames_ = 0;
    bool supportsHigh_ = false;
};

} // namespace echo::dsp
