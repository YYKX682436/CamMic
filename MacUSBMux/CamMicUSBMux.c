#include "CamMicUSBMux.h"

#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include <usbmuxd.h>

struct CamMicUSBMuxSubscription {
    usbmuxd_subscription_context_t context;
    CamMicUSBMuxEventCallback callback;
    void *user_context;
};

struct CamMicUSBMuxForwarder {
    pthread_mutex_t lock;
    unsigned int references;
    bool stopping;
    int listener;
    pthread_t accept_thread;
    bool accept_thread_started;
    uint16_t device_port;
    char udid[44];
    int active_local;
    int active_device;
};

struct CamMicUSBMuxConnectionArgument {
    CamMicUSBMuxForwarder *forwarder;
    int local;
};

static void forwarder_release(CamMicUSBMuxForwarder *forwarder)
{
    bool destroy = false;
    pthread_mutex_lock(&forwarder->lock);
    if (--forwarder->references == 0) destroy = true;
    pthread_mutex_unlock(&forwarder->lock);
    if (destroy) {
        pthread_mutex_destroy(&forwarder->lock);
        free(forwarder);
    }
}

static void usbmux_event(const usbmuxd_event_t *event, void *context)
{
    CamMicUSBMuxSubscription *subscription = context;
    if (!event || !subscription || !subscription->callback ||
        event->device.conn_type != CONNECTION_TYPE_USB || event->device.udid[0] == '\0') return;
    subscription->callback(event->event, event->device.udid, subscription->user_context);
}

CamMicUSBMuxSubscription *cammic_usbmux_subscribe(
    CamMicUSBMuxEventCallback callback,
    void *context,
    int *error_code
)
{
    if (error_code) *error_code = 0;
    if (!callback) {
        if (error_code) *error_code = EINVAL;
        return NULL;
    }
    CamMicUSBMuxSubscription *subscription = calloc(1, sizeof(*subscription));
    if (!subscription) {
        if (error_code) *error_code = ENOMEM;
        return NULL;
    }
    subscription->callback = callback;
    subscription->user_context = context;
    int result = usbmuxd_events_subscribe(&subscription->context, usbmux_event, subscription);
    if (result < 0) {
        if (error_code) *error_code = -result;
        free(subscription);
        return NULL;
    }
    return subscription;
}

void cammic_usbmux_unsubscribe(CamMicUSBMuxSubscription *subscription)
{
    if (!subscription) return;
    usbmuxd_events_unsubscribe(subscription->context);
    free(subscription);
}

int cammic_usbmux_copy_usb_devices(CamMicUSBMuxDeviceCallback callback, void *context)
{
    if (!callback) return -EINVAL;
    usbmuxd_device_info_t *devices = NULL;
    int count = usbmuxd_get_device_list(&devices);
    if (count < 0) return count;
    for (int index = 0; index < count; ++index) {
        if (devices[index].conn_type == CONNECTION_TYPE_USB && devices[index].udid[0] != '\0') {
            callback(devices[index].udid, context);
        }
    }
    usbmuxd_device_list_free(&devices);
    return count;
}

static int connect_usb_device(const char *udid, uint16_t port)
{
    usbmuxd_device_info_t device;
    memset(&device, 0, sizeof(device));
    int found = usbmuxd_get_device_by_udid(udid, &device);
    if (found != 1 || device.conn_type != CONNECTION_TYPE_USB) return -ENODEV;
    return usbmuxd_connect(device.handle, port);
}

struct ByteBuffer {
    unsigned char bytes[65536];
    size_t start;
    size_t end;
};

static size_t buffer_size(const struct ByteBuffer *buffer)
{
    return buffer->end - buffer->start;
}

static size_t buffer_space(struct ByteBuffer *buffer)
{
    if (buffer->start > 0 && buffer->end == sizeof(buffer->bytes)) {
        size_t length = buffer_size(buffer);
        memmove(buffer->bytes, buffer->bytes + buffer->start, length);
        buffer->start = 0;
        buffer->end = length;
    }
    return sizeof(buffer->bytes) - buffer->end;
}

static void buffer_consume(struct ByteBuffer *buffer, size_t count)
{
    buffer->start += count;
    if (buffer->start == buffer->end) buffer->start = buffer->end = 0;
}

static int set_nonblocking_socket_options(int descriptor)
{
    int flags = fcntl(descriptor, F_GETFL, 0);
    if (flags < 0 || fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) < 0) return -1;
    int enabled = 1;
    (void)setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
    (void)setsockopt(descriptor, IPPROTO_TCP, TCP_NODELAY, &enabled, sizeof(enabled));
    return 0;
}

static bool is_stopping(CamMicUSBMuxForwarder *forwarder)
{
    pthread_mutex_lock(&forwarder->lock);
    bool stopping = forwarder->stopping;
    pthread_mutex_unlock(&forwarder->lock);
    return stopping;
}

static void relay(int local, int device, CamMicUSBMuxForwarder *forwarder)
{
    if (set_nonblocking_socket_options(local) < 0 || set_nonblocking_socket_options(device) < 0) return;
    struct ByteBuffer local_to_device = {0};
    struct ByteBuffer device_to_local = {0};
    while (!is_stopping(forwarder)) {
        struct pollfd descriptors[2] = {
            { .fd = local, .events = (short)((buffer_space(&local_to_device) ? POLLIN : 0) |
                (buffer_size(&device_to_local) ? POLLOUT : 0)) },
            { .fd = device, .events = (short)((buffer_space(&device_to_local) ? POLLIN : 0) |
                (buffer_size(&local_to_device) ? POLLOUT : 0)) }
        };
        int result = poll(descriptors, 2, 500);
        if (result < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (result == 0) continue;
        if ((descriptors[0].revents | descriptors[1].revents) & (POLLERR | POLLNVAL)) break;

        if (descriptors[0].revents & POLLIN) {
            size_t space = buffer_space(&local_to_device);
            ssize_t amount = recv(local, local_to_device.bytes + local_to_device.end, space, 0);
            if (amount <= 0) break;
            local_to_device.end += (size_t)amount;
        }
        if (descriptors[1].revents & POLLIN) {
            size_t space = buffer_space(&device_to_local);
            ssize_t amount = recv(device, device_to_local.bytes + device_to_local.end, space, 0);
            if (amount <= 0) break;
            device_to_local.end += (size_t)amount;
        }
        if ((descriptors[1].revents & POLLOUT) && buffer_size(&local_to_device)) {
            ssize_t amount = send(device, local_to_device.bytes + local_to_device.start,
                buffer_size(&local_to_device), 0);
            if (amount < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) break;
            if (amount > 0) buffer_consume(&local_to_device, (size_t)amount);
        }
        if ((descriptors[0].revents & POLLOUT) && buffer_size(&device_to_local)) {
            ssize_t amount = send(local, device_to_local.bytes + device_to_local.start,
                buffer_size(&device_to_local), 0);
            if (amount < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) break;
            if (amount > 0) buffer_consume(&device_to_local, (size_t)amount);
        }
        if ((descriptors[0].revents | descriptors[1].revents) & POLLHUP) break;
    }
}

static void *forward_connection(void *argument)
{
    struct CamMicUSBMuxConnectionArgument *connection = argument;
    CamMicUSBMuxForwarder *forwarder = connection->forwarder;
    int local = connection->local;
    free(connection);

    int device = connect_usb_device(forwarder->udid, forwarder->device_port);
    pthread_mutex_lock(&forwarder->lock);
    bool stopping = forwarder->stopping;
    if (!stopping && device >= 0) forwarder->active_device = device;
    pthread_mutex_unlock(&forwarder->lock);

    if (device >= 0 && !stopping) relay(local, device, forwarder);
    if (device >= 0) usbmuxd_disconnect(device);
    close(local);

    pthread_mutex_lock(&forwarder->lock);
    if (forwarder->active_local == local) {
        forwarder->active_local = -1;
        forwarder->active_device = -1;
    }
    pthread_mutex_unlock(&forwarder->lock);
    forwarder_release(forwarder);
    return NULL;
}

static void *accept_connections(void *argument)
{
    CamMicUSBMuxForwarder *forwarder = argument;
    for (;;) {
        pthread_mutex_lock(&forwarder->lock);
        bool stopping = forwarder->stopping;
        int listener = forwarder->listener;
        pthread_mutex_unlock(&forwarder->lock);
        if (stopping || listener < 0) break;

        struct pollfd descriptor = { .fd = listener, .events = POLLIN };
        int result = poll(&descriptor, 1, 500);
        if (result < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (result == 0) continue;
        if (descriptor.revents & (POLLERR | POLLHUP | POLLNVAL)) break;
        if (!(descriptor.revents & POLLIN)) continue;

        int local = accept(listener, NULL, NULL);
        if (local < 0) {
            if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) continue;
            break;
        }
        (void)fcntl(local, F_SETFD, FD_CLOEXEC);

        pthread_mutex_lock(&forwarder->lock);
        bool reject = forwarder->stopping || forwarder->active_local >= 0;
        struct CamMicUSBMuxConnectionArgument *connection = reject ? NULL : malloc(sizeof(*connection));
        if (!reject && connection) {
            connection->forwarder = forwarder;
            connection->local = local;
            forwarder->active_local = local;
            forwarder->active_device = -1;
            ++forwarder->references;
        }
        pthread_mutex_unlock(&forwarder->lock);
        if (reject || !connection) {
            close(local);
            free(connection);
            continue;
        }

        pthread_t worker;
        if (pthread_create(&worker, NULL, forward_connection, connection) != 0) {
            pthread_mutex_lock(&forwarder->lock);
            forwarder->active_local = -1;
            forwarder->active_device = -1;
            pthread_mutex_unlock(&forwarder->lock);
            close(local);
            free(connection);
            forwarder_release(forwarder);
            continue;
        }
        pthread_detach(worker);
    }

    pthread_mutex_lock(&forwarder->lock);
    int listener = forwarder->listener;
    forwarder->listener = -1;
    pthread_mutex_unlock(&forwarder->lock);
    if (listener >= 0) close(listener);
    forwarder_release(forwarder);
    return NULL;
}

CamMicUSBMuxForwarder *cammic_usbmux_forwarder_start(
    const char *udid,
    uint16_t device_port,
    uint16_t *local_port,
    int *error_code
)
{
    if (error_code) *error_code = 0;
    if (!udid || !*udid || strlen(udid) >= sizeof(((CamMicUSBMuxForwarder *)0)->udid) ||
        !local_port || device_port == 0) {
        if (error_code) *error_code = EINVAL;
        return NULL;
    }
    CamMicUSBMuxForwarder *forwarder = calloc(1, sizeof(*forwarder));
    if (!forwarder) {
        if (error_code) *error_code = ENOMEM;
        return NULL;
    }
    if (pthread_mutex_init(&forwarder->lock, NULL) != 0) {
        if (error_code) *error_code = EAGAIN;
        free(forwarder);
        return NULL;
    }
    forwarder->references = 2; // Owner plus the accept loop.
    forwarder->listener = -1;
    forwarder->active_local = -1;
    forwarder->active_device = -1;
    forwarder->device_port = device_port;
    memcpy(forwarder->udid, udid, strlen(udid) + 1);

    int listener = socket(AF_INET, SOCK_STREAM, 0);
    if (listener < 0) goto fail;
    (void)fcntl(listener, F_SETFD, FD_CLOEXEC);
    struct sockaddr_in address = {0};
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = 0;
    if (bind(listener, (struct sockaddr *)&address, sizeof(address)) < 0 || listen(listener, 2) < 0) {
        int saved = errno;
        close(listener);
        if (error_code) *error_code = saved;
        goto fail;
    }
    socklen_t address_length = sizeof(address);
    if (getsockname(listener, (struct sockaddr *)&address, &address_length) < 0) {
        int saved = errno;
        close(listener);
        if (error_code) *error_code = saved;
        goto fail;
    }
    forwarder->listener = listener;
    *local_port = ntohs(address.sin_port);

    if (pthread_create(&forwarder->accept_thread, NULL, accept_connections, forwarder) != 0) {
        if (error_code) *error_code = EAGAIN;
        close(listener);
        forwarder->listener = -1;
        goto fail;
    }
    forwarder->accept_thread_started = true;
    return forwarder;

fail:
    forwarder->references = 1;
    forwarder_release(forwarder);
    return NULL;
}

void cammic_usbmux_forwarder_stop(CamMicUSBMuxForwarder *forwarder)
{
    if (!forwarder) return;
    pthread_mutex_lock(&forwarder->lock);
    forwarder->stopping = true;
    pthread_t accept_thread = forwarder->accept_thread;
    bool join_accept_thread = forwarder->accept_thread_started;
    forwarder->accept_thread_started = false;
    if (forwarder->listener >= 0) shutdown(forwarder->listener, SHUT_RDWR);
    if (forwarder->active_local >= 0) shutdown(forwarder->active_local, SHUT_RDWR);
    if (forwarder->active_device >= 0) shutdown(forwarder->active_device, SHUT_RDWR);
    pthread_mutex_unlock(&forwarder->lock);
    if (join_accept_thread && !pthread_equal(pthread_self(), accept_thread)) {
        (void)pthread_join(accept_thread, NULL);
    }
    forwarder_release(forwarder);
}
