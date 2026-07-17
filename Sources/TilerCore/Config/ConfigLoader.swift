import Foundation
import TOMLKit

/// Loads and parses the TOML config file from `~/.config/tiler/config.toml`.
/// Falls back to `Config.defaults` when the file is missing or invalid.
public class ConfigLoader {
  private let fileManager = FileManager.default

  public init() {}

  /// Path to the config file.
  public var configPath: String {
    let home = fileManager.homeDirectoryForCurrentUser.path
    return "\(home)/.config/tiler/config.toml"
  }

  /// Load config from file, returning defaults if file doesn't exist.
  public func load() -> Config {
    let path = configPath
    guard fileManager.fileExists(atPath: path) else {
      tiler_log("No config found at \(path), using defaults")
      return Config.defaults
    }

    do {
      let content = try String(contentsOfFile: path, encoding: .utf8)
      let toml = try TOMLTable(string: content)
      return parseConfig(from: toml)
    } catch {
      tiler_log("Failed to parse config: \(error)")
      tiler_log("Using defaults")
      return Config.defaults
    }
  }

  // MARK: - Parsing

  private func parseConfig(from toml: TOMLTable) -> Config {
    var config = Config.defaults

    // [general]
    if let general = toml["general"]?.table {
      if let og = general["outer_gaps"]?.double { config.general.outerGaps = max(0, CGFloat(og)) }
      if let ig = general["inner_gaps"]?.double { config.general.innerGaps = max(0, CGFloat(ig)) }
      if let cg = general["column_gaps"]?.double { config.general.columnGaps = max(0, CGFloat(cg)) }
      if let mww = general["min_window_width"]?.double {
        config.general.minWindowWidth = max(0, CGFloat(mww))
      }
      if let mwh = general["min_window_height"]?.double {
        config.general.minWindowHeight = max(0, CGFloat(mwh))
      }
      if let fw = general["focus_column_wrap"]?.bool {
        config.general.focusColumnWrap = fw
      }
    }

    // [layout]
    if let layout = toml["layout"]?.table {
      if let dcw = layout["default_column_width"]?.double {
        config.layout.defaultColumnWidth = min(max(CGFloat(dcw), 0.1), 1.0)
      }
      if let cfc = layout["center_focused_column"]?.string,
        let mode = CenterFocusedColumn(rawValue: cfc)
      {
        config.layout.centerFocusedColumn = mode
      }

    }

    // [workspaces]
    if let workspaces = toml["workspaces"]?.table {
      if let count = workspaces["count"]?.int { config.workspaces.count = max(1, count) }
    }

    // [[keybind]]
    if let keybindsArray = toml["keybind"]?.array {
      for element in keybindsArray {
        guard let table = element.table,
          let keys = table["keys"]?.string,
          let action = table["action"]?.string
        else { continue }
        let args = table["args"]?.array?.compactMap { $0.string } ?? []
        config.keybinds.append(KeybindConfig(keys: keys, action: action, args: args))
      }
    }

    // [[app_rule]]
    if let appRulesArray = toml["app_rule"]?.array {
      for element in appRulesArray {
        guard let table = element.table,
          let app = table["app"]?.string
        else { continue }
        let action = table["action"]?.string
        let columnWidth = table["column_width"]?.double.map { CGFloat($0) }
        config.appRules.append(AppRuleConfig(app: app, action: action, columnWidth: columnWidth))
      }
    }

    return config
  }
}
