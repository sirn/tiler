import os

public extension OSLog {
    static let tiler = OSLog(subsystem: "co.cakework.Tiler", category: "tiler")
}

/// Convenience for tiler log messages. Uses .default level for persistence.
public func tiler_log(_ message: String) {
    os_log(.default, log: OSLog.tiler, "%{public}s", message)
}
