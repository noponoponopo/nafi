import Foundation

enum FileNameSearchMatcher {
  private static let locale = Locale(identifier: "ja_JP")

  static func normalize(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
      locale: locale
    )
  }

  static func terms(_ value: String) -> [String] {
    normalize(value)
      .split(whereSeparator: { $0.isWhitespace })
      .map(String.init)
      .filter { !$0.isEmpty }
  }


  /// Spotlight's predicate modifiers are case/diacritic aware but do not expose
  /// NSString's width-insensitive option. Query the normalized term plus its
  /// explicit full/half-width forms, then perform the final authoritative match
  /// with `matches` so Japanese/ASCII width differences are never lost.
  static func spotlightVariants(for normalizedTerm: String) -> [String] {
    var values: [String] = []
    var seen = Set<String>()
    for candidate in [
      normalizedTerm,
      normalizedTerm.applyingTransform(.fullwidthToHalfwidth, reverse: false),
      normalizedTerm.applyingTransform(.fullwidthToHalfwidth, reverse: true),
    ].compactMap({ $0 }) {
      if seen.insert(candidate).inserted { values.append(candidate) }
    }
    return values
  }

  static func matches(normalizedCandidate: String, terms: [String]) -> Bool {
    !terms.isEmpty && terms.allSatisfy(normalizedCandidate.contains)
  }
}
