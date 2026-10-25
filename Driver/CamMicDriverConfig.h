#pragma once

#include <stdbool.h>

// Keep the upstream HAL render/capture engine. CamMic publishes one microphone
// device and one hidden, output-only endpoint used by the Mac receiver.
#define kDriver_Name "CamMic"
#define kPlugIn_BundleID "com.yykx682436.CamMicAudioDriver"
#define kPlugIn_Icon "CamMic.icns"
#define kDevice_Name "CamMic"
#define kDevice2_Name "CamMicInternalOutput"
#define kManufacturer_Name "CamMic"
#define kNumber_Of_Channels 2

#define kDevice_IsHidden false
#define kDevice_HasInput true
#define kDevice_HasOutput false

#define kDevice2_IsHidden true
#define kDevice2_HasInput false
#define kDevice2_HasOutput true

// The public microphone must be selectable as a content/default input device.
// The hidden output is an internal writer endpoint and must never be selectable.
#define kPublicInputCanBeDefaultDevice true
#define kHiddenOutputCanBeDefaultDevice false
#define kCanBeDefaultDevice (inObjectID == kObjectID_Device ? kPublicInputCanBeDefaultDevice : kHiddenOutputCanBeDefaultDevice)
#define kCanBeDefaultSystemDevice false
