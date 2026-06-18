import AppKit

/// A menu bar item showing occupied workspaces as a row of bordered numbers, with the
/// current workspace inverted. Clicking opens a menu with an "Exit Tiler" item.
final class StatusBarController {
  private let statusItem: NSStatusItem

  init() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.button?.imagePosition = .imageOnly
    let menu = NSMenu()
    let exitItem = NSMenuItem(
      title: "Exit Tiler",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    )
    exitItem.target = NSApplication.shared
    menu.addItem(exitItem)
    statusItem.menu = menu
  }

  /// Update the indicator to show `occupied` workspaces, drawing `current` inverted.
  func update(occupied: [Int], current: Int) {
    statusItem.button?.image = StatusBarController.indicatorImage(occupied: occupied, current: current)
  }
  /// Toggle degraded-mode display. When true, show "⚠ Grant Accessibility" as
  /// the button title (no image) so the user sees permission is pending and can
  /// still open the Exit Tiler menu. When false, clear the title and restore
  /// image-only mode; the next `update()` call sets the workspace indicator.
  func setDegradedMode(_ degraded: Bool) {
    if degraded {
      statusItem.button?.image = nil
      statusItem.button?.imagePosition = .noImage
      statusItem.button?.title = "⚠ Grant Accessibility"
    } else {
      statusItem.button?.title = ""
      statusItem.button?.imagePosition = .imageOnly
    }
  }

  private static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
  private static let attrs: [NSAttributedString.Key: Any] = [
    .font: font, .foregroundColor: NSColor.black,
  ]

  /// Render the workspace row as a template image. Each workspace is a rounded 1px box;
  /// the current one is filled with the digit knocked out so the menu bar background shows
  /// through (the inverse look). Template rendering tints it for light/dark automatically.
  private static func indicatorImage(occupied: [Int], current: Int) -> NSImage {
    let paddingX: CGFloat = 4
    let paddingY: CGFloat = 1.5
    let lineWidth: CGFloat = 1
    let gap: CGFloat = 3

    struct Box {
      let text: String
      let frameSize: NSSize
      let textSize: NSSize
      let selected: Bool
    }

    let boxes: [Box] = occupied.map { n in
      let text = "\(n)"
      let ts = (text as NSString).size(withAttributes: attrs)
      let w = ceil(ts.width) + paddingX * 2 + lineWidth
      let h = ceil(ts.height) + paddingY * 2 + lineWidth
      return Box(text: text, frameSize: NSSize(width: w, height: h), textSize: ts, selected: n == current)
    }

    guard !boxes.isEmpty else { return NSImage(size: NSSize(width: 1, height: 1)) }

    let totalWidth = boxes.reduce(0) { $0 + $1.frameSize.width } + gap * CGFloat(boxes.count - 1)
    let height = boxes.map { $0.frameSize.height }.max() ?? 0
    let size = NSSize(width: totalWidth, height: height)

    let image = NSImage(size: size, flipped: false) { _ in
      var x: CGFloat = 0
      for box in boxes {
        let boxRect = NSRect(
          x: x, y: (height - box.frameSize.height) / 2,
          width: box.frameSize.width, height: box.frameSize.height)
        let border = boxRect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let path = NSBezierPath(roundedRect: border, xRadius: 3, yRadius: 3)
        path.lineWidth = lineWidth
        let textOrigin = NSPoint(
          x: boxRect.minX + (boxRect.width - box.textSize.width) / 2,
          y: boxRect.minY + (boxRect.height - box.textSize.height) / 2)

        if box.selected {
          NSColor.black.setFill()
          path.fill()
          // Knock the digit out of the filled box so the bar background shows through.
          NSGraphicsContext.current?.compositingOperation = .destinationOut
          (box.text as NSString).draw(at: textOrigin, withAttributes: attrs)
          NSGraphicsContext.current?.compositingOperation = .sourceOver
        } else {
          NSColor.black.setStroke()
          path.stroke()
          (box.text as NSString).draw(at: textOrigin, withAttributes: attrs)
        }
        x += box.frameSize.width + gap
      }
      return true
    }
    image.isTemplate = true
    return image
  }
}
