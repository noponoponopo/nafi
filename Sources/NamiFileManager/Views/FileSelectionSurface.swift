import AppKit
import SwiftUI

private struct SelectionItemFramePreferenceKey: PreferenceKey {
  static var defaultValue: [URL: CGRect] = [:]

  static func reduce(value: inout [URL: CGRect], nextValue: () -> [URL: CGRect]) {
    value.merge(nextValue(), uniquingKeysWith: { _, newer in newer })
  }
}

extension View {
  func fileSelectionHitTarget(_ url: URL, in coordinateSpace: String) -> some View {
    background {
      GeometryReader { proxy in
        Color.clear.preference(
          key: SelectionItemFramePreferenceKey.self,
          value: [url: proxy.frame(in: .named(coordinateSpace))]
        )
      }
    }
  }
}

/// A shared Finder-style selection layer for list, matrix, column, and gallery views.
/// It updates selection on mouse-down (not gesture completion), handles context-click
/// selection, and provides drag-marquee selection without intercepting native scrolling,
/// dragging, or context menus.
struct FileSelectionSurface<Content: View>: View {
  @ObservedObject var model: FilePaneModel

  let scopeURL: URL
  let onSelect: (FileItem, NSEvent.ModifierFlags) -> Void
  private let itemForURL: (URL) -> FileItem?
  private let content: (String) -> Content

  @State private var coordinateSpaceName = UUID().uuidString
  @State private var marqueeRect: CGRect?
  @State private var marqueeStart: CGPoint?
  @State private var marqueeBaseSelection: Set<URL> = []
  @State private var marqueeModifiers: NSEvent.ModifierFlags = []
  @State private var marqueeURLs: Set<URL> = []
  @State private var marqueeAnchorURL: URL?
  @State private var pendingItemClick: FileItem?
  @State private var pendingItemModifiers: NSEvent.ModifierFlags = []

  init(
    model: FilePaneModel,
    scopeURL: URL,
    onSelect: @escaping (FileItem, NSEvent.ModifierFlags) -> Void,
    itemForURL: @escaping (URL) -> FileItem?,
    @ViewBuilder content: @escaping (String) -> Content
  ) {
    _model = ObservedObject(wrappedValue: model)
    self.scopeURL = scopeURL
    self.onSelect = onSelect
    self.itemForURL = itemForURL
    self.content = content
  }

  var body: some View {
    ZStack {
      content(coordinateSpaceName)

      if let marqueeRect {
        Rectangle()
          .fill(Color.accentColor.opacity(0.11))
          .overlay {
            Rectangle()
              .stroke(Color.accentColor.opacity(0.72), lineWidth: 1)
          }
          .frame(width: marqueeRect.width, height: marqueeRect.height)
          .position(x: marqueeRect.midX, y: marqueeRect.midY)
          .allowsHitTesting(false)
      }
    }
    .clipped()
    .coordinateSpace(name: coordinateSpaceName)
    .overlayPreferenceValue(SelectionItemFramePreferenceKey.self) { itemFrames in
      SelectionEventBridge(
        mouseDown: { point, button, modifiers in
          handleMouseDown(
            at: point,
            button: button,
            modifiers: modifiers,
            itemFrames: itemFrames
          )
        },
        mouseDragged: { point in
          handleMouseDragged(to: point, itemFrames: itemFrames)
        },
        mouseUp: handleMouseUp
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .allowsHitTesting(false)
    }
  }

  private func handleMouseDown(
    at point: CGPoint,
    button: SelectionMouseButton,
    modifiers: NSEvent.ModifierFlags,
    itemFrames: [URL: CGRect]
  ) {
    let modifiers = modifiers.intersection([.command, .shift])
    let hitURL = hitTest(point, itemFrames: itemFrames)

    switch button {
    case .context:
      pendingItemClick = nil
      pendingItemModifiers = []
      marqueeStart = nil
      marqueeRect = nil
      marqueeURLs = []
      marqueeAnchorURL = nil
      guard let hitURL, let item = itemForURL(hitURL) else { return }
      model.prepareContextMenu(for: item, scope: scopeURL)

    case .primary:
      pendingItemClick = nil
      pendingItemModifiers = []
      marqueeStart = nil
      marqueeRect = nil
      marqueeURLs = []
      marqueeAnchorURL = nil

      if let hitURL, let item = itemForURL(hitURL) {
        let selected = model.currentSelectionURLs
        let shouldDeferPlainCollapse =
          modifiers.isEmpty && selected.count > 1
          && selected.contains(item.url)
        let shouldDeferCommandToggle = modifiers == [.command] && selected.contains(item.url)

        if shouldDeferPlainCollapse || shouldDeferCommandToggle {
          pendingItemClick = item
          pendingItemModifiers = modifiers
        } else {
          onSelect(item, modifiers)
        }
        return
      }

      marqueeStart = point
      marqueeBaseSelection = model.currentSelectionURLs
      marqueeModifiers = modifiers

      if modifiers.isDisjoint(with: [.command, .shift]) {
        model.clearSelection()
      }
    }
  }

  private func handleMouseDragged(to point: CGPoint, itemFrames: [URL: CGRect]) {
    if pendingItemClick != nil {
      pendingItemClick = nil
      pendingItemModifiers = []
    }

    guard let start = marqueeStart else { return }

    let dragDistance = hypot(point.x - start.x, point.y - start.y)
    guard dragDistance >= 3 else { return }

    let rect = CGRect(
      x: min(start.x, point.x),
      y: min(start.y, point.y),
      width: abs(point.x - start.x),
      height: abs(point.y - start.y)
    )

    let intersecting = Set(
      itemFrames.compactMap { url, frame in
        rect.intersects(frame) ? url : nil
      }
    )
    let selectionChanged = intersecting != marqueeURLs
    var transaction = Transaction()
    transaction.animation = nil
    withTransaction(transaction) {
      marqueeRect = rect
      guard selectionChanged else { return }

      let anchorURL = intersecting.min { lhs, rhs in
        pointDistance(from: center(of: itemFrames[lhs]), to: point)
          < pointDistance(from: center(of: itemFrames[rhs]), to: point)
      }
      let intersectingItems = intersecting.compactMap(itemForURL)

      marqueeURLs = intersecting
      marqueeAnchorURL = anchorURL
      model.updateMarqueeSelection(
        intersecting,
        intersectingItems: intersectingItems,
        baseSelection: marqueeBaseSelection,
        modifiers: marqueeModifiers,
        primary: anchorURL
      )
    }
  }

  private func handleMouseUp() {
    if let pendingItemClick {
      onSelect(pendingItemClick, pendingItemModifiers)
      self.pendingItemClick = nil
      pendingItemModifiers = []
    }

    guard marqueeStart != nil else { return }

    if marqueeRect != nil {
      model.finishMarqueeSelection(anchor: marqueeAnchorURL, scope: scopeURL)
    }

    marqueeStart = nil
    marqueeRect = nil
    marqueeURLs = []
    marqueeAnchorURL = nil
    marqueeBaseSelection = []
    marqueeModifiers = []
  }

  private func center(of frame: CGRect?) -> CGPoint? {
    guard let frame else { return nil }
    return CGPoint(x: frame.midX, y: frame.midY)
  }

  private func pointDistance(from point: CGPoint?, to target: CGPoint) -> CGFloat {
    guard let point else { return .greatestFiniteMagnitude }
    return hypot(point.x - target.x, point.y - target.y)
  }

  private func hitTest(_ point: CGPoint, itemFrames: [URL: CGRect]) -> URL? {
    itemFrames.first(where: { $0.value.contains(point) })?.key
  }
}

enum SelectionMouseButton {
  case primary
  case context
}

private struct SelectionEventBridge: NSViewRepresentable {
  let mouseDown: (CGPoint, SelectionMouseButton, NSEvent.ModifierFlags) -> Void
  let mouseDragged: (CGPoint) -> Void
  let mouseUp: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(
      mouseDown: mouseDown,
      mouseDragged: mouseDragged,
      mouseUp: mouseUp
    )
  }

  func makeNSView(context: Context) -> FlippedPassiveView {
    let view = FlippedPassiveView()
    context.coordinator.attach(to: view)
    return view
  }

  func updateNSView(_ nsView: FlippedPassiveView, context: Context) {
    context.coordinator.update(
      mouseDown: mouseDown,
      mouseDragged: mouseDragged,
      mouseUp: mouseUp
    )
  }

  static func dismantleNSView(_ nsView: FlippedPassiveView, coordinator: Coordinator) {
    coordinator.detach()
  }

  final class Coordinator {
    private weak var view: FlippedPassiveView?
    private var monitor: Any?
    private var isTrackingPrimaryMouse = false
    private var startedInside = false

    private var mouseDown: (CGPoint, SelectionMouseButton, NSEvent.ModifierFlags) -> Void
    private var mouseDragged: (CGPoint) -> Void
    private var mouseUp: () -> Void

    init(
      mouseDown: @escaping (CGPoint, SelectionMouseButton, NSEvent.ModifierFlags) -> Void,
      mouseDragged: @escaping (CGPoint) -> Void,
      mouseUp: @escaping () -> Void
    ) {
      self.mouseDown = mouseDown
      self.mouseDragged = mouseDragged
      self.mouseUp = mouseUp
    }

    func update(
      mouseDown: @escaping (CGPoint, SelectionMouseButton, NSEvent.ModifierFlags) -> Void,
      mouseDragged: @escaping (CGPoint) -> Void,
      mouseUp: @escaping () -> Void
    ) {
      self.mouseDown = mouseDown
      self.mouseDragged = mouseDragged
      self.mouseUp = mouseUp
    }

    func attach(to view: FlippedPassiveView) {
      self.view = view
      monitor = NSEvent.addLocalMonitorForEvents(
        matching: [.leftMouseDown, .rightMouseDown, .leftMouseDragged, .leftMouseUp]
      ) { [weak self] event in
        guard let self else { return event }

        switch event.type {
        case .leftMouseDown:
          let inside = self.contains(event)
          self.startedInside = inside
          self.isTrackingPrimaryMouse = inside
          guard inside, let point = self.localPoint(for: event) else { return event }

          let isControlClick = event.modifierFlags.contains(.control)
          self.mouseDown(
            point,
            isControlClick ? .context : .primary,
            event.modifierFlags
          )
          return event

        case .rightMouseDown:
          guard self.contains(event), let point = self.localPoint(for: event) else { return event }
          self.mouseDown(point, .context, event.modifierFlags)
          return event

        case .leftMouseDragged:
          guard self.isTrackingPrimaryMouse, self.startedInside,
            let point = self.localPoint(for: event)
          else { return event }
          self.mouseDragged(point)
          return event

        case .leftMouseUp:
          if self.isTrackingPrimaryMouse {
            self.mouseUp()
          }
          self.isTrackingPrimaryMouse = false
          self.startedInside = false
          return event

        default:
          return event
        }
      }
    }

    func detach() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
      view = nil
      isTrackingPrimaryMouse = false
      startedInside = false
    }

    deinit {
      detach()
    }

    private func contains(_ event: NSEvent) -> Bool {
      guard let view, let window = view.window, event.window === window else { return false }
      let point = view.convert(event.locationInWindow, from: nil)
      return view.visibleRect.contains(point)
    }

    private func localPoint(for event: NSEvent) -> CGPoint? {
      guard let view, let window = view.window, event.window === window else { return nil }
      return view.convert(event.locationInWindow, from: nil)
    }
  }
}

private final class FlippedPassiveView: NSView {
  override var isFlipped: Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }
}
