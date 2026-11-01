#import "SourceSwitch.h"

#include "DSPMath.hpp"
#include "SmoothedValue.hpp"

#include <algorithm>
#include <atomic>
#include <vector>

using namespace echo::dsp;

namespace {
/// SPEC § 6.3: swaps crossfade over 20 ms.
constexpr double kCrossfadeSeconds = 0.02;
}

struct EESourceSwitch {
    std::atomic<float> requested{0};
    std::atomic<bool> hasRequest{false};
    SmoothedValue mix;   // 0 = input 0, 1 = input 1
    float target = 0;
    int rampFrames = 1;
    int maximumFrames = 0;
    int channelCount = 0;
    bool isPrepared = false;
    /// Input 0 when the host passes no buffers, and input 1, each `kMaxChannels` × `maximumFrames`.
    std::vector<float> scratch0, scratch1;
    /// Input 1's buffer list (`kMaxChannels` buffers).
    std::vector<uint8_t> list1Storage;

    void setTarget(float input) noexcept {
        target = input >= 0.5f ? 1.0f : 0.0f;
        mix.setTarget(target, rampFrames);
    }
};

EESourceSwitch *EESourceSwitchCreate(void) {
    auto source = new EESourceSwitch();
    source->mix.reset(0);
    return source;
}

void EESourceSwitchDestroy(EESourceSwitch *source) { delete source; }

void EESourceSwitchPrepare(EESourceSwitch *source, double sampleRate, int32_t channelCount, int32_t maximumFrames) {
    source->maximumFrames = std::max(1, static_cast<int>(maximumFrames));
    source->channelCount = std::clamp(static_cast<int>(channelCount), 1, kMaxChannels);
    source->rampFrames = std::max(1, static_cast<int>(kCrossfadeSeconds * sampleRate));
    const size_t samples = static_cast<size_t>(kMaxChannels) * static_cast<size_t>(source->maximumFrames);
    source->scratch0.assign(samples, 0.0f);
    source->scratch1.assign(samples, 0.0f);
    source->list1Storage.assign(offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer) * kMaxChannels, 0);
    if (source->hasRequest.exchange(false)) { source->target = source->requested.load() >= 0.5f ? 1.0f : 0.0f; }
    source->mix.reset(source->target);
    source->isPrepared = true;
}

void EESourceSwitchSetSource(EESourceSwitch *source, float input) {
    source->requested.store(input, std::memory_order_relaxed);
    source->hasRequest.store(true, std::memory_order_release);
}

float EESourceSwitchSource(const EESourceSwitch *source) { return source->requested.load(std::memory_order_relaxed); }

AUInternalRenderBlock EESourceSwitchRenderBlock(EESourceSwitch *source) {
    // Captures only the raw pointer (SPEC § 4.5).
    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *, const AudioTimeStamp *timestamp, AUAudioFrameCount frameCount,
                              NSInteger, AudioBufferList *outputData, const AURenderEvent *events,
                              AURenderPullInputBlock pullInput) {
        if (pullInput == nullptr) { return kAudioUnitErr_NoConnection; }
        if (!source->isPrepared || static_cast<int>(frameCount) > source->maximumFrames) {
            return kAudioUnitErr_TooManyFramesToProcess;
        }
        const int channels = static_cast<int>(std::min<UInt32>(outputData->mNumberBuffers, kMaxChannels));
        const size_t stride = static_cast<size_t>(source->maximumFrames);
        for (int channel = 0; channel < channels; ++channel) {
            AudioBuffer &buffer = outputData->mBuffers[channel];
            if (buffer.mData == nullptr) { buffer.mData = source->scratch0.data() + channel * stride; }
            buffer.mDataByteSize = frameCount * sizeof(float);
        }
        AudioUnitRenderActionFlags flags = 0;
        AUAudioUnitStatus status = pullInput(&flags, timestamp, frameCount, 0, outputData);
        if (status != noErr) { return status; }

        auto *list1 = reinterpret_cast<AudioBufferList *>(source->list1Storage.data());
        list1->mNumberBuffers = static_cast<UInt32>(channels);
        for (int channel = 0; channel < channels; ++channel) {
            list1->mBuffers[channel].mNumberChannels = 1;
            list1->mBuffers[channel].mData = source->scratch1.data() + channel * stride;
            list1->mBuffers[channel].mDataByteSize = frameCount * sizeof(float);
        }
        flags = 0;
        if (pullInput(&flags, timestamp, frameCount, 1, list1) != noErr) {
            for (int channel = 0; channel < channels; ++channel) {
                std::fill_n(static_cast<float *>(list1->mBuffers[channel].mData), frameCount, 0.0f);
            }
        }

        if (source->hasRequest.exchange(false, std::memory_order_acquire)) {
            source->setTarget(source->requested.load(std::memory_order_relaxed));
        }
        // Scheduled switches start at their exact sample within this cycle.
        const AUEventSampleTime blockStart = static_cast<AUEventSampleTime>(timestamp->mSampleTime);
        const AURenderEvent *event = events;
        for (AUAudioFrameCount frame = 0; frame < frameCount; ++frame) {
            while (event != nullptr && (event->head.eventType != AURenderEventParameter
                                        && event->head.eventType != AURenderEventParameterRamp)) {
                event = event->head.next;
            }
            while (event != nullptr && event->head.eventSampleTime - blockStart <= static_cast<AUEventSampleTime>(frame)) {
                if ((event->head.eventType == AURenderEventParameter || event->head.eventType == AURenderEventParameterRamp)
                    && event->parameter.parameterAddress == EESourceSwitchParameterSource) {
                    source->setTarget(event->parameter.value);
                    source->requested.store(event->parameter.value, std::memory_order_relaxed);
                }
                event = event->head.next;
            }
            const float mix = source->mix.next();
            for (int channel = 0; channel < channels; ++channel) {
                float *output = static_cast<float *>(outputData->mBuffers[channel].mData);
                const float other = static_cast<const float *>(list1->mBuffers[channel].mData)[frame];
                output[frame] += (other - output[frame]) * mix;
            }
        }
        return noErr;
    };
}
