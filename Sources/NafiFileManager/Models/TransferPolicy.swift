import Foundation

enum TransferVerificationMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case automatic
  case sizeOnly
  case checksum
  case downloadAndHash

  var id: String { rawValue }
  var label: String {
    switch self {
    case .automatic: "自動"
    case .sizeOnly: "サイズ"
    case .checksum: "チェックサム"
    case .downloadAndHash: "再読込して検証"
    }
  }
}

struct ConnectionTransferPolicy: Codable, Hashable, Sendable {
  var engine: TransferEngineID = .automatic
  var parallelTransfers: Int = 4
  var parallelChecks: Int = 8
  var bandwidthLimit: String = "off"
  var verification: TransferVerificationMode = .automatic
  var retryCount: Int = 3
  var lowLevelRetryCount: Int = 10
  var preserveEmptyDirectories = true
  var useServerSideCopy = true
  var largeFileThresholdBytes: Int64 = 512 * 1_024 * 1_024
  var stabilityDelaySeconds: Double = 8

  static let `default` = ConnectionTransferPolicy()

  mutating func clamp() {
    parallelTransfers = min(max(parallelTransfers, 1), 32)
    parallelChecks = min(max(parallelChecks, 1), 64)
    retryCount = min(max(retryCount, 0), 20)
    lowLevelRetryCount = min(max(lowLevelRetryCount, 0), 100)
    largeFileThresholdBytes = min(max(largeFileThresholdBytes, 1 * 1_024 * 1_024), 16 * 1_024 * 1_024 * 1_024)
    if !stabilityDelaySeconds.isFinite { stabilityDelaySeconds = 8 }
    stabilityDelaySeconds = min(max(stabilityDelaySeconds, 1), 3_600)
    if bandwidthLimit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      bandwidthLimit = "off"
    }
  }
}
