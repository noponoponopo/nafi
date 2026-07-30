import CoreFoundation
import Darwin
import Foundation
import os

private let fpBridgeLogger = Logger(subsystem: "app.nafi.filemanager.fileprovider", category: "rclone")

private final class FPNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

actor FPRcloneBridge {
  private var descriptor: FPRuntimeDescriptor
  private let session: URLSession

  init() throws {
    descriptor = try FPSharedStore.descriptor()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 60
    configuration.timeoutIntervalForResource = 24 * 60 * 60
    configuration.urlCache = nil
    session = URLSession(
      configuration: configuration,
      delegate: FPNoRedirectDelegate(),
      delegateQueue: nil
    )
  }

  func call(_ method: String, _ parameters: [String: Any], timeout: TimeInterval = 120) async throws -> [String: Any] {
    guard timeout.isFinite, timeout > 0, timeout <= 24 * 60 * 60 else {
      throw FPBridgeError.malformedResponse
    }
    var lastError: Error = FPBridgeError.runtimeUnavailable
    for attempt in 0..<2 {
      do {
        if attempt > 0 || descriptor.expiresAt.timeIntervalSinceNow < 15 * 60 {
          descriptor = try FPSharedStore.descriptor()
        }
        return try await callOnce(method, parameters, timeout: timeout)
      } catch {
        fpBridgeLogger.error("RC \(method, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        lastError = error
        guard attempt == 0, shouldReloadDescriptor(after: error) else { throw error }
      }
    }
    throw lastError
  }

  func runJob(
    _ method: String,
    _ parameters: [String: Any],
    timeout: TimeInterval = 24 * 60 * 60
  ) async throws -> [String: Any] {
    guard timeout.isFinite, timeout > 0, timeout <= 24 * 60 * 60 else {
      throw FPBridgeError.malformedResponse
    }
    var values = parameters
    let group = "nafi-file-provider-\(UUID().uuidString)"
    values["_async"] = true
    values["_group"] = group
    let started = try await call(method, values, timeout: 90)
    guard let number = started["jobid"] as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID(),
      let jobID = Int64(number.stringValue), jobID >= 0,
      let executeID = started["executeId"] as? String, Self.validExecuteID(executeID)
    else {
      throw FPBridgeError.malformedResponse
    }
    let generation = descriptor.generation
    let timeoutNanoseconds = UInt64(timeout * 1_000_000_000)
    let start = DispatchTime.now().uptimeNanoseconds
    let deadline = start.addingReportingOverflow(timeoutNanoseconds).overflow
      ? UInt64.max
      : start + timeoutNanoseconds
    do {
      while DispatchTime.now().uptimeNanoseconds < deadline {
        try Task.checkCancellation()
        let status = try await call("job/status", ["jobid": jobID], timeout: 60)
        guard descriptor.generation == generation,
          let currentExecuteID = status["executeId"] as? String,
          currentExecuteID == executeID
        else {
          throw FPBridgeError.runtimeUnavailable
        }
        guard let finished = status["finished"] as? Bool else {
          throw FPBridgeError.malformedResponse
        }
        if finished {
          guard let success = status["success"] as? Bool else {
            throw FPBridgeError.malformedResponse
          }
          guard status["error"] == nil || status["error"] is NSNull || status["error"] is String else {
            throw FPBridgeError.malformedResponse
          }
          let message = status["error"] as? String ?? ""
          guard Self.validRemoteMessage(message) else { throw FPBridgeError.malformedResponse }
          guard success && message.isEmpty else {
            throw FPBridgeError.remote(message.isEmpty ? "rcloneジョブに失敗しました。" : message)
          }
          _ = try? await call("core/stats-delete", ["group": group], timeout: 30)
          guard let output = status["output"], !(output is NSNull) else { return [:] }
          guard let dictionary = output as? [String: Any] else {
            throw FPBridgeError.malformedResponse
          }
          return dictionary
        }
        try await Task.sleep(nanoseconds: 400_000_000)
      }
      throw URLError(.timedOut)
    } catch {
      await Self.cleanupJob(
        jobID: jobID,
        executeID: executeID,
        group: group,
        generation: generation
      )
      throw error
    }
  }

  private static func cleanupJob(
    jobID: Int64,
    executeID: String,
    group: String,
    generation: UUID
  ) async {
    await Task.detached(priority: .utility) {
      guard let bridge = try? FPRcloneBridge(), await bridge.descriptor.generation == generation else {
        return
      }
      guard let status = try? await bridge.call("job/status", ["jobid": jobID], timeout: 30),
        await bridge.descriptor.generation == generation,
        let currentExecuteID = status["executeId"] as? String,
        currentExecuteID == executeID
      else { return }
      _ = try? await bridge.call("job/stop", ["jobid": jobID], timeout: 30)
      _ = try? await bridge.call("core/stats-delete", ["group": group], timeout: 30)
    }.value
  }

  private func callOnce(
    _ method: String, _ parameters: [String: Any], timeout: TimeInterval
  ) async throws -> [String: Any] {
    let processAlive = kill(descriptor.processIdentifier, 0) == 0 || errno == EPERM
    guard descriptor.expiresAt > Date(), processAlive else {
      throw FPBridgeError.runtimeUnavailable
    }
    let clean = method.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !clean.isEmpty, !clean.contains("..") else { throw FPBridgeError.malformedResponse }
    var request = URLRequest(url: descriptor.baseURL.appendingPathComponent(clean))
    request.httpMethod = "POST"
    request.timeoutInterval = timeout
    let body = try JSONSerialization.data(withJSONObject: parameters)
    guard body.count <= 16 * 1024 * 1024 else { throw FPBridgeError.malformedResponse }
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let auth = Data("\(descriptor.username):\(descriptor.password)".utf8).base64EncodedString()
    request.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization")
    let (data, response) = try await session.data(for: request)
    guard data.count <= 64 * 1024 * 1024, let http = response as? HTTPURLResponse else {
      throw FPBridgeError.malformedResponse
    }
    guard sameOrigin(http.url, descriptor.baseURL) else {
      throw FPBridgeError.runtimeUnavailable
    }
    guard (200..<300).contains(http.statusCode) else {
      if http.statusCode == 401 || http.statusCode == 403 { throw FPBridgeError.runtimeUnavailable }
      let dictionary = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      let text = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let message = (dictionary?["error"] as? String)
        ?? (text.flatMap { $0.isEmpty ? nil : $0 })
        ?? "HTTP \(http.statusCode)"
      guard Self.validRemoteMessage(message) else { throw FPBridgeError.malformedResponse }
      throw FPBridgeError.remote(message)
    }
    guard !data.isEmpty else { return [:] }
    let decoded = try JSONSerialization.jsonObject(with: data)
    guard let object = decoded as? [String: Any] else {
      throw FPBridgeError.malformedResponse
    }
    return object
  }

  private nonisolated static func validExecuteID(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 4_096
      && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
  }

  private nonisolated static func validRemoteMessage(_ value: String) -> Bool {
    value.utf8.count <= 1 * 1_024 * 1_024
      && !value.unicodeScalars.contains(where: { $0.value == 0 })
  }

  private func shouldReloadDescriptor(after error: Error) -> Bool {
    if case FPBridgeError.runtimeUnavailable = error { return true }
    guard let urlError = error as? URLError else { return false }
    return [.cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .timedOut]
      .contains(urlError.code)
  }

  private func sameOrigin(_ lhs: URL?, _ rhs: URL) -> Bool {
    guard let lhs else { return false }
    return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
      && lhs.host?.lowercased() == rhs.host?.lowercased()
      && lhs.port == rhs.port
  }
}
