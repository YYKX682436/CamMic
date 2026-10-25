// CoreAudio end-to-end test: generated PCM -> CamMicInternalOutput -> HAL -> CamMic input.
// Build with: clang -std=c11 -O2 scripts/test-cammic-coreaudio-loopback.c -framework CoreAudio -lm -o /tmp/cammic-loopback

#include <CoreAudio/CoreAudio.h>
#include <math.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

enum { kMaxCaptureFrames = 48000 * 8 };

typedef struct {
    AudioStreamBasicDescription format;
    uint32_t bytes_per_sample;
} PCMFormat;

typedef struct {
    AudioDeviceID output_device;
    AudioDeviceID input_device;
    PCMFormat output_format;
    PCMFormat input_format;
    float *captured;
    atomic_uint_fast64_t captured_frames;
    atomic_uint_fast64_t completed_frames;
    atomic_uint_fast64_t output_frames;
    atomic_uint_fast64_t output_callbacks;
    atomic_uint_fast64_t input_callbacks;
    atomic_uint_fast64_t missing_input_buffers;
    atomic_uint_fast64_t capture_overflows;
    double frequency;
    float amplitude;
} LoopbackContext;

static OSStatus get_data(AudioObjectID object, AudioObjectPropertySelector selector,
                         AudioObjectPropertyScope scope, UInt32 *size, void *value) {
    AudioObjectPropertyAddress address = { selector, scope, kAudioObjectPropertyElementMain };
    return AudioObjectGetPropertyData(object, &address, 0, NULL, size, value);
}

static OSStatus resolve_uid(const char *text, AudioDeviceID *device) {
    CFStringRef uid = CFStringCreateWithCString(NULL, text, kCFStringEncodingUTF8);
    if (!uid) return kAudioHardwareUnspecifiedError;
    AudioObjectPropertyAddress address = { kAudioHardwarePropertyTranslateUIDToDevice,
                                            kAudioObjectPropertyScopeGlobal,
                                            kAudioObjectPropertyElementMain };
    UInt32 size = sizeof(*device);
    OSStatus status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &address,
                                                sizeof(uid), &uid, &size, device);
    CFRelease(uid);
    return status;
}

static OSStatus query_format(AudioDeviceID device, AudioObjectPropertyScope scope, PCMFormat *format) {
    UInt32 size = sizeof(format->format);
    OSStatus status = get_data(device, kAudioDevicePropertyStreamFormat, scope,
                               &size, &format->format);
    if (status == noErr) format->bytes_per_sample = format->format.mBitsPerChannel / 8;
    return status;
}

static OSStatus query_uint(AudioObjectID object, AudioObjectPropertySelector selector,
                           AudioObjectPropertyScope scope, UInt32 *value) {
    return get_data(object, selector, scope, &(UInt32){sizeof(*value)}, value);
}

static OSStatus query_owner(AudioObjectID object, AudioObjectID *owner) {
    UInt32 size = sizeof(*owner);
    return get_data(object, kAudioObjectPropertyOwner, kAudioObjectPropertyScopeGlobal, &size, owner);
}

static int query_object_list(AudioObjectID object, AudioObjectPropertySelector selector,
                             AudioObjectPropertyScope scope, AudioObjectID *items,
                             UInt32 capacity, UInt32 *count) {
    AudioObjectPropertyAddress address = { selector, scope, kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(object, &address, 0, NULL, &size);
    if (status != noErr || size % sizeof(AudioObjectID) != 0 || size > capacity * sizeof(AudioObjectID)) {
        fprintf(stderr, "query object-list size selector=0x%x scope=0x%x failed OSStatus=%d bytes=%u\n",
                selector, scope, (int)status, size);
        return 1;
    }
    status = AudioObjectGetPropertyData(object, &address, 0, NULL, &size, items);
    if (status != noErr) {
        fprintf(stderr, "query object-list selector=0x%x scope=0x%x failed OSStatus=%d\n",
                selector, scope, (int)status);
        return 1;
    }
    *count = size / sizeof(AudioObjectID);
    return 0;
}

static int verify_owner(AudioObjectID child, AudioObjectID expected_owner, const char *label) {
    AudioObjectID owner = kAudioObjectUnknown;
    OSStatus status = query_owner(child, &owner);
    if (status != noErr || owner != expected_owner) {
        fprintf(stderr, "%s owner mismatch: status=%d owner=%u expected=%u\n",
                label, (int)status, owner, expected_owner);
        return 1;
    }
    return 0;
}

static int verify_output_control_classes(const AudioObjectID *controls, UInt32 count) {
    int found_volume = 0, found_mute = 0, found_coreaudio_device_control = 0;
    for (UInt32 index = 0; index < count; index++) {
        UInt32 class_id = 0;
        OSStatus status = query_uint(controls[index], kAudioObjectPropertyClass,
                                     kAudioObjectPropertyScopeGlobal, &class_id);
        if (status != noErr) {
            fprintf(stderr, "hidden output control %u class lookup failed OSStatus=%d\n",
                    controls[index], (int)status);
            return 1;
        }
        if (class_id == kAudioVolumeControlClassID) found_volume++;
        else if (class_id == kAudioMuteControlClassID) found_mute++;
        // CoreAudio adds this private device control to HAL devices on this host.
        // It is also present on the built-in speaker and the unmodified BlackHole device.
        else if (class_id == UINT32_C(0x65766973)) found_coreaudio_device_control++;
        else {
            fprintf(stderr, "hidden output exposes unexpected control class 0x%08x\n", class_id);
            return 1;
        }
    }
    if (found_volume != 1 || found_mute != 1 || found_coreaudio_device_control > 1 ||
        count != (UInt32)(2 + found_coreaudio_device_control)) {
        fprintf(stderr, "hidden output control set invalid: volume=%d mute=%d CoreAudio=%d total=%u\n",
                found_volume, found_mute, found_coreaudio_device_control, count);
        return 1;
    }
    return 0;
}

static int is_listed(AudioObjectID wanted, const AudioObjectID *items, UInt32 count) {
    for (UInt32 index = 0; index < count; index++) if (items[index] == wanted) return 1;
    return 0;
}

static OSStatus query_string(AudioObjectID object, AudioObjectPropertySelector selector, char *buffer, size_t capacity);

static OSStatus resolve_plugin_device(AudioObjectID plugin, const char *text, AudioDeviceID *device) {
    CFStringRef uid = CFStringCreateWithCString(NULL, text, kCFStringEncodingUTF8);
    if (!uid) return kAudioHardwareUnspecifiedError;
    AudioObjectPropertyAddress address = { kAudioPlugInPropertyTranslateUIDToDevice,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 size = sizeof(*device);
    OSStatus status = AudioObjectGetPropertyData(plugin, &address, sizeof(uid), &uid, &size, device);
    CFRelease(uid);
    return status;
}

static int verify_plugin_graph(AudioDeviceID input, AudioDeviceID output) {
    int failed = 0;
    CFStringRef bundle_id = CFSTR("com.yykx682436.CamMicAudioDriver");
    AudioObjectPropertyAddress translate_address = { kAudioHardwarePropertyTranslateBundleIDToPlugIn,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioObjectID plugin = kAudioObjectUnknown;
    UInt32 plugin_size = sizeof(plugin);
    OSStatus plugin_status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &translate_address,
        sizeof(bundle_id), &bundle_id, &plugin_size, &plugin);
    if (plugin_status != noErr || plugin == kAudioObjectUnknown) {
        fprintf(stderr, "CamMic HAL plug-in bundle lookup failed: status=%d id=%u\n", (int)plugin_status, plugin);
        return 1;
    }
    char registered_bundle[256] = "";
    OSStatus bundle_status = query_string(plugin, kAudioPlugInPropertyBundleID,
                                           registered_bundle, sizeof(registered_bundle));
    UInt32 plugin_class = 0;
    OSStatus class_status = query_uint(plugin, kAudioObjectPropertyClass,
                                       kAudioObjectPropertyScopeGlobal, &plugin_class);
    AudioObjectID plugin_owner = kAudioObjectUnknown;
    OSStatus owner_status = query_owner(plugin, &plugin_owner);
    if (bundle_status != noErr || strcmp(registered_bundle, "com.yykx682436.CamMicAudioDriver") != 0 ||
        class_status != noErr || plugin_class != kAudioPlugInClassID || owner_status != noErr ||
        plugin_owner != kAudioObjectSystemObject) {
        fprintf(stderr, "CamMic HAL plug-in identity/owner mismatch: bundle=%s/%d class=0x%08x/%d owner=%u/%d\n",
                registered_bundle, (int)bundle_status, plugin_class, (int)class_status,
                plugin_owner, (int)owner_status);
        failed = 1;
    }

    AudioObjectID plugins[64] = {0};
    UInt32 plugin_count = 0;
    failed |= query_object_list(kAudioObjectSystemObject, kAudioHardwarePropertyPlugInList,
                                kAudioObjectPropertyScopeGlobal, plugins, 64, &plugin_count);
    if (!is_listed(plugin, plugins, plugin_count)) {
        fprintf(stderr, "CamMic HAL plug-in %u is absent from the registered plug-in list\n", plugin);
        failed = 1;
    }
    AudioDeviceID plugin_input = kAudioObjectUnknown, plugin_output = kAudioObjectUnknown;
    OSStatus plugin_input_status = resolve_plugin_device(plugin, "CamMic2ch_UID", &plugin_input);
    OSStatus plugin_output_status = resolve_plugin_device(plugin, "CamMic2ch_2_UID", &plugin_output);
    if (plugin_input_status != noErr || plugin_output_status != noErr ||
        plugin_input != input || plugin_output != output) {
        fprintf(stderr, "CamMic plug-in UID mapping mismatch: input=%u/%d expected=%u output=%u/%d expected=%u\n",
                plugin_input, (int)plugin_input_status, input,
                plugin_output, (int)plugin_output_status, output);
        failed = 1;
    }
    AudioObjectID devices[8] = {0};
    UInt32 device_count = 0;
    failed |= query_object_list(plugin, kAudioPlugInPropertyDeviceList,
                                kAudioObjectPropertyScopeGlobal, devices, 8, &device_count);
    if (!is_listed(input, devices, device_count)) {
        fprintf(stderr, "CamMic public input %u is absent from its HAL plug-in device list (count=%u)\n",
                input, device_count);
        failed = 1;
    }
    printf("plugin-check id=%u class=0x%08x bundle=%s systemOwner=%u registered=%s deviceListCount=%u publicInput=%s hiddenOutput=%s\n",
           plugin, plugin_class, registered_bundle, plugin_owner, failed ? "FAIL" : "PASS", device_count,
           is_listed(input, devices, device_count) ? "listed" : "missing",
           is_listed(output, devices, device_count) ? "listed" : "hidden-or-omitted");
    return failed;
}

static int verify_endpoint_objects(AudioDeviceID input, AudioDeviceID output) {
    int failed = 0;
    UInt32 input_hidden = UINT32_MAX, output_hidden = UINT32_MAX;
    OSStatus input_hidden_status = query_uint(input, kAudioDevicePropertyIsHidden,
        kAudioObjectPropertyScopeGlobal, &input_hidden);
    OSStatus output_hidden_status = query_uint(output, kAudioDevicePropertyIsHidden,
        kAudioObjectPropertyScopeGlobal, &output_hidden);
    if (input_hidden_status != noErr || output_hidden_status != noErr || input_hidden != 0 || output_hidden != 1) {
        fprintf(stderr, "endpoint visibility mismatch: input status=%d hidden=%u; output status=%d hidden=%u\n",
                (int)input_hidden_status, input_hidden, (int)output_hidden_status, output_hidden);
        failed = 1;
    }
    failed |= verify_plugin_graph(input, output);

    AudioObjectID input_streams[8] = {0}, output_streams[8] = {0};
    UInt32 input_stream_count = 0, output_stream_count = 0;
    failed |= query_object_list(input, kAudioDevicePropertyStreams, kAudioDevicePropertyScopeInput,
                                input_streams, 8, &input_stream_count);
    failed |= query_object_list(input, kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput,
                                output_streams, 8, &output_stream_count);
    if (input_stream_count != 1 || output_stream_count != 0) {
        fprintf(stderr, "public CamMic stream scopes invalid: input=%u output=%u\n", input_stream_count, output_stream_count);
        failed = 1;
    }
    for (UInt32 index = 0; index < input_stream_count; index++) failed |= verify_owner(input_streams[index], input, "public input stream");
    AudioObjectID public_input_stream = input_stream_count == 1 ? input_streams[0] : kAudioObjectUnknown;

    input_stream_count = output_stream_count = 0;
    failed |= query_object_list(output, kAudioDevicePropertyStreams, kAudioDevicePropertyScopeInput,
                                input_streams, 8, &input_stream_count);
    failed |= query_object_list(output, kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput,
                                output_streams, 8, &output_stream_count);
    if (input_stream_count != 0 || output_stream_count != 1) {
        fprintf(stderr, "hidden output stream scopes invalid: input=%u output=%u\n", input_stream_count, output_stream_count);
        failed = 1;
    }
    for (UInt32 index = 0; index < output_stream_count; index++) failed |= verify_owner(output_streams[index], output, "hidden output stream");
    AudioObjectID hidden_output_stream = output_stream_count == 1 ? output_streams[0] : kAudioObjectUnknown;

    AudioObjectID controls[8] = {0};
    UInt32 control_count = 0;
    failed |= query_object_list(input, kAudioObjectPropertyControlList, kAudioObjectPropertyScopeGlobal,
                                controls, 8, &control_count);
    if (control_count != 3) { fprintf(stderr, "public input expected 3 controls, got %u\n", control_count); failed = 1; }
    for (UInt32 index = 0; index < control_count; index++) failed |= verify_owner(controls[index], input, "public input control");
    AudioObjectID input_controls[8] = {0};
    UInt32 input_control_count = control_count;
    memcpy(input_controls, controls, input_control_count * sizeof(AudioObjectID));
    control_count = 0;
    failed |= query_object_list(output, kAudioObjectPropertyControlList, kAudioObjectPropertyScopeGlobal,
                                controls, 8, &control_count);
    for (UInt32 index = 0; index < control_count; index++) failed |= verify_owner(controls[index], output, "hidden output control");
    failed |= verify_output_control_classes(controls, control_count);
    AudioObjectID output_controls[8] = {0};
    UInt32 output_control_count = control_count;
    memcpy(output_controls, controls, output_control_count * sizeof(AudioObjectID));

    AudioObjectID owned_children[8] = {0};
    UInt32 child_count = 0;
    failed |= query_object_list(input, kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal,
                                owned_children, 8, &child_count);
    if (child_count != input_control_count + 1 || !is_listed(public_input_stream, owned_children, child_count)) {
        fprintf(stderr, "public input owned-object list invalid: count=%u stream=%u controls=%u\n",
                child_count, public_input_stream, input_control_count);
        failed = 1;
    }
    for (UInt32 index = 0; index < input_control_count; index++) {
        if (!is_listed(input_controls[index], owned_children, child_count)) {
            fprintf(stderr, "public input owned-object list omits control %u\n", input_controls[index]);
            failed = 1;
        }
    }
    child_count = 0;
    failed |= query_object_list(output, kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal,
                                owned_children, 8, &child_count);
    if (child_count != output_control_count + 1 || !is_listed(hidden_output_stream, owned_children, child_count)) {
        fprintf(stderr, "hidden output owned-object list invalid: count=%u stream=%u controls=%u\n",
                child_count, hidden_output_stream, output_control_count);
        failed = 1;
    }
    for (UInt32 index = 0; index < output_control_count; index++) {
        if (!is_listed(output_controls[index], owned_children, child_count)) {
            fprintf(stderr, "hidden output owned-object list omits control %u\n", output_controls[index]);
            failed = 1;
        }
    }

    UInt32 input_clock = 0, output_clock = 0;
    OSStatus input_clock_status = query_uint(input, kAudioDevicePropertyClockDomain,
        kAudioObjectPropertyScopeGlobal, &input_clock);
    OSStatus output_clock_status = query_uint(output, kAudioDevicePropertyClockDomain,
        kAudioObjectPropertyScopeGlobal, &output_clock);
    if (input_clock_status != noErr || output_clock_status != noErr || input_clock == 0 || input_clock != output_clock) {
        fprintf(stderr, "shared clock domain mismatch: input=%u/%d output=%u/%d\n",
                input_clock, (int)input_clock_status, output_clock, (int)output_clock_status);
        failed = 1;
    }
    AudioObjectID related[4] = {0};
    UInt32 related_count = 0;
    failed |= query_object_list(input, kAudioDevicePropertyRelatedDevices, kAudioObjectPropertyScopeGlobal,
                                related, 4, &related_count);
    if (related_count != 2 || !is_listed(input, related, related_count) || !is_listed(output, related, related_count)) {
        fprintf(stderr, "public input related-device list invalid: count=%u\n", related_count);
        failed = 1;
    }
    related_count = 0;
    failed |= query_object_list(output, kAudioDevicePropertyRelatedDevices, kAudioObjectPropertyScopeGlobal,
                                related, 4, &related_count);
    if (related_count != 2 || !is_listed(input, related, related_count) || !is_listed(output, related, related_count)) {
        fprintf(stderr, "hidden output related-device list invalid: count=%u\n", related_count);
        failed = 1;
    }

    AudioObjectPropertyAddress devices_address = { kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 devices_size = 0;
    int hidden_output_in_inventory = 0;
    OSStatus devices_status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &devices_address, 0, NULL, &devices_size);
    AudioDeviceID *devices = devices_status == noErr ? calloc(1, devices_size) : NULL;
    if (devices_status != noErr || !devices) {
        fprintf(stderr, "cannot read visible CoreAudio device inventory: OSStatus=%d\n", (int)devices_status);
        failed = 1;
    } else {
        devices_status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &devices_address, 0, NULL, &devices_size, devices);
        UInt32 count = devices_status == noErr ? devices_size / sizeof(*devices) : 0;
        hidden_output_in_inventory = is_listed(output, devices, count);
        UInt32 listed_output_hidden = UINT32_MAX;
        OSStatus listed_output_hidden_status = hidden_output_in_inventory
            ? query_uint(output, kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal, &listed_output_hidden)
            : noErr;
        if (devices_status != noErr || !is_listed(input, devices, count) ||
            (hidden_output_in_inventory && (listed_output_hidden_status != noErr || listed_output_hidden != 1))) {
            fprintf(stderr, "public/hidden endpoint enumeration mismatch: inputListed=%d hiddenOutputListed=%d hidden=%u status=%d\n",
                    is_listed(input, devices, count), hidden_output_in_inventory,
                    listed_output_hidden, (int)listed_output_hidden_status);
            failed = 1;
        }
        free(devices);
    }
    printf("object-check inputHidden=%u outputHidden=%u inputStreamId=%u outputStreamId=%u inputControls=%u outputControls=%u sharedClockDomain=0x%08x hiddenOutputListedInHardwareInventory=%s result=%s\n",
           input_hidden, output_hidden, public_input_stream, hidden_output_stream, input_control_count,
           output_control_count, input_clock, hidden_output_in_inventory ? "yes-hidden" : "no",
           failed ? "FAIL" : "PASS");
    return failed;
}

static OSStatus query_string(AudioObjectID object, AudioObjectPropertySelector selector, char *buffer, size_t capacity) {
    CFStringRef value = NULL;
    UInt32 size = sizeof(value);
    OSStatus status = get_data(object, selector, kAudioObjectPropertyScopeGlobal, &size, &value);
    if (status == noErr && value && !CFStringGetCString(value, buffer, (CFIndex)capacity, kCFStringEncodingUTF8)) {
        status = kAudioHardwareUnspecifiedError;
    }
    if (value) CFRelease(value);
    if (status != noErr && capacity) buffer[0] = '\0';
    return status;
}

static float decode_sample(const void *data, size_t index, const PCMFormat *format) {
    if (format->format.mFormatFlags & kAudioFormatFlagIsFloat) {
        if (format->format.mBitsPerChannel == 32) {
            float sample;
            memcpy(&sample, (const uint8_t *)data + index * sizeof(sample), sizeof(sample));
            return sample;
        }
        if (format->format.mBitsPerChannel == 64) {
            double sample;
            memcpy(&sample, (const uint8_t *)data + index * sizeof(sample), sizeof(sample));
            return (float)sample;
        }
    } else if (format->format.mBitsPerChannel == 16) {
        int16_t sample;
        memcpy(&sample, (const uint8_t *)data + index * sizeof(sample), sizeof(sample));
        return (float)sample / 32768.0f;
    } else if (format->format.mBitsPerChannel == 32) {
        int32_t sample;
        memcpy(&sample, (const uint8_t *)data + index * sizeof(sample), sizeof(sample));
        return (float)((double)sample / 2147483648.0);
    }
    return 0.0f;
}

static void encode_sample(void *data, size_t index, const PCMFormat *format, float value) {
    if (format->format.mFormatFlags & kAudioFormatFlagIsFloat) {
        if (format->format.mBitsPerChannel == 32) {
            memcpy((uint8_t *)data + index * sizeof(value), &value, sizeof(value));
        } else if (format->format.mBitsPerChannel == 64) {
            double sample = value;
            memcpy((uint8_t *)data + index * sizeof(sample), &sample, sizeof(sample));
        }
    } else if (format->format.mBitsPerChannel == 16) {
        int16_t sample = (int16_t)lrintf(fmaxf(-1.0f, fminf(1.0f, value)) * 32767.0f);
        memcpy((uint8_t *)data + index * sizeof(sample), &sample, sizeof(sample));
    } else if (format->format.mBitsPerChannel == 32) {
        int32_t sample = (int32_t)llround(fmax(-1.0, fmin(1.0, value)) * 2147483647.0);
        memcpy((uint8_t *)data + index * sizeof(sample), &sample, sizeof(sample));
    }
}

static OSStatus output_proc(AudioObjectID device, const AudioTimeStamp *now,
                            const AudioBufferList *input, const AudioTimeStamp *input_time,
                            AudioBufferList *output, const AudioTimeStamp *output_time,
                            void *client_data) {
    (void)device; (void)now; (void)input; (void)input_time; (void)output_time;
    LoopbackContext *context = client_data;
    atomic_fetch_add_explicit(&context->output_callbacks, 1, memory_order_relaxed);
    if (!output) return noErr;

    uint32_t channels = 0;
    for (UInt32 index = 0; index < output->mNumberBuffers; index++) channels += output->mBuffers[index].mNumberChannels;
    if (channels < 2 || context->output_format.bytes_per_sample == 0) return noErr;

    uint32_t frames = UINT32_MAX;
    for (UInt32 index = 0; index < output->mNumberBuffers; index++) {
        const AudioBuffer *buffer = &output->mBuffers[index];
        uint32_t buffer_channels = buffer->mNumberChannels;
        uint32_t bytes_per_frame = buffer_channels * context->output_format.bytes_per_sample;
        if (buffer_channels == 0 || bytes_per_frame == 0) return noErr;
        uint32_t available = buffer->mDataByteSize / bytes_per_frame;
        if (available < frames) frames = available;
    }
    if (frames == UINT32_MAX || frames == 0) return noErr;
    uint64_t start = atomic_fetch_add_explicit(&context->output_frames, frames, memory_order_relaxed);
    double rate = context->output_format.format.mSampleRate;

    for (UInt32 buffer_index = 0; buffer_index < output->mNumberBuffers; buffer_index++) {
        AudioBuffer *buffer = &output->mBuffers[buffer_index];
        if (!buffer->mData) continue;
        UInt32 base_channel = 0;
        for (UInt32 previous = 0; previous < buffer_index; previous++) base_channel += output->mBuffers[previous].mNumberChannels;
        for (UInt32 frame = 0; frame < frames; frame++) {
            double phase = 2.0 * M_PI * context->frequency * (double)(start + frame) / rate;
            float sample = context->amplitude * (float)sin(phase);
            for (UInt32 channel = 0; channel < buffer->mNumberChannels; channel++) {
                encode_sample(buffer->mData, (size_t)frame * buffer->mNumberChannels + channel,
                              &context->output_format, base_channel + channel < 2 ? sample : 0.0f);
            }
        }
    }
    return noErr;
}

static OSStatus input_proc(AudioObjectID device, const AudioTimeStamp *now,
                           const AudioBufferList *input, const AudioTimeStamp *input_time,
                           AudioBufferList *output, const AudioTimeStamp *output_time,
                           void *client_data) {
    (void)device; (void)now; (void)output; (void)output_time;
    LoopbackContext *context = client_data;
    atomic_fetch_add_explicit(&context->input_callbacks, 1, memory_order_relaxed);
    if (!input) {
        atomic_fetch_add_explicit(&context->missing_input_buffers, 1, memory_order_relaxed);
        return noErr;
    }
    uint32_t channels = 0;
    for (UInt32 index = 0; index < input->mNumberBuffers; index++) channels += input->mBuffers[index].mNumberChannels;
    if (channels < 2 || context->input_format.bytes_per_sample == 0) {
        atomic_fetch_add_explicit(&context->missing_input_buffers, 1, memory_order_relaxed);
        return noErr;
    }
    uint32_t frames = UINT32_MAX;
    for (UInt32 index = 0; index < input->mNumberBuffers; index++) {
        const AudioBuffer *buffer = &input->mBuffers[index];
        uint32_t buffer_channels = buffer->mNumberChannels;
        uint32_t bytes_per_frame = buffer_channels * context->input_format.bytes_per_sample;
        if (buffer_channels == 0 || bytes_per_frame == 0) return noErr;
        uint32_t available = buffer->mDataByteSize / bytes_per_frame;
        if (available < frames) frames = available;
    }
    if (frames == UINT32_MAX || frames == 0) return noErr;
    uint64_t start = atomic_fetch_add_explicit(&context->captured_frames, frames, memory_order_relaxed);
    if (start + frames > kMaxCaptureFrames) {
        atomic_fetch_add_explicit(&context->capture_overflows, 1, memory_order_relaxed);
        return noErr;
    }
    if (input_time && (input_time->mFlags & kAudioTimeStampSampleTimeValid) == 0) {
        atomic_fetch_add_explicit(&context->missing_input_buffers, 1, memory_order_relaxed);
    }
    for (UInt32 frame = 0; frame < frames; frame++) {
        float values[2] = { 0.0f, 0.0f };
        UInt32 channel_index = 0;
        for (UInt32 buffer_index = 0; buffer_index < input->mNumberBuffers; buffer_index++) {
            const AudioBuffer *buffer = &input->mBuffers[buffer_index];
            if (!buffer->mData) {
                channel_index += buffer->mNumberChannels;
                continue;
            }
            for (UInt32 channel = 0; channel < buffer->mNumberChannels; channel++) {
                if (channel_index < 2) {
                    values[channel_index] = decode_sample(buffer->mData,
                        (size_t)frame * buffer->mNumberChannels + channel, &context->input_format);
                }
                channel_index++;
            }
        }
        context->captured[(start + frame) * 2] = values[0];
        context->captured[(start + frame) * 2 + 1] = values[1];
    }
    uint64_t completed = atomic_load_explicit(&context->completed_frames, memory_order_relaxed);
    uint64_t end = start + frames;
    while (completed < end &&
           !atomic_compare_exchange_weak_explicit(&context->completed_frames, &completed, end,
                                                  memory_order_release, memory_order_relaxed)) { }
    return noErr;
}

static void sleep_seconds(double seconds) {
    struct timespec request = { .tv_sec = (time_t)seconds,
                                .tv_nsec = (long)((seconds - (time_t)seconds) * 1e9) };
    while (nanosleep(&request, &request) != 0) { }
}

static void analyze(const LoopbackContext *context, uint64_t first_frame, uint64_t last_frame,
                    double frequency,
                    double *out_rms, double *out_amplitude, double *out_peak,
                    double *out_stereo_error, double *out_max_step) {
    uint64_t total_frames = atomic_load_explicit(&context->captured_frames, memory_order_relaxed);
    if (last_frame > total_frames) last_frame = total_frames;
    uint64_t begin = first_frame + 512;
    uint64_t end = last_frame > 512 ? last_frame - 512 : last_frame;
    if (begin >= end) { begin = first_frame; end = last_frame; }
    double sum_squares = 0.0, sin_sum = 0.0, cos_sum = 0.0;
    double peak = 0.0, stereo_error = 0.0, max_step = 0.0;
    uint64_t count = 0;
    for (uint64_t frame = begin; frame < end; frame++) {
        double left = context->captured[frame * 2];
        double right = context->captured[frame * 2 + 1];
        if (!isfinite(left) || !isfinite(right)) continue;
        double sample = (left + right) * 0.5;
        double phase = 2.0 * M_PI * frequency * (double)frame / context->input_format.format.mSampleRate;
        sin_sum += sample * sin(phase);
        cos_sum += sample * cos(phase);
        sum_squares += sample * sample;
        double absolute = fabs(sample);
        if (absolute > peak) peak = absolute;
        double difference = fabs(left - right);
        if (difference > stereo_error) stereo_error = difference;
        if (frame > begin) {
            double step = fabs(sample - context->captured[(frame - 1) * 2]);
            if (step > max_step) max_step = step;
        }
        count++;
    }
    *out_rms = count ? sqrt(sum_squares / count) : 0.0;
    *out_amplitude = count ? 2.0 * hypot(sin_sum, cos_sum) / count : 0.0;
    *out_peak = peak;
    *out_stereo_error = stereo_error;
    *out_max_step = max_step;
}

static void analyze_silence(const LoopbackContext *context, uint64_t first_frame, uint64_t last_frame,
                            double *out_rms, double *out_peak) {
    uint64_t total_frames = atomic_load_explicit(&context->captured_frames, memory_order_relaxed);
    if (last_frame > total_frames) last_frame = total_frames;
    uint64_t begin = first_frame + 512;
    if (begin > last_frame) begin = first_frame;
    double sum_squares = 0.0, peak = 0.0;
    uint64_t count = 0;
    for (uint64_t frame = begin; frame < last_frame; frame++) {
        double left = context->captured[frame * 2];
        double right = context->captured[frame * 2 + 1];
        double sample = (left + right) * 0.5;
        sum_squares += sample * sample;
        if (fabs(sample) > peak) peak = fabs(sample);
        count++;
    }
    *out_rms = count ? sqrt(sum_squares / count) : 0.0;
    *out_peak = peak;
}

static int write_wav(const char *path, const LoopbackContext *context) {
    FILE *file = fopen(path, "wb");
    if (!file) { perror("open wav"); return 1; }
    uint64_t frames = atomic_load_explicit(&context->captured_frames, memory_order_relaxed);
    if (frames > kMaxCaptureFrames) frames = kMaxCaptureFrames;
    uint32_t sample_rate = (uint32_t)context->input_format.format.mSampleRate;
    uint32_t data_bytes = (uint32_t)(frames * 2 * sizeof(int16_t));
    uint8_t header[44] = { 'R','I','F','F', 0,0,0,0, 'W','A','V','E', 'f','m','t',' ', 16,0,0,0,
                           1,0, 2,0, 0,0,0,0, 0,0,0,0, 4,0, 16,0, 'd','a','t','a', 0,0,0,0 };
    uint32_t riff_size = 36 + data_bytes, byte_rate = sample_rate * 4;
    memcpy(header + 4, &riff_size, 4); memcpy(header + 24, &sample_rate, 4);
    memcpy(header + 28, &byte_rate, 4); memcpy(header + 40, &data_bytes, 4);
    if (fwrite(header, 1, sizeof(header), file) != sizeof(header)) { fclose(file); return 1; }
    for (uint64_t index = 0; index < frames * 2; index++) {
        float value = fmaxf(-1.0f, fminf(1.0f, context->captured[index]));
        int16_t sample = (int16_t)lrintf(value * 32767.0f);
        if (fwrite(&sample, sizeof(sample), 1, file) != 1) { fclose(file); return 1; }
    }
    return fclose(file) != 0;
}

int main(int argc, char **argv) {
    const char *wav_path = argc > 1 ? argv[1] : NULL;
    LoopbackContext context = {0};
    OSStatus status = resolve_uid("CamMic2ch_2_UID", &context.output_device);
    if (status != noErr || context.output_device == kAudioObjectUnknown) {
        fprintf(stderr, "resolve hidden output UID failed OSStatus=%d device=%u\n", (int)status, context.output_device);
        return 1;
    }
    status = resolve_uid("CamMic2ch_UID", &context.input_device);
    if (status != noErr || context.input_device == kAudioObjectUnknown) {
        fprintf(stderr, "resolve public input UID failed OSStatus=%d device=%u\n", (int)status, context.input_device);
        return 1;
    }
    char output_name[256] = "", output_uid[256] = "", input_name[256] = "", input_uid[256] = "";
    query_string(context.output_device, kAudioObjectPropertyName, output_name, sizeof(output_name));
    query_string(context.output_device, kAudioDevicePropertyDeviceUID, output_uid, sizeof(output_uid));
    query_string(context.input_device, kAudioObjectPropertyName, input_name, sizeof(input_name));
    query_string(context.input_device, kAudioDevicePropertyDeviceUID, input_uid, sizeof(input_uid));
    printf("resolved output id=%u name=%s uid=%s; input id=%u name=%s uid=%s\n",
           context.output_device, output_name, output_uid, context.input_device, input_name, input_uid);
    if (strcmp(output_name, "CamMicInternalOutput") != 0 || strcmp(output_uid, "CamMic2ch_2_UID") != 0 ||
        strcmp(input_name, "CamMic") != 0 || strcmp(input_uid, "CamMic2ch_UID") != 0) {
        fprintf(stderr, "endpoint identity check failed\n");
        return 1;
    }
    if (verify_endpoint_objects(context.input_device, context.output_device) != 0) return 1;
    status = query_format(context.output_device, kAudioDevicePropertyScopeOutput, &context.output_format);
    if (status != noErr) { fprintf(stderr, "query output format failed OSStatus=%d\n", (int)status); return 1; }
    status = query_format(context.input_device, kAudioDevicePropertyScopeInput, &context.input_format);
    if (status != noErr) { fprintf(stderr, "query input format failed OSStatus=%d\n", (int)status); return 1; }
    printf("output format rate=%.0f channels=%u bits=%u flags=0x%x bytesPerFrame=%u; input format rate=%.0f channels=%u bits=%u flags=0x%x bytesPerFrame=%u\n",
           context.output_format.format.mSampleRate, context.output_format.format.mChannelsPerFrame,
           context.output_format.format.mBitsPerChannel, (unsigned)context.output_format.format.mFormatFlags,
           context.output_format.format.mBytesPerFrame, context.input_format.format.mSampleRate,
           context.input_format.format.mChannelsPerFrame, context.input_format.format.mBitsPerChannel,
           (unsigned)context.input_format.format.mFormatFlags, context.input_format.format.mBytesPerFrame);
    if (context.output_format.format.mChannelsPerFrame < 2 || context.input_format.format.mChannelsPerFrame < 2 ||
        fabs(context.output_format.format.mSampleRate - context.input_format.format.mSampleRate) > 0.5) {
        fprintf(stderr, "incompatible endpoint formats\n");
        return 1;
    }
    context.captured = calloc((size_t)kMaxCaptureFrames * 2, sizeof(float));
    if (!context.captured) return 1;
    atomic_init(&context.captured_frames, 0); atomic_init(&context.completed_frames, 0);
    atomic_init(&context.output_frames, 0);
    atomic_init(&context.output_callbacks, 0); atomic_init(&context.input_callbacks, 0);
    atomic_init(&context.missing_input_buffers, 0); atomic_init(&context.capture_overflows, 0);

    AudioDeviceIOProcID output_proc_id = NULL;
    status = AudioDeviceCreateIOProcID(context.output_device, output_proc, &context, &output_proc_id);
    if (status != noErr) {
        fprintf(stderr, "create internal output IOProc failed OSStatus=%d (0x%08x)\n", (int)status, (unsigned)status);
        free(context.captured);
        return 1;
    }
    AudioDeviceIOProcID input_proc_id = NULL;
    status = AudioDeviceCreateIOProcID(context.input_device, input_proc, &context, &input_proc_id);
    if (status != noErr) {
        fprintf(stderr, "create public input IOProc failed OSStatus=%d (0x%08x)\n", (int)status, (unsigned)status);
        AudioDeviceDestroyIOProcID(context.output_device, output_proc_id);
        free(context.captured);
        return 1;
    }

    int failed = 0;
    int output_running = 0, input_running = 0;
    context.frequency = 997.0;
    context.amplitude = 0.25f;
    atomic_store_explicit(&context.output_frames, 0, memory_order_relaxed);
    status = AudioDeviceStart(context.output_device, output_proc_id);
    if (status != noErr) {
        fprintf(stderr, "start CamMicInternalOutput failed OSStatus=%d (0x%08x)\n", (int)status, (unsigned)status);
        failed = 1;
    } else {
        output_running = 1;
    }
    if (!failed) {
        sleep_seconds(0.20);
        status = AudioDeviceStart(context.input_device, input_proc_id);
        if (status != noErr) {
            fprintf(stderr, "start CamMic public input failed OSStatus=%d (0x%08x)\n", (int)status, (unsigned)status);
            failed = 1;
        } else {
            input_running = 1;
        }
    }

    uint64_t first_tone_start = 0, first_tone_end = 0, first_silence_start = 0, first_silence_end = 0;
    uint64_t second_tone_start = 0, second_tone_end = 0, second_silence_start = 0, second_silence_end = 0;
    if (!failed) {
        sleep_seconds(0.30);
        first_tone_start = atomic_load_explicit(&context.completed_frames, memory_order_acquire);
        sleep_seconds(1.00);
        first_tone_end = atomic_load_explicit(&context.completed_frames, memory_order_acquire);
        status = AudioDeviceStop(context.output_device, output_proc_id);
        if (status != noErr) { fprintf(stderr, "stop first output phase failed OSStatus=%d\n", (int)status); failed = 1; }
        else output_running = 0;
        first_silence_start = atomic_load_explicit(&context.completed_frames, memory_order_acquire);
        sleep_seconds(0.25);
        first_silence_end = atomic_load_explicit(&context.completed_frames, memory_order_acquire);

        context.frequency = 1499.0;
        context.amplitude = 0.18f;
        atomic_store_explicit(&context.output_frames, 0, memory_order_relaxed);
        status = AudioDeviceStart(context.output_device, output_proc_id);
        if (status != noErr) {
            fprintf(stderr, "restart CamMicInternalOutput failed OSStatus=%d (0x%08x)\n", (int)status, (unsigned)status);
            failed = 1;
        } else {
            output_running = 1;
            sleep_seconds(0.30);
            second_tone_start = atomic_load_explicit(&context.completed_frames, memory_order_acquire);
            sleep_seconds(1.00);
            second_tone_end = atomic_load_explicit(&context.completed_frames, memory_order_acquire);
            status = AudioDeviceStop(context.output_device, output_proc_id);
            if (status != noErr) { fprintf(stderr, "stop second output phase failed OSStatus=%d\n", (int)status); failed = 1; }
            else output_running = 0;
            second_silence_start = atomic_load_explicit(&context.completed_frames, memory_order_acquire);
            sleep_seconds(0.25);
            second_silence_end = atomic_load_explicit(&context.completed_frames, memory_order_acquire);
        }
    }
    if (output_running) AudioDeviceStop(context.output_device, output_proc_id);
    if (input_running) AudioDeviceStop(context.input_device, input_proc_id);

    double rms=0, amplitude=0, peak=0, stereo_error=0, max_step=0;
    analyze(&context, first_tone_start, first_tone_end, 997.0, &rms, &amplitude, &peak, &stereo_error, &max_step);
    printf("known-PCM-997Hz frames=%llu outputFrames=%llu rms=%.6f toneAmplitude=%.6f peak=%.6f stereoMaxError=%.6f maxAdjacentStep=%.6f\n",
           (unsigned long long)(first_tone_end - first_tone_start),
           (unsigned long long)atomic_load_explicit(&context.output_frames, memory_order_relaxed),
           rms, amplitude, peak, stereo_error, max_step);
    if (first_tone_end - first_tone_start < 30000 || rms < 0.12 || amplitude < 0.20 || amplitude > 0.30 ||
        stereo_error > 0.01 || max_step > 0.15) {
        fprintf(stderr, "997 Hz PCM was not captured with the expected continuous stereo waveform\n");
        failed = 1;
    }
    double silence_rms=0, silence_peak=0;
    analyze_silence(&context, first_silence_start, first_silence_end, &silence_rms, &silence_peak);
    printf("output-stop silence frames=%llu rms=%.9f peak=%.9f\n",
           (unsigned long long)(first_silence_end - first_silence_start), silence_rms, silence_peak);
    if (first_silence_end - first_silence_start < 5000 || silence_peak > 0.00001) {
        fprintf(stderr, "old PCM remained audible after stopping CamMicInternalOutput\n");
        failed = 1;
    }
    double second_rms=0, second_amplitude=0, second_peak=0, second_stereo=0, second_step=0;
    analyze(&context, second_tone_start, second_tone_end, 1499.0,
            &second_rms, &second_amplitude, &second_peak, &second_stereo, &second_step);
    double stale_rms=0, stale_amplitude=0, stale_peak=0, stale_stereo=0, stale_step=0;
    analyze(&context, second_tone_start, second_tone_end, 997.0,
            &stale_rms, &stale_amplitude, &stale_peak, &stale_stereo, &stale_step);
    printf("restarted-PCM-1499Hz frames=%llu rms=%.6f toneAmplitude=%.6f peak=%.6f stereoMaxError=%.6f maxAdjacentStep=%.6f\n",
           (unsigned long long)(second_tone_end - second_tone_start), second_rms,
           second_amplitude, second_peak, second_stereo, second_step);
    printf("prior-997Hz-session leakage amplitude=%.6f (must be <0.010000)\n", stale_amplitude);
    if (second_tone_end - second_tone_start < 30000 || second_rms < 0.08 ||
        second_amplitude < 0.145 || second_amplitude > 0.215 || second_stereo > 0.01 ||
        second_step > 0.15 || stale_amplitude > 0.01) {
        fprintf(stderr, "1499 Hz PCM was not captured after output restart\n");
        failed = 1;
    }
    analyze_silence(&context, second_silence_start, second_silence_end, &silence_rms, &silence_peak);
    printf("final-stop silence frames=%llu rms=%.9f peak=%.9f\n",
           (unsigned long long)(second_silence_end - second_silence_start), silence_rms, silence_peak);
    if (second_silence_end - second_silence_start < 5000 || silence_peak > 0.00001) {
        fprintf(stderr, "old PCM remained audible after final output stop\n");
        failed = 1;
    }
    if (atomic_load_explicit(&context.capture_overflows, memory_order_relaxed) != 0 ||
        atomic_load_explicit(&context.missing_input_buffers, memory_order_relaxed) != 0) {
        fprintf(stderr, "CoreAudio input buffers were missing or capture storage overflowed\n");
        failed = 1;
    }
    if (wav_path && write_wav(wav_path, &context) != 0) {
        fprintf(stderr, "could not write captured PCM evidence to %s\n", wav_path);
        failed = 1;
    }
    AudioDeviceDestroyIOProcID(context.output_device, output_proc_id);
    free(context.captured);
    return failed ? 1 : 0;
}
