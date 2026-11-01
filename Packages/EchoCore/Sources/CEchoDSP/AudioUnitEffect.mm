#import "AudioUnitEffect.h"

#include "CompressorKernel.hpp"
#include "DeEsserKernel.hpp"
#include "EQKernel.hpp"
#include "GainKernel.hpp"
#include "GateKernel.hpp"
#include "LimiterKernel.hpp"
#include "PitchShiftKernel.hpp"
#include "ReverbKernel.hpp"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <memory>
#include <vector>

namespace {

using namespace echo::dsp;

/// Crossfades an effect's output to its dry input delayed by the effect's latency, so bypassing never shifts the
/// audio in time (SPEC § 6.6 "Hold for original"). The effect keeps running underneath, so releasing is seamless.
class LatencyMatchedBypass {
public:
    /// Allocates; not on the render thread.
    void prepare(double sampleRate, int latencyFrames, int maximumFrames) {
        latency_ = latencyFrames;
        rampFrames_ = rampFrames(sampleRate);
        amount_.reset(amount_.target());
        size_t size = 1;
        while (size < static_cast<size_t>(latencyFrames + maximumFrames + 1)) { size <<= 1; }
        size_ = size;
        mask_ = static_cast<int64_t>(size) - 1;
        ring_.assign(kMaxChannels * size, 0.0f);
        position_ = 0;
    }

    void set(bool isBypassed) noexcept { amount_.setTarget(isBypassed ? 1 : 0, rampFrames_); }

    /// Before the effect: remembers the dry input.
    void capture(float* const* channels, int channelCount, int frameCount) noexcept {
        for (int channel = 0; channel < channelCount; ++channel) {
            float* ring = ring_.data() + static_cast<size_t>(channel) * size_;
            for (int frame = 0; frame < frameCount; ++frame) {
                ring[static_cast<size_t>((position_ + frame) & mask_)] = channels[channel][frame];
            }
        }
    }

    /// After the effect: blends in the delayed dry input while bypassed.
    void mix(float* const* channels, int channelCount, int frameCount) noexcept {
        if (amount_.isSmoothing() || amount_.current() > 0) {
            for (int frame = 0; frame < frameCount; ++frame) {
                const float amount = amount_.next();
                const size_t index = static_cast<size_t>((position_ + frame - latency_) & mask_);
                for (int channel = 0; channel < channelCount; ++channel) {
                    const float dry = ring_[static_cast<size_t>(channel) * size_ + index];
                    channels[channel][frame] += (dry - channels[channel][frame]) * amount;
                }
            }
        }
        position_ += frameCount;
    }

    void reset() noexcept {
        amount_.reset(amount_.target());
        std::fill(ring_.begin(), ring_.end(), 0.0f);
    }

private:
    SmoothedValue amount_;
    std::vector<float> ring_;
    size_t size_ = 0;
    int64_t mask_ = 0;
    int64_t position_ = 0;
    int latency_ = 0;
    int rampFrames_ = 0;
};

/// A chain of kernels behind parameter addresses. `apply` and `process` run on the render thread.
class EffectProcessor {
public:
    virtual ~EffectProcessor() = default;
    virtual uint64_t parameterCount() const noexcept = 0;
    /// The 0/1 parameter that bypasses the whole effect.
    virtual uint64_t bypassAddress() const noexcept = 0;
    virtual float defaultValue(uint64_t address) const noexcept = 0;
    virtual void prepare(double sampleRate) = 0;
    virtual void apply(uint64_t address, float value) noexcept = 0;
    virtual void process(float* const* channels, int channelCount, int frameCount) noexcept = 0;
    virtual void reset() noexcept = 0;
    virtual int latencyFrames() const noexcept = 0;
};

/// Whether `address` is one of the EQ bands' fields.
constexpr bool isEQAddress(uint64_t address) noexcept {
    return address >= EEManualChainParameterEQFirst
        && address < EEManualChainParameterEQFirst + EEManualChainParameterEQStride * EEManualChainParameterEQBandCount;
}

FilterShape filterShape(float kind) noexcept {
    switch (static_cast<int>(std::lround(kind))) {
    case EEEQBandKindLowShelf: return FilterShape::lowShelf;
    case EEEQBandKindPeaking: return FilterShape::peaking;
    case EEEQBandKindHighShelf: return FilterShape::highShelf;
    default: return FilterShape::bypass;
    }
}

class ManualChain final : public EffectProcessor {
public:
    uint64_t parameterCount() const noexcept override { return EEManualChainParameterCount; }
    uint64_t bypassAddress() const noexcept override { return EEManualChainParameterBypass; }

    float defaultValue(uint64_t address) const noexcept override {
        // Neutral or off, matching `ManualSettings()` (SPEC § 8).
        switch (address) {
        case EEManualChainParameterGateThreshold: return -50;
        case EEManualChainParameterGateRange: return -40;
        case EEManualChainParameterGateAttack: return 2;
        case EEManualChainParameterGateRelease: return 150;
        case EEManualChainParameterDeEsserFrequency: return 6'500;
        case EEManualChainParameterDeEsserAmount: return 0.5f;
        case EEManualChainParameterCompressorThreshold: return -18;
        case EEManualChainParameterCompressorRatio: return 3;
        case EEManualChainParameterCompressorAttack: return 10;
        case EEManualChainParameterCompressorRelease: return 120;
        case EEManualChainParameterReverbRoomSize: return 0.5f;
        case EEManualChainParameterReverbDamping: return 0.5f;
        case EEManualChainParameterReverbMix: return 0.2f;
        default: break;
        }
        if (isEQAddress(address)) {
            static constexpr float kFrequencies[EEManualChainParameterEQBandCount] = {80, 250, 1'000, 3'000, 6'000, 12'000};
            const uint64_t band = (address - EEManualChainParameterEQFirst) / EEManualChainParameterEQStride;
            switch ((address - EEManualChainParameterEQFirst) % EEManualChainParameterEQStride) {
            case EEEQBandFieldKind:
                return band == 0 ? EEEQBandKindLowShelf : band == EEManualChainParameterEQBandCount - 1 ? EEEQBandKindHighShelf : EEEQBandKindPeaking;
            case EEEQBandFieldFrequency: return kFrequencies[band];
            case EEEQBandFieldGain: return 0;
            case EEEQBandFieldQ: return band == 0 || band == EEManualChainParameterEQBandCount - 1 ? 0.71f : 1;
            }
        }
        return 0;
    }

    void prepare(double sampleRate) override {
        gain_.prepare(sampleRate);
        gate_.prepare(sampleRate);
        eq_.prepare(sampleRate);
        deEsser_.prepare(sampleRate);
        compressor_.prepare(sampleRate);
        pitch_.prepare(sampleRate);
        reverb_.prepare(sampleRate);
    }

    void apply(uint64_t address, float value) noexcept override {
        switch (address) {
        case EEManualChainParameterInputGain: gain_.setGainDB(value); return;
        case EEManualChainParameterGateEnabled: gate_.setEnabled(value >= 0.5f); return;
        case EEManualChainParameterGateThreshold: gate_.setThresholdDB(value); return;
        case EEManualChainParameterGateRange: gate_.setRangeDB(value); return;
        case EEManualChainParameterGateAttack: gate_.setAttackMs(value); return;
        case EEManualChainParameterGateRelease: gate_.setReleaseMs(value); return;
        case EEManualChainParameterDeEsserEnabled: deEsser_.setEnabled(value >= 0.5f); return;
        case EEManualChainParameterDeEsserFrequency: deEsser_.setFrequency(value); return;
        case EEManualChainParameterDeEsserAmount: deEsser_.setAmount(value); return;
        case EEManualChainParameterCompressorEnabled: compressor_.setEnabled(value >= 0.5f); return;
        case EEManualChainParameterCompressorThreshold: compressor_.setThresholdDB(value); return;
        case EEManualChainParameterCompressorRatio: compressor_.setRatio(value); return;
        case EEManualChainParameterCompressorAttack: compressor_.setAttackMs(value); return;
        case EEManualChainParameterCompressorRelease: compressor_.setReleaseMs(value); return;
        case EEManualChainParameterCompressorMakeup: compressor_.setMakeupDB(value); return;
        case EEManualChainParameterPitchSemitones: pitch_.setSemitones(value); return;
        case EEManualChainParameterReverbEnabled: reverb_.setEnabled(value >= 0.5f); return;
        case EEManualChainParameterReverbRoomSize: reverb_.setRoomSize(value); return;
        case EEManualChainParameterReverbDamping: reverb_.setDamping(value); return;
        case EEManualChainParameterReverbMix: reverb_.setMix(value); return;
        default: break;
        }
        if (isEQAddress(address)) {
            const uint64_t band = (address - EEManualChainParameterEQFirst) / EEManualChainParameterEQStride;
            float* fields = bands_[band];
            fields[(address - EEManualChainParameterEQFirst) % EEManualChainParameterEQStride] = value;
            eq_.setBand(static_cast<int>(band), filterShape(fields[EEEQBandFieldKind]), fields[EEEQBandFieldFrequency],
                        fields[EEEQBandFieldGain], fields[EEEQBandFieldQ]);
        }
    }

    void process(float* const* channels, int channelCount, int frameCount) noexcept override {
        gain_.process(channels, channelCount, frameCount);
        gate_.process(channels, channelCount, frameCount);
        eq_.process(channels, channelCount, frameCount);
        deEsser_.process(channels, channelCount, frameCount);
        compressor_.process(channels, channelCount, frameCount);
        pitch_.process(channels, channelCount, frameCount);
        reverb_.process(channels, channelCount, frameCount);
    }

    void reset() noexcept override {
        gain_.reset();
        gate_.reset();
        eq_.reset();
        deEsser_.reset();
        compressor_.reset();
        pitch_.reset();
        reverb_.reset();
    }

    int latencyFrames() const noexcept override { return pitch_.latencyFrames(); }

private:
    GainKernel gain_;
    GateKernel gate_;
    EQKernel eq_;
    DeEsserKernel deEsser_;
    CompressorKernel compressor_;
    PitchShiftKernel pitch_;
    ReverbKernel reverb_;
    /// Each band's kind, frequency, gain and Q, so one changed field can set the whole band.
    float bands_[EEManualChainParameterEQBandCount][EEManualChainParameterEQStride] = {};
};

class OutputLimiter final : public EffectProcessor {
public:
    uint64_t parameterCount() const noexcept override { return EEOutputLimiterParameterCount; }
    uint64_t bypassAddress() const noexcept override { return EEOutputLimiterParameterBypass; }
    float defaultValue(uint64_t address) const noexcept override { return address == EEOutputLimiterParameterCeiling ? -1 : 0; }
    void prepare(double sampleRate) override {
        gain_.prepare(sampleRate);
        limiter_.prepare(sampleRate);
    }
    void apply(uint64_t address, float value) noexcept override {
        if (address == EEOutputLimiterParameterCeiling) { limiter_.setCeilingDB(value); }
        if (address == EEOutputLimiterParameterGain) { gain_.setGainDB(std::clamp(value, -20.0f, 20.0f)); }
    }
    void process(float* const* channels, int channelCount, int frameCount) noexcept override {
        gain_.process(channels, channelCount, frameCount);
        limiter_.process(channels, channelCount, frameCount);
    }
    void reset() noexcept override {
        gain_.reset();
        limiter_.reset();
    }
    int latencyFrames() const noexcept override { return limiter_.latencyFrames(); }

private:
    /// Auto Level (SPEC § 6.7): ramps to a new gain like every parameter.
    GainKernel gain_;
    LimiterKernel limiter_;
};

} // namespace

struct EEEffect {
    std::unique_ptr<EffectProcessor> processor;
    LatencyMatchedBypass bypass;
    /// Latest value per address, and whether the render thread has yet to apply it.
    std::unique_ptr<std::atomic<float>[]> values;
    std::unique_ptr<std::atomic<bool>[]> pending;
    std::atomic<bool> hasPending{false};
    std::atomic<bool> needsReset{false};
    /// Render buffers for hosts that pass none; `kMaxChannels` × `maximumFrames`.
    std::vector<float> scratch;
    int maximumFrames = 0;
    bool isPrepared = false;

    /// Render thread.
    void applyPendingParameters() noexcept {
        if (!hasPending.exchange(false, std::memory_order_acquire)) { return; }
        const uint64_t count = processor->parameterCount();
        for (uint64_t address = 0; address < count; ++address) {
            if (pending[address].exchange(false, std::memory_order_acquire)) {
                apply(address, values[address].load(std::memory_order_relaxed));
            }
        }
    }

    void apply(uint64_t address, float value) noexcept {
        if (address == processor->bypassAddress()) {
            bypass.set(value >= 0.5f);
        } else {
            processor->apply(address, value);
        }
    }

    void process(float* const* channels, int channelCount, int frameCount) noexcept {
        bypass.capture(channels, channelCount, frameCount);
        processor->process(channels, channelCount, frameCount);
        bypass.mix(channels, channelCount, frameCount);
    }

    void reset() noexcept {
        processor->reset();
        bypass.reset();
    }
};

EEEffect *EEEffectCreate(EEEffectKind kind) {
    auto effect = new EEEffect();
    if (kind == EEEffectKindOutputLimiter) {
        effect->processor = std::make_unique<OutputLimiter>();
    } else {
        effect->processor = std::make_unique<ManualChain>();
    }
    const uint64_t count = effect->processor->parameterCount();
    effect->values = std::make_unique<std::atomic<float>[]>(count);
    effect->pending = std::make_unique<std::atomic<bool>[]>(count);
    for (uint64_t address = 0; address < count; ++address) {
        const float value = effect->processor->defaultValue(address);
        effect->values[address].store(value);
        effect->pending[address].store(false);
        effect->apply(address, value);
    }
    return effect;
}

void EEEffectDestroy(EEEffect *effect) { delete effect; }

void EEEffectPrepare(EEEffect *effect, double sampleRate, int32_t channelCount, int32_t maximumFrames) {
    (void)channelCount;
    effect->applyPendingParameters();
    effect->processor->prepare(sampleRate);
    effect->maximumFrames = std::max(1, static_cast<int>(maximumFrames));
    effect->bypass.prepare(sampleRate, effect->processor->latencyFrames(), effect->maximumFrames);
    effect->scratch.assign(static_cast<size_t>(kMaxChannels) * static_cast<size_t>(effect->maximumFrames), 0.0f);
    effect->needsReset.store(false);
    effect->isPrepared = true;
}

void EEEffectSetParameter(EEEffect *effect, uint64_t address, float value) {
    if (address >= effect->processor->parameterCount() || !std::isfinite(value)) { return; }
    effect->values[address].store(value, std::memory_order_relaxed);
    effect->pending[address].store(true, std::memory_order_release);
    effect->hasPending.store(true, std::memory_order_release);
}

float EEEffectParameter(const EEEffect *effect, uint64_t address) {
    if (address >= effect->processor->parameterCount()) { return 0; }
    return effect->values[address].load(std::memory_order_relaxed);
}

uint64_t EEEffectParameterCount(const EEEffect *effect) { return effect->processor->parameterCount(); }

void EEEffectRequestReset(EEEffect *effect) { effect->needsReset.store(true, std::memory_order_release); }

int32_t EEEffectLatencyFrames(const EEEffect *effect) {
    return effect->isPrepared ? effect->processor->latencyFrames() : 0;
}

void EEEffectProcess(EEEffect *effect, float *const *channels, int32_t channelCount, int32_t frameCount) {
    if (!effect->isPrepared) { return; }
    effect->applyPendingParameters();
    const int count = std::clamp(static_cast<int>(channelCount), 0, kMaxChannels);
    for (int start = 0; start < frameCount; start += effect->maximumFrames) {
        const int frames = std::min(effect->maximumFrames, static_cast<int>(frameCount) - start);
        float *chunk[kMaxChannels] = {};
        for (int channel = 0; channel < count; ++channel) { chunk[channel] = channels[channel] + start; }
        effect->process(chunk, count, frames);
    }
}

AUInternalRenderBlock EEEffectRenderBlock(EEEffect *effect) {
    // Captures only the raw pointer: no Objective-C or Swift object is touched while rendering (SPEC § 4.5).
    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *, const AudioTimeStamp *timestamp, AUAudioFrameCount frameCount,
                              NSInteger, AudioBufferList *outputData, const AURenderEvent *events,
                              AURenderPullInputBlock pullInput) {
        if (pullInput == nullptr) { return kAudioUnitErr_NoConnection; }
        if (!effect->isPrepared || static_cast<int>(frameCount) > effect->maximumFrames) {
            return kAudioUnitErr_TooManyFramesToProcess;
        }
        const int channelCount = static_cast<int>(std::min<UInt32>(outputData->mNumberBuffers, kMaxChannels));
        for (int channel = 0; channel < channelCount; ++channel) {
            AudioBuffer &buffer = outputData->mBuffers[channel];
            if (buffer.mData == nullptr) {
                buffer.mData = effect->scratch.data() + static_cast<size_t>(channel) * static_cast<size_t>(effect->maximumFrames);
            }
            buffer.mDataByteSize = frameCount * sizeof(float);
        }
        AudioUnitRenderActionFlags pullFlags = 0;
        const AUAudioUnitStatus status = pullInput(&pullFlags, timestamp, frameCount, 0, outputData);
        if (status != noErr) { return status; }

        if (effect->needsReset.exchange(false, std::memory_order_acquire)) { effect->reset(); }
        effect->applyPendingParameters();
        for (const AURenderEvent *event = events; event != nullptr; event = event->head.next) {
            if (event->head.eventType == AURenderEventParameter || event->head.eventType == AURenderEventParameterRamp) {
                effect->apply(event->parameter.parameterAddress, event->parameter.value);
            }
        }
        float *channels[kMaxChannels] = {};
        for (int channel = 0; channel < channelCount; ++channel) {
            channels[channel] = static_cast<float *>(outputData->mBuffers[channel].mData);
        }
        effect->process(channels, channelCount, static_cast<int>(frameCount));
        return noErr;
    };
}
