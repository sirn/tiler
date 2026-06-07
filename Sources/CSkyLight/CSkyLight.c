#include "CSkyLight.h"

#include <dlfcn.h>
#include <string.h>
#include <unistd.h>
#include <ApplicationServices/ApplicationServices.h>  // ProcessSerialNumber, GetProcessForPID

typedef int (*set_front_fn)(ProcessSerialNumber *psn, uint32_t wid, uint32_t mode);
typedef int (*post_event_fn)(ProcessSerialNumber *psn, uint8_t *bytes);

bool tiler_focus_window(pid_t pid, uint32_t wid, uint32_t last_wid) {
    static set_front_fn set_front = NULL;
    static post_event_fn post_event = NULL;
    static bool resolved = false;

    if (!resolved) {
        void *handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY | RTLD_GLOBAL);
        if (handle) {
            set_front = (set_front_fn)dlsym(handle, "_SLPSSetFrontProcessWithOptions");
            post_event = (post_event_fn)dlsym(handle, "SLPSPostEventRecordTo");
        }
        resolved = true;
    }
    if (!set_front || !post_event) return false;

    ProcessSerialNumber psn;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (GetProcessForPID(pid, &psn) != 0) return false;
#pragma clang diagnostic pop

    // Same-app focus switch: resign the previously-focused window, then activate the new
    // one (with a 1ms gap — some apps get confused if both events arrive instantaneously).
    if (last_wid != 0 && last_wid != wid) {
        uint8_t bytes[0xf8] = {0};
        bytes[0x04] = 0xf8;
        bytes[0x08] = 0x0d;

        bytes[0x8a] = 0x02;
        memcpy(bytes + 0x3c, &last_wid, sizeof(uint32_t));
        post_event(&psn, bytes);

        usleep(1000);

        bytes[0x8a] = 0x01;
        memcpy(bytes + 0x3c, &wid, sizeof(uint32_t));
        post_event(&psn, bytes);
    }

    // kCPSUserGenerated = 0x200
    set_front(&psn, wid, 0x200);

    // Make `wid` the key window.
    uint8_t key[0xf8] = {0};
    key[0x04] = 0xf8;
    key[0x08] = 0x01;
    key[0x3a] = 0x10;
    memcpy(key + 0x3c, &wid, sizeof(uint32_t));
    memset(key + 0x20, 0xff, 0x10);
    post_event(&psn, key);

    key[0x08] = 0x02;
    post_event(&psn, key);

    return true;
}
