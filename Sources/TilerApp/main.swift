import AppKit
import TilerCore

// If launched with --crash-recovery, gather stranded windows from the
// previous crash and exit immediately. This is invoked by the signal
// handler via posix_spawn after a crash.
if CommandLine.arguments.contains("--crash-recovery") {
    TilerCrashRecoveryGather()
    let path = TilerCrashRecoveryFilePath()
    try? FileManager.default.removeItem(atPath: path)
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
