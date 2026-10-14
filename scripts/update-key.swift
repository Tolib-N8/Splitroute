// Ключ подписи обновлений (Ed25519). Приватный ключ хранится в связке ключей macOS, в репозиторий не попадает.
//   swift scripts/update-key.swift generate   — создать ключ (один раз) и напечатать публичный
//   swift scripts/update-key.swift public     — напечатать публичный ключ
//   swift scripts/update-key.swift sign FILE  — подписать SHA-256 файла, напечатать подпись (base64)
import CryptoKit
import Foundation

let service = "splitroute-update-signing"

func security(_ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    try! p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
}

func loadKey() -> Curve25519.Signing.PrivateKey {
    let (status, b64) = security(["find-generic-password", "-s", service, "-a", "splitroute", "-w"])
    guard status == 0, let raw = Data(base64Encoded: b64), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        FileHandle.standardError.write(Data("Нет ключа в связке ключей. Создайте: swift scripts/update-key.swift generate\n".utf8))
        exit(1)
    }
    return key
}

switch CommandLine.arguments.dropFirst().first {
case "generate":
    if security(["find-generic-password", "-s", service, "-a", "splitroute"]).0 == 0 {
        FileHandle.standardError.write(Data("Ключ уже есть — не перезаписываю.\n".utf8))
        print(loadKey().publicKey.rawRepresentation.base64EncodedString())
        exit(0)
    }
    let key = Curve25519.Signing.PrivateKey()
    let (status, _) = security(["add-generic-password", "-s", service, "-a", "splitroute", "-l", "Splitroute update signing key",
                                "-w", key.rawRepresentation.base64EncodedString()])
    guard status == 0 else { FileHandle.standardError.write(Data("Не удалось сохранить ключ\n".utf8)); exit(1) }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "public":
    print(loadKey().publicKey.rawRepresentation.base64EncodedString())
case "sign":
    let file = URL(fileURLWithPath: CommandLine.arguments[2])
    let digest = Data(SHA256.hash(data: try Data(contentsOf: file)))
    print(try loadKey().signature(for: digest).base64EncodedString())
default:
    print("usage: update-key.swift generate | public | sign FILE")
}
