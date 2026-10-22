import UIKit

/// Private UIKit state: TestFlight processing may reject it (ITMS-90338).
/// If that happens, remove this file and keep only the hardware key-command path.
enum SoftwareKeyboardShift {
  @MainActor static func state() -> (shifted: Bool, automatic: Bool, locked: Bool)? {
    let active = NSSelectorFromString("activeInstance")
    guard let type = NSClassFromString("UIKeyboardImpl") as? NSObject.Type,
      type.responds(to: active),
      let keyboard = type.perform(active)?.takeUnretainedValue() as? NSObject
    else { return nil }
    func flag(_ name: String) -> Bool? {
      let selector = NSSelectorFromString(name)
      guard keyboard.responds(to: selector) else { return nil }
      // BOOL getters must not be invoked through perform (which expects an object return).
      let getter = unsafeBitCast(
        keyboard.method(for: selector), to: (@convention(c) (AnyObject, Selector) -> ObjCBool).self)
      return getter(keyboard, selector).boolValue
    }
    guard let shifted = flag("isShifted"), let automatic = flag("isAutoShifted"),
      let locked = flag("isShiftLocked")
    else { return nil }
    return (shifted, automatic, locked)
  }
}
