import Foundation
import SplitrouteCore
import SystemConfiguration

// Root-helper Splitroute.
//
//   install <user> <app-bundle>   — один раз через пароль администратора (osascript)
//   apply | start | stop | status — через `sudo -n`, разрешено правилом в /etc/sudoers.d/splitroute
//   uninstall                     — убрать всё
//
// Helper никогда не принимает готовый конфиг sing-box: он читает профиль пользователя,
// декодирует его в типизированную модель и собирает конфиг сам.

struct HelperError: Error, CustomStringConvertible {
    var description: String
    init(_ d: String) { description = d }
}

nonisolated(unsafe) let fm = FileManager.default

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("splitroute-helper: \(message)\n".utf8))
    exit(1)
}

@discardableResult
func run(_ path: String, _ args: [String], allowFailure: Bool = false) throws -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let out = String(data: data, encoding: .utf8) ?? ""
    if p.terminationStatus != 0 && !allowFailure {
        throw HelperError("\((path as NSString).lastPathComponent) \(args.joined(separator: " ")): \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    return (p.terminationStatus, out)
}

func requireRoot() {
    if getuid() != 0 { fail("нужны права root") }
}

/// Пользователь, от имени которого вызван helper через sudo.
func invokingUser() throws -> (name: String, uid: uid_t, gid: gid_t, home: String) {
    guard let uidString = ProcessInfo.processInfo.environment["SUDO_UID"], let uid = uid_t(uidString),
          let pw = getpwuid(uid)
    else { throw HelperError("helper нужно вызывать через sudo") }
    return (String(cString: pw.pointee.pw_name), uid, pw.pointee.pw_gid, String(cString: pw.pointee.pw_dir))
}

/// Читает профиль из домашней папки пользователя без перехода по симлинкам и только если файл принадлежит ему.
func readProfile(home: String, uid: uid_t) throws -> Profile {
    let path = Paths.profile(home: home)
    let fd = open(path, O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else { throw HelperError("нет профиля \(path)") }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    var st = stat()
    guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == uid else {
        throw HelperError("профиль должен быть обычным файлом пользователя")
    }
    guard st.st_size < 4 * 1024 * 1024 else { throw HelperError("профиль слишком большой") }
    let data = try handle.readToEnd() ?? Data()
    do {
        return try JSONDecoder().decode(Profile.self, from: data)
    } catch {
        throw HelperError("профиль повреждён")
    }
}

/// Читает файл пользователя: обычный файл, без симлинков, его владелец — пользователь, размер ограничен.
func readUserFile(_ path: String, uid: uid_t, maxSize: Int) throws -> Data {
    let fd = open(path, O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else { throw HelperError("нет файла \(path)") }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    var st = stat()
    guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == uid, Int(st.st_size) <= maxSize else {
        throw HelperError("недопустимый файл \(path)")
    }
    return try handle.readToEnd() ?? Data()
}

/// Копирует скачанные приложением наборы правил в системную папку. Возвращает теги, которые на месте.
func syncRuleSets(home: String, uid: uid_t) -> Set<String> {
    try? fm.createDirectory(atPath: Paths.ruleSetsDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    var available = Set<String>()
    for tag in PresetInfo.allowedRuleSets {
        let src = Paths.userRuleSets(home: home) + "/\(tag).srs"
        let dst = Paths.ruleSetsDir + "/\(tag).srs"
        if let data = try? readUserFile(src, uid: uid, maxSize: 32 * 1024 * 1024), !data.isEmpty {
            try? writeFile(data, to: dst, mode: 0o644)
        }
        if fm.fileExists(atPath: dst) { available.insert(tag) }
    }
    return available
}

func randomSecret() -> String {
    var bytes = [UInt8](repeating: 0, count: 24)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return bytes.map { String(format: "%02x", $0) }.joined()
}

func writeFile(_ data: Data, to path: String, mode: Int, owner: uid_t = 0, group: gid_t = 0) throws {
    let tmp = path + ".tmp"
    fm.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: mode])
    guard chown(tmp, owner, group) == 0 else { throw HelperError("chown \(tmp)") }
    guard rename(tmp, path) == 0 else { throw HelperError("rename \(path)") }
}

func daemonLoaded() -> Bool {
    (try? run("/bin/launchctl", ["print", "system/\(Paths.daemonLabel)"], allowFailure: true).status) == 0
}

func daemonPID() -> Int? {
    guard let out = try? run("/bin/launchctl", ["print", "system/\(Paths.daemonLabel)"], allowFailure: true), out.status == 0 else { return nil }
    for line in out.output.split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("pid = ") { return Int(t.dropFirst(6)) }
    }
    return nil
}

// MARK: - Команды

func install(user: String, appBundle: String) throws {
    requireRoot()
    // Через sudoers (без пароля) разрешены только apply/start/stop: иначе любой процесс пользователя
    // мог бы подсунуть свой бандл и получить root. Установка — только с паролем администратора.
    if ProcessInfo.processInfo.environment["SUDO_UID"] != nil {
        throw HelperError("установка и обновление компонента — только из Splitroute с паролем администратора")
    }
    guard let pw = getpwnam(user) else { throw HelperError("нет пользователя \(user)") }
    guard user.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }) else { throw HelperError("недопустимое имя пользователя") }
    let resources = appBundle + "/Contents/Resources"
    let srcHelper = appBundle + "/Contents/MacOS/splitroute-helper"
    let srcSingBox = resources + "/sing-box"
    for p in [srcHelper, srcSingBox] where !fm.isExecutableFile(atPath: p) {
        throw HelperError("в бандле нет \(p)")
    }

    // Старое задание launchd держит прежний ProgramArguments — выгружаем, новое поднимет apply.
    if daemonLoaded() {
        try run("/bin/launchctl", ["bootout", "system/\(Paths.daemonLabel)"], allowFailure: true)
    }
    try fm.createDirectory(atPath: Paths.installDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    try fm.createDirectory(atPath: Paths.dataDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    try fm.createDirectory(atPath: (Paths.log as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    for (src, dst) in [(srcHelper, Paths.helper), (srcSingBox, Paths.singBox)] {
        try writeFile(try Data(contentsOf: URL(fileURLWithPath: src)), to: dst, mode: 0o755)
    }

    let plist: [String: Any] = [
        "Label": Paths.daemonLabel,
        // helper — обёртка: держит системный DNS ядра, пока жив sing-box.
        "ProgramArguments": [Paths.helper, "run"],
        "RunAtLoad": true,
        "KeepAlive": true,
        "StandardOutPath": Paths.log,
        "StandardErrorPath": Paths.log,
    ]
    let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try writeFile(plistData, to: Paths.launchDaemonPlist, mode: 0o644)

    // sudo без пароля — только для этих команд helper'а и только для этого пользователя.
    let cmds = ["apply", "start", "stop", "status", "uninstall"].map { "\(Paths.helper) \($0)" }.joined(separator: ", ")
    let sudoers = "\(user) ALL=(root) NOPASSWD: \(cmds)\n"
    let tmp = Paths.sudoers + ".check"
    try writeFile(Data(sudoers.utf8), to: tmp, mode: 0o440)
    defer { try? fm.removeItem(atPath: tmp) }
    try run("/usr/sbin/visudo", ["-cf", tmp])
    try writeFile(Data(sudoers.utf8), to: Paths.sudoers, mode: 0o440)

    _ = pw
    // До первого apply конфига нет — не даём launchd запускать ядро при загрузке.
    try run("/bin/launchctl", ["disable", "system/\(Paths.daemonLabel)"], allowFailure: true)
    print("installed")
}

func apply() throws {
    requireRoot()
    let user = try invokingUser()
    let profile = try readProfile(home: user.home, uid: user.uid)

    let credentials = APICredentials.load() ?? APICredentials(listen: "127.0.0.1:9095", secret: randomSecret())
    let env = NetworkState.environment()
    let ruleSets = syncRuleSets(home: user.home, uid: user.uid)
    let options = ConfigOptions(
        apiListen: credentials.listen, apiSecret: credentials.secret, cacheFilePath: Paths.cacheFile,
        availableRuleSets: ruleSets
    )
    let data = try ConfigBuilder(profile: profile, environment: env, options: options).build().encoded()

    let candidate = Paths.dataDir + "/config.candidate.json"
    try writeFile(data, to: candidate, mode: 0o600)
    defer { try? fm.removeItem(atPath: candidate) }
    try run(Paths.singBox, ["check", "-c", candidate])
    try writeFile(data, to: Paths.config, mode: 0o600)

    // Флаг перехвата DNS читает `run` при старте — если он поменялся, ядро нужно перезапустить.
    let hijackBefore = fm.fileExists(atPath: Paths.dnsHijackFlag)
    if profile.hijackSystemDNS {
        try writeFile(Data(), to: Paths.dnsHijackFlag, mode: 0o644)
    } else {
        try? fm.removeItem(atPath: Paths.dnsHijackFlag)
    }
    let restartNeeded = hijackBefore != profile.hijackSystemDNS

    let credData = try JSONEncoder().encode(credentials)
    try writeFile(credData, to: Paths.apiCredentials, mode: 0o600, owner: user.uid, group: user.gid)

    try run("/bin/launchctl", ["enable", "system/\(Paths.daemonLabel)"])
    if daemonPID() != nil && !restartNeeded {
        // Горячая перезагрузка: sing-box перечитывает конфиг по SIGHUP без перезапуска процесса.
        try run("/bin/launchctl", ["kill", "SIGHUP", "system/\(Paths.daemonLabel)"])
    } else if daemonLoaded() {
        try run("/bin/launchctl", ["kickstart", "-k", "system/\(Paths.daemonLabel)"])
    } else {
        try run("/bin/launchctl", ["bootstrap", "system", Paths.launchDaemonPlist])
    }
    let vpn = env.vpnServices.map { "\($0.key)=\($0.value.interface)" }.sorted().joined(separator: ",")
    print("applied physical=\(env.physicalInterface ?? "-") ipv6=\(env.physicalIPv6) vpn=[\(vpn)]")
}

/// Запуск ядра под launchd. DNS ядра публикуется временным ключом SCDynamicStore: configd удалит его
/// сам, как только этот процесс завершится (в том числе аварийно), и система вернётся к прежнему DNS.
func runCore() -> Never {
    requireRoot()
    let store = SCDynamicStoreCreate(nil, "com.splitroute.core" as CFString, nil, nil)
    if fm.fileExists(atPath: Paths.dnsHijackFlag), let store {
        // Проверено на живой системе: приоритет задаёт SupplementalMatchOrders (меньше — выше).
        // SearchOrder для сервиса вне ServiceOrder игнорируется (резолвер получал order 102000,
        // ниже Tailscale), а вместе с SupplementalMatchOrders ломал приоритет.
        let dns: [String: Any] = [
            "ServerAddresses": [ConfigBuilder.tunDNS],
            "SupplementalMatchDomains": [""],   // все домены; более точные (ts.net) остаются у Tailscale
            "SupplementalMatchOrders": [1],
        ]
        if SCDynamicStoreAddTemporaryValue(store, Paths.dnsStoreKey as CFString, dns as CFDictionary) {
            flushDNSCache()
        } else {
            FileHandle.standardError.write(Data("splitroute-helper: не удалось опубликовать DNS\n".utf8))
        }
    }

    let child = Process()
    child.executableURL = URL(fileURLWithPath: Paths.singBox)
    child.arguments = ["run", "-c", Paths.config, "-D", Paths.dataDir]
    do { try child.run() } catch { fail("не удалось запустить sing-box: \(error)") }

    var sources: [DispatchSourceSignal] = []
    for sig in [SIGHUP, SIGTERM, SIGINT] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        src.setEventHandler { kill(child.processIdentifier, sig) }
        src.resume()
        sources.append(src)
    }
    child.waitUntilExit()
    _ = sources
    if let store, SCDynamicStoreRemoveValue(store, Paths.dnsStoreKey as CFString) { flushDNSCache() }
    exit(child.terminationStatus)
}

/// Сбросить кэш mDNSResponder: иначе приложения ещё долго получают старые (подменённые) ответы.
func flushDNSCache() {
    _ = try? run("/usr/bin/dscacheutil", ["-flushcache"], allowFailure: true)
    _ = try? run("/usr/bin/killall", ["-HUP", "mDNSResponder"], allowFailure: true)
}

func stop() throws {
    requireRoot()
    // Выключено пользователем — не поднимать ядро и после перезагрузки.
    try run("/bin/launchctl", ["disable", "system/\(Paths.daemonLabel)"], allowFailure: true)
    if daemonLoaded() {
        try run("/bin/launchctl", ["bootout", "system/\(Paths.daemonLabel)"])
    }
    print("stopped")
}

func status() {
    let installed = fm.isExecutableFile(atPath: Paths.singBox) && fm.fileExists(atPath: Paths.launchDaemonPlist)
    let pid = daemonPID()
    let json: [String: Any] = ["installed": installed, "running": pid != nil, "pid": pid ?? 0, "protocol": HelperProtocol.version]
    let data = try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}

func uninstall() throws {
    requireRoot()
    if daemonLoaded() {
        try run("/bin/launchctl", ["bootout", "system/\(Paths.daemonLabel)"], allowFailure: true)
    }
    for p in [Paths.sudoers, Paths.launchDaemonPlist, Paths.installDir, Paths.dataDir] {
        try? fm.removeItem(atPath: p)
    }
    print("uninstalled")
}

let args = CommandLine.arguments.dropFirst()
do {
    switch args.first {
    case "install":
        guard args.count == 3 else { fail("usage: install <user> <app-bundle>") }
        try install(user: args[args.startIndex + 1], appBundle: args[args.startIndex + 2])
    case "apply": try apply()
    case "run": runCore()
    case "start": try apply()
    case "stop": try stop()
    case "status": status()
    case "preview":
        let profile = try Profile.load(from: Paths.userProfile)
        let dir = Paths.userRuleSets(home: NSHomeDirectory())
        let sets = PresetInfo.allowedRuleSets.filter { fm.fileExists(atPath: "\(dir)/\($0).srs") }
        let options = ConfigOptions(apiSecret: "preview", cacheFilePath: Paths.cacheFile, ruleSetsDir: dir, availableRuleSets: sets)
        let data = try ConfigBuilder(profile: profile, environment: NetworkState.environment(), options: options).build().encoded()
        print(String(data: data, encoding: .utf8)!)
    case "env":
        let env = NetworkState.environment()
        print("physical:", env.physicalInterface ?? "-", env.physicalIPv6 ? "ipv6" : "ipv4-only")
        for s in NetworkState.vpnServices() {
            print("vpn:", s.name, s.id, s.providerBundleID ?? "-", s.interface ?? "disconnected", s.serverAddress ?? "-", s.ipv6 ? "ipv6" : "ipv4-only")
        }
    case "uninstall": try uninstall()
    default: fail("usage: splitroute-helper install|apply|start|stop|status|uninstall")
    }
} catch {
    fail("\(error)")
}
