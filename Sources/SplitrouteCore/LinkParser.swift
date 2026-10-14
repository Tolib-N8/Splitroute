import Foundation

public struct ParsedProxy: Sendable, Equatable {
    public var name: String
    public var config: ProxyConfig

    public init(name: String, config: ProxyConfig) {
        self.name = name
        self.config = config
    }
}

public enum ParseError: Error, Equatable, LocalizedError {
    case unsupportedScheme(String)
    case missing(String)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedScheme(let s): return "Неподдерживаемый формат: \(s)"
        case .missing(let f): return "Не хватает поля: \(f)"
        case .invalid(let f): return "Некорректное значение: \(f)"
        }
    }
}

/// Разбор ссылок и файлов конфигураций в типизированные `ProxyConfig`.
public enum LinkParser {

    /// Любой поддерживаемый текст: одна ссылка, список ссылок, base64-подписка, WireGuard .conf или .ovpn.
    public static func parseAny(_ text: String, fileName: String? = nil) throws -> [ParsedProxy] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = fileName.map { ($0 as NSString).deletingPathExtension }
        if trimmed.contains("[Interface]") && trimmed.contains("[Peer]") {
            return [try parseWireGuard(trimmed, name: baseName)]
        }
        if isOpenVPN(trimmed) {
            return [try parseOpenVPN(trimmed, name: baseName)]
        }
        let lines = trimmed.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if lines.contains(where: { $0.contains("://") }) {
            let parsed = lines.compactMap { try? parseLink($0) }
            if parsed.isEmpty, let first = lines.first { _ = try parseLink(first) }
            return parsed
        }
        if let decoded = decodeBase64(trimmed), decoded.contains("://") {
            return try parseAny(decoded)
        }
        throw ParseError.unsupportedScheme(String(trimmed.prefix(24)))
    }

    public static func parseLink(_ link: String) throws -> ParsedProxy {
        guard let schemeEnd = link.range(of: "://") else { throw ParseError.unsupportedScheme(link) }
        let scheme = link[..<schemeEnd.lowerBound].lowercased()
        switch scheme {
        case "vless": return try parseVLESS(link)
        case "ss": return try parseShadowsocks(link)
        case "trojan": return try parseTrojan(link)
        case "hysteria2", "hy2": return try parseHysteria2(link)
        default: throw ParseError.unsupportedScheme(scheme)
        }
    }

    // MARK: - Ссылки

    private struct LinkParts {
        var user: String
        var host: String
        var port: Int
        var query: [String: String]
        var name: String
    }

    private static func parts(_ link: String, defaultPort: Int? = nil) throws -> LinkParts {
        // URLComponents не любит некоторые символы во фрагменте — отрезаем его заранее.
        var body = link
        var name = ""
        if let hash = body.firstIndex(of: "#") {
            name = String(body[body.index(after: hash)...]).removingPercentEncoding ?? ""
            body = String(body[..<hash])
        }
        guard let c = URLComponents(string: body) else { throw ParseError.invalid("url") }
        guard let host = c.host, !host.isEmpty else { throw ParseError.missing("host") }
        guard let port = c.port ?? defaultPort else { throw ParseError.missing("port") }
        var query: [String: String] = [:]
        for item in c.queryItems ?? [] { query[item.name.lowercased()] = item.value ?? "" }
        let user = (c.percentEncodedUser ?? "").removingPercentEncoding ?? ""
        let cleanHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return LinkParts(user: user, host: cleanHost, port: port, query: query, name: name.isEmpty ? cleanHost : name)
    }

    private static func tls(from q: [String: String], defaultSNI: String?) -> TLSOptions {
        var t = TLSOptions()
        t.serverName = nonEmpty(q["sni"]) ?? nonEmpty(q["peer"]) ?? defaultSNI
        t.insecure = ["1", "true"].contains(q["allowinsecure"] ?? q["insecure"] ?? "")
        t.alpn = (q["alpn"] ?? "").split(separator: ",").map(String.init)
        t.fingerprint = nonEmpty(q["fp"])
        if let pbk = nonEmpty(q["pbk"]) {
            t.reality = .init(publicKey: pbk, shortID: q["sid"] ?? "")
        }
        return t
    }

    private static func transport(from q: [String: String]) -> Transport? {
        switch q["type"] ?? "tcp" {
        case "ws": return Transport(kind: .ws, path: nonEmpty(q["path"]), host: nonEmpty(q["host"]))
        case "grpc": return Transport(kind: .grpc, serviceName: nonEmpty(q["servicename"]))
        case "httpupgrade": return Transport(kind: .httpupgrade, path: nonEmpty(q["path"]), host: nonEmpty(q["host"]))
        case "http", "h2": return Transport(kind: .http, path: nonEmpty(q["path"]), host: nonEmpty(q["host"]))
        default: return nil
        }
    }

    static func parseVLESS(_ link: String) throws -> ParsedProxy {
        let p = try parts(link)
        guard !p.user.isEmpty else { throw ParseError.missing("uuid") }
        let security = p.query["security"] ?? "none"
        let tlsOpts: TLSOptions? = (security == "tls" || security == "reality") ? tls(from: p.query, defaultSNI: nil) : nil
        let v = VLESS(server: p.host, port: p.port, uuid: p.user, flow: nonEmpty(p.query["flow"]), tls: tlsOpts, transport: transport(from: p.query))
        return ParsedProxy(name: p.name, config: .vless(v))
    }

    static func parseTrojan(_ link: String) throws -> ParsedProxy {
        let p = try parts(link, defaultPort: 443)
        guard !p.user.isEmpty else { throw ParseError.missing("password") }
        let v = Trojan(server: p.host, port: p.port, password: p.user, tls: tls(from: p.query, defaultSNI: p.host), transport: transport(from: p.query))
        return ParsedProxy(name: p.name, config: .trojan(v))
    }

    static func parseHysteria2(_ link: String) throws -> ParsedProxy {
        let p = try parts(link, defaultPort: 443)
        var t = tls(from: p.query, defaultSNI: p.host)
        if t.alpn.isEmpty { t.alpn = ["h3"] }
        let obfs = p.query["obfs"] == "salamander" ? nonEmpty(p.query["obfs-password"]) : nil
        let v = Hysteria2(server: p.host, port: p.port, password: p.user, obfsPassword: obfs, tls: t)
        return ParsedProxy(name: p.name, config: .hysteria2(v))
    }

    static func parseShadowsocks(_ link: String) throws -> ParsedProxy {
        var body = String(link.dropFirst("ss://".count))
        var name = ""
        if let hash = body.firstIndex(of: "#") {
            name = String(body[body.index(after: hash)...]).removingPercentEncoding ?? ""
            body = String(body[..<hash])
        }
        if let q = body.firstIndex(of: "?") { body = String(body[..<q]) }
        // Старый формат: ss://base64(method:password@host:port)
        if !body.contains("@"), let decoded = decodeBase64(body) { body = decoded }
        guard let at = body.lastIndex(of: "@") else { throw ParseError.invalid("ss") }
        var userinfo = String(body[..<at])
        let hostPort = String(body[body.index(after: at)...])
        if !userinfo.contains(":"), let decoded = decodeBase64(userinfo.removingPercentEncoding ?? userinfo) {
            userinfo = decoded
        } else {
            userinfo = userinfo.removingPercentEncoding ?? userinfo
        }
        guard let colon = userinfo.firstIndex(of: ":") else { throw ParseError.missing("password") }
        let (host, port) = try splitHostPort(hostPort)
        let v = Shadowsocks(server: host, port: port, method: String(userinfo[..<colon]), password: String(userinfo[userinfo.index(after: colon)...]))
        return ParsedProxy(name: name.isEmpty ? host : name, config: .shadowsocks(v))
    }

    // MARK: - WireGuard

    public static func parseWireGuard(_ text: String, name: String? = nil) throws -> ParsedProxy {
        var section = ""
        var iface: [String: String] = [:]
        var peer: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if line.isEmpty { continue }
            if line.hasPrefix("[") { section = line.lowercased(); continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if section == "[interface]" { iface[key] = value } else if section == "[peer]", peer[key] == nil { peer[key] = value }
        }
        guard let privateKey = iface["privatekey"] else { throw ParseError.missing("PrivateKey") }
        guard let publicKey = peer["publickey"] else { throw ParseError.missing("PublicKey") }
        guard let endpoint = peer["endpoint"] else { throw ParseError.missing("Endpoint") }
        let (host, port) = try splitHostPort(endpoint)
        let list = { (s: String?) in (s ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        let wg = WireGuard(
            privateKey: privateKey,
            addresses: list(iface["address"]),
            mtu: iface["mtu"].flatMap { Int($0) },
            peer: .init(
                server: host, port: port, publicKey: publicKey,
                preSharedKey: peer["presharedkey"],
                allowedIPs: list(peer["allowedips"]),
                keepalive: peer["persistentkeepalive"].flatMap { Int($0) }
            )
        )
        return ParsedProxy(name: name ?? host, config: .wireguard(wg))
    }

    // MARK: - OpenVPN

    static func isOpenVPN(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            return l.hasPrefix("remote ") || l == "client" || l.hasPrefix("<ca>")
        } && !text.contains("://")
    }

    public static func parseOpenVPN(_ text: String, name: String? = nil) throws -> ParsedProxy {
        var blocks: [String: String] = [:]
        var directives: [[String]] = []
        var currentBlock: String?
        var blockLines: [String] = []

        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let block = currentBlock {
                if line == "</\(block)>" {
                    blocks[block] = blockLines.joined(separator: "\n")
                    currentBlock = nil
                    blockLines = []
                } else {
                    blockLines.append(line)
                }
                continue
            }
            if line.hasPrefix("<"), line.hasSuffix(">"), !line.hasPrefix("</") {
                currentBlock = String(line.dropFirst().dropLast())
                continue
            }
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            directives.append(line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init))
        }

        func args(_ name: String) -> [String]? { directives.first { $0.first == name }.map { Array($0.dropFirst()) } }

        var defaultProto = normalizeProto(args("proto")?.first ?? "udp")
        if defaultProto.isEmpty { defaultProto = "udp" }
        let defaultPort = args("port").flatMap { $0.first }.flatMap { Int($0) } ?? 1194

        var remotes: [OpenVPN.Remote] = []
        for d in directives where d.first == "remote" && d.count >= 2 {
            let port = d.count >= 3 ? Int(d[2]) ?? defaultPort : defaultPort
            let proto = d.count >= 4 ? normalizeProto(d[3]) : defaultProto
            remotes.append(.init(host: d[1], port: port, proto: proto))
        }
        guard !remotes.isEmpty else { throw ParseError.missing("remote") }
        guard let ca = blocks["ca"] else { throw ParseError.missing("<ca>") }

        let keyDirection = args("key-direction")?.first
        var wrap: OpenVPN.ControlWrap?
        if let key = blocks["tls-crypt-v2"] {
            wrap = .init(type: "tls_crypt_v2", key: key, direction: nil)
        } else if let key = blocks["tls-crypt"] {
            wrap = .init(type: "tls_crypt", key: key, direction: nil)
        } else if let key = blocks["tls-auth"] {
            let dir = keyDirection ?? args("tls-auth")?.dropFirst().first
            wrap = .init(type: "tls_auth", key: key, direction: dir == "1" ? "client" : dir == "0" ? "server" : nil)
        }

        var compression: String?
        if let c = args("compress") { compression = c.first ?? "stub" }
        var lzo: String?
        if let c = args("comp-lzo") { lzo = c.first ?? "adaptive" }

        var cfg = OpenVPN(remotes: remotes, ca: ca)
        cfg.cert = blocks["cert"]
        cfg.key = blocks["key"]
        cfg.controlWrap = wrap
        cfg.dataCiphers = (args("data-ciphers") ?? args("ncp-ciphers"))?.first.map { $0.split(separator: ":").map(String.init) } ?? []
        cfg.dataCiphersFallback = args("data-ciphers-fallback")?.first ?? args("cipher")?.first
        cfg.auth = args("auth")?.first
        cfg.compression = compression
        cfg.compressionLZO = lzo
        cfg.verifyName = args("verify-x509-name")?.first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }
        cfg.remoteCertTLS = args("remote-cert-tls")?.first
        cfg.passwordRequired = args("auth-user-pass") != nil
        return ParsedProxy(name: name ?? remotes[0].host, config: .openvpn(cfg))
    }

    private static func normalizeProto(_ p: String) -> String {
        p.lowercased().hasPrefix("tcp") ? "tcp" : "udp"
    }

    // MARK: - Утилиты

    static func splitHostPort(_ s: String) throws -> (String, Int) {
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            let host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()) else { throw ParseError.missing("port") }
            return (host, port)
        }
        guard let colon = s.lastIndex(of: ":"), let port = Int(s[s.index(after: colon)...]) else { throw ParseError.missing("port") }
        return (String(s[..<colon]), port)
    }

    static func decodeBase64(_ s: String) -> String? {
        var b = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b.append("=") }
        guard let data = Data(base64Encoded: b) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}

/// Загрузка ссылки-подписки.
public enum Subscription {
    public static func fetch(_ url: URL) async throws -> [ParsedProxy] {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Splitroute/1.0 (sing-box)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ParseError.invalid("HTTP \(http.statusCode)")
        }
        guard let text = String(data: data, encoding: .utf8) else { throw ParseError.invalid("encoding") }
        return try LinkParser.parseAny(text)
    }
}
