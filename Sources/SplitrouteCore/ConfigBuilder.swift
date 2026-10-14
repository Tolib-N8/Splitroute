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

    public init(physicalInterface: String?, physicalIPv6: Bool = false, vpnServices: [String: VPNService] = [:]) {
        self.physicalInterface = physicalInterface
        self.physicalIPv6 = physicalIPv6
        self.vpnServices = vpnServices
    }
}

public struct ConfigOptions: Sendable, Equatable {
    public var apiListen: String
    public var apiSecret: String
    public var cacheFilePath: String?
    public var logLevel: String

    public init(apiListen: String = "127.0.0.1:9095", apiSecret: String, cacheFilePath: String? = nil, logLevel: String = "warn") {
        self.apiListen = apiListen
        self.apiSecret = apiSecret
        self.cacheFilePath = cacheFilePath
        self.logLevel = logLevel
    }
}

/// Собирает конфиг sing-box из профиля пользователя.
public struct ConfigBuilder: Sendable {
    public static let tunAddress = ["172.19.0.1/30", "fdfe:dcba:9876::1/126"]

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

    /// Куда фактически отправится трафик выхода с учётом состояния сети и kill switch.
    public func target(forExitID id: String) -> Target {
        guard let exit = profile.exit(id: id) else { return target(forExitID: Exit.directID) }
        switch exit.kind {
        case .direct: return .outbound("direct")
        case .block: return .reject
        case .proxy: return .outbound(exit.tag)
        case .vpnApp(let serviceID):
            if environment.vpnServices[serviceID] != nil { return .outbound(exit.tag) }
            return profile.killSwitch ? .reject : .outbound("direct")
        }
    }

    /// Работает ли IPv6 через выход. Если нет — IPv6-соединения отклоняются сразу,
    /// и приложения мгновенно переходят на IPv4, а не ждут таймаута.
    public func supportsIPv6(exitID id: String) -> Bool {
        guard let exit = profile.exit(id: id) else { return environment.physicalIPv6 }
        switch exit.kind {
        case .direct: return environment.physicalIPv6
        case .block: return true
        case .proxy: return true
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
            case .direct, .block:
                continue
            }
        }

        var config: [String: JSONValue] = [
            "log": ["level": .string(options.logLevel), "timestamp": true],
            "dns": .compact([
                ("servers", .array(dnsServers)),
                ("final", .string(finalDNSTag)),
                ("strategy", environment.physicalIPv6 ? nil : "ipv4_only"),
            ]),
            "inbounds": [tunInbound()],
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
            "address": .strings(Self.tunAddress),
            "auto_route": true,
            "strict_route": false,
            "route_exclude_address": .strings(Self.baseExcludedRoutes + vpnServerAddresses),
        ]
    }

    private func route() -> JSONValue {
        var rules: [JSONValue] = [
            ["action": "sniff"],
            ["protocol": "dns", "action": "hijack-dns"],
        ]
        if !vpnServerAddresses.isEmpty {
            rules.append(["ip_cidr": .strings(vpnServerAddresses), "outbound": "direct"])
        }

        // Одно правило на выход, в порядке появления выходов в маршрутах.
        var order: [String] = []
        var patterns: [String: [String]] = [:]
        for r in profile.routes {
            if patterns[r.exitID] == nil { order.append(r.exitID) }
            patterns[r.exitID, default: []].append(Self.processPattern(forBundlePath: r.path))
        }
        for exitID in order {
            let match: JSONValue = .strings(patterns[exitID] ?? [])
            switch target(forExitID: exitID) {
            case .outbound(let tag):
                if !supportsIPv6(exitID: tag == "direct" ? Exit.directID : exitID) {
                    rules.append(["process_path_regex": match, "ip_version": 6, "action": "reject"])
                }
                rules.append(["process_path_regex": match, "outbound": .string(tag)])
            case .reject:
                rules.append(["process_path_regex": match, "action": "reject"])
            }
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
            if !supportsIPv6(exitID: tag == "direct" ? Exit.directID : profile.defaultExitID) {
                rules.append(["inbound": ["tun-in"], "ip_version": 6, "action": "reject"])
            }
            route["final"] = .string(tag)
        case .reject:
            rules.append(["inbound": ["tun-in"], "action": "reject"])
            route["final"] = "direct"
        }
        route["rules"] = .array(rules)
        return .object(route)
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
