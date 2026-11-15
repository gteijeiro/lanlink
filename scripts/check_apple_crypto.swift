import Foundation
import CryptoKit

let ownBytes = Data((0..<32).map { UInt8($0 + 1) })
let remoteBytes = Data((0..<32).map { UInt8($0 + 33) })
let own = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: ownBytes)
let remote = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: remoteBytes).publicKey.rawRepresentation
let serverNonce = Data(repeating: 0x31, count: 32), clientNonce = Data(repeating: 0x72, count: 32)
let session = "abcdefghijklmnopqrstuv"
let key = try QuickNativeCrypto.key(own, remote: remote, serverNonce: serverNonce, clientNonce: clientNonce)
let keyText = key.withUnsafeBytes { QuickNativeCrypto.b64(Data($0)) }
let commit = QuickNativeCrypto.commit(session, remote, serverNonce)
let code = QuickNativeCrypto.code(key, session: session)
let path = CommandLine.arguments[1]
if CommandLine.arguments.contains("--generate") {
  let box = try QuickNativeCrypto.sealJSON(["message": "Hola desde Apple 🌎"], key: key, aad: "interop-v1")
  let fixture: [String: Any] = ["privateKey": QuickNativeCrypto.b64(ownBytes), "remotePublic": QuickNativeCrypto.b64(remote), "serverNonce": QuickNativeCrypto.b64(serverNonce), "clientNonce": QuickNativeCrypto.b64(clientNonce), "session": session, "key": keyText, "commit": commit, "code": code, "box": box]
  try JSONSerialization.data(withJSONObject: fixture, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
} else {
  let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
  precondition(fixture["key"] as? String == keyText)
  precondition(fixture["commit"] as? String == commit)
  precondition(fixture["code"] as? String == code)
  let message = try QuickNativeCrypto.openJSON(fixture["box"] as! [String: Any], key: key, aad: "interop-v1")
  precondition(message["message"] as? String == "Hola desde Apple 🌎")
  print("Apple/Dart crypto vector verified")
}
