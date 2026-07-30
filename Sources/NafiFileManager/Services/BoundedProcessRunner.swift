import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// Runs a subprocess without allowing its output, run time, or cancellation behavior to become
/// unbounded. Output is redirected to private temporary files so a child process cannot deadlock
/// by filling a pipe while the caller is waiting for termination.
enum BoundedProcessRunner {
  struct Result: Sendable {
    let stdout: Data
    let stderr: Data
    let terminationStatus: Int32
  }

  enum Failure: LocalizedError, Sendable {
    case invalidInput(String)
    case launch(String)
    case timedOut
    case outputLimitExceeded
    case cancelled

    var errorDescription: String? {
      switch self {
      case .invalidInput(let message): message
      case .launch(let message): message
      case .timedOut: "外部プロセスが時間内に完了しませんでした。"
      case .outputLimitExceeded: "外部プロセスの出力が安全上限を超えました。"
      case .cancelled: "処理をキャンセルしました。"
      }
    }
  }

  private final class Controller: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func install(_ process: Process) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      guard !cancelled else { return false }
      self.process = process
      return true
    }

    func cancel() {
      let process: Process?
      lock.lock()
      cancelled = true
      process = self.process
      lock.unlock()
      if process?.isRunning == true { process?.terminate() }
    }

    var isCancelled: Bool {
      lock.lock()
      defer { lock.unlock() }
      return cancelled
    }

    func clear() {
      lock.lock()
      process = nil
      lock.unlock()
    }
  }

  static func run(
    executableURL: URL,
    arguments: [String],
    standardInput: Data? = nil,
    environment: [String: String]? = nil,
    currentDirectoryURL: URL? = nil,
    timeout: TimeInterval = 120,
    maximumStandardOutputBytes: Int = 64 * 1024 * 1024,
    maximumStandardErrorBytes: Int = 4 * 1024 * 1024
  ) async throws -> Result {
    guard timeout.isFinite, timeout > 0, timeout <= 7 * 24 * 60 * 60,
      executableURL.isFileURL,
      arguments.count <= 100_000,
      boundedUTF8Size(arguments, maximum: 16 * 1024 * 1024),
      environment.map({ boundedEnvironmentSize($0, maximum: 16 * 1024 * 1024) }) ?? true,
      (0...1_024 * 1_024 * 1_024).contains(maximumStandardOutputBytes),
      (0...1_024 * 1_024 * 1_024).contains(maximumStandardErrorBytes),
      (standardInput?.count ?? 0) <= 4 * 1024 * 1024
    else {
      throw Failure.invalidInput("外部プロセスの実行条件が不正です。")
    }

    let controller = Controller()
    return try await withTaskCancellationHandler {
      try await Task.detached(priority: .userInitiated) {
        try runSynchronously(
          executableURL: executableURL,
          arguments: arguments,
          standardInput: standardInput,
          environment: environment,
          currentDirectoryURL: currentDirectoryURL,
          timeout: timeout,
          maximumStandardOutputBytes: maximumStandardOutputBytes,
          maximumStandardErrorBytes: maximumStandardErrorBytes,
          controller: controller
        )
      }.value
    } onCancel: {
      controller.cancel()
    }
  }

  private static func boundedUTF8Size<S: Sequence>(
    _ values: S,
    maximum: Int
  ) -> Bool where S.Element == String {
    var total = 0
    for value in values {
      let count = value.utf8.count
      guard count <= maximum - total else { return false }
      total += count
    }
    return true
  }

  private static func boundedEnvironmentSize(
    _ environment: [String: String],
    maximum: Int
  ) -> Bool {
    guard environment.count <= 100_000 else { return false }
    var total = 0
    for (key, value) in environment {
      guard !key.isEmpty, !key.contains("="), !key.contains("\0"), !value.contains("\0") else {
        return false
      }
      let keyCount = key.utf8.count
      let valueCount = value.utf8.count
      guard keyCount <= maximum - total else { return false }
      total += keyCount
      guard total < maximum else { return false }
      total += 1
      guard valueCount <= maximum - total else { return false }
      total += valueCount
    }
    return true
  }

  private static func runSynchronously(
    executableURL: URL,
    arguments: [String],
    standardInput: Data?,
    environment: [String: String]?,
    currentDirectoryURL: URL?,
    timeout: TimeInterval,
    maximumStandardOutputBytes: Int,
    maximumStandardErrorBytes: Int,
    controller: Controller
  ) throws -> Result {
    if controller.isCancelled { throw Failure.cancelled }

    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory.appendingPathComponent(
      "nafi-process-\(UUID().uuidString)",
      isDirectory: true
    )
    try fileManager.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    defer { try? fileManager.removeItem(at: temporaryDirectory) }

    let stdoutURL = temporaryDirectory.appendingPathComponent("stdout")
    let stderrURL = temporaryDirectory.appendingPathComponent("stderr")
    guard
      fileManager.createFile(
        atPath: stdoutURL.path,
        contents: nil,
        attributes: [.posixPermissions: 0o600]
      ),
      fileManager.createFile(
        atPath: stderrURL.path,
        contents: nil,
        attributes: [.posixPermissions: 0o600]
      )
    else {
      throw Failure.launch("外部プロセス用の一時出力を作成できませんでした。")
    }

    let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
    let stderrHandle = try FileHandle(forWritingTo: stderrURL)
    let inputHandle: FileHandle?
    if let standardInput {
      let inputURL = temporaryDirectory.appendingPathComponent("stdin")
      try standardInput.write(
        to: inputURL,
        options: [.atomic, .completeFileProtectionUnlessOpen]
      )
      try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: inputURL.path)
      inputHandle = try FileHandle(forReadingFrom: inputURL)
    } else {
      inputHandle = nil
    }
    defer {
      try? stdoutHandle.close()
      try? stderrHandle.close()
      try? inputHandle?.close()
    }

    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    process.standardOutput = stdoutHandle
    process.standardError = stderrHandle
    process.standardInput = inputHandle ?? FileHandle.nullDevice
    if let environment { process.environment = environment }
    if let currentDirectoryURL {
      guard currentDirectoryURL.isFileURL else {
        throw Failure.invalidInput("外部プロセスの作業フォルダが不正です。")
      }
      process.currentDirectoryURL = currentDirectoryURL
    }

    guard controller.install(process) else { throw Failure.cancelled }
    defer { controller.clear() }

    do {
      try process.run()
    } catch {
      throw Failure.launch(error.localizedDescription)
    }

    let timeoutNanoseconds = UInt64(timeout * 1_000_000_000)
    let start = DispatchTime.now().uptimeNanoseconds
    let deadline = start.addingReportingOverflow(timeoutNanoseconds).overflow
      ? UInt64.max
      : start + timeoutNanoseconds
    var failure: Failure?
    while process.isRunning {
      if controller.isCancelled {
        failure = .cancelled
        break
      }
      if DispatchTime.now().uptimeNanoseconds >= deadline {
        failure = .timedOut
        break
      }
      let stdoutSize = fileSize(at: stdoutURL)
      let stderrSize = fileSize(at: stderrURL)
      if stdoutSize > maximumStandardOutputBytes || stderrSize > maximumStandardErrorBytes {
        failure = .outputLimitExceeded
        break
      }
      Thread.sleep(forTimeInterval: 0.05)
    }

    if failure != nil { terminate(process) }
    process.waitUntilExit()
    try? stdoutHandle.synchronize()
    try? stderrHandle.synchronize()

    if let failure { throw failure }
    if controller.isCancelled { throw Failure.cancelled }

    let stdout = try boundedData(at: stdoutURL, maximumBytes: maximumStandardOutputBytes)
    let stderr = try boundedData(at: stderrURL, maximumBytes: maximumStandardErrorBytes)
    return Result(
      stdout: stdout,
      stderr: stderr,
      terminationStatus: process.terminationStatus
    )
  }

  private static func terminate(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    let graceDeadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
    while process.isRunning, DispatchTime.now().uptimeNanoseconds < graceDeadline {
      Thread.sleep(forTimeInterval: 0.02)
    }
    if process.isRunning {
      kill(process.processIdentifier, SIGKILL)
    }
  }

  private static func fileSize(at url: URL) -> Int {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      let value = attributes[.size] as? NSNumber
    else { return 0 }
    return value.intValue
  }

  private static func boundedData(at url: URL, maximumBytes: Int) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
    guard data.count <= maximumBytes else { throw Failure.outputLimitExceeded }
    return data
  }
}
