/* iOS shim: Apple's OpenAL has no EFX. Reverb is compiled to no-ops; the rest
 * of the audio path (3D positioning, doppler, music) is unaffected. */
#pragma once
#include <OpenAL/al.h>
#include <OpenAL/alc.h>

#define AL_METERS_PER_UNIT            0x20004
#define AL_AUXILIARY_SEND_FILTER      0x20006
#define AL_FILTER_NULL                0x0000
#define AL_EFFECT_NULL                0x0000
#define AL_EFFECT_TYPE                0x8001
#define AL_EFFECT_EAXREVERB           0x8000
#define AL_EFFECTSLOT_EFFECT          0x0001

#define AL_EAXREVERB_DENSITY              0x0001
#define AL_EAXREVERB_DIFFUSION            0x0002
#define AL_EAXREVERB_GAIN                 0x0003
#define AL_EAXREVERB_GAINHF               0x0004
#define AL_EAXREVERB_GAINLF               0x0005
#define AL_EAXREVERB_DECAY_TIME           0x0006
#define AL_EAXREVERB_DECAY_HFRATIO        0x0007
#define AL_EAXREVERB_DECAY_LFRATIO        0x0008
#define AL_EAXREVERB_REFLECTIONS_GAIN     0x0009
#define AL_EAXREVERB_REFLECTIONS_DELAY    0x000A
#define AL_EAXREVERB_REFLECTIONS_PAN      0x000B
#define AL_EAXREVERB_LATE_REVERB_GAIN     0x000C
#define AL_EAXREVERB_LATE_REVERB_DELAY    0x000D
#define AL_EAXREVERB_LATE_REVERB_PAN      0x000E
#define AL_EAXREVERB_ECHO_TIME            0x000F
#define AL_EAXREVERB_ECHO_DEPTH           0x0010
#define AL_EAXREVERB_MODULATION_TIME      0x0011
#define AL_EAXREVERB_MODULATION_DEPTH     0x0012
#define AL_EAXREVERB_AIR_ABSORPTION_GAINHF 0x0013
#define AL_EAXREVERB_HFREFERENCE          0x0014
#define AL_EAXREVERB_LFREFERENCE          0x0015
#define AL_EAXREVERB_ROOM_ROLLOFF_FACTOR  0x0016
#define AL_EAXREVERB_DECAY_HFLIMIT        0x0017

static inline void alGenEffects(ALsizei n, ALuint *e) { for (ALsizei i = 0; i < n; i++) e[i] = 0; }
static inline void alDeleteEffects(ALsizei n, const ALuint *e) { (void)n; (void)e; }
static inline void alEffecti(ALuint e, ALenum p, ALint v) { (void)e; (void)p; (void)v; }
static inline void alEffectf(ALuint e, ALenum p, ALfloat v) { (void)e; (void)p; (void)v; }
static inline void alEffectfv(ALuint e, ALenum p, const ALfloat *v) { (void)e; (void)p; (void)v; }
static inline void alGenAuxiliaryEffectSlots(ALsizei n, ALuint *s) { for (ALsizei i = 0; i < n; i++) s[i] = 0; }
static inline void alDeleteAuxiliaryEffectSlots(ALsizei n, const ALuint *s) { (void)n; (void)s; }
static inline void alAuxiliaryEffectSloti(ALuint s, ALenum p, ALint v) { (void)s; (void)p; (void)v; }
