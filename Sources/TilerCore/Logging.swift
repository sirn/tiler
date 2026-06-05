import Foundation
import os

public extension OSLog {
    static let tiler = OSLog(subsystem: "co.cakework.Tiler", category: "tiler")
}

/// Convenience for tiler log messages. Uses .default level for persistence.
public func tiler_log(_ message: String) {
    os_log(.default, log: OSLog.tiler, "%{public}s", message)
}

// Only emit when TILER_DEBUG is set — avoids log spam on every layout/reconcile cycle.
private let tilerDebugEnabled = ProcessInfo.processInfo.environment["TILER_DEBUG"] != nil

/// Debug-gated log for high-frequency tracing. Set TILER_DEBUG to enable.
public func tiler_debug(_ message: String) {
    guard tilerDebugEnabled else { return }
    os_log(.debug, log: OSLog.tiler, "%{public}s", message)
}
