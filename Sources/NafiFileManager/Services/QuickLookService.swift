import AppKit
import Foundation
import QuickLookUI

@MainActor
final class QuickLookService: NSObject, @preconcurrency QLPreviewPanelDataSource {
  static let shared = QuickLookService()

  private var previewItems: [NSURL] = []

  func show(urls: [URL], selected: URL?) {
    guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
    previewItems = urls.map { $0 as NSURL }
    panel.dataSource = self
    panel.reloadData()
    if let selected, let index = urls.firstIndex(of: selected) {
      panel.currentPreviewItemIndex = index
    } else {
      panel.currentPreviewItemIndex = 0
    }
    panel.makeKeyAndOrderFront(nil)
  }

  func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
    previewItems.count
  }

  func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
    previewItems[index]
  }
}
