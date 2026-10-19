// Ключ подписи обновлений (Ed25519). Приватный ключ хранится в связке ключей macOS, в репозиторий не попадает.
//   swift scripts/update-key.swift generate   — создать ключ (один раз) и напечатать публичный
//   swift scripts/update-key.swift public     — напечатать публичный ключ
//   swift scripts/update-key.swift sign FILE  — подписать SHA-256 файла, напечатать подпись (base64)
//   swift scripts/update-key.swift backup [FILE]   — зашифрованная копия ключа (фраза — в системном окне)
//   swift scripts/update-key.swift restore FILE    — вернуть ключ из копии в связку ключей
// Без ключа установленные копии Splitroute не примут ни одного обновления — храните копию вне этого Mac.
import CommonCrypto
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

/// Фраза в системном окне со скрытым вводом — не попадает ни в терминал, ни в аргументы процессов.
func askPassphrase(_ prompt: String) -> String? {
    let script = """
    display dialog "\(prompt)" default answer "" with hidden answer with title "Splitroute" buttons {"Отмена", "OK"} default button "OK"
    text returned of result
    """
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    try? p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines)
}

/// Формат копии: "SRKEY1" | соль 16 байт | число итераций (UInt32 BE) | AES-GCM (nonce+шифр+тег).
let magic = Data("SRKEY1".utf8)
let iterations: UInt32 = 600_000

func deriveKey(_ passphrase: String, salt: Data, rounds: UInt32) -> SymmetricKey {
    var key = [UInt8](repeating: 0, count: 32)
    let pass = Array(passphrase.utf8)
    _ = salt.withUnsafeBytes { s in
        CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pass.map { Int8(bitPattern: $0) }, pass.count,
                             s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                             CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &key, key.count)
    }
    return SymmetricKey(data: key)
}

func decrypt(_ blob: Data, passphrase: String) -> Curve25519.Signing.PrivateKey? {
    guard blob.count > magic.count + 20, blob.prefix(magic.count) == magic else { return nil }
    let salt = blob.subdata(in: 6..<22)
    let rounds = blob.subdata(in: 22..<26).reduce(0) { $0 << 8 | UInt32($1) }
    guard let box = try? AES.GCM.SealedBox(combined: blob.subdata(in: 26..<blob.count)),
          let raw = try? AES.GCM.open(box, using: deriveKey(passphrase, salt: salt, rounds: rounds))
    else { return nil }
    return try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
}

/// Публичный ключ, зашитый в приложение (Sources/SplitrouteCore/UpdateFeed.swift).
func shippedPublicKey() -> String? {
    let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../Sources/SplitrouteCore/UpdateFeed.swift")
    guard let text = try? String(contentsOf: src, encoding: .utf8),
          let r = text.range(of: #"publicKey = "([^"]+)""#, options: .regularExpression) else { return nil }
    return String(text[r]).components(separatedBy: "\"")[1]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

switch CommandLine.arguments.dropFirst().first {
case "backup":
    let path = CommandLine.arguments.count > 2 ? CommandLine.arguments[2]
        : NSHomeDirectory() + "/Documents/Splitroute-update-key.enc"
    let key = loadKey()
    guard let p1 = askPassphrase("Придумайте фразу для резервной копии ключа подписи обновлений Splitroute (не короче 12 символов). Без неё копию не открыть."),
          let p2 = askPassphrase("Повторите фразу") else { fail("Отменено") }
    guard p1 == p2 else { fail("Фразы не совпадают") }
    guard p1.count >= 12 else { fail("Фраза короче 12 символов") }
    var salt = Data(count: 16)
    _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
    let sealed = try AES.GCM.seal(key.rawRepresentation, using: deriveKey(p1, salt: salt, rounds: iterations))
    var blob = magic + salt
    withUnsafeBytes(of: iterations.bigEndian) { blob.append(contentsOf: $0) }
    blob.append(sealed.combined!)
    try blob.write(to: URL(fileURLWithPath: path), options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    // Проверка: копия открывается той же фразой и даёт тот же ключ, что зашит в приложение.
    guard let back = decrypt(try Data(contentsOf: URL(fileURLWithPath: path)), passphrase: p1),
          back.rawRepresentation == key.rawRepresentation else { fail("Проверка копии не прошла — файл не годится") }
    let pub = back.publicKey.rawRepresentation.base64EncodedString()
    if let shipped = shippedPublicKey(), shipped != pub { fail("Ключ в связке не совпадает с ключом в приложении!") }
    print("Копия ключа: \(path)")
    print("Проверено: открывается фразой, публичный ключ \(pub) совпадает с приложением.")
case "restore":
    guard CommandLine.arguments.count > 2 else { fail("usage: update-key.swift restore FILE") }
    let blob = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
    guard let pass = askPassphrase("Фраза от резервной копии ключа Splitroute") else { fail("Отменено") }
    guard let key = decrypt(blob, passphrase: pass) else { fail("Неверная фраза или повреждённый файл") }
    let pub = key.publicKey.rawRepresentation.base64EncodedString()
    if let shipped = shippedPublicKey(), shipped != pub { fail("Это не тот ключ, что зашит в приложение") }
    _ = security(["delete-generic-password", "-s", service, "-a", "splitroute"])
    let (status, _) = security(["add-generic-password", "-s", service, "-a", "splitroute", "-l", "Splitroute update signing key",
                                "-w", key.rawRepresentation.base64EncodedString()])
    guard status == 0 else { fail("Не удалось сохранить ключ в связку ключей") }
    print("Ключ восстановлен, публичный: \(pub)")
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
    print("usage: update-key.swift generate | public | sign FILE | backup [FILE] | restore FILE")
}
