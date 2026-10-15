import Foundation

public struct InstalledApp: Sendable, Equatable, Identifiable, Hashable {
    public var bundleID: String
    public var name: String
    public var path: String
    public var id: String { bundleID }
}

/// Установленные приложения из стандартных папок.
public enum AppCatalog {
    public static var searchRoots: [String] {
        [
            "/Applications", "/Applications/Utilities",
            NSHomeDirectory() + "/Applications",
            "/System/Applications", "/System/Applications/Utilities",
        ]
    }

    public static func scan(roots: [String] = searchRoots) -> [InstalledApp] {
        let fm = FileManager.default
        var seen = Set<String>()
        var result: [InstalledApp] = []
        for root in roots {
            guard let items = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for item in items where item.hasSuffix(".app") {
                let path = (root as NSString).appendingPathComponent(item)
                guard let app = app(at: path), seen.insert(app.bundleID).inserted else { continue }
                result.append(app)
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func app(at path: String) -> InstalledApp? {
        guard let bundle = Bundle(path: path), let id = bundle.bundleIdentifier else { return nil }
        let info = bundle.localizedInfoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return InstalledApp(bundleID: id, name: name, path: path)
    }

    /// Программы, путь к которым содержит номер версии: правило ставится на общую папку.
    /// `inHome` — папка в домашнем каталоге (её можно найти и предложить при добавлении).
    static let versionedFolders: [(marker: String, name: String, inHome: Bool)] = [
        ("/.local/share/claude/versions/", "Claude Code", true),
        ("/Library/Application Support/Claude/claude-code/", "Claude Code в приложении Claude", true),
        ("/.codex/packages/standalone/releases/", "Codex CLI", true),
        ("/Caskroom/codex/", "Codex CLI", false),
        ("/node_modules/@openai/codex/", "Codex CLI", false),
    ]

    /// Папка для версионной программы, если путь внутри одной из известных.
    public static func versionedFolder(for path: String) -> (path: String, name: String)? {
        for v in versionedFolders {
            if let r = path.range(of: v.marker) { return (String(path[..<r.upperBound]), v.name) }
        }
        return nil
    }

    /// Папки версионных программ, которые есть на этом Mac (для подсказок при добавлении).
    public static var installedVersionedFolders: [(path: String, name: String)] {
        let home = NSHomeDirectory()
        return versionedFolders.filter(\.inHome).map { (home + $0.marker, $0.name) }.filter { FileManager.default.fileExists(atPath: $0.0) }
    }

    /// Что поставить в правило для процесса: бандл .app или папку (с «/» на конце),
    /// чтобы правило пережило обновление программы.
    public static func routeTarget(forProcessPath path: String) -> (path: String, name: String) {
        if let folder = versionedFolder(for: path) { return folder }
        if let bundle = bundlePath(forProcessPath: path) ?? (path.hasSuffix(".app") ? path : nil) {
            return (bundle, app(at: bundle)?.name ?? ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension)
        }
        if path.hasSuffix("/") {
            return (path, (path as NSString).lastPathComponent)
        }
        return ((path as NSString).deletingLastPathComponent + "/", (path as NSString).lastPathComponent)
    }

    /// Бандл, которому принадлежит путь процесса, например `/Applications/WhatsApp.app/Contents/MacOS/WhatsApp` → `/Applications/WhatsApp.app`.
    public static func bundlePath(forProcessPath path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }
}
