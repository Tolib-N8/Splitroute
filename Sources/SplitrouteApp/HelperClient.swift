import Foundation
import SplitrouteCore

/// Вызовы root-helper'а: установка через пароль администратора, остальное через `sudo -n`.
enum HelperClient {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    struct Status: Decodable {
        var installed: Bool
        var running: Bool
        var pid: Int
        /// Старые helper'ы поле не отдают — это протокол 1.
        var `protocol`: Int?
    }

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: Paths.helper)
            && FileManager.default.fileExists(atPath: Paths.sudoers)
            && FileManager.default.fileExists(atPath: Paths.launchDaemonPlist)
    }

    static var bundledHelper: String { Bundle.main.bundlePath + "/Contents/MacOS/splitroute-helper" }
    static var runningFromBundle: Bool { FileManager.default.isExecutableFile(atPath: bundledHelper) }

    /// Установленный helper старше, чем нужно этой версии приложения.
    static func needsUpdate() async -> Bool {
        guard runningFromBundle, isInstalled else { return false }
        guard let status = await status() else { return true }
        return (status.protocol ?? 1) < HelperProtocol.version
    }

    /// Установка: один запрос пароля администратора.
    static func install() async throws {
        guard runningFromBundle else {
            throw Failure(message: "Установка доступна только из собранного Splitroute.app (scripts/bundle.sh)")
        }
        let cmd = [bundledHelper, "install", NSUserName(), Bundle.main.bundlePath].map(shellQuote).joined(separator: " ")
        let script = "do shell script \(appleScriptQuote(cmd)) with administrator privileges with prompt \"Splitroute устанавливает системный компонент для маршрутизации трафика.\""
        _ = try await run("/usr/bin/osascript", ["-e", script])
    }

    /// Удаление: через пароль администратора (в sudoers тоже есть, но так надёжнее, если правило сломано).
    static func uninstall() async throws {
        let script = "do shell script \(appleScriptQuote(shellQuote(Paths.helper) + " uninstall")) with administrator privileges"
        _ = try await run("/usr/bin/osascript", ["-e", script])
    }

    @discardableResult
    static func call(_ command: String) async throws -> String {
        try await run("/usr/bin/sudo", ["-n", Paths.helper, command])
    }

    static func status() async -> Status? {
        guard isInstalled, let out = try? await call("status") else { return nil }
        return try? JSONDecoder().decode(Status.self, from: Data(out.utf8))
    }

    private static func run(_ path: String, _ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                do {
                    try p.run()
                } catch {
                    cont.resume(throwing: error)
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if p.terminationStatus == 0 {
                    cont.resume(returning: out)
                } else {
                    let msg = out.replacingOccurrences(of: "splitroute-helper: ", with: "")
                    cont.resume(throwing: Failure(message: msg.isEmpty ? "Ошибка \(p.terminationStatus)" : msg))
                }
            }
        }
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
