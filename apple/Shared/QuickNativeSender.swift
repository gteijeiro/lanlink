import Foundation
import CryptoKit
import Security

struct NativeSharedFile: Sendable {
  let url: URL
  let name: String
  let size: Int64
  let hash: String
  var metadata: [String: Any] { ["name": name, "size": size, "hash": hash] }
}

enum QuickNativeCrypto {
  static func b64(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_") }
  static func decode(_ text: Any?) throws -> Data {
    guard var text = text as? String else { throw DirectError.invalid }
    text = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    text += String(repeating: "=", count: (4 - text.count % 4) % 4)
    guard let data = Data(base64Encoded: text) else { throw DirectError.invalid }; return data
  }
  static func commit(_ session: String, _ publicKey: Data, _ nonce: Data) -> String {
    var data = Data("lanlink-quick-commit-v1:\(session):".utf8); data.append(publicKey); data.append(nonce)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  static func key(_ own: Curve25519.KeyAgreement.PrivateKey, remote: Data, serverNonce: Data, clientNonce: Data) throws -> SymmetricKey {
    guard remote.count == 32, serverNonce.count == 32, clientNonce.count == 32 else { throw DirectError.invalid }
    let shared = try own.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: remote))
    return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: serverNonce + clientNonce, sharedInfo: Data("lanlink-quick-v1".utf8), outputByteCount: 32)
  }
  static func code(_ key: SymmetricKey, session: String) -> String {
    let bytes = HMAC<SHA256>.authenticationCode(for: Data("lanlink-quick-code-v1:\(session)".utf8), using: key)
    let value = bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    return String(format: "%06u", value % 1_000_000)
  }
  static func seal(_ bytes: Data, key: SymmetricKey, aad: String) throws -> [String: String] {
    let box = try AES.GCM.seal(bytes, using: key, authenticating: Data(aad.utf8))
    return ["n": b64(Data(box.nonce)), "c": b64(box.ciphertext), "m": b64(box.tag)]
  }
  static func sealJSON(_ object: [String: Any], key: SymmetricKey, aad: String) throws -> [String: String] { try seal(JSONSerialization.data(withJSONObject: object), key: key, aad: aad) }
  static func openJSON(_ object: [String: Any], key: SymmetricKey, aad: String) throws -> [String: Any] {
    let nonce = try decode(object["n"]), tag = try decode(object["m"])
    guard nonce.count == 12, tag.count == 16 else { throw DirectError.invalid }
    let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: decode(object["c"]), tag: tag)
    let bytes = try AES.GCM.open(box, using: key, authenticating: Data(aad.utf8))
    guard let result = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw DirectError.invalid }
    return result
  }
}

final class QuickNativeSender {
  typealias RPC = (String, [String: Any]) async throws -> [String: Any]
  var onCode: ((String) -> Void)?
  var confirmCode: ((String) async -> Bool)?
  var onProgress: ((String, Int64, Int64) -> Void)?
  var cancelled = false
  private func check() throws { if cancelled { throw CancellationError() } }
  static func prepare(_ urls: [URL]) throws -> [NativeSharedFile] {
    guard !urls.isEmpty, urls.count <= 100 else { throw DirectError.invalid }
    var total: Int64 = 0
    return try urls.map { url in
      guard url.isFileURL else { throw DirectError.invalid }
      let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? -1
      total += size
      guard size >= 0, size <= 17_179_869_184, total <= 17_179_869_184 else { throw DirectError.invalid }
      let reader = try FileHandle(forReadingFrom: url); defer { try? reader.close() }
      var hash = SHA256()
      while let bytes = try reader.read(upToCount: 128 * 1024), !bytes.isEmpty { hash.update(data: bytes) }
      return NativeSharedFile(url: url, name: url.lastPathComponent, size: size, hash: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
  }
  func send(_ files: [NativeSharedFile], name: String, rpc: @escaping RPC, chunkSize: Int, selectedChunkSize: (() -> Int)? = nil) async throws {
    try check()
    let hello = try await rpc("/quick/hello", [:])
    let chunkSize = selectedChunkSize?() ?? chunkSize
    guard chunkSize > 0, chunkSize <= 128 * 1024 else { throw DirectError.invalid }
    guard hello["v"] as? Int == 1, let session = hello["session"] as? String, session.count == 22 else { throw DirectError.invalid }
    let own = Curve25519.KeyAgreement.PrivateKey()
    let publicKey = own.publicKey.rawRepresentation
    var nonce = Data(count: 32)
    let status = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
    guard status == errSecSuccess else { throw DirectError.invalid }
    let revealed = try await rpc("/quick/reveal", ["session": session, "commit": QuickNativeCrypto.commit(session, publicKey, nonce)])
    let serverPublic = try QuickNativeCrypto.decode(revealed["publicKey"]), serverNonce = try QuickNativeCrypto.decode(revealed["nonce"])
    guard QuickNativeCrypto.commit(session, serverPublic, serverNonce) == hello["commit"] as? String else { throw DirectError.invalid }
    let key = try QuickNativeCrypto.key(own, remote: serverPublic, serverNonce: serverNonce, clientNonce: nonce)
    let code = QuickNativeCrypto.code(key, session: session)
    onCode?(code)
    let offer = try QuickNativeCrypto.sealJSON(["name": name, "files": files.map(\.metadata)], key: key, aad: "quick-offer-v1:\(session)")
    let decision = try await rpc("/quick/offer", ["session": session, "publicKey": QuickNativeCrypto.b64(publicKey), "nonce": QuickNativeCrypto.b64(nonce), "box": offer])
    guard try QuickNativeCrypto.openJSON(decision, key: key, aad: "quick-decision-v1:\(session)")["accepted"] as? Bool == true else { throw DirectError.rejected }
    do {
      try check()
      guard await confirmCode?(code) == true else { throw CancellationError() }
      for (index, file) in files.enumerated() {
        let reader = try FileHandle(forReadingFrom: file.url); defer { try? reader.close() }
        var offset: Int64 = 0
        repeat {
          try check()
          let data = try reader.read(upToCount: chunkSize) ?? Data()
          if data.isEmpty && file.size != 0 { break }
          let packet: [String: Any] = ["session": session, "index": index, "offset": offset, "box": try QuickNativeCrypto.seal(data, key: key, aad: "quick-chunk-v1:\(session):\(index):\(offset)")]
          var response: [String: Any]
          do { response = try await rpc("/quick/chunk", packet) }
          catch { response = try await rpc("/quick/chunk", packet) }
          let ack = try QuickNativeCrypto.openJSON(response, key: key, aad: "quick-ack-v1:\(session):\(index):\(offset)")
          guard ack["index"] as? Int == index, (ack["offset"] as? NSNumber)?.int64Value == offset + Int64(data.count) else { throw DirectError.invalid }
          offset += Int64(data.count); onProgress?(file.name, offset, file.size)
          if file.size == 0 { break }
        } while offset < file.size
        guard offset == file.size else { throw DirectError.invalid }
      }
    } catch {
      _ = try? await rpc("/quick/cancel", ["session": session, "box": try QuickNativeCrypto.sealJSON([:], key: key, aad: "quick-cancel-v1:\(session)")])
      throw error
    }
  }
}
