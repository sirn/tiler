import CoreGraphics
import Foundation

// MARK: - Top-level Config

/// Root configuration type that mirrors the TOML config file structure.
public struct Config {
  public var general: GeneralConfig
  public var layout: LayoutConfig
  public var workspaces: WorkspacesConfig
  public var keybinds: [KeybindConfig]
  public var appRules: [AppRuleConfig]

  public static let defaults = Config(
    general: GeneralConfig(),
    layout: LayoutConfig(),
    workspaces: WorkspacesConfig(),
    keybinds: [],
    appRules: []
  )

  public init(
    general: GeneralConfig = GeneralConfig(),
    layout: LayoutConfig = LayoutConfig(),
    workspaces: WorkspacesConfig = WorkspacesConfig(),
    keybinds: [KeybindConfig] = [],
    appRules: [AppRuleConfig] = []
  ) {
    self.general = general
    self.layout = layout
    self.workspaces = workspaces
    self.keybinds = keybinds
    self.appRules = appRules
  }
}

// MARK: - General

/// [general] section — gap sizes in points.
public struct GeneralConfig: Codable {
  public var outerGaps: CGFloat
  public var innerGaps: CGFloat
  public var columnGaps: CGFloat

  public init(outerGaps: CGFloat = 8, innerGaps: CGFloat = 6, columnGaps: CGFloat = 8) {
    self.outerGaps = outerGaps
    self.innerGaps = innerGaps
    self.columnGaps = columnGaps
  }

  enum CodingKeys: String, CodingKey {
    case outerGaps = "outer_gaps"
    case innerGaps = "inner_gaps"
    case columnGaps = "column_gaps"
  }
}

// MARK: - Layout

/// [layout] section — default column behaviour.
public struct LayoutConfig: Codable {
  public var defaultColumnWidth: CGFloat
  public var centerFocusedColumn: Bool

  public init(defaultColumnWidth: CGFloat = 0.5, centerFocusedColumn: Bool = true) {
    self.defaultColumnWidth = defaultColumnWidth
    self.centerFocusedColumn = centerFocusedColumn
  }

  enum CodingKeys: String, CodingKey {
    case defaultColumnWidth = "default_column_width"
    case centerFocusedColumn = "center_focused_column"
  }
}

// MARK: - Workspaces

/// [workspaces] section.
public struct WorkspacesConfig: Codable {
  public var count: Int

  public init(count: Int = 9) {
    self.count = count
  }
}

// MARK: - Keybind

/// A single [[keybind]] array-of-tables entry.
public struct KeybindConfig: Decodable {
  public var keys: String
  public var action: String
  public var args: [String]

  public init(keys: String, action: String, args: [String] = []) {
    self.keys = keys
    self.action = action
    self.args = args
  }

  enum CodingKeys: String, CodingKey {
    case keys, action, args
  }
}

// MARK: - App Rule

/// A single [[app_rule]] array-of-tables entry.
public struct AppRuleConfig: Decodable {
  public var app: String
  public var action: String?
  public var columnWidth: CGFloat?

  public init(app: String, action: String? = nil, columnWidth: CGFloat? = nil) {
    self.app = app
    self.action = action
    self.columnWidth = columnWidth
  }

  enum CodingKeys: String, CodingKey {
    case app, action
    case columnWidth = "column_width"
  }
}
