import AppKit
import Observation
import SplitrouteCore

/// Автообновление из GitHub Releases: appcast.json + DMG, подписанный ключом Ed25519.
@MainActor
@Observable
final class Updater {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Appcast)
        case downloading(Appcast, Double)
        case installing
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var lastCheck: Date? = UserDefaults.standard.object(forKey: "updateLastCheck") as? Date

    var autoCheck: Bool = UserDefaults.standard.object(forKey: "updateAutoCheck") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoCheck, forKey: "updateAutoCheck") }
    }

    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    static var currentBuild: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0" }

    /// Для проверки обновлений локально: `defaults write com.splitroute.app updateFeedURL file:///…/appcast.json`.
    private var feedURL: URL {
        UserDefaults.standard.string(forKey: "updateFeedURL").flatMap(URL.init(string:)) ?? UpdateFeed.feedURL
    }

    /// Запущено из временной копии (App Translocation) или с образа — заменить себя нельзя.
    static var isTranslocated: Bool {
        let p = Bundle.main.bundlePath
        return p.contains("/AppTranslocation/") || p.hasPrefix("/Volumes/")
    }

    var availableUpdate: Appcast? {
        if case .available(let a) = state { return a }
        return nil
    }

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        // Проверка цикла обновления целиком: SPLITROUTE_UPDATE_TEST=1 — сразу проверить и установить.
        if ProcessInfo.processInfo.environment["SPLITROUTE_UPDATE_TEST"] == "1" {
            Task {
                await check(userInitiated: true)
                if let a = availableUpdate { await install(a) }
            }
            return
        }
        Task {
            try? await Task.sleep(for: .seconds(15))
            while !Task.isCancelled {
                if autoCheck, HelperClient.runningFromBundle { await check(userInitiated: false) }
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }

    func check(userInitiated: Bool) async {
        if case .downloading = state { return }
        if state == .installing { return }
        state = .checking
        do {
            var req = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            req.setValue("Splitroute/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                state = .upToDate   // релизов ещё нет
                return
            }
            let appcast = try JSONDecoder().decode(Appcast.self, from: data)
            lastCheck = Date()
            UserDefaults.standard.set(lastCheck, forKey: "updateLastCheck")
            if UpdateFeed.isNewer(appcast.version, than: Self.currentVersion),
               ProcessInfo.processInfo.isOperatingSystemAtLeast(Self.osVersion(appcast.minimumSystemVersion)) {
                state = .available(appcast)
            } else {
                state = .upToDate
            }
        } catch {
            state = userInitiated ? .failed("Не удалось проверить обновления: \(error.localizedDescription)") : .idle
        }
    }

    func install(_ appcast: Appcast) async {
        guard !Self.isTranslocated else {
            state = .failed("Переместите Splitroute в папку «Программы» — оттуда приложение может обновлять себя")
            return
        }
        let target = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            state = .failed("Нет прав на запись в \(target.deletingLastPathComponent().path)")
            return
        }
        state = .downloading(appcast, 0)
        do {
            let file = try await Downloader.download(appcast.url) { [weak self] p in
                Task { @MainActor in self?.state = .downloading(appcast, p) }
            }
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            try UpdateFeed.verify(data, appcast: appcast)
            state = .installing
            let staged = try await Self.stage(dmg: file, appcast: appcast, next: target)
            try Self.relaunch(replacing: target, with: staged)
            NSApp.terminate(nil)
        } catch {
            state = .failed("Обновление не установлено: \(error.localizedDescription)")
        }
    }

    private static func osVersion(_ s: String) -> OperatingSystemVersion {
        let p = s.split(separator: ".").map { Int($0) ?? 0 }
        return OperatingSystemVersion(majorVersion: p.first ?? 0, minorVersion: p.count > 1 ? p[1] : 0, patchVersion: p.count > 2 ? p[2] : 0)
    }

    /// Монтирует образ и копирует новую версию рядом с текущей (тот же том — замена атомарна).
    private static func stage(dmg: URL, appcast: Appcast, next target: URL) async throws -> URL {
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("splitroute-mnt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try await shell("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        defer { Task.detached { try? await shell("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) } }

        let source = mount.appendingPathComponent("Splitroute.app")
        guard let info = NSDictionary(contentsOf: source.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleShortVersionString"] as? String == appcast.version,
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier
        else { throw UpdateError("в образе не та версия приложения") }

        let staged = target.deletingLastPathComponent().appendingPathComponent(".Splitroute-\(appcast.version)-\(UUID().uuidString.prefix(8)).app")
        try await shell("/usr/bin/ditto", [source.path, staged.path])
        _ = try? await shell("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        return staged
    }

    /// После выхода приложения: старую версию в сторону, новую на её место, запустить. Если что-то
    /// пошло не так — вернуть старую.
    private static func relaunch(replacing target: URL, with staged: URL) throws {
        let backup = target.deletingLastPathComponent().appendingPathComponent(".Splitroute-backup-\(UUID().uuidString.prefix(8)).app")
        let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        if mv \(q(target.path)) \(q(backup.path)) && mv \(q(staged.path)) \(q(target.path)); then
          rm -rf \(q(backup.path))
        else
          [ -d \(q(backup.path)) ] && [ ! -d \(q(target.path)) ] && mv \(q(backup.path)) \(q(target.path))
          rm -rf \(q(staged.path))
        fi
        open \(q(target.path))
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        try p.run()
    }

    struct UpdateError: LocalizedError {
        var message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    @discardableResult
    static func shell(_ path: String, _ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                do { try p.run() } catch { cont.resume(throwing: error); return }
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                p.waitUntilExit()
                if p.terminationStatus == 0 { cont.resume(returning: out) } else {
                    cont.resume(throwing: UpdateError("\((path as NSString).lastPathComponent): \(out.trimmingCharacters(in: .whitespacesAndNewlines))"))
                }
            }
        }
    }
}

/// Загрузка с прогрессом.
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?

    private init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }

    static func download(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let d = Downloader(progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: d, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { cont in
            d.continuation = cont
            session.downloadTask(with: URLRequest(url: url, timeoutInterval: 60)).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            continuation?.resume(throwing: Updater.UpdateError("HTTP \(http.statusCode)"))
            continuation = nil
            return
        }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("Splitroute-update-\(UUID().uuidString).dmg")
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            continuation?.resume(returning: dest)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
