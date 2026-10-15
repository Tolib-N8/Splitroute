import Foundation
import SystemConfiguration

/// VPN-сервис из Системных настроек (ZoogVPN, AIRLINK, Tailscale…).
public struct VPNServiceInfo: Sendable, Equatable, Identifiable, Hashable {
    public var id: String
    public var name: String
    /// Например `com.zoogvpn.ios` — бандл провайдера Network Extension.
    public var providerBundleID: String?
    /// utun, если сервис подключён.
    public var interface: String?
    public var serverAddress: String?
    public var ipv6: Bool = false

    public var isConnected: Bool { interface != nil }
    /// Tailscale — это mesh-сеть, а не выход в интернет; в списке выходов его не показываем.
    public var isMesh: Bool { providerBundleID?.contains("tailscale") == true || name.localizedCaseInsensitiveContains("tailscale") }
}

/// Чтение сетевого состояния из SCDynamicStore / SCPreferences.
public enum NetworkState {

    public static func environment() -> NetworkEnvironment { snapshot().environment }

    /// Одно чтение: список VPN-сервисов и окружение для конфига. Медленно (десятки мс) — не на главном потоке.
    public static func snapshot() -> (services: [VPNServiceInfo], environment: NetworkEnvironment) {
        let services = vpnServices()
        var vpn: [String: NetworkEnvironment.VPNService] = [:]
        for s in services {
            if let iface = s.interface {
                vpn[s.id] = .init(interface: iface, serverAddress: s.serverAddress, ipv6: s.ipv6)
            }
        }
        let physical = physicalService()
        return (services, NetworkEnvironment(physicalInterface: physical?.interface, physicalIPv6: physical?.ipv6 ?? false, vpnServices: vpn))
    }

    /// Все VPN-сервисы из текущего набора сетевых настроек.
    public static func vpnServices() -> [VPNServiceInfo] {
        guard let prefs = SCPreferencesCreate(nil, "Splitroute" as CFString, nil),
              let services = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService]
        else { return [] }
        let store = SCDynamicStoreCreate(nil, "Splitroute" as CFString, nil, nil)

        return services.compactMap { service -> VPNServiceInfo? in
            guard let iface = SCNetworkServiceGetInterface(service),
                  let type = SCNetworkInterfaceGetInterfaceType(iface) as String?,
                  type == "VPN" || type == (kSCNetworkInterfaceTypeIPSec as String),
                  let id = SCNetworkServiceGetServiceID(service) as String?
            else { return nil }
            let name = (SCNetworkServiceGetName(service) as String?) ?? id
            var info = VPNServiceInfo(id: id, name: name, providerBundleID: providerBundleID(service: service, interface: iface))
            if let state = ipv4State(store: store, serviceID: id) {
                info.interface = state["InterfaceName"] as? String
                info.serverAddress = state["ServerAddress"] as? String
                info.ipv6 = hasGlobalIPv6(store: store, serviceID: id)
            } else if let status = connectedStatus(serviceID: id) {
                // Некоторые Network Extension (AIRLINK) публикуют состояние под ID сессии, а не
                // под ID сервиса из настроек — тогда берём его из статуса соединения.
                let v4 = status["IPv4"] as? [String: Any]
                let v6 = status["IPv6"] as? [String: Any]
                info.interface = v4?["InterfaceName"] as? String
                info.serverAddress = v4?["ServerAddress"] as? String
                info.ipv6 = (v6?["Addresses"] as? [String])?.contains(where: isGlobalIPv6) ?? false
            }
            return info
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Первый физический интерфейс с маршрутизатором по порядку сервисов (en0 и т. п.).
    public static func physicalInterface() -> String? { physicalService()?.interface }

    static func physicalService() -> (interface: String, ipv6: Bool)? {
        guard let store = SCDynamicStoreCreate(nil, "Splitroute" as CFString, nil, nil) else { return nil }
        let setup = SCDynamicStoreCopyValue(store, "Setup:/Network/Global/IPv4" as CFString) as? [String: Any]
        var order = (setup?["ServiceOrder"] as? [String]) ?? []

        // Сервисы, у которых есть состояние, но которых нет в ServiceOrder, проверяем в конце.
        let keys = (SCDynamicStoreCopyKeyList(store, "State:/Network/Service/[^/]+/IPv4" as CFString) as? [String]) ?? []
        for key in keys {
            let id = key.components(separatedBy: "/")[3]
            if !order.contains(id) { order.append(id) }
        }

        for id in order {
            guard let state = ipv4State(store: store, serviceID: id),
                  let name = state["InterfaceName"] as? String,
                  isPhysical(name),
                  state["Router"] != nil
            else { continue }
            return (name, hasGlobalIPv6(store: store, serviceID: id))
        }
        return nil
    }

    /// Есть ли у сервиса глобальный IPv6-адрес (2000::/3). Link-local и ULA (fc00::/7) не считаются.
    static func hasGlobalIPv6(store: SCDynamicStore?, serviceID: String) -> Bool {
        guard let store,
              let state = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(serviceID)/IPv6" as CFString) as? [String: Any],
              let addresses = state["Addresses"] as? [String]
        else { return false }
        return addresses.contains(where: isGlobalIPv6)
    }

    static func isGlobalIPv6(_ address: String) -> Bool {
        guard let first = address.split(separator: ":").first, let hextet = UInt16(first, radix: 16) else { return false }
        return (0x2000...0x3FFF).contains(hextet)
    }

    static func isPhysical(_ name: String) -> Bool {
        let virtual = ["utun", "ipsec", "ppp", "gif", "stf", "awdl", "llw", "lo", "bridge", "anpi", "ap", "nan", "vmenet"]
        return !virtual.contains { name.hasPrefix($0) }
    }

    /// Попросить систему подключить VPN-сервис — как кнопка «Подключить» в Системных настройках.
    /// Не ждёт результата. Пропускает, если сервис уже подключается или подключён.
    @discardableResult
    public static func startVPN(serviceID: String) -> Bool {
        guard let conn = SCNetworkConnectionCreateWithServiceID(nil, serviceID as CFString, nil, nil) else { return false }
        switch SCNetworkConnectionGetStatus(conn) {
        case .connected, .connecting: return true
        default: return SCNetworkConnectionStart(conn, nil, false)
        }
    }

    /// Расширенный статус подключённого VPN (как в `scutil --nc status`), иначе nil.
    private static func connectedStatus(serviceID: String) -> [String: Any]? {
        guard let conn = SCNetworkConnectionCreateWithServiceID(nil, serviceID as CFString, nil, nil),
              SCNetworkConnectionGetStatus(conn) == .connected
        else { return nil }
        return SCNetworkConnectionCopyExtendedStatus(conn) as? [String: Any]
    }

    private static func ipv4State(store: SCDynamicStore?, serviceID: String) -> [String: Any]? {
        guard let store else { return nil }
        return SCDynamicStoreCopyValue(store, "State:/Network/Service/\(serviceID)/IPv4" as CFString) as? [String: Any]
    }

    private static func providerBundleID(service: SCNetworkService, interface: SCNetworkInterface) -> String? {
        // У Network Extension VPN подтип интерфейса — это бандл провайдера ("VPN:com.zoogvpn.ios").
        if let cfg = SCNetworkInterfaceGetConfiguration(interface) as? [String: Any],
           let id = cfg["ProviderBundleIdentifier"] as? String {
            return id
        }
        let protocols = (SCNetworkServiceCopyProtocols(service) as? [SCNetworkProtocol]) ?? []
        for proto in protocols {
            if let cfg = SCNetworkProtocolGetConfiguration(proto) as? [String: Any],
               let id = cfg["ProviderBundleIdentifier"] as? String {
                return id
            }
        }
        return nil
    }
}
