import Foundation
import os

extension OSLog {
  public static let tiler = OSLog(subsystem: "co.cakework.Tiler", category: "tiler")
}

/// Convenience for tiler log messages. Uses .default level for persistence.
public func tiler_log(_ message: String) {
  os_log(.default, log: OSLog.tiler, "%{public}s", message)
}

// Only emit when TILER_DEBUG is set — avoids log spam on every layout/reconcile cycle.
public let tilerDebugEnabled = ProcessInfo.processInfo.environment["TILER_DEBUG"] != nil

/// Debug-gated log for high-frequency tracing; emitted at default level only when TILER_DEBUG is set.
public func tiler_debug(_ message: String) {
  guard tilerDebugEnabled else { return }
  os_log(.default, log: OSLog.tiler, "%{public}s", message)
}
