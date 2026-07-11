import AppKit
import Carbon
import CoreGraphics

public class HotkeyDispatcher {
  public typealias ActionHandler = (Action) -> Void

  private var bindings: [KeyCombo: Action] = [:]
  private var hotKeyRefs: [EventHotKeyRef] = []
  private var eventHandler: EventHandlerRef?

  fileprivate static let signature: FourCharCode = {
    // Build "TILR" as a FourCharCode
    let string = "TILR"
    var result: FourCharCode = 0
    for char in string.utf16 {
      result = (result << 8) + FourCharCode(char)
    }
    return result
  }()

  // Static registry so the top-level C callback can look up actions and the handler.
  // There is only ever one HotkeyDispatcher instance, so static storage is safe.
  fileprivate static var actionMap: [UInt32: Action] = [:]
  fileprivate static var nextID: UInt32 = 1
  fileprivate static var actionHandler: ActionHandler?

  public init() {}

  deinit {
    stop()
  }

  public func setActionHandler(_ handler: @escaping ActionHandler) {
    Self.actionHandler = handler
  }

  /// Register keybindings from a mapping of parsed actions.
  public func setBindings(_ bindings: [KeyCombo: Action]) {
    self.bindings = bindings
    // If we're already started, re-register with the new bindings
    if eventHandler != nil {
      stop()
      start()
    }
  }

  /// Start the Carbon hotkey event handler. Does NOT require Input Monitoring permission.
  public func start() {
    guard eventHandler == nil else { return }

    // Install one Carbon event handler for kEventHotKeyPressed
    let eventSpec = [
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard),
        eventKind: UInt32(kEventHotKeyPressed)
      )
    ]

    var handlerRef: EventHandlerRef?
    let status = InstallEventHandler(
      GetEventDispatcherTarget(),
      hotkeyEventHandlerCallback,
      eventSpec.count,
      eventSpec,
      nil,
      &handlerRef
    )
    guard status == noErr, let handlerRef else {
      tiler_log("Failed to install Carbon event handler (status \(status))")
      return
    }
    eventHandler = handlerRef

    // Register each binding as an EventHotKey
    hotKeyRefs.removeAll()
    for (combo, action) in bindings {
      let keyCode = UInt32(combo.keyCode)
      let modifiers = carbonModifiers(from: combo.modifiers)
      let id = Self.nextID
      Self.nextID &+= 1
      Self.actionMap[id] = action

      let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
      var ref: EventHotKeyRef?
      let regStatus = RegisterEventHotKey(
        keyCode,
        modifiers,
        hotKeyID,
        GetEventDispatcherTarget(),
        0,
        &ref
      )
      if regStatus == noErr, let ref {
        hotKeyRefs.append(ref)
      } else {
        tiler_log(
          "Failed to register hotkey for keyCode \(keyCode), modifiers \(modifiers) (status \(regStatus))"
        )
      }
    }

    tiler_log("Hotkey dispatcher started with \(bindings.count) bindings (Carbon)")
  }

  public func stop() {
    if let eventHandler {
      RemoveEventHandler(eventHandler)
      self.eventHandler = nil
    }
    for ref in hotKeyRefs {
      UnregisterEventHotKey(ref)
    }
    hotKeyRefs.removeAll()
    Self.actionMap.removeAll()
    Self.nextID = 0
  }
}

// MARK: - Carbon modifier conversion

private func carbonModifiers(from flags: CGEventFlags) -> UInt32 {
  var carbon: UInt32 = 0
  if flags.contains(.maskCommand) { carbon |= UInt32(cmdKey) }  // 0x0100
  if flags.contains(.maskShift) { carbon |= UInt32(shiftKey) }  // 0x0200
  if flags.contains(.maskAlternate) { carbon |= UInt32(optionKey) }  // 0x0800
  if flags.contains(.maskControl) { carbon |= UInt32(controlKey) }  // 0x1000
  return carbon
}

// MARK: - C callback (top-level function, no captures)

private func hotkeyEventHandlerCallback(
  eventHandlerCall: EventHandlerCallRef?,
  event: EventRef?,
  userData: UnsafeMutableRawPointer?
) -> OSStatus {
  guard let event else { return OSStatus(eventNotHandledErr) }

  var hotKeyID = EventHotKeyID()
  let err = GetEventParameter(
    event,
    UInt32(kEventParamDirectObject),
    UInt32(typeEventHotKeyID),
    nil,
    MemoryLayout<EventHotKeyID>.size,
    nil,
    &hotKeyID
  )
  guard err == noErr else { return err }

  guard hotKeyID.signature == HotkeyDispatcher.signature else {
    return OSStatus(eventNotHandledErr)
  }

  if let action = HotkeyDispatcher.actionMap[hotKeyID.id] {
    DispatchQueue.main.async {
      HotkeyDispatcher.actionHandler?(action)
    }
    return noErr
  }

  return OSStatus(eventNotHandledErr)
}
