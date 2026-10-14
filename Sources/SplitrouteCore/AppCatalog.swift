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

    /// Бандл, которому принадлежит путь процесса, например `/Applications/WhatsApp.app/Contents/MacOS/WhatsApp` → `/Applications/WhatsApp.app`.
    public static func bundlePath(forProcessPath path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }
}
