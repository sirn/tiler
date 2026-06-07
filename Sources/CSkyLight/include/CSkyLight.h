#ifndef CSKYLIGHT_H
#define CSKYLIGHT_H

#include <sys/types.h>
#include <stdint.h>
#include <stdbool.h>

/// Force keyboard focus to window `wid` of process `pid` via the private SkyLight API
/// (the same mechanism yabai uses). Works for windows AXRaise cannot focus — notably
/// native macOS background tabs, which this selects. Symbols are resolved lazily via
/// dlsym; returns false when unavailable so the caller can fall back to the AX path.
bool tiler_focus_window(pid_t pid, uint32_t wid);

#endif
