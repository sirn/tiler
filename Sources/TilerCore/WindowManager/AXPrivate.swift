import ApplicationServices
import CoreGraphics
import Darwin

// Resolved at runtime so the app doesn't crash if Apple removes the private SPI.
private let _axGetWindowFn: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError.RawValue)? = {
  // RTLD_DEFAULT is a C macro ((void *)-2) not bridged to Swift; use the raw pointer directly.
  let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)!
  guard let sym = dlsym(rtldDefault, "_AXUIElementGetWindow") else { return nil }
  return unsafeBitCast(sym, to: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError.RawValue).self)
}()

func axGetWindowID(_ element: AXUIElement) -> CGWindowID? {
  guard let fn = _axGetWindowFn else { return nil }
  var wid: CGWindowID = 0
  guard AXError(rawValue: fn(element, &wid)) == .success, wid != 0 else { return nil }
  return wid
}
