#import "CaptureCore.h"

#include "LiveChain.hpp"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <vector>

namespace {

constexpr int kMaxInputs = EE_CAPTURE_MAX_INPUT_CHANNELS;
constexpr int kMaxMixdownChannels = 2;
constexpr int kMaxPlanes = kMaxInputs + kMaxMixdownChannels;

/// Raises `peak` to `value` when higher. Lock-free; the reader resets it with `exchange`.
void raisePeak(std::atomic<float> &peak, float value) noexcept {
    float current = peak.load(std::memory_order_relaxed);
    while (value > current && !peak.compare_exchange_weak(current, value, std::memory_order_relaxed)) {}
}

} // namespace

struct EECaptureCore {
    // Layout: written only by `EECaptureCoreConfigure`, while nothing renders or reads.
    double sampleRate = 0;
    int inputChannelCount = 0;
    int selected[kMaxInputs] = {};
    int selectedCount = 0;
    int mixdownChannelCount = 0;
    int maximumFrames = 0;
    bool isConfigured = false;

    /// `planeCount` planes of `capacity` frames each (a power of two).
    std::vector<float> ring;
    int64_t capacity = 0;
    int64_t mask = 0;
    /// Monotonic frame positions: the render thread advances `writeIndex`, the writer `readIndex`.
    std::atomic<int64_t> writeIndex{0};
    std::atomic<int64_t> readIndex{0};

    std::atomic<bool> isTakeOpen{false};
    std::atomic<bool> isCapturing{false};
    std::atomic<uint64_t> renderCycles{0};
    std::atomic<int64_t> capturedFrames{0};
    std::atomic<int64_t> droppedFrames{0};
    /// Dropped frames the reader hasn't replaced with silence yet.
    std::atomic<int64_t> pendingSilence{0};
    std::atomic<float> peaks[kMaxInputs];

    // Writer-thread state: `silenceFrames` of silence go in at ring position `silenceAt`.
    int64_t silenceAt = 0;
    int64_t silenceFrames = 0;

    // Render scratch: the pulled input (`inputChannelCount` × `maximumFrames`), the monitor output for hosts that pass
    // no buffers, the recorded processed signal, and the input buffer list.
    std::vector<float> inputScratch;
    std::vector<float> outputScratch;
    std::vector<float> recordedScratch;
    std::vector<uint8_t> inputListStorage;

    echo::dsp::LiveChain chain;
    /// Latest value per parameter, and whether the render thread has yet to apply it.
    std::atomic<float> parameters[EECaptureParameterCount];
    std::atomic<bool> hasPending{false};

    /// Render thread.
    void applyParameters() noexcept {
        if (!hasPending.exchange(false, std::memory_order_acquire)) { return; }
        const int tier = static_cast<int>(parameters[EECaptureParameterSuppression].load(std::memory_order_relaxed));
        chain.setTier(static_cast<echo::dsp::SuppressionTier>(std::clamp(tier, 0, 2)));
        const float gainDB = std::clamp(parameters[EECaptureParameterInputGain].load(std::memory_order_relaxed), -24.0f, 24.0f);
        chain.setInputGainDB(gainDB);
        meterGain = echo::dsp::dbToLinear(gainDB);
    }

    /// The input gain as the meters show it.
    float meterGain = 1;

    float *recordedChannel(int channel) noexcept {
        return recordedScratch.data() + static_cast<size_t>(channel) * static_cast<size_t>(maximumFrames);
    }

    int planeCount() const noexcept { return selectedCount + mixdownChannelCount; }

    float *plane(int index) noexcept { return ring.data() + static_cast<size_t>(index) * static_cast<size_t>(capacity); }

    float *outputScratchChannel(int channel) noexcept {
        return outputScratch.data() + static_cast<size_t>(channel) * static_cast<size_t>(maximumFrames);
    }

    /// One render cycle of at most `maximumFrames` frames. Real-time safe.
    void render(const float *const *input, float *const *output, int frames) noexcept {
        applyParameters();
        // Meters show each channel as it goes into processing: after the input gain (SPEC § 13.4).
        for (int channel = 0; channel < inputChannelCount; ++channel) {
            const float *samples = input[channel];
            float peak = 0;
            for (int frame = 0; frame < frames; ++frame) { peak = std::max(peak, std::fabs(samples[frame])); }
            raisePeak(peaks[channel], peak * meterGain);
        }

        const size_t bytes = static_cast<size_t>(frames) * sizeof(float);
        if (mixdownChannelCount == 2) {
            std::memcpy(output[0], input[selected[0]], bytes);
            std::memcpy(output[1], input[selected[1]], bytes);
        } else {
            std::memcpy(output[0], input[selected[0]], bytes);
            for (int index = 1; index < selectedCount; ++index) {
                const float *samples = input[selected[index]];
                for (int frame = 0; frame < frames; ++frame) { output[0][frame] += samples[frame]; }
            }
        }
        // Live processing (SPEC § 13.4): `output` becomes the monitor signal; the recorded one is a constant latency later.
        float *recorded[kMaxMixdownChannels] = {};
        for (int channel = 0; channel < mixdownChannelCount; ++channel) { recorded[channel] = recordedChannel(channel); }
        chain.process(output, recorded, mixdownChannelCount, frames);

        if (isCapturing.load(std::memory_order_acquire)) {
            capturedFrames.fetch_add(frames, std::memory_order_relaxed);
            const float *planes[kMaxPlanes] = {};
            for (int index = 0; index < selectedCount; ++index) { planes[index] = input[selected[index]]; }
            for (int channel = 0; channel < mixdownChannelCount; ++channel) { planes[selectedCount + channel] = recorded[channel]; }
            push(planes, frames);
        }
        renderCycles.fetch_add(1, std::memory_order_release);
    }

    void push(const float *const *planes, int frames) noexcept {
        const int64_t write = writeIndex.load(std::memory_order_relaxed);
        const int64_t read = readIndex.load(std::memory_order_acquire);
        if (capacity - (write - read) < frames) {
            droppedFrames.fetch_add(frames, std::memory_order_relaxed);
            pendingSilence.fetch_add(frames, std::memory_order_release);
            return;
        }
        const int64_t start = write & mask;
        const int64_t first = std::min<int64_t>(frames, capacity - start);
        for (int index = 0; index < planeCount(); ++index) {
            float *destination = plane(index);
            std::memcpy(destination + start, planes[index], static_cast<size_t>(first) * sizeof(float));
            if (first < frames) {
                std::memcpy(destination, planes[index] + first, static_cast<size_t>(frames - first) * sizeof(float));
            }
        }
        writeIndex.store(write + frames, std::memory_order_release);
    }

    bool hasLayout(double rate, int inputs, const int32_t *channels, int count, int mixdown, int frames, int64_t ringCapacity) const noexcept {
        if (!isConfigured || sampleRate != rate || inputChannelCount != inputs || selectedCount != count
            || mixdownChannelCount != mixdown || maximumFrames != frames || capacity != ringCapacity) {
            return false;
        }
        for (int index = 0; index < count; ++index) {
            if (selected[index] != channels[index]) { return false; }
        }
        return true;
    }
};

EECaptureCore *EECaptureCoreCreate(void) {
    auto core = new EECaptureCore();
    for (auto &peak : core->peaks) { peak.store(0); }
    for (auto &parameter : core->parameters) { parameter.store(0); }
    return core;
}

void EECaptureCoreDestroy(EECaptureCore *core) { delete core; }

bool EECaptureCoreConfigure(EECaptureCore *core, double sampleRate, int32_t inputChannelCount, const int32_t *selected,
                            int32_t selectedCount, int32_t mixdownChannelCount, int32_t maximumFrames, int32_t ringFrames) {
    if (!(sampleRate > 0) || inputChannelCount < 1 || inputChannelCount > kMaxInputs || selected == nullptr
        || selectedCount < 1 || selectedCount > inputChannelCount || maximumFrames < 1
        || (mixdownChannelCount != 1 && mixdownChannelCount != 2) || (mixdownChannelCount == 2 && selectedCount != 2)) {
        return false;
    }
    bool isUsed[kMaxInputs] = {};
    for (int index = 0; index < selectedCount; ++index) {
        const int channel = selected[index];
        if (channel < 0 || channel >= inputChannelCount || isUsed[channel]) { return false; }
        isUsed[channel] = true;
    }
    int64_t capacity = 1;
    while (capacity < std::max<int64_t>(ringFrames, 2 * static_cast<int64_t>(maximumFrames))) { capacity <<= 1; }

    if (core->hasLayout(sampleRate, inputChannelCount, selected, selectedCount, mixdownChannelCount, maximumFrames, capacity)) {
        return true;
    }
    if (core->isTakeOpen.load(std::memory_order_acquire)) { return false; }

    core->sampleRate = sampleRate;
    core->inputChannelCount = inputChannelCount;
    std::copy(selected, selected + selectedCount, core->selected);
    core->selectedCount = selectedCount;
    core->mixdownChannelCount = mixdownChannelCount;
    core->maximumFrames = maximumFrames;
    core->capacity = capacity;
    core->mask = capacity - 1;
    core->ring.assign(static_cast<size_t>(core->planeCount()) * static_cast<size_t>(capacity), 0.0f);
    core->writeIndex.store(0);
    core->readIndex.store(0);
    core->pendingSilence.store(0);
    core->silenceAt = 0;
    core->silenceFrames = 0;
    core->inputScratch.assign(static_cast<size_t>(inputChannelCount) * static_cast<size_t>(maximumFrames), 0.0f);
    core->outputScratch.assign(static_cast<size_t>(kMaxMixdownChannels) * static_cast<size_t>(maximumFrames), 0.0f);
    core->recordedScratch.assign(static_cast<size_t>(kMaxMixdownChannels) * static_cast<size_t>(maximumFrames), 0.0f);
    core->chain.prepare(sampleRate, mixdownChannelCount, maximumFrames);
    core->hasPending.store(true);
    core->inputListStorage.assign(offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer) * static_cast<size_t>(inputChannelCount), 0);
    for (auto &peak : core->peaks) { peak.store(0); }
    core->isConfigured = true;
    return true;
}

bool EECaptureCoreIsConfigured(const EECaptureCore *core) { return core->isConfigured; }
double EECaptureCoreSampleRate(const EECaptureCore *core) { return core->sampleRate; }
int32_t EECaptureCoreInputChannelCount(const EECaptureCore *core) { return core->inputChannelCount; }
int32_t EECaptureCoreMixdownChannelCount(const EECaptureCore *core) { return core->mixdownChannelCount; }
int32_t EECaptureCoreMaximumFrames(const EECaptureCore *core) { return core->maximumFrames; }
int32_t EECaptureCorePlaneCount(const EECaptureCore *core) { return core->planeCount(); }

int32_t EECaptureCoreProcessedLatencyFrames(const EECaptureCore *core) {
    return core->isConfigured ? core->chain.recordedLatencyFrames() : 0;
}

bool EECaptureCoreSupportsHigh(const EECaptureCore *core) { return core->isConfigured && core->chain.supportsHigh(); }

void EECaptureCoreSetParameter(EECaptureCore *core, uint64_t address, float value) {
    if (address >= EECaptureParameterCount || !std::isfinite(value)) { return; }
    core->parameters[address].store(value, std::memory_order_relaxed);
    core->hasPending.store(true, std::memory_order_release);
}

float EECaptureCoreParameter(const EECaptureCore *core, uint64_t address) {
    return address < EECaptureParameterCount ? core->parameters[address].load(std::memory_order_relaxed) : 0;
}

void EECaptureCoreSetTakeOpen(EECaptureCore *core, bool isOpen) { core->isTakeOpen.store(isOpen, std::memory_order_release); }

void EECaptureCoreSetCapturing(EECaptureCore *core, bool isCapturing) {
    core->isCapturing.store(isCapturing, std::memory_order_release);
}

uint64_t EECaptureCoreRenderCycles(const EECaptureCore *core) { return core->renderCycles.load(std::memory_order_acquire); }
int64_t EECaptureCoreCapturedFrames(const EECaptureCore *core) { return core->capturedFrames.load(std::memory_order_relaxed); }
int64_t EECaptureCoreDroppedFrames(const EECaptureCore *core) { return core->droppedFrames.load(std::memory_order_relaxed); }

int32_t EECaptureCoreRead(EECaptureCore *core, float *const *planes, int32_t maximumFrames) {
    if (!core->isConfigured || maximumFrames <= 0) { return 0; }
    if (core->silenceFrames == 0) {
        const int64_t dropped = core->pendingSilence.exchange(0, std::memory_order_acquire);
        if (dropped > 0) {
            // The audio was lost when the ring was full, so after everything queued until now.
            core->silenceFrames = dropped;
            core->silenceAt = core->writeIndex.load(std::memory_order_acquire);
        }
    }
    const int64_t read = core->readIndex.load(std::memory_order_relaxed);
    if (core->silenceFrames > 0 && read == core->silenceAt) {
        const int frames = static_cast<int>(std::min<int64_t>(core->silenceFrames, maximumFrames));
        for (int index = 0; index < core->planeCount(); ++index) { std::fill_n(planes[index], frames, 0.0f); }
        core->silenceFrames -= frames;
        return frames;
    }
    int64_t available = core->writeIndex.load(std::memory_order_acquire) - read;
    if (core->silenceFrames > 0) { available = std::min(available, core->silenceAt - read); }
    const int frames = static_cast<int>(std::min<int64_t>(available, maximumFrames));
    if (frames <= 0) { return 0; }
    const int64_t start = read & core->mask;
    const int64_t first = std::min<int64_t>(frames, core->capacity - start);
    for (int index = 0; index < core->planeCount(); ++index) {
        const float *source = core->plane(index);
        std::memcpy(planes[index], source + start, static_cast<size_t>(first) * sizeof(float));
        if (first < frames) {
            std::memcpy(planes[index] + first, source, static_cast<size_t>(frames - first) * sizeof(float));
        }
    }
    core->readIndex.store(read + frames, std::memory_order_release);
    return frames;
}

void EECaptureCoreDiscard(EECaptureCore *core) {
    core->readIndex.store(core->writeIndex.load(std::memory_order_acquire), std::memory_order_release);
    core->pendingSilence.store(0, std::memory_order_relaxed);
    core->silenceFrames = 0;
}

int32_t EECaptureCoreTakePeaks(EECaptureCore *core, float *peaks, int32_t count) {
    const int values = std::clamp(static_cast<int>(count), 0, core->inputChannelCount);
    for (int channel = 0; channel < values; ++channel) {
        peaks[channel] = core->peaks[channel].exchange(0, std::memory_order_relaxed);
    }
    return values;
}

void EECaptureCoreProcess(EECaptureCore *core, const float *const *input, float *const *output, int32_t frameCount) {
    if (!core->isConfigured) { return; }
    for (int start = 0; start < frameCount; start += core->maximumFrames) {
        const int frames = std::min(core->maximumFrames, static_cast<int>(frameCount) - start);
        const float *in[kMaxInputs] = {};
        for (int channel = 0; channel < core->inputChannelCount; ++channel) { in[channel] = input[channel] + start; }
        float *out[kMaxMixdownChannels] = {};
        for (int channel = 0; channel < core->mixdownChannelCount; ++channel) {
            out[channel] = output != nullptr ? output[channel] + start : core->outputScratchChannel(channel);
        }
        core->render(in, out, frames);
    }
}

AUInternalRenderBlock EECaptureCoreRenderBlock(EECaptureCore *core) {
    // Captures only the raw pointer: no Objective-C or Swift object is touched while rendering (SPEC § 4.5).
    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *, const AudioTimeStamp *timestamp, AUAudioFrameCount frameCount,
                              NSInteger, AudioBufferList *outputData, const AURenderEvent *, AURenderPullInputBlock pullInput) {
        if (pullInput == nullptr) { return kAudioUnitErr_NoConnection; }
        if (!core->isConfigured || static_cast<int>(frameCount) > core->maximumFrames) {
            return kAudioUnitErr_TooManyFramesToProcess;
        }
        const UInt32 bytes = frameCount * static_cast<UInt32>(sizeof(float));
        auto *input = reinterpret_cast<AudioBufferList *>(core->inputListStorage.data());
        input->mNumberBuffers = static_cast<UInt32>(core->inputChannelCount);
        for (int channel = 0; channel < core->inputChannelCount; ++channel) {
            input->mBuffers[channel].mNumberChannels = 1;
            input->mBuffers[channel].mDataByteSize = bytes;
            input->mBuffers[channel].mData = core->inputScratch.data() + static_cast<size_t>(channel) * static_cast<size_t>(core->maximumFrames);
        }
        AudioUnitRenderActionFlags pullFlags = 0;
        const AUAudioUnitStatus status = pullInput(&pullFlags, timestamp, frameCount, 0, input);
        if (status != noErr) { return status; }

        // The input may hand back its own buffers.
        const float *channels[kMaxInputs] = {};
        for (int channel = 0; channel < core->inputChannelCount; ++channel) {
            channels[channel] = static_cast<const float *>(input->mBuffers[channel].mData);
        }
        float *outputs[kMaxMixdownChannels] = {};
        for (int channel = 0; channel < core->mixdownChannelCount; ++channel) {
            if (channel < static_cast<int>(outputData->mNumberBuffers)) {
                AudioBuffer &buffer = outputData->mBuffers[channel];
                if (buffer.mData == nullptr) { buffer.mData = core->outputScratchChannel(channel); }
                buffer.mDataByteSize = bytes;
                outputs[channel] = static_cast<float *>(buffer.mData);
            } else {
                outputs[channel] = core->outputScratchChannel(channel);
            }
        }
        core->render(channels, outputs, static_cast<int>(frameCount));
        return noErr;
    };
}
