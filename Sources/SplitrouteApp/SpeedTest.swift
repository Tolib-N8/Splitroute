import Foundation

/// Результат замера скорости одного выхода.
struct SpeedResult: Equatable {
    /// Байт/с; 0 — не скачалось ничего.
    var bytesPerSecond: Double
    /// До первого байта ответа, мс.
    var latencyMs: Int?
    var at: Date

    var failed: Bool { bytesPerSecond <= 0 }
}

/// Скачивание тестового файла через конкретный выход: SOCKS5 на входе «probe-in» ядра,
/// пользователь = тег выхода, пароль = секрет API. Первая секунда — разгон, она не считается.
enum SpeedTest {
    static let url = URL(string: "https://speed.cloudflare.com/__down?bytes=25000000")!
    static let limit: TimeInterval = 7
    static let warmup: TimeInterval = 1

    static func run(tag: String, probe: String, secret: String) async -> SpeedResult {
        guard let colon = probe.lastIndex(of: ":"), let port = Int(probe[probe.index(after: colon)...]) else {
            return SpeedResult(bytesPerSecond: 0, at: Date())
        }
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [
            kCFNetworkProxiesSOCKSEnable as String: 1,
            kCFNetworkProxiesSOCKSProxy as String: String(probe[..<colon]),
            kCFNetworkProxiesSOCKSPort as String: port,
            kCFStreamPropertySOCKSUser as String: tag,
            kCFStreamPropertySOCKSPassword as String: secret,
        ]
        config.timeoutIntervalForRequest = 10
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let probeDelegate = Probe()
        let session = URLSession(configuration: config, delegate: probeDelegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return await probeDelegate.measure(session.dataTask(with: url))
    }

    private final class Probe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var start = Date()
        private var firstByte: Date?
        private var bytes = 0, warmBytes = 0
        private var continuation: CheckedContinuation<SpeedResult, Never>?
        private var task: URLSessionDataTask?

        func measure(_ task: URLSessionDataTask) async -> SpeedResult {
            await withCheckedContinuation { cont in
                lock.withLock {
                    continuation = cont
                    self.task = task
                    start = Date()
                }
                task.resume()
                DispatchQueue.global().asyncAfter(deadline: .now() + SpeedTest.limit) { [weak self] in self?.finish() }
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.withLock {
                let now = Date()
                if firstByte == nil { firstByte = now }
                bytes += data.count
                if now.timeIntervalSince(firstByte!) < SpeedTest.warmup { warmBytes = bytes }
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            finish()
        }

        private func finish() {
            let (cont, result): (CheckedContinuation<SpeedResult, Never>?, SpeedResult) = lock.withLock {
                let now = Date()
                var rate = 0.0
                if let fb = firstByte {
                    let total = now.timeIntervalSince(fb)
                    // После разгона — честная скорость; если файл пришёл почти сразу — считаем всё.
                    rate = total > SpeedTest.warmup + 0.5
                        ? Double(bytes - warmBytes) / (total - SpeedTest.warmup)
                        : Double(bytes) / max(total, 0.05)
                }
                let latency = firstByte.map { Int($0.timeIntervalSince(start) * 1000) }
                let c = continuation
                continuation = nil
                return (c, SpeedResult(bytesPerSecond: rate, latencyMs: latency, at: now))
            }
            guard let cont else { return }
            task?.cancel()
            cont.resume(returning: result)
        }
    }
}
