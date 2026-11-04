#pragma once

// The real-time side of recording (SPEC § 4.5, § 13.3), for the capture Audio Unit in `EchoAudioUnits`: its render
// block meters every input channel, mixes the selected channels down (the monitor output, where live processing
// goes in F11) and, while capturing, queues the selected raw channels and the processed mixdown in a lock-free
// single-producer single-consumer ring. The take writer drains the ring off the render thread. Objective-C++ only;
// Swift imports it with C++ interop.

#import <AudioToolbox/AudioToolbox.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Most channels of one input device that can be metered and recorded.
#define EE_CAPTURE_MAX_INPUT_CHANNELS 32

/// Live processing parameters (SPEC § 13.4), set through the capture Audio Unit's parameter tree.
typedef CF_ENUM(uint64_t, EECaptureParameter) {
    /// 0 Off, 1 Standard (noise gate), 2 High (RNNoise).
    EECaptureParameterSuppression = 0,
    /// −24…+24 dB, ramped. The meters show it too.
    EECaptureParameterInputGain = 1,
    /// Auto-tune (SPEC § 13.5): 0/1, fading in and out.
    EECaptureParameterAutoTune = 2,
    /// −1 chromatic, else 0 (C) … 11 (B).
    EECaptureParameterAutoTuneKey = 3,
    /// 0 major, 1 minor.
    EECaptureParameterAutoTuneMinor = 4,
    /// 0 (robotic) … 100 ms (natural).
    EECaptureParameterAutoTuneRetune = 5,
    /// 0…1.
    EECaptureParameterAutoTuneHumanize = 6,
    /// 0/1.
    EECaptureParameterAutoTuneFormants = 7,
    /// The monitor's level, 0…1 (linear, ramped); 0 by default. The recorded signal and a backing track don't change.
    EECaptureParameterMonitorGain = 8,
    EECaptureParameterCount = 9,
};

typedef struct EECaptureCore EECaptureCore;

EECaptureCore *EECaptureCoreCreate(void);
void EECaptureCoreDestroy(EECaptureCore *core);

/// Allocates; never while rendering or reading. `selected` are input channel indices in take order (unique, below
/// `inputChannelCount`); `mixdownChannelCount` 1 sums them, 2 takes the two of them as left and right. The ring holds at
/// least `ringFrames` frames. Keeps everything when nothing changes; refuses a different layout while a take is open.
/// Returns false for an invalid or refused configuration.
bool EECaptureCoreConfigure(EECaptureCore *core, double sampleRate, int32_t inputChannelCount, const int32_t *selected,
                            int32_t selectedCount, int32_t mixdownChannelCount, int32_t maximumFrames, int32_t ringFrames);
bool EECaptureCoreIsConfigured(const EECaptureCore *core);
double EECaptureCoreSampleRate(const EECaptureCore *core);
int32_t EECaptureCoreInputChannelCount(const EECaptureCore *core);
int32_t EECaptureCoreMixdownChannelCount(const EECaptureCore *core);
int32_t EECaptureCoreMaximumFrames(const EECaptureCore *core);
/// Planes in the ring, per frame: the selected raw channels in take order, then the processed mixdown's channels.
int32_t EECaptureCorePlaneCount(const EECaptureCore *core);
/// How far the processed planes are behind the raw ones, in frames; constant for the configuration. The writer removes it.
int32_t EECaptureCoreProcessedLatencyFrames(const EECaptureCore *core);
/// Whether High (RNNoise) can run at the configured rate (44.1 kHz or more); below, it acts as Standard.
bool EECaptureCoreSupportsHigh(const EECaptureCore *core);

/// Any thread: the render thread picks the value up at its next cycle.
void EECaptureCoreSetParameter(EECaptureCore *core, uint64_t address, float value);
float EECaptureCoreParameter(const EECaptureCore *core, uint64_t address);

/// Any thread. While a take is open the layout can't change (a restarted engine keeps writing into the same ring).
void EECaptureCoreSetTakeOpen(EECaptureCore *core, bool isOpen);
/// Any thread: while true, rendered audio enters the ring; while false (paused, between takes) only the meters run.
void EECaptureCoreSetCapturing(EECaptureCore *core, bool isCapturing);
/// Any thread: starts capturing exactly at render sample time `sampleTime` (the engine's timeline), so a backing track
/// scheduled at the same sample starts with the take. Capturing counts as off until then.
void EECaptureCoreStartCapturingAt(EECaptureCore *core, int64_t sampleTime);
/// Any thread: starts capturing at the frame that plays at `hostTime` (live: a backing track's player starts at the same
/// host time, whatever its own sample rate).
void EECaptureCoreStartCapturingAtHostTime(EECaptureCore *core, uint64_t hostTime, double hostTicksPerFrame);
/// The render sample time the next cycle starts at, as last seen by the render thread.
int64_t EECaptureCoreNextSampleTime(const EECaptureCore *core);
/// Render cycles finished so far. A cycle that starts after `EECaptureCoreSetCapturing(false)` returns sees it, so once
/// this grew by 2 no more audio enters the ring.
uint64_t EECaptureCoreRenderCycles(const EECaptureCore *core);
/// Frames captured so far, including frames that couldn't be queued (see `EECaptureCoreDroppedFrames`).
int64_t EECaptureCoreCapturedFrames(const EECaptureCore *core);
/// Frames the render thread found no room for because the writer fell behind. The reader puts the same number of
/// silent frames about where they were lost, so the take keeps its length.
int64_t EECaptureCoreDroppedFrames(const EECaptureCore *core);

/// The writer (one thread): copies up to `maximumFrames` queued frames into `planes` (`EECaptureCorePlaneCount`
/// pointers) and frees them in the ring. Returns the frames copied; 0 when nothing is queued.
int32_t EECaptureCoreRead(EECaptureCore *core, float *const *planes, int32_t maximumFrames);
/// The writer, while not capturing: forgets everything queued (before a new take starts).
void EECaptureCoreDiscard(EECaptureCore *core);

/// Any thread: the highest |sample| of each input channel since the previous call (1 = full scale), then starts over.
/// Writes and returns `min(count, input channel count)` values.
int32_t EECaptureCoreTakePeaks(EECaptureCore *core, float *peaks, int32_t count);

AUInternalRenderBlock EECaptureCoreRenderBlock(EECaptureCore *core);
/// Offline (tests): render cycles over `input` (input channel count planes of `frameCount` frames), writing the
/// monitor output (mixdown channel count planes) to `output` unless it is NULL.
void EECaptureCoreProcess(EECaptureCore *core, const float *const *input, float *const *output, int32_t frameCount);

#ifdef __cplusplus
}
#endif
