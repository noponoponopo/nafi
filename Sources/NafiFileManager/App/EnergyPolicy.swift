import AppKit
import SwiftUI

enum EnergyPreferenceKey {
  /// Default-on because Nafi is a file manager that is commonly left open all day.
  /// Users can opt back into live materials and eager previews in Settings.
  static let ultraEfficiency = "Nafi.energy.ultraEfficiency"
}

enum NafiChromeSurface {
  case bar
  case sidebar
  case footer
}

private struct NafiChromeBackgroundModifier: ViewModifier {
  @AppStorage(EnergyPreferenceKey.ultraEfficiency) private var ultraEfficiency = true
  let surface: NafiChromeSurface

  @ViewBuilder
  func body(content: Content) -> some View {
    if ultraEfficiency {
      content.background(staticColor)
    } else {
      switch surface {
      case .bar:
        content.background(.bar)
      case .sidebar:
        content.background(.regularMaterial)
      case .footer:
        content.background(.ultraThinMaterial)
      }
    }
  }

  private var staticColor: Color {
    switch surface {
    case .bar:
      Color(nsColor: .windowBackgroundColor)
    case .sidebar:
      Color(nsColor: .controlBackgroundColor)
    case .footer:
      Color(nsColor: .controlBackgroundColor)
    }
  }
}

extension View {
  /// Avoids live backdrop sampling in the main browser chrome while keeping an
  /// opt-out for users who prefer vibrancy. Opaque system colors are essentially
  /// free while the window is idle and still adapt to light/dark appearance.
  func nafiChromeBackground(_ surface: NafiChromeSurface) -> some View {
    modifier(NafiChromeBackgroundModifier(surface: surface))
  }
}

enum NafiEnergyPolicy {
  /// Automatic thumbnails are intentionally all-or-nothing in ultra-efficiency mode.
  /// Even local Quick Look thumbnailing performs decode, IPC and cache writes; cloud-backed
  /// URLs can additionally materialize data. Manual Quick Look/open remains on demand.
  static func suppressAutomaticThumbnail(ultraEfficiency: Bool) -> Bool {
    ultraEfficiency
  }
}
