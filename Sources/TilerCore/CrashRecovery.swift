import AppKit
import ApplicationServices
import CoreGraphics
import Darwin

// Recovery file path

public func TilerCrashRecoveryFilePath() -> String {
    let appSupport = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask).first!
    let dir = appSupport.appendingPathComponent("tiler")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("crash_recovery.json").path
}

// Signal handler
//
// The signal handler must be async-signal-safe. We use posix_spawn to
// relaunch the Tiler binary with a --crash-recovery flag so a fresh
// process performs the window gathering (the crashed process's state
// may be corrupt). The parent restores the default handler and
// re-raises the signal so the crash proceeds normally.

private let crashSignals: [Int32] = [
    SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE, SIGTRAP, SIGPIPE
]

// The binary path is captured at install time so the signal handler
// can posix_spawn it without accessing Swift runtime state.
private var crashRecoveryBinaryPath: [CChar] = []
private var crashRecoveryArg: [CChar] = Array("--crash-recovery".utf8.map { CChar($0) }) + [0]

private func crashSignalHandler(_ sig: Int32) {
    crashRecoveryBinaryPath.withUnsafeMutableBufferPointer { binaryPathBuf in
        crashRecoveryArg.withUnsafeMutableBufferPointer { argBuf in
            var argv: [UnsafeMutablePointer<CChar>?] = [
                binaryPathBuf.baseAddress,
                argBuf.baseAddress,
                nil
            ]
            var pid: pid_t = 0
            // posix_spawnp is async-signal-safe per POSIX.
            _ = argv.withUnsafeMutableBufferPointer { argvBuf in
                posix_spawnp(&pid, argvBuf.baseAddress!.pointee, nil, nil, argvBuf.baseAddress, nil)
            }
        }
    }

    signal(sig, SIG_DFL)
    raise(sig)
}

public func TilerInstallCrashHandlers() {
    // Capture the binary path so the signal handler can relaunch it.
    let binaryPath = CommandLine.arguments.first ?? ""
    crashRecoveryBinaryPath = Array(binaryPath.utf8.map { CChar($0) }) + [0]

    for sig in crashSignals {
        signal(sig, crashSignalHandler)
    }
}

// Window gathering (runs in a fresh process after crash)

public func TilerCrashRecoveryGather() {
    let path = TilerCrashRecoveryFilePath()
    guard FileManager.default.fileExists(atPath: path) else { return }

    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let pidArray = try? JSONSerialization.jsonObject(with: data) as? [Int]
    else { return }

    let targetPIDs = Set(pidArray)
    guard !targetPIDs.isEmpty else { return }

    guard let mainScreen = NSScreen.screens.first else { return }
    let visibleFrame = mainScreen.visibleFrame
    let screenHeight = mainScreen.frame.height

    guard let windowList = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
    ) as? [[String: Any]]
    else { return }

    // Resolve _AXUIElementGetWindow at runtime.
    let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)!
    guard let sym = dlsym(rtldDefault, "_AXUIElementGetWindow") else { return }
    let axGetWindowID: @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError.RawValue =
        unsafeBitCast(sym, to: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError.RawValue).self)

    for info in windowList {
        guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
              targetPIDs.contains(Int(ownerPID))
        else { continue }
        guard let layer = info[kCGWindowLayer as String] as? Int, layer <= 0 else { continue }
        guard let wid = info[kCGWindowNumber as String] as? CGWindowID else { continue }
        guard let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat]
        else { continue }

        let bx = boundsDict["X"] ?? 0
        let by = boundsDict["Y"] ?? 0
        let bw = boundsDict["Width"] ?? 0
        let bh = boundsDict["Height"] ?? 0

        // CG bounds are top-left origin; convert to Cocoa bottom-left.
        let cocoaX = bx
        let cocoaY = screenHeight - by - bh
        let windowFrame = NSRect(x: cocoaX, y: cocoaY, width: bw, height: bh)

        // Skip if already fully visible on the main screen.
        if visibleFrame.contains(windowFrame) { continue }

        var target = windowFrame

        let intersects = windowFrame.intersects(visibleFrame)

        if intersects {
            // Partially visible: snap to the nearest edge.
            if target.minX < visibleFrame.minX {
                target.origin.x = visibleFrame.minX
            } else if target.maxX > visibleFrame.maxX {
                target.origin.x = visibleFrame.maxX - target.width
            }
            if target.minY < visibleFrame.minY {
                target.origin.y = visibleFrame.minY
            } else if target.maxY > visibleFrame.maxY {
                target.origin.y = visibleFrame.maxY - target.height
            }
        } else {
            // Not visible at all: center on the main screen.
            target.origin.x = visibleFrame.midX - target.width / 2.0
            target.origin.y = visibleFrame.midY - target.height / 2.0
        }

        if target == windowFrame { continue }

        let appElement = AXUIElementCreateApplication(ownerPID)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement]
        else { continue }

        for axWindow in axWindows {
            var axWid: CGWindowID = 0
            guard AXError(rawValue: axGetWindowID(axWindow, &axWid)) == .success,
                  axWid == wid
            else { continue }

            // Set position (AX uses top-left origin), then size, then position again.
            var axPos = CGPoint(x: target.origin.x, y: screenHeight - target.origin.y - target.height)
            if let posValue = AXValueCreate(.cgPoint, &axPos) {
                AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, posValue)
            }
            var axSize = target.size
            if let sizeValue = AXValueCreate(.cgSize, &axSize) {
                AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeValue)
            }
            if let posValue = AXValueCreate(.cgPoint, &axPos) {
                AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, posValue)
            }
            break
        }
    }
}
