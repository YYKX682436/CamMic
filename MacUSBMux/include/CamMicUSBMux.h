#ifndef CAMMIC_USB_MUX_H
#define CAMMIC_USB_MUX_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*CamMicUSBMuxEventCallback)(int event_type, const char *udid, void *context);
typedef void (*CamMicUSBMuxDeviceCallback)(const char *udid, void *context);
typedef struct CamMicUSBMuxSubscription CamMicUSBMuxSubscription;
typedef struct CamMicUSBMuxForwarder CamMicUSBMuxForwarder;

CamMicUSBMuxSubscription *cammic_usbmux_subscribe(CamMicUSBMuxEventCallback callback, void *context, int *error_code);
void cammic_usbmux_unsubscribe(CamMicUSBMuxSubscription *subscription);
int cammic_usbmux_copy_usb_devices(CamMicUSBMuxDeviceCallback callback, void *context);

CamMicUSBMuxForwarder *cammic_usbmux_forwarder_start(const char *udid, uint16_t device_port, uint16_t *local_port, int *error_code);
void cammic_usbmux_forwarder_stop(CamMicUSBMuxForwarder *forwarder);

#ifdef __cplusplus
}
#endif

#endif
