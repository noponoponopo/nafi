import SwiftUI

struct SidebarReorderDropModifier: ViewModifier {
  @ObservedObject var model: SidebarModel
  let beforeID: UUID
  @State private var targeted = false

  func body(content: Content) -> some View {
    content
      .overlay(alignment: .top) {
        if targeted {
          SidebarDropPositionLine()
            .padding(.horizontal, 8)
            .offset(y: -2)
            .allowsHitTesting(false)
        }
      }
      .onDrop(of: [.nafiSidebarFavorite], isTargeted: $targeted) { providers in
        guard DragPayloadProvider.containsSidebarFavoritePayload(in: providers) else {
          return false
        }
        DragPayloadProvider.loadSidebarFavoritePayload(from: providers) { payload in
          guard let payload else { return }
          Task { @MainActor in
            model.move(itemID: payload.favoriteID, before: beforeID)
          }
        }
        return true
      }
  }
}

struct SidebarReorderEndDropOverlay: ViewModifier {
  @ObservedObject var model: SidebarModel
  let isEnabled: Bool
  @State private var targeted = false

  func body(content: Content) -> some View {
    content.overlay(alignment: .bottom) {
      if isEnabled {
        Rectangle()
          .fill(Color.clear)
          .frame(height: 10)
          .contentShape(Rectangle())
          .overlay(alignment: .bottom) {
            if targeted {
              SidebarDropPositionLine()
                .padding(.horizontal, 8)
                .allowsHitTesting(false)
            }
          }
          .onDrop(of: [.nafiSidebarFavorite], isTargeted: $targeted) { providers in
            guard DragPayloadProvider.containsSidebarFavoritePayload(in: providers) else {
              return false
            }
            DragPayloadProvider.loadSidebarFavoritePayload(from: providers) { payload in
              guard let payload else { return }
              Task { @MainActor in
                model.moveToEnd(itemID: payload.favoriteID)
              }
            }
            return true
          }
      }
    }
  }
}

private struct SidebarDropPositionLine: View {
  var body: some View {
    RoundedRectangle(cornerRadius: 2, style: .continuous)
      .fill(Color.accentColor)
      .frame(height: 3)
  }
}
