#pragma once
typedef struct {
    float flDensity, flDiffusion, flGain, flGainHF, flGainLF;
    float flDecayTime, flDecayHFRatio, flDecayLFRatio;
    float flReflectionsGain, flReflectionsDelay, flReflectionsPan[3];
    float flLateReverbGain, flLateReverbDelay, flLateReverbPan[3];
    float flEchoTime, flEchoDepth, flModulationTime, flModulationDepth;
    float flAirAbsorptionGainHF, flHFReference, flLFReference, flRoomRolloffFactor;
    int   iDecayHFLimit;
} EFXEAXREVERBPROPERTIES;

#define EFX_REVERB_PRESET_GENERIC \
 { 1.0000f, 1.0000f, 0.3162f, 0.8913f, 1.0000f, 1.4900f, 0.8300f, 1.0000f, 0.0500f, 0.0070f, { 0.0000f, 0.0000f, 0.0000f }, 1.2589f, 0.0110f, { 0.0000f, 0.0000f, 0.0000f }, 0.2500f, 0.0000f, 0.2500f, 0.0000f, 0.9943f, 5000.0000f, 250.0000f, 0.0000f, 0x1 }
