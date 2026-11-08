/* iOS shim: OpenAL Soft "*_SOFT" extensions do not exist in Apple's OpenAL.
 * Everything here is a harmless no-op so NOpenALDrv.cpp compiles unmodified.
 * The driver already probes alIsExtensionPresent()/alcIsExtensionPresent()
 * at runtime, and Apple's implementation reports these as absent, so the
 * stubs below are never reached in practice. */
#pragma once
#include <OpenAL/al.h>
#include <OpenAL/alc.h>

#define ALC_SOFT_HRTF 1
#define ALC_HRTF_SOFT 0x1992

static inline void alDeferUpdatesSOFT(void) {}
static inline void alProcessUpdatesSOFT(void) {}
static inline void alcDevicePauseSOFT(ALCdevice *d) { (void)d; }
static inline void alcDeviceResumeSOFT(ALCdevice *d) { (void)d; }
