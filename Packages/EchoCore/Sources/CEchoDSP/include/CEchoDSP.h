#pragma once

// Umbrella header for CEchoDSP. C++ (and Objective-C++ for the Audio Unit glue): Swift modules importing it must
// enable C++ interop.
#include "DSPMath.hpp"
#include "SmoothedValue.hpp"
#include "Biquad.hpp"
#include "GainKernel.hpp"
#include "EQKernel.hpp"
#include "GateKernel.hpp"
#include "CompressorKernel.hpp"
#include "DeEsserKernel.hpp"
#include "LimiterKernel.hpp"
#include "PitchDetector.hpp"
#include "PitchShiftKernel.hpp"
#include "ReverbKernel.hpp"
#include "AudioUnitEffect.h"
