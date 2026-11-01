#pragma once

// A two-input crossfader for preview playback (SPEC § 6.3, § 6.6): input 0 and input 1 are two players; switching
// fades from one to the other over 20 ms, starting at an exact render sample when scheduled through the Audio Unit's
// parameter events. Objective-C++ only; Swift imports it with C++ interop.

#import <AudioToolbox/AudioToolbox.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef CF_ENUM(uint64_t, EESourceSwitchParameter) {
    /// 0 = input 0, 1 = input 1.
    EESourceSwitchParameterSource = 0,
};

typedef struct EESourceSwitch EESourceSwitch;

EESourceSwitch *EESourceSwitchCreate(void);
void EESourceSwitchDestroy(EESourceSwitch *source);
/// Allocates (never on the render thread).
void EESourceSwitchPrepare(EESourceSwitch *source, double sampleRate, int32_t channelCount, int32_t maximumFrames);
/// Any thread: switches at the next render cycle (with the crossfade).
void EESourceSwitchSetSource(EESourceSwitch *source, float input);
float EESourceSwitchSource(const EESourceSwitch *source);
AUInternalRenderBlock EESourceSwitchRenderBlock(EESourceSwitch *source);

#ifdef __cplusplus
}
#endif
