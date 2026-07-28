import Crypto
import Foundation

#if canImport(FoundationXML)
  import FoundationXML
#endif

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

private final class S3URLSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
  private let verifyCertificate: Bool

  init(verifyCertificate: Bool) {
    self.verifyCertificate = verifyCertificate
  }

  func urlSession(
    _ session: URLSession,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    #if os(macOS)
      guard !verifyCertificate,
        challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
        let trust = challenge.protectionSpace.serverTrust
      else {
        completionHandler(.performDefaultHandling, nil)
        return
      }
      completionHandler(.useCredential, URLCredential(trust: trust))
    #else
      completionHandler(.performDefaultHandling, nil)
    #endif
  }
}

actor S3RemoteSession: RemoteServerSession {
  private struct Credentials: Sendable {
    let accessKey: String
    let secretKey: String
    let sessionToken: String?
  }

  private struct ListedObject: Sendable {
    let key: String
    let size: UInt64?
    let modifiedAt: Date?
  }

  private struct ListResult: Sendable {
    var objects: [ListedObject]
    var commonPrefixes: [String]
    var isTruncated: Bool
    var nextContinuationToken: String?
  }

  private struct RequestTarget: Sendable {
    let url: URL
    let canonicalURI: String
    let canonicalQuery: String
  }

  private let profile: ServerProfile
  private let credentials: Credentials?
  private let sessionDelegate: S3URLSessionDelegate
  private let urlSession: URLSession

  private static let emptyPayloadHash = sha256Hex(Data())
  private static let multipartThreshold: UInt64 = 128 * 1_024 * 1_024

  private init(profile: ServerProfile, credentials: Credentials?) {
    self.profile = profile
    self.credentials = credentials
    let delegate = S3URLSessionDelegate(verifyCertificate: profile.verifyTLSCertificate)
    self.sessionDelegate = delegate
    let configuration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = 120
    configuration.timeoutIntervalForResource = 60 * 60
    #if os(macOS)
      configuration.waitsForConnectivity = true
    #endif
    self.urlSession = URLSession(
      configuration: configuration, delegate: delegate, delegateQueue: nil)
  }

  static func connect(
    profile: ServerProfile,
    secretAccessKey: String,
    sessionToken: String
  ) async throws -> S3RemoteSession {
    let bucket = profile.s3Bucket.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !bucket.isEmpty else {
      throw RemoteServerError.invalidResponse("S3バケット名が指定されていません。")
    }
    guard endpointURL(for: profile) != nil else {
      throw RemoteServerError.invalidResponse("S3互換エンドポイントが正しくありません。")
    }

    let credentials: Credentials?
    if profile.s3Anonymous {
      credentials = nil
    } else {
      let accessKey = profile.username.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !accessKey.isEmpty, !secretAccessKey.isEmpty else {
        throw RemoteServerError.invalidResponse(
          "S3接続にはアクセスキーIDとシークレットアクセスキーが必要です。")
      }
      credentials = Credentials(
        accessKey: accessKey,
        secretKey: secretAccessKey,
        sessionToken: sessionToken.isEmpty ? nil : sessionToken
      )
    }

    let remote = S3RemoteSession(profile: profile, credentials: credentials)
    _ = try await remote.listDirectory(at: profile.path)
    return remote
  }

  func listDirectory(at path: String) async throws -> [RemoteFileItem] {
    let prefix = directoryKey(for: path)
    var continuationToken: String?
    var objects: [String: RemoteFileItem] = [:]

    repeat {
      var query = [
        URLQueryItem(name: "list-type", value: "2"),
        URLQueryItem(name: "delimiter", value: "/"),
        URLQueryItem(name: "prefix", value: prefix),
      ]
      if let continuationToken {
        query.append(URLQueryItem(name: "continuation-token", value: continuationToken))
      }
      let (data, _) = try await dataRequest(method: "GET", key: nil, query: query)
      let result = try parseListResult(data)

      for commonPrefix in result.commonPrefixes {
        let trimmed = String(commonPrefix.dropLast(commonPrefix.hasSuffix("/") ? 1 : 0))
        guard !trimmed.isEmpty, trimmed != String(prefix.dropLast()) else { continue }
        let name = String(trimmed.dropFirst(prefix.count))
        guard !name.isEmpty, !name.contains("/") else { continue }
        objects[name] = RemoteFileItem(
          name: name,
          path: "/" + trimmed,
          isDirectory: true,
          size: nil,
          modifiedAt: nil
        )
      }

      for object in result.objects {
        guard object.key != prefix, !object.key.hasSuffix("/") else { continue }
        let name = String(object.key.dropFirst(prefix.count))
        guard !name.isEmpty, !name.contains("/") else { continue }
        if objects[name]?.isDirectory == true { continue }
        objects[name] = RemoteFileItem(
          name: name,
          path: "/" + object.key,
          isDirectory: false,
          size: object.size,
          modifiedAt: object.modifiedAt
        )
      }

      continuationToken = result.isTruncated ? result.nextContinuationToken : nil
    } while continuationToken != nil

    return objects.values.sorted(by: remoteItemSort)
  }

  func createDirectory(at path: String) async throws {
    let key = directoryKey(for: path)
    guard !key.isEmpty else { return }
    _ = try await dataRequest(method: "PUT", key: key, body: Data())
  }

  func renameItem(at oldPath: String, to newPath: String) async throws {
    let oldKey = objectKey(for: oldPath)
    let newKey = objectKey(for: newPath)
    guard !oldKey.isEmpty, !newKey.isEmpty else {
      throw RemoteServerError.invalidName
    }

    let directoryObjects = try await listAllObjects(prefix: oldKey + "/")
    if !directoryObjects.isEmpty {
      for object in directoryObjects {
        let suffix = String(object.key.dropFirst(oldKey.count))
        try await copyObject(from: object.key, to: newKey + suffix)
      }
      for object in directoryObjects.reversed() {
        try await deleteObject(key: object.key)
      }
      return
    }

    try await copyObject(from: oldKey, to: newKey)
    try await deleteObject(key: oldKey)
  }

  func removeItem(at path: String, isDirectory: Bool) async throws {
    let key = objectKey(for: path)
    guard !key.isEmpty else { return }
    try await deleteObject(key: isDirectory ? key + "/" : key)
  }

  func downloadItem(at remotePath: String, to localURL: URL) async throws {
    let key = objectKey(for: remotePath)
    var request = try makeRequest(method: "GET", key: key, payloadHash: Self.emptyPayloadHash)
    request.timeoutInterval = 60 * 60
    let (temporaryURL, response) = try await urlSession.download(for: request)
    try validate(response: response, data: nil)

    try FileManager.default.createDirectory(
      at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: localURL.path) {
      try FileManager.default.removeItem(at: localURL)
    }
    try FileManager.default.moveItem(at: temporaryURL, to: localURL)
  }

  func uploadItem(from localURL: URL, to remotePath: String) async throws {
    let values = try localURL.resourceValues(forKeys: [.fileSizeKey])
    let size = UInt64(max(values.fileSize ?? 0, 0))
    let key = objectKey(for: remotePath)
    if size >= Self.multipartThreshold {
      try await multipartUpload(localURL: localURL, key: key, fileSize: size)
    } else {
      try await singleUpload(localURL: localURL, key: key)
    }
  }

  func close() async {
    urlSession.invalidateAndCancel()
  }

  // MARK: - Object operations

  private func singleUpload(localURL: URL, key: String) async throws {
    let hash = try Self.sha256Hex(ofFile: localURL)
    var request = try makeRequest(method: "PUT", key: key, payloadHash: hash)
    request.timeoutInterval = 60 * 60
    let (_, response) = try await urlSession.upload(for: request, fromFile: localURL)
    try validate(response: response, data: nil)
  }

  private func multipartUpload(localURL: URL, key: String, fileSize: UInt64) async throws {
    let (createData, _) = try await dataRequest(
      method: "POST",
      key: key,
      query: [URLQueryItem(name: "uploads", value: "")],
      body: Data()
    )
    guard let uploadID = XMLTextValues(data: createData).first("UploadId"), !uploadID.isEmpty else {
      throw RemoteServerError.invalidResponse("S3マルチパートアップロードIDを取得できません。")
    }

    let minimumPartSize: UInt64 = 64 * 1_024 * 1_024
    let requiredPartSize = (fileSize + 9_999) / 10_000
    let mebibyte: UInt64 = 1_024 * 1_024
    let partSize = max(minimumPartSize, ((requiredPartSize + mebibyte - 1) / mebibyte) * mebibyte)
    let staging = FileManager.default.temporaryDirectory
      .appendingPathComponent("nafi-s3-parts", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: staging) }

    var completedParts: [(number: Int, etag: String)] = []
    let input = try FileHandle(forReadingFrom: localURL)
    defer { try? input.close() }

    do {
      var partNumber = 1
      while true {
        let chunk = try input.read(upToCount: Int(partSize)) ?? Data()
        guard !chunk.isEmpty else { break }
        let partURL = staging.appendingPathComponent("part-\(partNumber)")
        try chunk.write(to: partURL, options: .atomic)
        let hash = Self.sha256Hex(chunk)
        let query = [
          URLQueryItem(name: "partNumber", value: String(partNumber)),
          URLQueryItem(name: "uploadId", value: uploadID),
        ]
        var request = try makeRequest(method: "PUT", key: key, query: query, payloadHash: hash)
        request.timeoutInterval = 60 * 60
        let (_, response) = try await urlSession.upload(for: request, fromFile: partURL)
        try validate(response: response, data: nil)
        guard let http = response as? HTTPURLResponse,
          let etag = http.value(forHTTPHeaderField: "ETag")
        else {
          throw RemoteServerError.invalidResponse("S3パートのETagを取得できません。")
        }
        completedParts.append((partNumber, etag))
        try? FileManager.default.removeItem(at: partURL)
        partNumber += 1
      }

      let partsXML = completedParts.map { part in
        "<Part><PartNumber>\(part.number)</PartNumber><ETag>\(Self.xmlEscape(part.etag))</ETag></Part>"
      }.joined()
      let completeBody = Data(
        "<CompleteMultipartUpload>\(partsXML)</CompleteMultipartUpload>".utf8)
      let (completeData, _) = try await dataRequest(
        method: "POST",
        key: key,
        query: [URLQueryItem(name: "uploadId", value: uploadID)],
        headers: ["Content-Type": "application/xml"],
        body: completeBody
      )
      if let code = XMLTextValues(data: completeData).first("Code") {
        let message = XMLTextValues(data: completeData).first("Message") ?? code
        throw RemoteServerError.invalidResponse(
          "S3マルチパートアップロードの完了に失敗しました: \(message)")
      }
    } catch {
      _ = try? await dataRequest(
        method: "DELETE",
        key: key,
        query: [URLQueryItem(name: "uploadId", value: uploadID)]
      )
      throw error
    }
  }

  private func copyObject(from sourceKey: String, to destinationKey: String) async throws {
    let encodedSource =
      "/" + Self.awsEncode(profile.s3Bucket, encodeSlash: true) + "/"
      + Self.awsEncode(sourceKey, encodeSlash: false)
    do {
      let (data, _) = try await dataRequest(
        method: "PUT",
        key: destinationKey,
        headers: ["x-amz-copy-source": encodedSource],
        body: Data()
      )
      if let code = XMLTextValues(data: data).first("Code") {
        let message = XMLTextValues(data: data).first("Message") ?? code
        throw RemoteServerError.invalidResponse("S3コピーに失敗しました: \(message)")
      }
    } catch {
      // CopyObjectは1回のコピー上限があるため、大きいオブジェクトはローカルステージ経由で移します。
      let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent("nafi-s3-copy-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: temporary) }
      try await downloadItem(at: "/" + sourceKey, to: temporary)
      try await uploadItem(from: temporary, to: "/" + destinationKey)
    }
  }

  private func deleteObject(key: String) async throws {
    _ = try await dataRequest(method: "DELETE", key: key)
  }

  private func listAllObjects(prefix: String) async throws -> [ListedObject] {
    var continuationToken: String?
    var objects: [ListedObject] = []
    repeat {
      var query = [
        URLQueryItem(name: "list-type", value: "2"),
        URLQueryItem(name: "prefix", value: prefix),
      ]
      if let continuationToken {
        query.append(URLQueryItem(name: "continuation-token", value: continuationToken))
      }
      let (data, _) = try await dataRequest(method: "GET", key: nil, query: query)
      let result = try parseListResult(data)
      objects.append(contentsOf: result.objects)
      continuationToken = result.isTruncated ? result.nextContinuationToken : nil
    } while continuationToken != nil
    return objects
  }

  // MARK: - HTTP and Signature V4

  private func dataRequest(
    method: String,
    key: String?,
    query: [URLQueryItem] = [],
    headers: [String: String] = [:],
    body: Data? = nil
  ) async throws -> (Data, URLResponse) {
    let body = body ?? Data()
    var request = try makeRequest(
      method: method,
      key: key,
      query: query,
      headers: headers,
      payloadHash: Self.sha256Hex(body)
    )
    request.httpBody = body.isEmpty ? nil : body
    let (data, response) = try await urlSession.data(for: request)
    try validate(response: response, data: data)
    return (data, response)
  }

  private func makeRequest(
    method: String,
    key: String?,
    query: [URLQueryItem] = [],
    headers: [String: String] = [:],
    payloadHash: String
  ) throws -> URLRequest {
    let target = try requestTarget(key: key, query: query)
    var request = URLRequest(url: target.url)
    request.httpMethod = method
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

    guard let credentials else { return request }

    let now = Date()
    let amzDate = Self.amzDate(now)
    let shortDate = String(amzDate.prefix(8))
    request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
    request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
    if let token = credentials.sessionToken {
      request.setValue(token, forHTTPHeaderField: "x-amz-security-token")
    }

    let host = Self.hostHeader(for: target.url)
    var signedHeaderValues: [String: String] = [
      "host": host,
      "x-amz-content-sha256": payloadHash,
      "x-amz-date": amzDate,
    ]
    if let token = credentials.sessionToken {
      signedHeaderValues["x-amz-security-token"] = token
    }
    for (name, value) in headers where name.lowercased().hasPrefix("x-amz-") {
      signedHeaderValues[name.lowercased()] = Self.normalizedHeaderValue(value)
    }

    let sortedHeaderNames = signedHeaderValues.keys.sorted()
    let canonicalHeaders = sortedHeaderNames.map {
      "\($0):\(Self.normalizedHeaderValue(signedHeaderValues[$0] ?? ""))\n"
    }.joined()
    let signedHeaders = sortedHeaderNames.joined(separator: ";")
    let canonicalRequest = [
      method,
      target.canonicalURI,
      target.canonicalQuery,
      canonicalHeaders,
      signedHeaders,
      payloadHash,
    ].joined(separator: "\n")

    let region =
      profile.s3Region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "us-east-1" : profile.s3Region.trimmingCharacters(in: .whitespacesAndNewlines)
    let scope = "\(shortDate)/\(region)/s3/aws4_request"
    let stringToSign = [
      "AWS4-HMAC-SHA256",
      amzDate,
      scope,
      Self.sha256Hex(Data(canonicalRequest.utf8)),
    ].joined(separator: "\n")

    let dateKey = Self.hmac(key: Data(("AWS4" + credentials.secretKey).utf8), value: shortDate)
    let regionKey = Self.hmac(key: dateKey, value: region)
    let serviceKey = Self.hmac(key: regionKey, value: "s3")
    let signingKey = Self.hmac(key: serviceKey, value: "aws4_request")
    let signature = Self.hex(Self.hmac(key: signingKey, data: Data(stringToSign.utf8)))
    let authorization =
      "AWS4-HMAC-SHA256 Credential=\(credentials.accessKey)/\(scope), "
      + "SignedHeaders=\(signedHeaders), Signature=\(signature)"
    request.setValue(authorization, forHTTPHeaderField: "Authorization")
    return request
  }

  private func requestTarget(key: String?, query: [URLQueryItem]) throws -> RequestTarget {
    guard var components = Self.endpointComponents(for: profile) else {
      throw RemoteServerError.invalidResponse("S3互換エンドポイントが正しくありません。")
    }

    let style = resolvedAddressingStyle()
    let bucket = profile.s3Bucket.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let objectKey = key.map { String($0.drop(while: { $0 == "/" })) } ?? ""
    let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

    let rawPath: String
    switch style {
    case .pathStyle, .automatic:
      rawPath = "/" + [basePath, bucket, objectKey].filter { !$0.isEmpty }.joined(separator: "/")
    case .virtualHostedStyle:
      guard let host = components.host else {
        throw RemoteServerError.invalidResponse("S3エンドポイントのホスト名がありません。")
      }
      components.host = "\(bucket).\(host)"
      rawPath = "/" + [basePath, objectKey].filter { !$0.isEmpty }.joined(separator: "/")
    }

    let canonicalURI = Self.awsEncodePath(rawPath)
    var encodedQueryPairs: [(name: String, value: String)] = []
    encodedQueryPairs.reserveCapacity(query.count)
    for item in query {
      encodedQueryPairs.append(
        (
          name: Self.awsEncode(item.name, encodeSlash: true),
          value: Self.awsEncode(item.value ?? "", encodeSlash: true)
        ))
    }
    encodedQueryPairs.sort { lhs, rhs in
      lhs.name == rhs.name ? lhs.value < rhs.value : lhs.name < rhs.name
    }
    let canonicalQuery =
      encodedQueryPairs
      .map { "\($0.name)=\($0.value)" }
      .joined(separator: "&")

    components.percentEncodedPath = canonicalURI
    components.percentEncodedQuery = canonicalQuery.isEmpty ? nil : canonicalQuery
    guard let url = components.url else {
      throw RemoteServerError.invalidResponse("S3リクエストURLを作成できません。")
    }
    return RequestTarget(url: url, canonicalURI: canonicalURI, canonicalQuery: canonicalQuery)
  }

  private func resolvedAddressingStyle() -> ServerProfile.S3AddressingStyle {
    guard profile.s3AddressingStyle == .automatic else { return profile.s3AddressingStyle }
    let hostname = Self.endpointComponents(for: profile)?.host?.lowercased() ?? ""
    if hostname.contains("amazonaws.com") && !hostname.contains("r2.cloudflarestorage.com") {
      return .virtualHostedStyle
    }
    return .pathStyle
  }

  private func validate(response: URLResponse, data: Data?) throws {
    guard let response = response as? HTTPURLResponse else {
      throw RemoteServerError.invalidResponse("S3サーバーからHTTP応答を取得できません。")
    }
    guard (200..<300).contains(response.statusCode) else {
      let values = data.map(XMLTextValues.init(data:))
      let code = values?.first("Code")
      let message = values?.first("Message")
      let detail = [code, message].compactMap { $0 }.joined(separator: ": ")
      throw RemoteServerError.invalidResponse(
        detail.isEmpty
          ? "S3リクエストに失敗しました（HTTP \(response.statusCode)）。"
          : "S3リクエストに失敗しました（HTTP \(response.statusCode) / \(detail)）。"
      )
    }
  }

  // MARK: - Paths and XML

  private func objectKey(for path: String) -> String {
    String(RemotePath.normalized(path).drop(while: { $0 == "/" }))
  }

  private func directoryKey(for path: String) -> String {
    let key = objectKey(for: path)
    return key.isEmpty ? "" : key + "/"
  }

  private func parseListResult(_ data: Data) throws -> ListResult {
    let delegate = S3ListObjectsParser()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    guard parser.parse() else {
      throw RemoteServerError.invalidResponse(
        "S3一覧応答を解析できません: \(parser.parserError?.localizedDescription ?? "不明なXMLエラー")")
    }
    if let code = delegate.errorCode {
      throw RemoteServerError.invalidResponse(
        "S3一覧の取得に失敗しました: \(delegate.errorMessage ?? code)")
    }
    return ListResult(
      objects: delegate.objects.map {
        ListedObject(key: $0.key, size: $0.size, modifiedAt: $0.modifiedAt)
      },
      commonPrefixes: delegate.commonPrefixes,
      isTruncated: delegate.isTruncated,
      nextContinuationToken: delegate.nextContinuationToken
    )
  }

  private static func endpointURL(for profile: ServerProfile) -> URL? {
    endpointComponents(for: profile)?.url
  }

  private static func endpointComponents(for profile: ServerProfile) -> URLComponents? {
    let raw = profile.host.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return nil }
    var components: URLComponents?
    if raw.contains("://") {
      components = URLComponents(string: raw)
    } else {
      components = URLComponents()
      components?.scheme = profile.useTLS ? "https" : "http"
      components?.host = raw
    }
    guard var result = components, result.host != nil else { return nil }
    let defaultPort = profile.useTLS ? 443 : 80
    if result.port == nil, profile.port != defaultPort { result.port = profile.port }
    return result
  }

  private static func hostHeader(for url: URL) -> String {
    guard let host = url.host else { return "" }
    guard let port = url.port else { return host }
    let defaultPort = url.scheme == "https" ? 443 : 80
    return port == defaultPort ? host : "\(host):\(port)"
  }

  private static func normalizedHeaderValue(_ value: String) -> String {
    value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
  }

  private static func amzDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return formatter.string(from: date)
  }

  private static func awsEncodePath(_ path: String) -> String {
    let encoded = awsEncode(path, encodeSlash: false)
    return encoded.hasPrefix("/") ? encoded : "/" + encoded
  }

  private static func awsEncode(_ value: String, encodeSlash: Bool) -> String {
    value.utf8.map { byte -> String in
      let isAlphaNumeric =
        (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57)
      let isUnreserved = isAlphaNumeric || byte == 45 || byte == 46 || byte == 95 || byte == 126
      if isUnreserved || (!encodeSlash && byte == 47) {
        return String(UnicodeScalar(byte))
      }
      return String(format: "%%%02X", byte)
    }.joined()
  }

  private static func sha256Hex(_ data: Data) -> String {
    hex(Data(SHA256.hash(data: data)))
  }

  private static func sha256Hex(ofFile url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      let data = try handle.read(upToCount: 1_024 * 1_024) ?? Data()
      if data.isEmpty { break }
      hasher.update(data: data)
    }
    return hex(Data(hasher.finalize()))
  }

  private static func hmac(key: Data, value: String) -> Data {
    hmac(key: key, data: Data(value.utf8))
  }

  private static func hmac(key: Data, data: Data) -> Data {
    Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
  }

  private static func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
  }

  private static func xmlEscape(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&apos;")
  }
}

private final class XMLTextValues: NSObject, XMLParserDelegate {
  private var currentElement = ""
  private var currentText = ""
  private(set) var values: [String: [String]] = [:]

  init(data: Data) {
    super.init()
    let parser = XMLParser(data: data)
    parser.delegate = self
    _ = parser.parse()
  }

  func first(_ name: String) -> String? { values[name]?.first }

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    currentElement = elementName
    currentText = ""
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    currentText += string
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
    if !text.isEmpty { values[elementName, default: []].append(text) }
    currentElement = ""
    currentText = ""
  }
}

private final class S3ListObjectsParser: NSObject, XMLParserDelegate {
  struct ObjectRecord {
    var key = ""
    var size: UInt64?
    var modifiedAt: Date?
  }

  private var currentElement = ""
  private var currentText = ""
  private var currentObject: ObjectRecord?
  private var insideCommonPrefix = false

  private(set) var objects: [ObjectRecord] = []
  private(set) var commonPrefixes: [String] = []
  private(set) var isTruncated = false
  private(set) var nextContinuationToken: String?
  private(set) var errorCode: String?
  private(set) var errorMessage: String?

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    currentElement = elementName
    currentText = ""
    if elementName == "Contents" { currentObject = ObjectRecord() }
    if elementName == "CommonPrefixes" { insideCommonPrefix = true }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    currentText += string
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
    switch elementName {
    case "Key" where currentObject != nil:
      currentObject?.key = text
    case "Size" where currentObject != nil:
      currentObject?.size = UInt64(text)
    case "LastModified" where currentObject != nil:
      currentObject?.modifiedAt = Self.parseDate(text)
    case "Contents":
      if let currentObject, !currentObject.key.isEmpty { objects.append(currentObject) }
      self.currentObject = nil
    case "Prefix" where insideCommonPrefix:
      if !text.isEmpty { commonPrefixes.append(text) }
    case "CommonPrefixes":
      insideCommonPrefix = false
    case "IsTruncated":
      isTruncated = text.lowercased() == "true"
    case "NextContinuationToken":
      nextContinuationToken = text.isEmpty ? nil : text
    case "Code":
      errorCode = text.isEmpty ? nil : text
    case "Message":
      errorMessage = text.isEmpty ? nil : text
    default:
      break
    }
    currentElement = ""
    currentText = ""
  }

  private static func parseDate(_ text: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: text) { return date }
    return ISO8601DateFormatter().date(from: text)
  }
}
