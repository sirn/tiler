#ifndef CSKYLIGHT_H
#define CSKYLIGHT_H

#include <sys/types.h>
#include <stdint.h>
#include <stdbool.h>

/// Force keyboard focus to window `wid` of process `pid` via the private SkyLight API
/// (the mechanism yabai uses). `last_pid` is the previously-focused window's process (0 if
/// none); `last_wid` is the previously-focused window id (0 if none). The resign-old-key
/// dance only runs when `last_pid == pid` (same app); cross-app switches are handled by the
/// front-process call. Works for windows AXRaise cannot focus, notably native macOS
/// background tabs (which it selects). Symbols are resolved lazily via dlsym; returns false
/// when unavailable so the caller can fall back to the AX path.
bool tiler_focus_window(pid_t pid, uint32_t wid, pid_t last_pid, uint32_t last_wid);

#endif
