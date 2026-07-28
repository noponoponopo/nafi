import Citadel
import Crypto
import Foundation
import NIOCore

actor SFTPRemoteSession: RemoteServerSession {
  private enum OpenSSHKeyKind: String {
    case rsa = "ssh-rsa"
    case ed25519 = "ssh-ed25519"
  }

  private struct SSHBufferReader {
    private let data: Data
    private var offset = 0

    init(data: Data) {
      self.data = data
    }

    mutating func read(count: Int) -> Data? {
      guard count >= 0, offset + count <= data.count else { return nil }
      defer { offset += count }
      return data.subdata(in: offset..<(offset + count))
    }

    mutating func readUInt32() -> UInt32? {
      guard let bytes = read(count: 4) else { return nil }
      return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    mutating func readSSHData() -> Data? {
      guard let length = readUInt32() else { return nil }
      return read(count: Int(length))
    }

    mutating func readSSHString() -> String? {
      guard let bytes = readSSHData() else { return nil }
      return String(data: bytes, encoding: .utf8)
    }
  }

  private let sshClient: SSHClient
  private let sftpClient: SFTPClient

  private init(sshClient: SSHClient, sftpClient: SFTPClient) {
    self.sshClient = sshClient
    self.sftpClient = sftpClient
  }

  static func connect(
    profile: ServerProfile,
    password: String,
    keyPassphrase: String
  ) async throws -> SFTPRemoteSession {
    let username = profile.username.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !username.isEmpty else {
      throw RemoteServerError.invalidResponse("SFTP接続にはユーザー名が必要です。")
    }

    let authentication = try authenticationMethod(
      profile: profile,
      username: username,
      password: password,
      keyPassphrase: keyPassphrase
    )
    let settings = SSHClientSettings(
      host: profile.host,
      port: profile.port,
      authenticationMethod: { authentication },
      hostKeyValidator: .acceptAnything()
    )
    var configuredSettings = settings
    configuredSettings.algorithms = .all

    let sshClient = try await SSHClient.connect(to: configuredSettings)
    do {
      let sftpClient = try await sshClient.openSFTP()
      return SFTPRemoteSession(sshClient: sshClient, sftpClient: sftpClient)
    } catch {
      try? await sshClient.close()
      throw error
    }
  }

  private static func authenticationMethod(
    profile: ServerProfile,
    username: String,
    password: String,
    keyPassphrase: String
  ) throws -> SSHAuthenticationMethod {
    switch profile.sftpAuthentication {
    case .password:
      return .passwordBased(username: username, password: password)

    case .privateKey:
      let rawPath = profile.privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !rawPath.isEmpty else {
        throw RemoteServerError.invalidResponse("SFTP秘密鍵ファイルが指定されていません。")
      }
      let path = NSString(string: rawPath).expandingTildeInPath
      let keyURL = URL(fileURLWithPath: path)
      let keyData: Data
      do {
        keyData = try Data(contentsOf: keyURL, options: .mappedIfSafe)
      } catch {
        throw RemoteServerError.invalidResponse(
          "SFTP秘密鍵を読み込めません: \(error.localizedDescription)")
      }

      let passphraseData = keyPassphrase.isEmpty ? nil : Data(keyPassphrase.utf8)
      let kind = try detectOpenSSHKeyKind(in: keyData)
      do {
        switch kind {
        case .rsa:
          let key = try Insecure.RSA.PrivateKey(
            sshRsa: keyData,
            decryptionKey: passphraseData
          )
          return .rsa(username: username, privateKey: key)
        case .ed25519:
          let key = try Curve25519.Signing.PrivateKey(
            sshEd25519: keyData,
            decryptionKey: passphraseData
          )
          return .ed25519(username: username, privateKey: key)
        }
      } catch {
        let suffix =
          keyPassphrase.isEmpty
          ? "鍵が暗号化されている場合はパスフレーズを入力してください。"
          : "パスフレーズまたは鍵ファイルを確認してください。"
        throw RemoteServerError.invalidResponse(
          "SFTP秘密鍵を復号できません。\(suffix)（\(error.localizedDescription)）")
      }
    }
  }

  private static func detectOpenSSHKeyKind(in data: Data) throws -> OpenSSHKeyKind {
    guard let text = String(data: data, encoding: .utf8) else {
      throw RemoteServerError.invalidResponse("SFTP秘密鍵はUTF-8のOpenSSH形式である必要があります。")
    }
    let header = "-----BEGIN OPENSSH PRIVATE KEY-----"
    let footer = "-----END OPENSSH PRIVATE KEY-----"
    guard let headerRange = text.range(of: header), let footerRange = text.range(of: footer) else {
      throw RemoteServerError.invalidResponse(
        "対応している秘密鍵形式はOpenSSH形式のRSAまたはEd25519です。")
    }
    let payload = text[headerRange.upperBound..<footerRange.lowerBound]
      .filter { !$0.isWhitespace }
    guard let decoded = Data(base64Encoded: String(payload)) else {
      throw RemoteServerError.invalidResponse("SFTP秘密鍵のBase64データが壊れています。")
    }

    var reader = SSHBufferReader(data: decoded)
    let magic = Data("openssh-key-v1\0".utf8)
    guard reader.read(count: magic.count) == magic,
      reader.readSSHString() != nil,
      reader.readSSHString() != nil,
      reader.readSSHData() != nil,
      let numberOfKeys = reader.readUInt32(),
      numberOfKeys >= 1,
      let publicBlob = reader.readSSHData()
    else {
      throw RemoteServerError.invalidResponse("SFTP秘密鍵のOpenSSHヘッダーを解析できません。")
    }

    var publicReader = SSHBufferReader(data: publicBlob)
    guard let algorithm = publicReader.readSSHString(),
      let kind = OpenSSHKeyKind(rawValue: algorithm)
    else {
      throw RemoteServerError.invalidResponse(
        "このSFTP秘密鍵のアルゴリズムには未対応です。RSAまたはEd25519鍵を使用してください。")
    }
    return kind
  }

  func listDirectory(at path: String) async throws -> [RemoteFileItem] {
    let normalizedPath = RemotePath.normalized(path)
    let groups = try await sftpClient.listDirectory(atPath: normalizedPath)
    return
      groups
      .flatMap(\.components)
      .filter { $0.filename != "." && $0.filename != ".." }
      .map { component in
        let permissions = component.attributes.permissions ?? 0
        let itemType = permissions & 0o170000
        let isDirectory = itemType == 0o040000 || component.longname.first == "d"
        return RemoteFileItem(
          name: component.filename,
          path: RemotePath.appending(component.filename, to: normalizedPath),
          isDirectory: isDirectory,
          size: component.attributes.size,
          modifiedAt: component.attributes.accessModificationTime?.modificationTime
        )
      }
      .sorted(by: remoteItemSort)
  }

  func createDirectory(at path: String) async throws {
    try await sftpClient.createDirectory(atPath: RemotePath.normalized(path))
  }

  func renameItem(at oldPath: String, to newPath: String) async throws {
    try await sftpClient.rename(
      at: RemotePath.normalized(oldPath),
      to: RemotePath.normalized(newPath)
    )
  }

  func removeItem(at path: String, isDirectory: Bool) async throws {
    let normalizedPath = RemotePath.normalized(path)
    if isDirectory {
      try await sftpClient.rmdir(at: normalizedPath)
    } else {
      try await sftpClient.remove(at: normalizedPath)
    }
  }

  func downloadItem(at remotePath: String, to localURL: URL) async throws {
    let buffer = try await sftpClient.withFile(
      filePath: RemotePath.normalized(remotePath),
      flags: .read
    ) { file in
      try await file.readAll()
    }
    let data = Data(buffer.readableBytesView)
    try data.write(to: localURL, options: .atomic)
  }

  func uploadItem(from localURL: URL, to remotePath: String) async throws {
    let data = try Data(contentsOf: localURL, options: .mappedIfSafe)
    var preparedBuffer = ByteBufferAllocator().buffer(capacity: data.count)
    preparedBuffer.writeBytes(data)
    let buffer = preparedBuffer
    try await sftpClient.withFile(
      filePath: RemotePath.normalized(remotePath),
      flags: [.write, .create, .truncate]
    ) { file in
      try await file.write(buffer)
    }
  }

  func close() async {
    try? await sftpClient.close()
    try? await sshClient.close()
  }
}
