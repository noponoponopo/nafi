import AppKit

enum WindowEventHitTesting {
  /// Returns true only when the event is inside both the passive view and the
  /// unobscured content area of its window. Local event monitors otherwise see
  /// clicks in a full-size toolbar even when the toolbar visually covers the view.
  static func contains(_ event: NSEvent, in view: NSView) -> Bool {
    guard let window = view.window, event.window === window else { return false }
    guard window.contentLayoutRect.contains(event.locationInWindow) else { return false }

    let localPoint = view.convert(event.locationInWindow, from: nil)
    return view.visibleRect.contains(localPoint)
  }
}
