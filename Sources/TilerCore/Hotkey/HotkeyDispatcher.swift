import AppKit
import CoreGraphics

public class HotkeyDispatcher {
  public typealias ActionHandler = (Action) -> Void

  private var tap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var bindings: [KeyCombo: Action] = [:]
  private var handler: ActionHandler?

  public init() {}

  deinit {
    stop()
  }

  public func setActionHandler(_ handler: @escaping ActionHandler) {
    self.handler = handler
  }

  /// Register keybindings from a mapping of parsed actions.
  public func setBindings(_ bindings: [KeyCombo: Action]) {
    self.bindings = bindings
  }

  /// Start the CGEventTap. Requires Input Monitoring permission (prompted automatically).
  public func start() {
    guard tap == nil else { return }

    let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)

    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: CGEventMask(eventMask),
        callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
          guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
          let dispatcher = Unmanaged<HotkeyDispatcher>.fromOpaque(refcon).takeUnretainedValue()
          return dispatcher.handleEvent(proxy: proxy, type: type, event: event)
        },
        userInfo: Unmanaged.passUnretained(self).toOpaque()
      )
    else {
      tiler_log("Failed to create CGEventTap. Ensure Input Monitoring permission is granted.")
      return
    }

    self.tap = tap
    let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    self.runLoopSource = runLoopSource
    CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)

    tiler_log("Hotkey dispatcher started with \(bindings.count) bindings")
  }

  public func stop() {
    if let runLoopSource = runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
    }
    if let tap = tap {
      CFMachPortInvalidate(tap)
    }
    self.tap = nil
    self.runLoopSource = nil
  }

  private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<
    CGEvent
  >? {
    // Re-enable tap if it was disabled by the system
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let tap = self.tap {
        CGEvent.tapEnable(tap: tap, enable: true)
      }
      return Unmanaged.passUnretained(event)
    }

    guard type == .keyDown else {
      return Unmanaged.passUnretained(event)
    }

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags

    // Check if any binding matches
    for (combo, action) in bindings {
      if combo.keyCode == UInt16(keyCode)
        && combo.modifiers
          == flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
      {
        // Dispatch action on main queue
        DispatchQueue.main.async {
          self.handler?(action)
        }
        // Consume the event so it doesn't propagate to the active app
        return nil
      }
    }

    return Unmanaged.passUnretained(event)
  }
}
