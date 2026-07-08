import Foundation
import os

extension OSLog {
  public static let tiler = OSLog(subsystem: "co.cakework.Tiler", category: "tiler")
}

/// Convenience for tiler log messages. Uses .default level for persistence.
public func tiler_log(_ message: String) {
  os_log(.default, log: OSLog.tiler, "%{public}s", message)
}

// Mutable so the menu-bar "Enable debug logging" item can toggle it at runtime;
// defaults to the TILER_DEBUG environment variable so launching with TILER_DEBUG=1
// still enables it from the start.
public var tilerDebugEnabled = ProcessInfo.processInfo.environment["TILER_DEBUG"] != nil

/// Debug-gated log for high-frequency tracing; emitted at default level only when TILER_DEBUG is set.
public func tiler_debug(_ message: String) {
  guard tilerDebugEnabled else { return }
  os_log(.default, log: OSLog.tiler, "%{public}s", message)
}
