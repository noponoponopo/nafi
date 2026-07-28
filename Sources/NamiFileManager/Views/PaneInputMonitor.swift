import AppKit
import SwiftUI

struct PaneInputMonitor: NSViewRepresentable {
  let isActive: Bool
  let activate: () -> Void
  let moveSelection: (Int) -> Void
  let clearSelection: () -> Void
  let previewSelection: () -> Void
  let renameSelection: () -> Bool
  let canGoBack: () -> Bool
  let canGoForward: () -> Bool
  let goBack: () -> Void
  let goForward: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(
      isActive: isActive,
      activate: activate,
      moveSelection: moveSelection,
      clearSelection: clearSelection,
      previewSelection: previewSelection,
      renameSelection: renameSelection,
      canGoBack: canGoBack,
      canGoForward: canGoForward,
      goBack: goBack,
      goForward: goForward
    )
  }

  func makeNSView(context: Context) -> PassiveTrackingView {
    let view = PassiveTrackingView()
    context.coordinator.attach(to: view)
    return view
  }

  func updateNSView(_ nsView: PassiveTrackingView, context: Context) {
    context.coordinator.update(
      isActive: isActive,
      activate: activate,
      moveSelection: moveSelection,
      clearSelection: clearSelection,
      previewSelection: previewSelection,
      renameSelection: renameSelection,
      canGoBack: canGoBack,
      canGoForward: canGoForward,
      goBack: goBack,
      goForward: goForward
    )
  }

  static func dismantleNSView(_ nsView: PassiveTrackingView, coordinator: Coordinator) {
    coordinator.detach()
  }

  final class Coordinator {
    private weak var view: PassiveTrackingView?
    private var eventMonitor: Any?

    private var isActive: Bool
    private var activate: () -> Void
    private var moveSelection: (Int) -> Void
    private var clearSelection: () -> Void
    private var previewSelection: () -> Void
    private var renameSelection: () -> Bool
    private var canGoBack: () -> Bool
    private var canGoForward: () -> Bool
    private var goBack: () -> Void
    private var goForward: () -> Void

    private var horizontalAccumulator: CGFloat = 0
    private var didTriggerNavigation = false
    private var lastScrollTimestamp: TimeInterval = 0

    init(
      isActive: Bool,
      activate: @escaping () -> Void,
      moveSelection: @escaping (Int) -> Void,
      clearSelection: @escaping () -> Void,
      previewSelection: @escaping () -> Void,
      renameSelection: @escaping () -> Bool,
      canGoBack: @escaping () -> Bool,
      canGoForward: @escaping () -> Bool,
      goBack: @escaping () -> Void,
      goForward: @escaping () -> Void
    ) {
      self.isActive = isActive
      self.activate = activate
      self.moveSelection = moveSelection
      self.clearSelection = clearSelection
      self.previewSelection = previewSelection
      self.renameSelection = renameSelection
      self.canGoBack = canGoBack
      self.canGoForward = canGoForward
      self.goBack = goBack
      self.goForward = goForward
    }

    func update(
      isActive: Bool,
      activate: @escaping () -> Void,
      moveSelection: @escaping (Int) -> Void,
      clearSelection: @escaping () -> Void,
      previewSelection: @escaping () -> Void,
      renameSelection: @escaping () -> Bool,
      canGoBack: @escaping () -> Bool,
      canGoForward: @escaping () -> Bool,
      goBack: @escaping () -> Void,
      goForward: @escaping () -> Void
    ) {
      self.isActive = isActive
      self.activate = activate
      self.moveSelection = moveSelection
      self.clearSelection = clearSelection
      self.previewSelection = previewSelection
      self.renameSelection = renameSelection
      self.canGoBack = canGoBack
      self.canGoForward = canGoForward
      self.goBack = goBack
      self.goForward = goForward
    }

    func attach(to view: PassiveTrackingView) {
      self.view = view

      eventMonitor = NSEvent.addLocalMonitorForEvents(
        matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]
      ) { [weak self] event in
        guard let self else { return event }

        switch event.type {
        case .leftMouseDown, .rightMouseDown:
          if self.contains(event) { self.activate() }
          return event
        case .keyDown:
          guard self.shouldHandleKeyboardEvent(event) else { return event }
          switch event.keyCode {
          case 125:
            self.moveSelection(1)
            return nil
          case 126:
            self.moveSelection(-1)
            return nil
          case 53:
            self.clearSelection()
            return nil
          case 36,
            76
          where event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty:
            return self.renameSelection() ? nil : event
          case 49 where event.modifierFlags.intersection([.command, .option, .control]).isEmpty:
            self.previewSelection()
            return nil
          default:
            return event
          }
        case .scrollWheel:
          return self.handleScroll(event)
        default:
          return event
        }
      }
    }

    func detach() {
      if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
      eventMonitor = nil
      view = nil
    }

    deinit {
      detach()
    }

    private func shouldHandleKeyboardEvent(_ event: NSEvent) -> Bool {
      guard isActive, let window = view?.window, event.window === window else { return false }
      if window.firstResponder is NSTextView { return false }
      return true
    }

    private func contains(_ event: NSEvent) -> Bool {
      guard let view, let window = view.window, event.window === window else { return false }
      let point = view.convert(event.locationInWindow, from: nil)
      return view.bounds.contains(point)
    }

    private func handleScroll(_ event: NSEvent) -> NSEvent? {
      guard
        isActive,
        contains(event),
        event.hasPreciseScrollingDeltas,
        NSEvent.isSwipeTrackingFromScrollEventsEnabled
      else { return event }

      let horizontal = event.scrollingDeltaX
      let vertical = event.scrollingDeltaY
      guard abs(horizontal) > max(3, abs(vertical) * 1.2) else {
        resetSwipeIfNeeded(for: event)
        return event
      }

      if hasHorizontalScrollContainer(at: event.locationInWindow) {
        resetSwipe()
        return event
      }

      if event.timestamp - lastScrollTimestamp > 0.35 { resetSwipe() }
      lastScrollTimestamp = event.timestamp

      if event.phase.contains(.began) {
        resetSwipe()
        lastScrollTimestamp = event.timestamp
      }

      let deviceDelta = horizontal * (event.isDirectionInvertedFromDevice ? -1 : 1)
      horizontalAccumulator += deviceDelta

      guard !didTriggerNavigation else {
        resetSwipeIfNeeded(for: event)
        return event
      }

      let threshold: CGFloat = 72
      if horizontalAccumulator >= threshold, canGoForward() {
        didTriggerNavigation = true
        goForward()
        return nil
      }
      if horizontalAccumulator <= -threshold, canGoBack() {
        didTriggerNavigation = true
        goBack()
        return nil
      }

      resetSwipeIfNeeded(for: event)
      return event
    }

    private func resetSwipeIfNeeded(for event: NSEvent) {
      if event.phase.contains(.ended) || event.phase.contains(.cancelled)
        || event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled)
      {
        resetSwipe()
      }
    }

    private func resetSwipe() {
      horizontalAccumulator = 0
      didTriggerNavigation = false
    }

    private func hasHorizontalScrollContainer(at windowPoint: NSPoint) -> Bool {
      guard let window = view?.window, let contentView = window.contentView else { return false }
      let contentPoint = contentView.convert(windowPoint, from: nil)
      guard var current = contentView.hitTest(contentPoint) else { return false }

      while true {
        if let scrollView = current as? NSScrollView,
          let documentView = scrollView.documentView,
          documentView.frame.width > scrollView.contentView.bounds.width + 8
        {
          return true
        }
        guard let parent = current.superview else { break }
        current = parent
      }
      return false
    }
  }
}

final class PassiveTrackingView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
