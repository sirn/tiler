#ifndef CSKYLIGHT_H
#define CSKYLIGHT_H

#include <sys/types.h>
#include <stdint.h>
#include <stdbool.h>

/// Force keyboard focus to window `wid` of process `pid` via the private SkyLight API
/// (the mechanism yabai uses). `last_wid` is the previously-focused window id (0 if none)
/// — needed so same-app focus switches resign the old key window first. Works for windows
/// AXRaise cannot focus, notably native macOS background tabs (which it selects). Symbols
/// are resolved lazily via dlsym; returns false when unavailable so the caller can fall
/// back to the AX path.
bool tiler_focus_window(pid_t pid, uint32_t wid, uint32_t last_wid);

#endif
