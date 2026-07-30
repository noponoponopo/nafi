import Foundation

enum SyncMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case update
  case mirror
  case bidirectional

  var id: String { rawValue }
  var label: String {
    switch self {
    case .update: "追加・更新"
    case .mirror: "ミラー"
    case .bidirectional: "双方向"
    }
  }

  var description: String {
    switch self {
    case .update: "コピー先の余分な項目は削除しません。"
    case .mirror: "コピー先をコピー元と一致させます。余分な項目は削除対象です。"
    case .bidirectional: "双方の変更を反映し、競合は停止して確認します。"
    }
  }
}

enum SyncTrigger: String, Codable, CaseIterable, Identifiable, Sendable {
  case manual
  case continuous
  case hourly
  case daily

  var id: String { rawValue }
  var label: String {
    switch self {
    case .manual: "手動"
    case .continuous: "変更を集約して随時"
    case .hourly: "1時間ごと"
    case .daily: "1日ごと"
    }
  }
}

struct SavedSyncProfile: Identifiable, Codable, Hashable, Sendable {
  var id = UUID()
  var name: String
  var source: URL
  var destination: URL
  var mode: SyncMode = .update
  var trigger: SyncTrigger = .manual
  var enabled = true
  var includeRules: [String] = []
  var excludeRules: [String] = [".DS_Store", ".Trash/**"]
  var maxDeleteCount = 100
  var maxDeleteRatio = 0.20
  var stableForSeconds: Double = 8
  var largeFileThresholdBytes: Int64 = 512 * 1_024 * 1_024
  var fullReconciliationInterval: TimeInterval = 6 * 60 * 60
  var incrementalBatchThreshold: Int = 250
  var maxConcurrentIncrementalTransfers: Int = 3
  var bisyncInitialized = false
  var bisyncStateSignature: String?
  var lastRunAt: Date?
  var lastSuccessfulRunAt: Date?

  mutating func clamp() {
    name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256))
    maxDeleteCount = min(max(maxDeleteCount, 0), 1_000_000)
    if !maxDeleteRatio.isFinite { maxDeleteRatio = 0.20 }
    if !stableForSeconds.isFinite { stableForSeconds = 8 }
    if !fullReconciliationInterval.isFinite { fullReconciliationInterval = 6 * 60 * 60 }
    maxDeleteRatio = min(max(maxDeleteRatio, 0), 1)
    stableForSeconds = min(max(stableForSeconds, 1), 3_600)
    largeFileThresholdBytes = min(max(largeFileThresholdBytes, 1 * 1_024 * 1_024), 16 * 1_024 * 1_024 * 1_024)
    fullReconciliationInterval = min(max(fullReconciliationInterval, 15 * 60), 30 * 24 * 60 * 60)
    incrementalBatchThreshold = min(max(incrementalBatchThreshold, 25), 10_000)
    maxConcurrentIncrementalTransfers = min(max(maxConcurrentIncrementalTransfers, 1), 16)
    if mode != .bidirectional {
      bisyncInitialized = false
      bisyncStateSignature = nil
    }
    includeRules = Self.cleanRules(includeRules)
    excludeRules = Self.cleanRules(excludeRules)
  }

  private static func cleanRules(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.compactMap { raw in
      let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !value.isEmpty, value.utf8.count <= 4_096,
        !value.unicodeScalars.contains(where: { $0.value == 0 || $0 == "\r" || $0 == "\n" }),
        seen.insert(value).inserted
      else { return nil }
      return value
    }
    .prefix(10_000)
    .map { $0 }
  }
}

extension SavedSyncProfile {
  private enum CodingKeys: String, CodingKey {
    case id, name, source, destination, mode, trigger, enabled, includeRules, excludeRules
    case maxDeleteCount, maxDeleteRatio, stableForSeconds, largeFileThresholdBytes
    case fullReconciliationInterval, incrementalBatchThreshold, maxConcurrentIncrementalTransfers
    case bisyncInitialized, bisyncStateSignature, lastRunAt, lastSuccessfulRunAt
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    name = try c.decode(String.self, forKey: .name)
    source = try c.decode(URL.self, forKey: .source)
    destination = try c.decode(URL.self, forKey: .destination)
    mode = try c.decodeIfPresent(SyncMode.self, forKey: .mode) ?? .update
    trigger = try c.decodeIfPresent(SyncTrigger.self, forKey: .trigger) ?? .manual
    enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    includeRules = try c.decodeIfPresent([String].self, forKey: .includeRules) ?? []
    excludeRules = try c.decodeIfPresent([String].self, forKey: .excludeRules) ?? [".DS_Store", ".Trash/**"]
    maxDeleteCount = try c.decodeIfPresent(Int.self, forKey: .maxDeleteCount) ?? 100
    maxDeleteRatio = try c.decodeIfPresent(Double.self, forKey: .maxDeleteRatio) ?? 0.20
    stableForSeconds = try c.decodeIfPresent(Double.self, forKey: .stableForSeconds) ?? 8
    largeFileThresholdBytes = try c.decodeIfPresent(Int64.self, forKey: .largeFileThresholdBytes) ?? 512 * 1_024 * 1_024
    fullReconciliationInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .fullReconciliationInterval) ?? 6 * 60 * 60
    incrementalBatchThreshold = try c.decodeIfPresent(Int.self, forKey: .incrementalBatchThreshold) ?? 250
    maxConcurrentIncrementalTransfers = try c.decodeIfPresent(Int.self, forKey: .maxConcurrentIncrementalTransfers) ?? 3
    bisyncInitialized = try c.decodeIfPresent(Bool.self, forKey: .bisyncInitialized) ?? false
    bisyncStateSignature = try c.decodeIfPresent(String.self, forKey: .bisyncStateSignature)
    lastRunAt = try c.decodeIfPresent(Date.self, forKey: .lastRunAt)
    lastSuccessfulRunAt = try c.decodeIfPresent(Date.self, forKey: .lastSuccessfulRunAt)
    clamp()
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(name, forKey: .name)
    try c.encode(source, forKey: .source)
    try c.encode(destination, forKey: .destination)
    try c.encode(mode, forKey: .mode)
    try c.encode(trigger, forKey: .trigger)
    try c.encode(enabled, forKey: .enabled)
    try c.encode(includeRules, forKey: .includeRules)
    try c.encode(excludeRules, forKey: .excludeRules)
    try c.encode(maxDeleteCount, forKey: .maxDeleteCount)
    try c.encode(maxDeleteRatio, forKey: .maxDeleteRatio)
    try c.encode(stableForSeconds, forKey: .stableForSeconds)
    try c.encode(largeFileThresholdBytes, forKey: .largeFileThresholdBytes)
    try c.encode(fullReconciliationInterval, forKey: .fullReconciliationInterval)
    try c.encode(incrementalBatchThreshold, forKey: .incrementalBatchThreshold)
    try c.encode(maxConcurrentIncrementalTransfers, forKey: .maxConcurrentIncrementalTransfers)
    try c.encode(bisyncInitialized, forKey: .bisyncInitialized)
    try c.encodeIfPresent(bisyncStateSignature, forKey: .bisyncStateSignature)
    try c.encodeIfPresent(lastRunAt, forKey: .lastRunAt)
    try c.encodeIfPresent(lastSuccessfulRunAt, forKey: .lastSuccessfulRunAt)
  }

  var bisyncIdentity: String {
    [source.absoluteString, destination.absoluteString, includeRules.joined(separator: "\u{1F}"), excludeRules.joined(separator: "\u{1F}")].joined(separator: "\u{1E}")
  }
}

enum SyncPreviewAction: String, Codable, Sendable {
  case copy
  case update
  case delete
  case conflict
  case unchanged

  var label: String {
    switch self {
    case .copy: "追加"
    case .update: "更新"
    case .delete: "削除"
    case .conflict: "競合"
    case .unchanged: "一致"
    }
  }
}

struct SyncPreviewItem: Identifiable, Codable, Hashable, Sendable {
  let id: UUID
  let path: String
  let action: SyncPreviewAction
  let detail: String?

  init(path: String, action: SyncPreviewAction, detail: String? = nil) {
    id = UUID()
    self.path = path
    self.action = action
    self.detail = detail
  }
}

struct SyncPreview: Codable, Hashable, Sendable {
  let profileID: UUID
  let generatedAt: Date
  let items: [SyncPreviewItem]
  let totalDestinationItems: Int64
  let warnings: [String]
  let blockingReasons: [String]

  var additions: Int { items.lazy.filter { $0.action == .copy }.count }
  var updates: Int { items.lazy.filter { $0.action == .update }.count }
  var deletions: Int { items.lazy.filter { $0.action == .delete }.count }
  var conflicts: Int { items.lazy.filter { $0.action == .conflict }.count }
  var canRun: Bool { blockingReasons.isEmpty }
}

enum SyncRunPhase: String, Codable, Sendable {
  case idle
  case previewing
  case waitingForStability
  case running
  case verifying
  case completed
  case failed
  case cancelled
}

struct SyncRunStatus: Identifiable, Codable, Hashable, Sendable {
  let id: UUID
  let profileID: UUID
  var phase: SyncRunPhase
  var startedAt: Date?
  var updatedAt: Date
  var progress: TransferEngineProgress?
  var currentItem: String?
  var message: String?
  var rcloneJobID: Int64?
  var rcloneExecuteID: String?

  init(profileID: UUID) {
    id = UUID()
    self.profileID = profileID
    phase = .idle
    updatedAt = Date()
  }
}
