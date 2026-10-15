import Foundation
import SplitrouteCore

/// Одно соединение в журнале.
struct JournalEntry: Codable, Identifiable, Hashable {
    var id: String
    var start: Date
    var end: Date?
    var appKey: String
    var host: String
    var network: String
    var exitTag: String
    var reason: String
    var bytes: Int64
    var rejected: Bool = false
    /// Получено байт; nil — записи старых версий. Ноль у завершённого соединения — признак блокировки.
    var download: Int64?

    var duration: TimeInterval { (end ?? Date()).timeIntervalSince(start) }
}

/// Журнал соединений: живые + завершённые за сегодня в памяти, на диске — по файлу JSONL на день, 7 дней.
struct Journal {
    static let keepDays = 7
    static let memoryLimit = 5000

    private(set) var entries: [JournalEntry] = []   // новые в начале
    private(set) var todayCount = 0
    private var live: [String: Int] = [:]           // id соединения → индекс в entries
    private var day = Self.dayString(Date())

    static var dir: URL {
        Paths.userProfile.deletingLastPathComponent().appendingPathComponent("journal", isDirectory: true)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func dayString(_ d: Date) -> String { dayFormatter.string(from: d) }

    static func load() -> Journal {
        var j = Journal()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        j.pruneFiles()
        let url = dir.appendingPathComponent(j.day + ".jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return j }
        let dec = Self.decoder
        let lines = text.split(separator: "\n")
        j.todayCount = lines.count
        j.entries = lines.suffix(memoryLimit).reversed().compactMap { try? dec.decode(JournalEntry.self, from: Data($0.utf8)) }
        return j
    }

    /// Обновление по снимку `/connections`.
    mutating func update(with connections: [Connection], resolve: (Connection) -> (appKey: String, reason: String)) {
        let now = Date()
        if Self.dayString(now) != day {
            day = Self.dayString(now)
            todayCount = 0
        }
        var current = Set<String>()
        for c in connections {
            current.insert(c.id)
            let bytes = c.upload + c.download
            if let i = live[c.id], i < entries.count, entries[i].id == c.id {
                entries[i].bytes = bytes
                entries[i].download = c.download
                continue
            }
            let r = resolve(c)
            let host = c.metadata.host.flatMap { $0.isEmpty ? nil : $0 }
                ?? [c.metadata.destinationIP, c.metadata.destinationPort].compactMap { $0 }.joined(separator: ":")
            entries.insert(JournalEntry(
                id: c.id, start: now, appKey: r.appKey, host: host, network: c.metadata.network ?? "tcp",
                exitTag: c.outboundTag ?? "direct", reason: r.reason, bytes: bytes, download: c.download
            ), at: 0)
            todayCount += 1
            reindex()
        }
        // Завершённые соединения — на диск.
        var finished: [JournalEntry] = []
        for (id, i) in live where !current.contains(id) && i < entries.count {
            entries[i].end = now
            finished.append(entries[i])
        }
        if !finished.isEmpty { append(finished) }
        live = live.filter { current.contains($0.key) }
        if entries.count > Self.memoryLimit {
            entries.removeLast(entries.count - Self.memoryLimit)
            reindex()
        }
    }

    private mutating func reindex() {
        var map: [String: Int] = [:]
        for (i, e) in entries.prefix(800).enumerated() where e.end == nil { map[e.id] = i }
        live = map
    }

    private func append(_ items: [JournalEntry]) {
        let url = Self.dir.appendingPathComponent(day + ".jsonl")
        let enc = Self.encoder
        var data = Data()
        for e in items {
            guard let d = try? enc.encode(e) else { continue }
            data.append(d)
            data.append(0x0A)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    private func pruneFiles() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: Self.dir.path) else { return }
        let cutoff = Self.dayString(Date().addingTimeInterval(-Double(Self.keepDays) * 86400))
        for f in files where f.hasSuffix(".jsonl") && f < cutoff + ".jsonl" {
            try? fm.removeItem(at: Self.dir.appendingPathComponent(f))
        }
    }

    /// CSV для экспорта.
    static func csv(_ entries: [JournalEntry], appName: (String) -> String, exitName: (String) -> String) -> String {
        let f = ISO8601DateFormatter()
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var out = "time,app,host,network,route,reason,bytes,duration_s\n"
        for e in entries {
            out += [f.string(from: e.start), q(appName(e.appKey)), q(e.host), e.network, q(exitName(e.exitTag)), q(e.reason),
                    String(e.bytes), String(format: "%.1f", e.duration)].joined(separator: ",") + "\n"
        }
        return out
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }
}
