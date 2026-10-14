import Foundation

/// Свой конфиг выхода. Хранится типизированно: helper собирает из него JSON sing-box сам,
/// поэтому в итоговый конфиг не попадают пути к файлам и прочие поля, которые не задумывались.
public enum ProxyConfig: Codable, Sendable, Equatable, Hashable {
    case vless(VLESS)
    case shadowsocks(Shadowsocks)
    case trojan(Trojan)
    case hysteria2(Hysteria2)
    case wireguard(WireGuard)
    case openvpn(OpenVPN)

    public var protocolName: String {
        switch self {
        case .vless(let v): return v.tls?.reality != nil ? "VLESS · Reality" : "VLESS"
        case .shadowsocks: return "Shadowsocks"
        case .trojan: return "Trojan"
        case .hysteria2: return "Hysteria2"
        case .wireguard: return "WireGuard"
        case .openvpn: return "OpenVPN"
        }
    }

    /// Адрес сервера для отображения и пинга.
    public var server: String {
        switch self {
        case .vless(let v): return v.server
        case .shadowsocks(let v): return v.server
        case .trojan(let v): return v.server
        case .hysteria2(let v): return v.server
        case .wireguard(let v): return v.peer.server
        case .openvpn(let v): return v.remotes.first?.host ?? ""
        }
    }
}

public struct TLSOptions: Codable, Sendable, Equatable, Hashable {
    public struct Reality: Codable, Sendable, Equatable, Hashable {
        public var publicKey: String
        public var shortID: String
    }

    public var serverName: String?
    public var insecure: Bool = false
    public var alpn: [String] = []
    /// uTLS fingerprint: chrome, firefox, safari…
    public var fingerprint: String?
    public var reality: Reality?
}

public struct Transport: Codable, Sendable, Equatable, Hashable {
    public enum Kind: String, Codable, Sendable { case ws, grpc, httpupgrade, http }
    public var kind: Kind
    public var path: String?
    public var host: String?
    public var serviceName: String?
}

public struct VLESS: Codable, Sendable, Equatable, Hashable {
    public var server: String
    public var port: Int
    public var uuid: String
    public var flow: String?
    public var tls: TLSOptions?
    public var transport: Transport?
}

public struct Shadowsocks: Codable, Sendable, Equatable, Hashable {
    public var server: String
    public var port: Int
    public var method: String
    public var password: String
}

public struct Trojan: Codable, Sendable, Equatable, Hashable {
    public var server: String
    public var port: Int
    public var password: String
    public var tls: TLSOptions
    public var transport: Transport?
}

public struct Hysteria2: Codable, Sendable, Equatable, Hashable {
    public var server: String
    public var port: Int
    public var password: String
    public var obfsPassword: String?
    public var tls: TLSOptions
}

public struct WireGuard: Codable, Sendable, Equatable, Hashable {
    public struct Peer: Codable, Sendable, Equatable, Hashable {
        public var server: String
        public var port: Int
        public var publicKey: String
        public var preSharedKey: String?
        public var allowedIPs: [String]
        public var keepalive: Int?
    }

    public var privateKey: String
    public var addresses: [String]
    public var mtu: Int?
    public var peer: Peer
}

public struct OpenVPN: Codable, Sendable, Equatable, Hashable {
    public struct Remote: Codable, Sendable, Equatable, Hashable {
        public var host: String
        public var port: Int
        public var proto: String  // udp | tcp
    }

    public struct ControlWrap: Codable, Sendable, Equatable, Hashable {
        public var type: String  // tls_auth | tls_crypt | tls_crypt_v2
        public var key: String
        public var direction: String?  // server | client
    }

    public var remotes: [Remote]
    public var ca: String
    public var cert: String?
    public var key: String?
    public var controlWrap: ControlWrap?
    public var username: String?
    public var password: String?
    public var dataCiphers: [String] = []
    public var dataCiphersFallback: String?
    public var auth: String?
    public var compression: String?
    public var compressionLZO: String?
    public var verifyName: String?
    public var remoteCertTLS: String?
    /// В .ovpn есть `auth-user-pass` без файла — логин и пароль нужно спросить у пользователя.
    public var passwordRequired: Bool = false
    public var needsCredentials: Bool { passwordRequired && (username ?? "").isEmpty }
}
