import Foundation
import Testing
@testable import SplitrouteCore

enum WireGuardFixture {
    static let conf = """
    [Interface]
    PrivateKey = yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=
    Address = 10.66.66.2/32, fd42:42:42::2/128
    DNS = 1.1.1.1
    MTU = 1420

    [Peer]
    PublicKey = xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=
    PresharedKey = 4Ojz2pJmkDXWV0wJmpuYG6CSxjZ8NyRkV3jcErSB5tM=
    AllowedIPs = 0.0.0.0/0, ::/0
    Endpoint = [2001:db8::1]:51820
    PersistentKeepalive = 25
    """
}

enum OpenVPNFixture {
    static let ovpn = """
    client
    dev tun
    proto udp
    remote nl1.example.net 1194
    remote nl2.example.net 443 tcp
    cipher AES-256-CBC
    data-ciphers AES-256-GCM:CHACHA20-POLY1305
    auth SHA256
    remote-cert-tls server
    auth-user-pass
    key-direction 1
    <ca>
    -----BEGIN CERTIFICATE-----
    MIIBszCCAVmgAwIBAgIUDummyDummyDummyDummyDummyDummyMAoGCCqGSM49BAMC
    -----END CERTIFICATE-----
    </ca>
    <tls-auth>
    -----BEGIN OpenVPN Static key V1-----
    00112233445566778899aabbccddeeff
    -----END OpenVPN Static key V1-----
    </tls-auth>
    """
}

struct LinkParserTests {
    @Test func vlessReality() throws {
        let p = try LinkParser.parseLink(
            "vless://bf000d23-0752-40b4-affe-68f7707a9661@1.2.3.4:443?encryption=none&security=reality&sni=www.apple.com&fp=chrome&pbk=PUBKEY&sid=ab12&type=tcp&flow=xtls-rprx-vision#%F0%9F%87%B3%F0%9F%87%B1%20Amsterdam"
        )
        #expect(p.name == "🇳🇱 Amsterdam")
        guard case .vless(let v) = p.config else { Issue.record("not vless"); return }
        #expect(v.server == "1.2.3.4" && v.port == 443)
        #expect(v.flow == "xtls-rprx-vision")
        #expect(v.tls?.serverName == "www.apple.com")
        #expect(v.tls?.reality == .init(publicKey: "PUBKEY", shortID: "ab12"))
        #expect(v.transport == nil)
    }

    @Test func vlessWebSocket() throws {
        let p = try LinkParser.parseLink("vless://uuid@host.example:8443?security=tls&type=ws&path=%2Fws&host=cdn.example#ws")
        guard case .vless(let v) = p.config else { Issue.record("not vless"); return }
        #expect(v.transport == Transport(kind: .ws, path: "/ws", host: "cdn.example"))
        #expect(v.tls?.reality == nil)
    }

    @Test func shadowsocksSIP002() throws {
        // base64("chacha20-ietf-poly1305:secret")
        let p = try LinkParser.parseLink("ss://Y2hhY2hhMjAtaWV0Zi1wb2x5MTMwNTpzZWNyZXQ@5.6.7.8:8388#SS")
        guard case .shadowsocks(let s) = p.config else { Issue.record("not ss"); return }
        #expect(s.method == "chacha20-ietf-poly1305" && s.password == "secret" && s.port == 8388)
    }

    @Test func shadowsocks2022PlainUserinfo() throws {
        let p = try LinkParser.parseLink("ss://2022-blake3-aes-128-gcm:a2V5%3D@ss.example:443#x")
        guard case .shadowsocks(let s) = p.config else { Issue.record("not ss"); return }
        #expect(s.method == "2022-blake3-aes-128-gcm" && s.password == "a2V5=")
    }

    @Test func trojanAndHysteria2() throws {
        let t = try LinkParser.parseLink("trojan://pass@t.example:443?sni=t.example#T")
        guard case .trojan(let tr) = t.config else { Issue.record("not trojan"); return }
        #expect(tr.password == "pass" && tr.tls.serverName == "t.example")

        let h = try LinkParser.parseLink("hy2://pw@h.example:8443?obfs=salamander&obfs-password=ob&insecure=1#H")
        guard case .hysteria2(let hy) = h.config else { Issue.record("not hy2"); return }
        #expect(hy.obfsPassword == "ob" && hy.tls.insecure && hy.tls.alpn == ["h3"])
    }

    @Test func base64Subscription() throws {
        let list = "trojan://a@a.example:443#A\nvless://u@b.example:443?security=tls#B\n"
        let sub = Data(list.utf8).base64EncodedString()
        let parsed = try LinkParser.parseAny(sub)
        #expect(parsed.map(\.name) == ["A", "B"])
    }

    @Test func wireGuardConf() throws {
        let p = try LinkParser.parseAny(WireGuardFixture.conf, fileName: "home-router.conf")
        #expect(p.first?.name == "home-router")
        guard case .wireguard(let wg) = p.first?.config else { Issue.record("not wg"); return }
        #expect(wg.addresses == ["10.66.66.2/32", "fd42:42:42::2/128"])
        #expect(wg.peer.server == "2001:db8::1" && wg.peer.port == 51820)
        #expect(wg.peer.keepalive == 25 && wg.mtu == 1420)
    }

    @Test func openVPN() throws {
        let p = try LinkParser.parseAny(OpenVPNFixture.ovpn, fileName: "work.ovpn")
        guard case .openvpn(let o) = p.first?.config else { Issue.record("not ovpn"); return }
        #expect(o.remotes == [.init(host: "nl1.example.net", port: 1194, proto: "udp"), .init(host: "nl2.example.net", port: 443, proto: "tcp")])
        #expect(o.controlWrap?.type == "tls_auth" && o.controlWrap?.direction == "client")
        #expect(o.dataCiphers == ["AES-256-GCM", "CHACHA20-POLY1305"])
        #expect(o.dataCiphersFallback == "AES-256-CBC")
        #expect(o.needsCredentials)
    }

    @Test func rejectsUnknownScheme() {
        #expect(throws: ParseError.self) { try LinkParser.parseLink("vmess://abc") }
    }

    @Test func routeTargetForPrograms() {
        let claude = AppCatalog.routeTarget(forProcessPath: "/Users/u/.local/share/claude/versions/2.1.300")
        #expect(claude.path == "/Users/u/.local/share/claude/versions/" && claude.name == "Claude Code")
        let cli = AppCatalog.routeTarget(forProcessPath: "/opt/tools/bin/mytool")
        #expect(cli.path == "/opt/tools/bin/" && cli.name == "mytool")
        #expect(AppCatalog.routeTarget(forProcessPath: "/Applications/X.app/Contents/MacOS/X").path == "/Applications/X.app")
        // Правило на папку — префикс, оно совпадает с любой версией внутри.
        #expect(ConfigBuilder.processPattern(forBundlePath: claude.path) == #"^/Users/u/\.local/share/claude/versions/"#)
    }

    @Test func bundlePathFromProcessPath() {
        #expect(AppCatalog.bundlePath(forProcessPath: "/Applications/WhatsApp.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper") == "/Applications/WhatsApp.app")
        #expect(AppCatalog.bundlePath(forProcessPath: "/usr/bin/curl") == nil)
    }
}
