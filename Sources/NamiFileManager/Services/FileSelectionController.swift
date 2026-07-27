import Combine
import Foundation

@MainActor
final class SelectionFlag: ObservableObject {
  @Published fileprivate(set) var isSelected: Bool

  init(isSelected: Bool = false) {
    self.isSelected = isSelected
  }
}

@MainActor
final class FileSelectionController: ObservableObject {
  private(set) var count = 0
  private(set) var primaryURL: URL?

  private(set) var selectedURLs: Set<URL> = []
  private(set) var dragURLs: [URL] = []
  private var flags: [URL: SelectionFlag] = [:]

  func contains(_ url: URL) -> Bool {
    selectedURLs.contains(url)
  }

  func flag(for url: URL) -> SelectionFlag {
    if let existing = flags[url] { return existing }
    let flag = SelectionFlag(isSelected: selectedURLs.contains(url))
    flags[url] = flag
    return flag
  }

  func replace(with urls: Set<URL>, primary: URL? = nil) {
    apply(urls, primary: primary ?? urls.first)
  }

  func toggle(_ url: URL) {
    var next = selectedURLs
    if next.remove(url) == nil {
      next.insert(url)
      apply(next, primary: url)
    } else {
      apply(next, primary: primaryURL == url ? next.first : primaryURL)
    }
  }

  func formUnion(_ urls: Set<URL>, primary: URL?) {
    apply(selectedURLs.union(urls), primary: primary ?? primaryURL)
  }

  func removeAll() {
    apply([], primary: nil)
  }

  func reset() {
    apply([], primary: nil)
    flags.removeAll(keepingCapacity: true)
  }

  func retain(_ allowed: Set<URL>, plus preserved: Set<URL> = []) {
    let next = selectedURLs.intersection(allowed).union(preserved)
    apply(next, primary: primaryURL.flatMap { next.contains($0) ? $0 : nil } ?? next.first)

    let retained = allowed.union(preserved)
    flags = flags.filter { retained.contains($0.key) || $0.value.isSelected }
  }

  private func apply(_ next: Set<URL>, primary: URL?) {
    guard next != selectedURLs || primary != primaryURL else { return }

    let changed = selectedURLs.symmetricDifference(next)
    objectWillChange.send()
    selectedURLs = next
    primaryURL = primary.flatMap { next.contains($0) ? $0 : nil } ?? next.first
    if let primaryURL {
      dragURLs = [primaryURL] + next.lazy.filter { $0 != primaryURL }
    } else {
      dragURLs = []
    }
    count = next.count

    // Only rows whose selected state actually changed are invalidated.
    for url in changed {
      flags[url]?.isSelected = next.contains(url)
    }
  }
}
