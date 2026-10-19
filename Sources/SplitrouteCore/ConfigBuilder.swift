import Foundation

/// Состояние сети в момент сборки конфига.
public struct NetworkEnvironment: Sendable, Equatable {
    public struct VPNService: Sendable, Equatable {
        public var interface: String
        /// Адрес VPN-сервера; исключаем его из TUN, иначе трафик самого VPN-приложения может уйти в петлю.
        public var serverAddress: String?
        /// Есть ли у туннеля глобальный IPv6 (ULA вроде fd00::/8 не считается).
        public var ipv6: Bool

        public init(interface: String, serverAddress: String? = nil, ipv6: Bool = false) {
            self.interface = interface
            self.serverAddress = serverAddress
            self.ipv6 = ipv6
        }
    }

    /// Wi‑Fi / Ethernet, через который идёт «Напрямую». `nil`, если сети нет.
    public var physicalInterface: String?
    /// Есть ли у физической сети глобальный IPv6.
    public var physicalIPv6: Bool
    /// Подключённые VPN-сервисы по ID сервиса.
    public var vpnServices: [String: VPNService]
    /// Выходы (id), которые подключены, но не пропускают трафик — по проверке приложения (health.json).
    public var unhealthy: Set<String>
    /// Адрес TUN ядра (/30), не пересекающийся с чужими интерфейсами — см. `ConfigBuilder.chooseTunAddress`.
    public var tunAddress: String

    public init(physicalInterface: String?, physicalIPv6: Bool = false, vpnServices: [String: VPNService] = [:],
                unhealthy: Set<String> = [], tunAddress: String = ConfigBuilder.tunAddress4) {
        self.physicalInterface = physicalInterface
        self.physicalIPv6 = physicalIPv6
        self.vpnServices = vpnServices
        self.unhealthy = unhealthy
        self.tunAddress = tunAddress
    }
}

public struct ConfigOptions: Sendable, Equatable {
    public var apiListen: String
    public var apiSecret: String
    public var cacheFilePath: String?
    public var logLevel: String
    /// Папка с файлами `<tag>.srs` и какие из них на месте. Наборы без файлов пропускаются.
    public var ruleSetsDir: String
    public var availableRuleSets: Set<String>
    /// Локальный вход для проверки выходов (замер скорости, живость): `host:port` или nil — без него.
    public var probeListen: String?

    public init(
        apiListen: String = "127.0.0.1:9095", apiSecret: String, cacheFilePath: String? = nil, logLevel: String = "warn",
        ruleSetsDir: String = Paths.ruleSetsDir, availableRuleSets: Set<String> = [], probeListen: String? = nil
    ) {
        self.probeListen = probeListen
        self.apiListen = apiListen
        self.apiSecret = apiSecret
        self.cacheFilePath = cacheFilePath
        self.logLevel = logLevel
        self.ruleSetsDir = ruleSetsDir
        self.availableRuleSets = availableRuleSets
    }
}

/// Собирает конфиг sing-box из профиля пользователя.
public struct ConfigBuilder: Sendable {
    /// Адрес TUN не должен попадать ни в один исключённый диапазон, иначе ответы ядра
    /// уйдут мимо TUN и ни одно соединение не заработает (так было с 172.19.0.1 внутри 172.16.0.0/12).
    public static let tunAddress4 = "198.18.0.1/30"
    /// Запасные адреса TUN: 198.18.0.0/15 любят клиенты на Xray/sing-box (ZoogVPN занимает 198.18.0.0/16
    /// целиком), и тогда маршруты через «наш» 198.18.0.1 уходят в чужой туннель — весь трафик мимо Splitroute.
    public static let tunCandidates = ["198.18.0.1/30", "198.19.254.1/30", "203.0.113.1/30", "192.0.2.1/30"]
    public static let tunAddress6 = "fdfe:dcba:9876::1/126"
    /// DNS ядра внутри TUN: следующий адрес после tunAddress4; sing-box перехватывает запросы к нему.
    public static let tunDNS = "198.18.0.2"

    /// DNS ядра внутри TUN — следующий адрес после адреса TUN.
    public static func dnsAddress(forTun tun: String) -> String {
        guard let (addr, _) = parseCIDR(tun) else { return tunDNS }
        return formatIPv4(addr + 1)
    }

    /// Первый адрес-кандидат, не пересекающийся с чужими интерфейсами. Свой TUN (тот же адрес, /30) —
    /// не помеха: так адрес не прыгает при каждом пересчёте. Свободный свой — в приоритете.
    public static func chooseTunAddress(occupied: [(address: UInt32, prefix: Int)]) -> String {
        func network(_ a: UInt32, _ p: Int) -> (UInt32, UInt32) {
            let mask: UInt32 = p == 0 ? 0 : ~UInt32(0) << UInt32(32 - p)
            return (a & mask, mask)
        }
        func free(_ cidr: String) -> (free: Bool, ours: Bool) {
            guard let (addr, prefix) = parseCIDR(cidr) else { return (false, false) }
            var ours = false
            for o in occupied {
                if o.address == addr && o.prefix == prefix { ours = true; continue }
                let p = min(prefix, o.prefix)
                if network(addr, p).0 == network(o.address, p).0 { return (false, ours) }
            }
            return (true, ours)
        }
        let checked = tunCandidates.map { ($0, free($0)) }
        return checked.first { $0.1.free && $0.1.ours }?.0 ?? checked.first { $0.1.free }?.0 ?? tunAddress4
    }

    static func parseCIDR(_ s: String) -> (UInt32, Int)? {
        let parts = s.split(separator: "/")
        let octets = parts[0].split(separator: ".").compactMap { UInt32($0) }
        guard octets.count == 4, octets.allSatisfy({ $0 < 256 }) else { return nil }
        let prefix = parts.count > 1 ? Int(parts[1]) ?? 32 : 32
        return (octets[0] << 24 | octets[1] << 16 | octets[2] << 8 | octets[3], prefix)
    }

    static func formatIPv4(_ a: UInt32) -> String {
        "\(a >> 24 & 255).\(a >> 16 & 255).\(a >> 8 & 255).\(a & 255)"
    }
    /// Локальные имена всегда резолвит роутер.
    public static let localDomains = ["lan", "local", "home.arpa", "localhost"]

    /// Не забираем в TUN: локальные сети, Tailscale, link-local, мультикаст.
    public static let baseExcludedRoutes = [
        "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16",
        "100.64.0.0/10", "224.0.0.0/4", "255.255.255.255/32",
        "fe80::/10", "fd7a:115c:a1e0::/48", "ff00::/8",
    ]

    public enum Target: Equatable {
        case outbound(String)
        case reject
    }

    public let profile: Profile
    public let environment: NetworkEnvironment
    public let options: ConfigOptions

    public init(profile: Profile, environment: NetworkEnvironment, options: ConfigOptions) {
        self.profile = profile
        self.environment = environment
        self.options = options
    }

    // MARK: - Разрешение выходов

    /// Куда фактически отправится трафик выхода с учётом состояния сети, резерва и kill switch.
    public func target(forExitID id: String) -> Target {
        switch profile.resolve(exitID: id, in: environment) {
        case .reject: return .reject
        case .exit(let e, _): return .outbound(e.tag)
        }
    }

    /// Выход, которому принадлежит тег (после резерва это может быть не исходный выход).
    private func exitID(forTag tag: String) -> String {
        profile.allExits.first { $0.tag == tag }?.id ?? Exit.directID
    }

    /// Работает ли IPv6 через выход. Если нет — IPv6-соединения отклоняются сразу,
    /// и приложения мгновенно переходят на IPv4, а не ждут таймаута.
    public func supportsIPv6(exitID id: String) -> Bool {
        if profile.disableIPv6 { return false }
        guard let exit = profile.exit(id: id) else { return environment.physicalIPv6 }
        switch exit.kind {
        case .direct: return environment.physicalIPv6
        case .block: return true
        case .proxy: return true
        case .auto: return profile.autoCandidates(in: environment).allSatisfy { supportsIPv6(exitID: $0.id) }
        case .vpnApp(let serviceID): return environment.vpnServices[serviceID]?.ipv6 ?? false
        }
    }

    /// DNS-сервер по умолчанию: через первый подключённый VPN-выход (чистые ответы), иначе напрямую.
    private var finalDNSTag: String {
        for exit in profile.exits {
            if case .vpnApp(let id) = exit.kind, environment.vpnServices[id] != nil { return "dns-\(exit.tag)" }
        }
        return "dns-direct"
    }

    // MARK: - Сборка

    public func build() -> JSONValue {
        var outbounds: [JSONValue] = [directOutbound()]
        var endpoints: [JSONValue] = []
        var dnsServers: [JSONValue] = [directDNSServer()]

        for exit in profile.exits {
            switch exit.kind {
            case .vpnApp(let serviceID):
                guard let service = environment.vpnServices[serviceID] else { continue }
                let dnsTag = "dns-\(exit.tag)"
                outbounds.append([
                    "type": "direct", "tag": .string(exit.tag),
                    "bind_interface": .string(service.interface),
                    "domain_resolver": ["server": .string(dnsTag)],
                ])
                dnsServers.append([
                    "type": "udp", "tag": .string(dnsTag),
                    "server": .string(profile.tunnelDNS), "detour": .string(exit.tag),
                ])
            case .proxy(let proxy):
                let (isEndpoint, json) = Self.proxyJSON(proxy, tag: exit.tag)
                if isEndpoint { endpoints.append(json) } else { outbounds.append(json) }
            case .direct, .block, .auto:
                continue
            }
        }
        // «Авто»: ядро само держит самый быстрый из рабочих туннелей.
        let candidates = profile.autoCandidates(in: environment).map { JSONValue.string($0.tag) }
        if !candidates.isEmpty {
            outbounds.append([
                "type": "urltest", "tag": .string(Exit.auto.tag), "outbounds": .array(candidates),
                "url": "https://www.gstatic.com/generate_204", "interval": "1m", "tolerance": 50,
            ])
        }

        var config: [String: JSONValue] = [
            "log": ["level": .string(options.logLevel), "timestamp": true],
            "dns": .compact([
                ("servers", .array(dnsServers)),
                ("rules", .array(dnsRules)),
                ("final", .string(finalDNSTag)),
                ("strategy", ipv6Network ? nil : "ipv4_only"),
            ]),
            "inbounds": .array([tunInbound()] + (probeInbound().map { [$0] } ?? [])),
            "outbounds": .array(outbounds),
            "route": route(),
            "experimental": experimental(),
        ]
        if !endpoints.isEmpty { config["endpoints"] = .array(endpoints) }
        return .object(config)
    }

    private var vpnServerAddresses: [String] {
        environment.vpnServices.values.compactMap(\.serverAddress)
            .filter { !$0.isEmpty && $0 != "127.0.0.1" }
            .map { $0.contains(":") ? "\($0)/128" : "\($0)/32" }
            .sorted()
    }

    private func directOutbound() -> JSONValue {
        .compact([
            ("type", "direct"), ("tag", "direct"),
            ("bind_interface", environment.physicalInterface.map(JSONValue.string)),
        ])
    }

    private func directDNSServer() -> JSONValue {
        .compact([
            ("type", "dhcp"), ("tag", "dns-direct"),
            ("interface", environment.physicalInterface.map(JSONValue.string)),
        ])
    }

    private func tunInbound() -> JSONValue {
        [
            "type": "tun", "tag": "tun-in",
            // IPv6 на TUN — только если он есть в сети: иначе macOS начинает предпочитать IPv6.
            "address": .strings(ipv6Network ? [environment.tunAddress, Self.tunAddress6] : [environment.tunAddress]),
            "auto_route": true,
            "strict_route": false,
            "route_exclude_address": .strings(Self.baseExcludedRoutes + vpnServerAddresses),
        ]
    }

    // MARK: - Проба выходов

    /// Теги, через которые можно пустить пробу: напрямую, «Авто» и все туннели, что есть в конфиге.
    var probeTags: [String] {
        var tags = ["direct"]
        if !profile.autoCandidates(in: environment).isEmpty { tags.append(Exit.auto.tag) }
        for exit in profile.exits {
            switch exit.kind {
            case .vpnApp(let id) where environment.vpnServices[id] != nil: tags.append(exit.tag)
            case .proxy: tags.append(exit.tag)
            default: break
            }
        }
        return tags
    }

    /// SOCKS/HTTP на localhost: пользователь = тег выхода, пароль = секрет API.
    /// Приложение качает через него тестовый файл конкретным выходом; без секрета — отказ.
    private func probeInbound() -> JSONValue? {
        guard let listen = options.probeListen, let colon = listen.lastIndex(of: ":"),
              let port = Int(listen[listen.index(after: colon)...]) else { return nil }
        return [
            "type": "mixed", "tag": "probe-in",
            "listen": .string(String(listen[..<colon])), "listen_port": .int(port),
            "users": .array(probeTags.map { ["username": .string($0), "password": .string(options.apiSecret)] }),
        ]
    }

    private func route() -> JSONValue {
        var rules: [JSONValue] = []
        if options.probeListen != nil {
            for tag in probeTags {
                rules.append(["inbound": ["probe-in"], "auth_user": .strings([tag]), "outbound": .string(tag)])
            }
            rules.append(["inbound": ["probe-in"], "action": "reject"])
        }
        rules += [
            ["action": "sniff"],
            ["protocol": "dns", "action": "hijack-dns"],
        ]
        if !vpnServerAddresses.isEmpty {
            rules.append(["ip_cidr": .strings(vpnServerAddresses), "outbound": "direct"])
        }

        // 1. Свои правила, 2. готовые наборы, 3. маршруты приложений, 4. по умолчанию.
        for rule in profile.rules where rule.enabled && !rule.values.isEmpty {
            var m = rule.matchers()
            guard !m.isEmpty else { continue }
            if !rule.appPaths.isEmpty {
                m["process_path_regex"] = .strings(rule.appPaths.map(Self.processPattern(forBundlePath:)))
            }
            appendRule(&rules, matchers: m, exitID: rule.exitID)
        }
        for preset in profile.presets where preset.enabled {
            guard let info = PresetInfo.info(preset.id) else { continue }
            if info.ruleSets.isEmpty {
                appendRule(&rules, matchers: ["ip_is_private": true], exitID: preset.exitID)
                appendRule(&rules, matchers: ["domain_suffix": ["local", "lan", "home.arpa"]], exitID: preset.exitID)
                continue
            }
            let tags = info.ruleSets.filter(options.availableRuleSets.contains)
            guard !tags.isEmpty else { continue }
            appendRule(&rules, matchers: ["rule_set": .strings(tags)], exitID: preset.exitID)
        }

        // Одно правило на выход, в порядке появления выходов в маршрутах.
        var order: [String] = []
        var patterns: [String: [String]] = [:]
        for r in profile.routes {
            if patterns[r.exitID] == nil { order.append(r.exitID) }
            patterns[r.exitID, default: []].append(Self.processPattern(forBundlePath: r.path))
        }
        for exitID in order {
            appendRule(&rules, matchers: ["process_path_regex": .strings(patterns[exitID] ?? [])], exitID: exitID)
        }

        var route: [String: JSONValue] = [
            "find_process": true,
            "default_domain_resolver": "dns-direct",
        ]
        if let iface = environment.physicalInterface {
            route["default_interface"] = .string(iface)
        } else {
            route["auto_detect_interface"] = true
        }
        switch target(forExitID: profile.defaultExitID) {
        case .outbound(let tag):
            if !supportsIPv6(exitID: exitID(forTag: tag)) {
                rules.append(["inbound": ["tun-in"], "ip_version": 6, "action": "reject"])
            }
            route["final"] = .string(tag)
        case .reject:
            rules.append(["inbound": ["tun-in"], "action": "reject"])
            route["final"] = "direct"
        }
        route["rules"] = .array(rules)
        var presetSets = Set(profile.presets.filter(\.enabled).compactMap { PresetInfo.info($0.id) }.flatMap(\.ruleSets))
        if cnDNSRuleSet { presetSets.insert("geosite-cn") }
        let usedSets = presetSets.intersection(options.availableRuleSets).sorted()
        if !usedSets.isEmpty {
            route["rule_set"] = .array(usedSets.map {
                ["type": "local", "tag": .string($0), "format": "binary", "path": .string("\(options.ruleSetsDir)/\($0).srs")]
            })
        }
        return .object(route)
    }

    private var ipv6Network: Bool { environment.physicalIPv6 && !profile.disableIPv6 }

    /// Китайские домены резолвим напрямую (ближайшие серверы), остальное — через VPN (без подмены).
    private var cnDNSRuleSet: Bool { finalDNSTag != "dns-direct" && options.availableRuleSets.contains("geosite-cn") }

    private var dnsRules: [JSONValue] {
        var rules: [JSONValue] = [["domain_suffix": .strings(Self.localDomains), "action": "route", "server": "dns-direct"]]
        if cnDNSRuleSet {
            rules.append(["rule_set": ["geosite-cn"], "action": "route", "server": "dns-direct"])
        }
        return rules
    }

    /// Правило → выход, с отдельным мгновенным отказом для IPv6, если у выхода его нет.
    private func appendRule(_ rules: inout [JSONValue], matchers: [String: JSONValue], exitID: String) {
        switch target(forExitID: exitID) {
        case .outbound(let tag):
            if !supportsIPv6(exitID: self.exitID(forTag: tag)) {
                var v6 = matchers
                v6["ip_version"] = 6
                v6["action"] = "reject"
                rules.append(.object(v6))
            }
            var m = matchers
            m["outbound"] = .string(tag)
            rules.append(.object(m))
        case .reject:
            var m = matchers
            m["action"] = "reject"
            rules.append(.object(m))
        }
    }

    private func experimental() -> JSONValue {
        var e: [String: JSONValue] = [
            "clash_api": ["external_controller": .string(options.apiListen), "secret": .string(options.apiSecret)],
        ]
        if let path = options.cacheFilePath {
            e["cache_file"] = ["enabled": true, "path": .string(path)]
        }
        return .object(e)
    }

    // MARK: - Сопоставление процессов

    /// Регулярка RE2 для всех процессов внутри бандла, включая helper'ы.
    public static func processPattern(forBundlePath path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return "^" + escapeRegex(p) + "/"
    }

    static func escapeRegex(_ s: String) -> String {
        let special = Set("\\.+*?()|[]{}^$")
        var out = ""
        for ch in s {
            if special.contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    // MARK: - Свои конфиги

    static func proxyJSON(_ proxy: ProxyConfig, tag: String) -> (isEndpoint: Bool, JSONValue) {
        let t = JSONValue.string(tag)
        switch proxy {
        case .vless(let v):
            return (false, .compact([
                ("type", "vless"), ("tag", t),
                ("server", .string(v.server)), ("server_port", .int(v.port)),
                ("uuid", .string(v.uuid)), ("flow", v.flow.map(JSONValue.string)),
                ("packet_encoding", "xudp"),
                ("tls", v.tls.map(tlsJSON)), ("transport", v.transport.map(transportJSON)),
            ]))
        case .shadowsocks(let v):
            return (false, [
                "type": "shadowsocks", "tag": t,
                "server": .string(v.server), "server_port": .int(v.port),
                "method": .string(v.method), "password": .string(v.password),
            ])
        case .trojan(let v):
            return (false, .compact([
                ("type", "trojan"), ("tag", t),
                ("server", .string(v.server)), ("server_port", .int(v.port)),
                ("password", .string(v.password)),
                ("tls", tlsJSON(v.tls)), ("transport", v.transport.map(transportJSON)),
            ]))
        case .hysteria2(let v):
            return (false, .compact([
                ("type", "hysteria2"), ("tag", t),
                ("server", .string(v.server)), ("server_port", .int(v.port)),
                ("password", .string(v.password)),
                ("obfs", v.obfsPassword.map { ["type": "salamander", "password": .string($0)] }),
                ("tls", tlsJSON(v.tls)),
            ]))
        case .wireguard(let v):
            let peer = JSONValue.compact([
                ("address", .string(v.peer.server)), ("port", .int(v.peer.port)),
                ("public_key", .string(v.peer.publicKey)),
                ("pre_shared_key", v.peer.preSharedKey.map(JSONValue.string)),
                ("allowed_ips", .strings(v.peer.allowedIPs.isEmpty ? ["0.0.0.0/0", "::/0"] : v.peer.allowedIPs)),
                ("persistent_keepalive_interval", v.peer.keepalive.map(JSONValue.int)),
            ])
            return (true, .compact([
                ("type", "wireguard"), ("tag", t),
                ("address", .strings(v.addresses)), ("private_key", .string(v.privateKey)),
                ("mtu", v.mtu.map(JSONValue.int)),
                ("peers", .array([peer])),
            ]))
        case .openvpn(let v):
            let wrap = v.controlWrap.map {
                JSONValue.compact([("type", .string($0.type)), ("key", .strings(pemLines($0.key))), ("direction", $0.direction.map(JSONValue.string))])
            }
            let tls = JSONValue.compact([
                ("certificate", .strings(pemLines(v.ca))),
                ("client_certificate", v.cert.map { .strings(pemLines($0)) }),
                ("client_key", v.key.map { .strings(pemLines($0)) }),
                ("server_name", v.verifyName.map(JSONValue.string)),
                ("remote_certificate_tls", v.remoteCertTLS.map(JSONValue.string)),
                ("control_wrap", wrap),
            ])
            let servers = v.remotes.map {
                JSONValue.object(["server": .string($0.host), "server_port": .int($0.port), "network": .string($0.proto)])
            }
            return (true, .compact([
                ("type", "openvpn-client"), ("tag", t),
                ("servers", .array(servers)),
                ("username", v.username.map(JSONValue.string)), ("password", v.password.map(JSONValue.string)),
                ("data_ciphers", .strings(v.dataCiphers)),
                ("data_ciphers_fallback", v.dataCiphersFallback.map(JSONValue.string)),
                ("auth", v.auth.map(JSONValue.string)),
                ("compression", v.compression.map(JSONValue.string)),
                ("compression_lzo", v.compressionLZO.map(JSONValue.string)),
                ("tls", tls),
            ]))
        }
    }

    static func pemLines(_ pem: String) -> [String] {
        pem.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func tlsJSON(_ tls: TLSOptions) -> JSONValue {
        let fingerprint = tls.fingerprint ?? (tls.reality != nil ? "chrome" : nil)
        return .compact([
            ("enabled", true),
            ("server_name", tls.serverName.map(JSONValue.string)),
            ("insecure", tls.insecure ? true : nil),
            ("alpn", .strings(tls.alpn)),
            ("utls", fingerprint.map { ["enabled": true, "fingerprint": .string($0)] }),
            ("reality", tls.reality.map { ["enabled": true, "public_key": .string($0.publicKey), "short_id": .string($0.shortID)] }),
        ])
    }

    static func transportJSON(_ t: Transport) -> JSONValue {
        switch t.kind {
        case .ws:
            return .compact([
                ("type", "ws"), ("path", t.path.map(JSONValue.string)),
                ("headers", t.host.map { ["Host": .string($0)] }),
            ])
        case .grpc:
            return .compact([("type", "grpc"), ("service_name", t.serviceName.map(JSONValue.string))])
        case .httpupgrade:
            return .compact([("type", "httpupgrade"), ("path", t.path.map(JSONValue.string)), ("host", t.host.map(JSONValue.string))])
        case .http:
            return .compact([("type", "http"), ("path", t.path.map(JSONValue.string)), ("host", t.host.map { .strings([$0]) })])
        }
    }
}
