// Read-only inventory of CoreAudio devices and the HAL objects they own.
// Build with: clang scripts/cammic-coreaudio-inspect.c -framework CoreAudio -framework CoreFoundation -o /tmp/cammic-coreaudio-inspect

#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>

static OSStatus read_property(AudioObjectID object, AudioObjectPropertySelector selector,
                              AudioObjectPropertyScope scope, UInt32 qualifier_size,
                              const void *qualifier, UInt32 *size, void *output) {
    AudioObjectPropertyAddress address = { selector, scope, kAudioObjectPropertyElementMain };
    return AudioObjectGetPropertyData(object, &address, qualifier_size, qualifier, size, output);
}

static void print_string(AudioObjectID object, AudioObjectPropertySelector selector, const char *label) {
    CFStringRef value = NULL;
    UInt32 size = sizeof(value);
    OSStatus status = read_property(object, selector, kAudioObjectPropertyScopeGlobal,
                                    0, NULL, &size, &value);
    char text[512] = "";
    if (status == noErr && value) CFStringGetCString(value, text, sizeof(text), kCFStringEncodingUTF8);
    printf(" %s=%s", label, status == noErr ? text : "<unavailable>");
    if (value) CFRelease(value);
}

static UInt32 read_uint(AudioObjectID object, AudioObjectPropertySelector selector,
                        AudioObjectPropertyScope scope, OSStatus *status_out) {
    UInt32 value = 0, size = sizeof(value);
    OSStatus status = read_property(object, selector, scope, 0, NULL, &size, &value);
    if (status_out) *status_out = status;
    return value;
}

static AudioObjectID read_object(AudioObjectID object, AudioObjectPropertySelector selector,
                                 OSStatus *status_out) {
    AudioObjectID value = kAudioObjectUnknown;
    UInt32 size = sizeof(value);
    OSStatus status = read_property(object, selector, kAudioObjectPropertyScopeGlobal,
                                    0, NULL, &size, &value);
    if (status_out) *status_out = status;
    return value;
}

static AudioObjectID translate_bundle_id(const char *bundle_id, OSStatus *status_out) {
    CFStringRef bundle = CFStringCreateWithCString(NULL, bundle_id, kCFStringEncodingUTF8);
    if (!bundle) {
        if (status_out) *status_out = kAudioHardwareUnspecifiedError;
        return kAudioObjectUnknown;
    }
    AudioObjectPropertyAddress address = { kAudioHardwarePropertyTranslateBundleIDToPlugIn,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioObjectID plugin = kAudioObjectUnknown;
    UInt32 size = sizeof(plugin);
    OSStatus status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &address,
                                                sizeof(bundle), &bundle, &size, &plugin);
    CFRelease(bundle);
    if (status_out) *status_out = status;
    return plugin;
}

static UInt32 channel_count(AudioDeviceID device, AudioObjectPropertyScope scope, OSStatus *status_out) {
    AudioObjectPropertyAddress address = { kAudioDevicePropertyStreamConfiguration, scope,
                                           kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(device, &address, 0, NULL, &size);
    if (status != noErr || size == 0) {
        if (status_out) *status_out = status;
        return 0;
    }
    AudioBufferList *list = calloc(1, size);
    if (!list) {
        if (status_out) *status_out = kAudioHardwareUnspecifiedError;
        return 0;
    }
    status = AudioObjectGetPropertyData(device, &address, 0, NULL, &size, list);
    UInt32 channels = 0;
    if (status == noErr) {
        for (UInt32 index = 0; index < list->mNumberBuffers; index++) {
            channels += list->mBuffers[index].mNumberChannels;
        }
    }
    free(list);
    if (status_out) *status_out = status;
    return channels;
}

static const char *status_text(OSStatus status, char buffer[16]) {
    if (status == noErr) return "ok";
    snprintf(buffer, 16, "%d", (int)status);
    return buffer;
}

static void inspect_children(AudioObjectID object, AudioObjectPropertySelector selector, const char *label) {
    AudioObjectPropertyAddress address = { selector, kAudioObjectPropertyScopeGlobal,
                                           kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(object, &address, 0, NULL, &size);
    char status_buffer[16];
    printf("  %s status=%s bytes=%u", label, status_text(status, status_buffer), size);
    if (status != noErr || size == 0) {
        puts("");
        return;
    }
    AudioObjectID *objects = calloc(1, size);
    if (!objects) {
        puts(" allocation-failed");
        return;
    }
    status = AudioObjectGetPropertyData(object, &address, 0, NULL, &size, objects);
    printf(" read=%s count=%u\n", status_text(status, status_buffer), (unsigned)(size / sizeof(*objects)));
    if (status == noErr) {
        UInt32 count = size / sizeof(*objects);
        for (UInt32 index = 0; index < count; index++) {
            OSStatus owner_status = noErr, class_status = noErr;
            AudioObjectID owner = read_object(objects[index], kAudioObjectPropertyOwner, &owner_status);
            UInt32 class_id = read_uint(objects[index], kAudioObjectPropertyClass,
                                        kAudioObjectPropertyScopeGlobal, &class_status);
            printf("   id=%u class=%08x owner=%s%u", objects[index], class_id,
                   owner_status == noErr ? "" : "?", owner);
            print_string(objects[index], kAudioObjectPropertyName, "name");
            printf(" ownerStatus=%s classStatus=%s\n", status_text(owner_status, status_buffer),
                   status_text(class_status, status_buffer));
        }
    }
    free(objects);
}

static void inspect_streams(AudioDeviceID device, AudioObjectPropertyScope scope, const char *label) {
    AudioObjectPropertyAddress address = { kAudioDevicePropertyStreams, scope,
                                           kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(device, &address, 0, NULL, &size);
    char status_buffer[16];
    printf("  %s-streams status=%s bytes=%u", label, status_text(status, status_buffer), size);
    if (status != noErr || size == 0) {
        puts("");
        return;
    }
    AudioStreamID *streams = calloc(1, size);
    if (!streams) {
        puts(" allocation-failed");
        return;
    }
    status = AudioObjectGetPropertyData(device, &address, 0, NULL, &size, streams);
    printf(" read=%s count=%u\n", status_text(status, status_buffer), (unsigned)(size / sizeof(*streams)));
    if (status == noErr) {
        UInt32 count = size / sizeof(*streams);
        for (UInt32 index = 0; index < count; index++) {
            OSStatus owner_status = noErr, class_status = noErr, direction_status = noErr;
            AudioObjectID owner = read_object(streams[index], kAudioObjectPropertyOwner, &owner_status);
            UInt32 class_id = read_uint(streams[index], kAudioObjectPropertyClass,
                                        kAudioObjectPropertyScopeGlobal, &class_status);
            UInt32 direction = read_uint(streams[index], kAudioStreamPropertyDirection,
                                         kAudioObjectPropertyScopeGlobal, &direction_status);
            printf("   stream=%u class=%08x owner=%s%u direction=%u", streams[index], class_id,
                   owner_status == noErr ? "" : "?", owner, direction);
            print_string(streams[index], kAudioObjectPropertyName, "name");
            printf(" ownerStatus=%s directionStatus=%s\n",
                   status_text(owner_status, status_buffer), status_text(direction_status, status_buffer));
        }
    }
    free(streams);
}

static void inspect_device(AudioDeviceID device) {
    OSStatus hidden_status = noErr, running_status = noErr, transport_status = noErr;
    OSStatus input_status = noErr, output_status = noErr, plugin_status = noErr;
    OSStatus default_status = noErr;
    UInt32 hidden = read_uint(device, kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal, &hidden_status);
    UInt32 running = read_uint(device, kAudioDevicePropertyDeviceIsRunningSomewhere,
                               kAudioObjectPropertyScopeGlobal, &running_status);
    UInt32 transport = read_uint(device, kAudioDevicePropertyTransportType,
                                 kAudioObjectPropertyScopeGlobal, &transport_status);
    UInt32 input = channel_count(device, kAudioDevicePropertyScopeInput, &input_status);
    UInt32 output = channel_count(device, kAudioDevicePropertyScopeOutput, &output_status);
    AudioObjectPropertyScope default_scope = input > 0 ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput;
    UInt32 can_be_default = read_uint(device, kAudioDevicePropertyDeviceCanBeDefaultDevice,
                                      default_scope, &default_status);
    AudioObjectID owner = read_object(device, kAudioObjectPropertyOwner, &plugin_status);
    UInt32 owner_class = read_uint(owner, kAudioObjectPropertyClass,
                                   kAudioObjectPropertyScopeGlobal, NULL);
    printf("device id=%u", device);
    print_string(device, kAudioObjectPropertyName, "name");
    print_string(device, kAudioDevicePropertyDeviceUID, "uid");
    print_string(device, kAudioObjectPropertyManufacturer, "manufacturer");
    printf(" input=%s%u output=%s%u hidden=%s%u running=%s%u canBeDefault=%s%u transport=%s0x%08x owner=%s%u ownerClass=%08x",
           input_status == noErr ? "" : "?", input, output_status == noErr ? "" : "?", output,
           hidden_status == noErr ? "" : "?", hidden, running_status == noErr ? "" : "?", running,
           default_status == noErr ? "" : "?", can_be_default,
           transport_status == noErr ? "" : "?", transport, plugin_status == noErr ? "" : "?", owner, owner_class);
    puts("");
    inspect_children(device, kAudioObjectPropertyOwnedObjects, "ownedObjects");
    inspect_children(device, kAudioObjectPropertyControlList, "controlList");
    inspect_streams(device, kAudioDevicePropertyScopeInput, "input");
    inspect_streams(device, kAudioDevicePropertyScopeOutput, "output");
}

int main(void) {
    AudioObjectPropertyAddress address = { kAudioHardwarePropertyDevices,
                                            kAudioObjectPropertyScopeGlobal,
                                            kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, NULL, &size);
    if (status != noErr) {
        fprintf(stderr, "device-list-size OSStatus=%d\n", (int)status);
        return 1;
    }
    AudioDeviceID *devices = calloc(1, size);
    if (!devices) return 1;
    status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, devices);
    if (status != noErr) {
        fprintf(stderr, "device-list OSStatus=%d\n", (int)status);
        free(devices);
        return 1;
    }
    UInt32 count = size / sizeof(*devices);
    printf("CoreAudio deviceCount=%u\n", count);
    for (UInt32 index = 0; index < count; index++) inspect_device(devices[index]);
    free(devices);

    AudioObjectPropertyAddress plugins_address = { kAudioHardwarePropertyPlugInList,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 plugins_size = 0;
    status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &plugins_address, 0, NULL, &plugins_size);
    AudioObjectID *plugins = status == noErr ? calloc(1, plugins_size) : NULL;
    if (status != noErr || (plugins_size > 0 && !plugins)) {
        fprintf(stderr, "plugin-list-size OSStatus=%d bytes=%u\n", (int)status, plugins_size);
        free(plugins);
        return 1;
    }
    status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &plugins_address, 0, NULL, &plugins_size, plugins);
    UInt32 plugin_count = status == noErr ? plugins_size / sizeof(*plugins) : 0;
    printf("CoreAudio pluginCount=%u status=%d\n", plugin_count, (int)status);
    for (UInt32 index = 0; status == noErr && index < plugin_count; index++) {
        UInt32 class_id = read_uint(plugins[index], kAudioObjectPropertyClass,
                                    kAudioObjectPropertyScopeGlobal, NULL);
        printf("plugin id=%u class=%08x", plugins[index], class_id);
        print_string(plugins[index], kAudioPlugInPropertyBundleID, "bundleID");
        puts("");
        inspect_children(plugins[index], kAudioObjectPropertyOwnedObjects, "plugin-ownedObjects");
        inspect_children(plugins[index], kAudioPlugInPropertyDeviceList, "plugin-deviceList");
    }
    free(plugins);

    OSStatus cammic_plugin_status = noErr;
    AudioObjectID cammic_plugin = translate_bundle_id("com.yykx682436.CamMicAudioDriver", &cammic_plugin_status);
    char status_buffer[16];
    printf("translateBundleID=com.yykx682436.CamMicAudioDriver status=%s plugin=%u",
           status_text(cammic_plugin_status, status_buffer), cammic_plugin);
    if (cammic_plugin_status == noErr && cammic_plugin != kAudioObjectUnknown) {
        print_string(cammic_plugin, kAudioPlugInPropertyBundleID, "bundleID");
    }
    puts("");

    const AudioObjectPropertySelector defaults[] = {
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioHardwarePropertyDefaultSystemOutputDevice
    };
    const char *labels[] = { "defaultInput", "defaultOutput", "defaultSystemOutput" };
    for (int index = 0; index < 3; index++) {
        AudioObjectID id = read_object(kAudioObjectSystemObject, defaults[index], NULL);
        printf("%s id=%u", labels[index], id);
        print_string(id, kAudioObjectPropertyName, "name");
        print_string(id, kAudioDevicePropertyDeviceUID, "uid");
        puts("");
    }

    const char *uids[] = { "CamMic2ch_UID", "CamMic2ch_2_UID" };
    for (int index = 0; index < 2; index++) {
        CFStringRef uid = CFStringCreateWithCString(NULL, uids[index], kCFStringEncodingUTF8);
        AudioDeviceID resolved = kAudioObjectUnknown;
        UInt32 output_size = sizeof(resolved);
        address.mSelector = kAudioHardwarePropertyTranslateUIDToDevice;
        status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, sizeof(uid), &uid,
                                            &output_size, &resolved);
        printf("translateUID=%s status=%d device=%u\n", uids[index], (int)status, resolved);
        if (status == noErr && resolved != kAudioObjectUnknown &&
            CFStringCompare(uid, CFSTR("CamMic2ch_2_UID"), 0) == kCFCompareEqualTo) {
            inspect_device(resolved);
        }
        CFRelease(uid);
    }
    return 0;
}
