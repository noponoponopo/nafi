import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS

actor FTPRemoteSession: RemoteServerSession {
  private struct Reply {
    let code: Int
    let lines: [String]

    var message: String { lines.joined(separator: "\n") }
  }

  private struct Socket: @unchecked Sendable {
    let channel: Channel
    let incoming: FTPIncomingBuffer
    let tlsHandshake: FTPHandshakeSignal?
  }

  private static let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)

  private let profile: ServerProfile
  private let password: String
  private var control: Socket?
  private var tlsContext: NIOSSLContext?

  private init(profile: ServerProfile, password: String) {
    self.profile = profile
    self.password = password
  }

  static func connect(profile: ServerProfile, password: String) async throws -> FTPRemoteSession {
    let session = FTPRemoteSession(profile: profile, password: password)
    try await session.open()
    return session
  }

  func listDirectory(at path: String) async throws -> [RemoteFileItem] {
    do {
      let data = try await transferReceiving(command: "MLSD \(RemotePath.normalized(path))")
      return parseMachineListing(data, parentPath: path).sorted(by: remoteItemSort)
    } catch {
      let data = try await transferReceiving(command: "LIST \(RemotePath.normalized(path))")
      let items = parseUnixListing(data, parentPath: path)
      guard !items.isEmpty || data.isEmpty else { throw error }
      return items.sorted(by: remoteItemSort)
    }
  }

  func createDirectory(at path: String) async throws {
    try requireSuccess(
      reply: try await command("MKD \(RemotePath.normalized(path))"), accepted: 200..<300)
  }

  func renameItem(at oldPath: String, to newPath: String) async throws {
    try requireSuccess(
      reply: try await command("RNFR \(RemotePath.normalized(oldPath))"), accepted: 300..<400)
    try requireSuccess(
      reply: try await command("RNTO \(RemotePath.normalized(newPath))"), accepted: 200..<300)
  }

  func removeItem(at path: String, isDirectory: Bool) async throws {
    let verb = isDirectory ? "RMD" : "DELE"
    try requireSuccess(
      reply: try await command("\(verb) \(RemotePath.normalized(path))"), accepted: 200..<300)
  }

  func downloadItem(at remotePath: String, to localURL: URL) async throws {
    let data = try await transferReceiving(command: "RETR \(RemotePath.normalized(remotePath))")
    try data.write(to: localURL, options: .atomic)
  }

  func uploadItem(from localURL: URL, to remotePath: String) async throws {
    let data = try Data(contentsOf: localURL, options: .mappedIfSafe)
    try await transferSending(data: data, command: "STOR \(RemotePath.normalized(remotePath))")
  }

  func close() async {
    if control != nil {
      _ = try? await command("QUIT")
    }
    if let control {
      try? await control.channel.close().get()
    }
    control = nil
  }

  private func open() async throws {
    guard (1...65535).contains(profile.port) else {
      throw RemoteServerError.invalidResponse("FTPポート番号が正しくありません。")
    }

    if profile.ftpEncryption.usesTLS {
      var configuration = TLSConfiguration.makeClientConfiguration()
      configuration.certificateVerification =
        profile.verifyTLSCertificate ? .fullVerification : .none
      configuration.minimumTLSVersion = .tlsv12
      tlsContext = try NIOSSLContext(configuration: configuration)
    }

    let implicitTLS = profile.ftpEncryption == .implicitTLS
    let socket = try await makeSocket(
      host: profile.host,
      port: profile.port,
      tlsFromStart: implicitTLS,
      tlsServerName: profile.host,
      waitForTLS: true
    )
    control = socket
    try requireSuccess(reply: try await readReply(), accepted: 200..<300)

    if profile.ftpEncryption == .explicitTLS {
      let authReply = try await command("AUTH TLS")
      guard authReply.code == 234 || authReply.code == 334 else {
        throw RemoteServerError.invalidResponse(authReply.message)
      }
      try await enableTLS(on: socket, serverName: profile.host)
    }

    if profile.ftpEncryption.usesTLS {
      try requireSuccess(reply: try await command("PBSZ 0"), accepted: 200..<300)
      try requireSuccess(reply: try await command("PROT P"), accepted: 200..<300)
    }

    let username = profile.username.isEmpty ? "anonymous" : profile.username
    let userReply = try await command("USER \(username)")
    if userReply.code == 331 {
      let loginPassword = password.isEmpty && username == "anonymous" ? "nafi@localhost" : password
      try requireSuccess(reply: try await command("PASS \(loginPassword)"), accepted: 200..<300)
    } else {
      try requireSuccess(reply: userReply, accepted: 200..<300)
    }

    try requireSuccess(reply: try await command("TYPE I"), accepted: 200..<300)
    _ = try? await command("OPTS UTF8 ON")
  }

  private func command(_ value: String) async throws -> Reply {
    guard let control else { throw RemoteServerError.notConnected }
    try await send(Data("\(value)\r\n".utf8), on: control.channel)
    return try await readReply()
  }

  private func readReply() async throws -> Reply {
    guard let control else { throw RemoteServerError.notConnected }
    let firstLine = try await control.incoming.readLine()
    guard firstLine.count >= 3, let code = Int(firstLine.prefix(3)) else {
      throw RemoteServerError.invalidResponse("FTPサーバーから不正な応答を受信しました: \(firstLine)")
    }

    var lines = [firstLine]
    if firstLine.dropFirst(3).first == "-" {
      let terminator = "\(code) "
      while true {
        let line = try await control.incoming.readLine()
        lines.append(line)
        if line.hasPrefix(terminator) { break }
      }
    }
    return Reply(code: code, lines: lines)
  }

  private func openPassiveConnection() async throws -> Socket {
    let epsv = try await command("EPSV")
    var host = profile.host
    var portNumber: Int?

    if epsv.code == 229,
      let start = epsv.message.firstIndex(of: "("),
      let end = epsv.message[start...].firstIndex(of: ")")
    {
      let body = epsv.message[epsv.message.index(after: start)..<end]
      let pieces = body.split(separator: "|", omittingEmptySubsequences: true)
      portNumber = pieces.last.flatMap { Int($0) }
    }

    if portNumber == nil {
      let pasv = try await command("PASV")
      try requireSuccess(reply: pasv, accepted: 200..<300)
      guard let start = pasv.message.firstIndex(of: "("),
        let end = pasv.message[start...].firstIndex(of: ")")
      else {
        throw RemoteServerError.invalidResponse("FTP PASV応答を解析できません: \(pasv.message)")
      }
      let values = pasv.message[pasv.message.index(after: start)..<end]
        .split(separator: ",")
        .compactMap { Int(String($0).trimmingCharacters(in: .whitespaces)) }
      guard values.count == 6, values.allSatisfy({ (0...255).contains($0) }) else {
        throw RemoteServerError.invalidResponse("FTP PASV応答を解析できません: \(pasv.message)")
      }
      let advertisedHost = "\(values[0]).\(values[1]).\(values[2]).\(values[3])"
      if advertisedHost != "0.0.0.0" { host = advertisedHost }
      portNumber = values[4] * 256 + values[5]
    }

    guard let portNumber, (1...65535).contains(portNumber) else {
      throw RemoteServerError.invalidResponse("FTPデータ接続のポートを取得できません。")
    }
    return try await makeSocket(
      host: host,
      port: portNumber,
      tlsFromStart: profile.ftpEncryption.usesTLS,
      tlsServerName: profile.host,
      waitForTLS: false
    )
  }

  private func transferReceiving(command commandText: String) async throws -> Data {
    let dataSocket = try await openPassiveConnection()
    do {
      guard let control else { throw RemoteServerError.notConnected }
      try await send(Data("\(commandText)\r\n".utf8), on: control.channel)
      try requireSuccess(reply: try await readReply(), accepted: 100..<200)
      if let handshake = dataSocket.tlsHandshake { try await handshake.wait() }
      let data = try await dataSocket.incoming.readToEnd()
      try requireSuccess(reply: try await readReply(), accepted: 200..<300)
      try? await dataSocket.channel.close().get()
      return data
    } catch {
      try? await dataSocket.channel.close().get()
      throw error
    }
  }

  private func transferSending(data: Data, command commandText: String) async throws {
    let dataSocket = try await openPassiveConnection()
    do {
      guard let control else { throw RemoteServerError.notConnected }
      try await send(Data("\(commandText)\r\n".utf8), on: control.channel)
      try requireSuccess(reply: try await readReply(), accepted: 100..<200)
      if let handshake = dataSocket.tlsHandshake { try await handshake.wait() }
      try await send(data, on: dataSocket.channel)
      try await dataSocket.channel.close().get()
      try requireSuccess(reply: try await readReply(), accepted: 200..<300)
    } catch {
      try? await dataSocket.channel.close().get()
      throw error
    }
  }

  private func makeSocket(
    host: String,
    port: Int,
    tlsFromStart: Bool,
    tlsServerName: String,
    waitForTLS: Bool
  ) async throws -> Socket {
    let incoming = FTPIncomingBuffer()
    let handshake = FTPHandshakeSignal()
    let tlsContext = self.tlsContext

    let bootstrap = ClientBootstrap(group: Self.eventLoopGroup)
      .connectTimeout(.seconds(30))
      .channelInitializer { channel in
        let receiver = FTPInboundHandler(incoming: incoming)
        guard tlsFromStart else {
          return channel.pipeline.addHandler(receiver)
        }
        guard let tlsContext else {
          return channel.eventLoop.makeFailedFuture(
            RemoteServerError.invalidResponse("FTPSのTLS設定を初期化できません。"))
        }
        do {
          let tlsHandler = try NIOSSLClientHandler(
            context: tlsContext,
            serverHostname: tlsServerName
          )
          try channel.pipeline.syncOperations.addHandlers(
            tlsHandler,
            FTPHandshakeHandler(signal: handshake),
            receiver
          )
          return channel.eventLoop.makeSucceededVoidFuture()
        } catch {
          return channel.eventLoop.makeFailedFuture(error)
        }
      }

    let channel = try await bootstrap.connect(host: host, port: port).get()
    if tlsFromStart && waitForTLS {
      do {
        try await handshake.wait()
      } catch {
        try? await channel.close().get()
        throw error
      }
    }
    return Socket(
      channel: channel,
      incoming: incoming,
      tlsHandshake: tlsFromStart ? handshake : nil
    )
  }

  private func enableTLS(on socket: Socket, serverName: String) async throws {
    guard let tlsContext else {
      throw RemoteServerError.invalidResponse("FTPSのTLS設定を初期化できません。")
    }
    let handshake = FTPHandshakeSignal()

    // AUTH TLSの応答を読み終えてから、既存の制御チャネル先頭へTLSを差し込みます。
    try await socket.channel.eventLoop.submit {
      let tlsHandler = try NIOSSLClientHandler(
        context: tlsContext,
        serverHostname: serverName
      )
      try socket.channel.pipeline.syncOperations.addHandlers(
        tlsHandler,
        FTPHandshakeHandler(signal: handshake),
        position: .first
      )
    }.get()
    try await handshake.wait()
  }

  private func send(_ data: Data, on channel: Channel) async throws {
    var buffer = channel.allocator.buffer(capacity: data.count)
    buffer.writeBytes(data)
    try await channel.writeAndFlush(buffer).get()
  }

  private func requireSuccess(reply: Reply, accepted: Range<Int>) throws {
    guard accepted.contains(reply.code) else {
      throw RemoteServerError.invalidResponse(reply.message)
    }
  }

  private func parseMachineListing(_ data: Data, parentPath: String) -> [RemoteFileItem] {
    String(decoding: data, as: UTF8.self)
      .split(whereSeparator: \.isNewline)
      .compactMap { line -> RemoteFileItem? in
        guard let separator = line.firstIndex(of: " ") else { return nil }
        let factsPart = line[..<separator]
        let name = String(line[line.index(after: separator)...]).trimmingCharacters(
          in: .whitespaces)
        guard !name.isEmpty else { return nil }

        var facts: [String: String] = [:]
        for fact in factsPart.split(separator: ";") {
          let pair = fact.split(separator: "=", maxSplits: 1).map(String.init)
          if pair.count == 2 { facts[pair[0].lowercased()] = pair[1] }
        }
        let type = facts["type"]?.lowercased() ?? "file"
        guard type != "cdir", type != "pdir" else { return nil }
        return RemoteFileItem(
          name: name,
          path: RemotePath.appending(name, to: parentPath),
          isDirectory: type == "dir",
          size: facts["size"].flatMap(UInt64.init),
          modifiedAt: facts["modify"].flatMap(parseFTPDate)
        )
      }
  }

  private func parseUnixListing(_ data: Data, parentPath: String) -> [RemoteFileItem] {
    String(decoding: data, as: UTF8.self)
      .split(whereSeparator: \.isNewline)
      .compactMap { line -> RemoteFileItem? in
        let columns = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
        guard columns.count == 9 else { return nil }
        let permissions = columns[0]
        let name = String(columns[8])
        guard name != ".", name != ".." else { return nil }
        return RemoteFileItem(
          name: name,
          path: RemotePath.appending(name, to: parentPath),
          isDirectory: permissions.first == "d",
          size: UInt64(columns[4]),
          modifiedAt: nil
        )
      }
  }

  private func parseFTPDate(_ value: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMddHHmmss"
    return formatter.date(from: String(value.prefix(14)))
  }
}

private final class FTPIncomingBuffer: @unchecked Sendable {
  private let condition = NSCondition()
  private var buffer = Data()
  private var finished = false
  private var failure: Error?

  func append(_ data: Data) {
    guard !data.isEmpty else { return }
    condition.lock()
    buffer.append(data)
    condition.broadcast()
    condition.unlock()
  }

  func finish(error: Error? = nil) {
    condition.lock()
    if failure == nil { failure = error }
    finished = true
    condition.broadcast()
    condition.unlock()
  }

  func readLine() async throws -> String {
    try await Task.detached(priority: .userInitiated) { [self] in
      try blockingReadLine()
    }.value
  }

  func readToEnd() async throws -> Data {
    try await Task.detached(priority: .userInitiated) { [self] in
      try blockingReadToEnd()
    }.value
  }

  private func blockingReadLine() throws -> String {
    condition.lock()
    defer { condition.unlock() }
    while true {
      if let newline = buffer.firstIndex(of: 0x0A) {
        let lineData = buffer.prefix(upTo: newline)
        buffer.removeSubrange(...newline)
        var line = String(decoding: lineData, as: UTF8.self)
        if line.last == "\r" { line.removeLast() }
        return line
      }
      if let failure { throw failure }
      if finished {
        throw RemoteServerError.invalidResponse("FTPサーバーが接続を閉じました。")
      }
      condition.wait()
    }
  }

  private func blockingReadToEnd() throws -> Data {
    condition.lock()
    defer { condition.unlock() }
    while !finished && failure == nil {
      condition.wait()
    }
    if let failure { throw failure }
    let result = buffer
    buffer.removeAll(keepingCapacity: false)
    return result
  }
}

private final class FTPInboundHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = ByteBuffer

  private let incoming: FTPIncomingBuffer

  init(incoming: FTPIncomingBuffer) {
    self.incoming = incoming
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let buffer = unwrapInboundIn(data)
    incoming.append(Data(buffer.readableBytesView))
  }

  func channelInactive(context: ChannelHandlerContext) {
    incoming.finish()
    context.fireChannelInactive()
  }

  func errorCaught(context: ChannelHandlerContext, error: Error) {
    incoming.finish(error: error)
    context.close(promise: nil)
  }
}

private final class FTPHandshakeSignal: @unchecked Sendable {
  private enum State {
    case pending([CheckedContinuation<Void, Error>])
    case completed(Result<Void, Error>)
  }

  private let lock = NSLock()
  private var state: State = .pending([])

  func succeed() {
    resolve(.success(()))
  }

  func fail(_ error: Error) {
    resolve(.failure(error))
  }

  func wait() async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      lock.lock()
      switch state {
      case .pending(var continuations):
        continuations.append(continuation)
        state = .pending(continuations)
        lock.unlock()
      case .completed(let result):
        lock.unlock()
        continuation.resume(with: result)
      }
    }
  }

  private func resolve(_ result: Result<Void, Error>) {
    lock.lock()
    guard case .pending(let continuations) = state else {
      lock.unlock()
      return
    }
    state = .completed(result)
    lock.unlock()

    for continuation in continuations {
      continuation.resume(with: result)
    }
  }
}

private final class FTPHandshakeHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = ByteBuffer

  private let signal: FTPHandshakeSignal

  init(signal: FTPHandshakeSignal) {
    self.signal = signal
  }

  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    if let event = event as? TLSUserEvent {
      switch event {
      case .handshakeCompleted(_):
        signal.succeed()
      case .shutdownCompleted:
        break
      }
    }
    context.fireUserInboundEventTriggered(event)
  }

  func errorCaught(context: ChannelHandlerContext, error: Error) {
    signal.fail(error)
    context.fireErrorCaught(error)
  }

  func channelInactive(context: ChannelHandlerContext) {
    signal.fail(RemoteServerError.notConnected)
    context.fireChannelInactive()
  }
}
