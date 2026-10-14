import Foundation
import SplitrouteCore

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
    guard let pw = getpwnam(user) else { throw HelperError("нет пользователя \(user)") }
    guard user.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }) else { throw HelperError("недопустимое имя пользователя") }
    let resources = appBundle + "/Contents/Resources"
    let srcHelper = appBundle + "/Contents/MacOS/splitroute-helper"
    let srcSingBox = resources + "/sing-box"
    for p in [srcHelper, srcSingBox] where !fm.isExecutableFile(atPath: p) {
        throw HelperError("в бандле нет \(p)")
    }

    try fm.createDirectory(atPath: Paths.installDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    try fm.createDirectory(atPath: Paths.dataDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    try fm.createDirectory(atPath: (Paths.log as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    for (src, dst) in [(srcHelper, Paths.helper), (srcSingBox, Paths.singBox)] {
        try writeFile(try Data(contentsOf: URL(fileURLWithPath: src)), to: dst, mode: 0o755)
    }

    let plist: [String: Any] = [
        "Label": Paths.daemonLabel,
        "ProgramArguments": [Paths.singBox, "run", "-c", Paths.config, "-D", Paths.dataDir],
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
    let options = ConfigOptions(apiListen: credentials.listen, apiSecret: credentials.secret, cacheFilePath: Paths.cacheFile)
    let data = try ConfigBuilder(profile: profile, environment: env, options: options).build().encoded()

    let candidate = Paths.dataDir + "/config.candidate.json"
    try writeFile(data, to: candidate, mode: 0o600)
    defer { try? fm.removeItem(atPath: candidate) }
    try run(Paths.singBox, ["check", "-c", candidate])
    try writeFile(data, to: Paths.config, mode: 0o600)

    let credData = try JSONEncoder().encode(credentials)
    try writeFile(credData, to: Paths.apiCredentials, mode: 0o600, owner: user.uid, group: user.gid)

    try run("/bin/launchctl", ["enable", "system/\(Paths.daemonLabel)"])
    if daemonLoaded() {
        try run("/bin/launchctl", ["kickstart", "-k", "system/\(Paths.daemonLabel)"])
    } else {
        try run("/bin/launchctl", ["bootstrap", "system", Paths.launchDaemonPlist])
    }
    let vpn = env.vpnServices.map { "\($0.key)=\($0.value.interface)" }.sorted().joined(separator: ",")
    print("applied physical=\(env.physicalInterface ?? "-") vpn=[\(vpn)]")
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
    let json: [String: Any] = ["installed": installed, "running": pid != nil, "pid": pid ?? 0]
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
    case "start": try apply()
    case "stop": try stop()
    case "status": status()
    case "env":
        let env = NetworkState.environment()
        print("physical:", env.physicalInterface ?? "-")
        for s in NetworkState.vpnServices() {
            print("vpn:", s.name, s.id, s.providerBundleID ?? "-", s.interface ?? "disconnected", s.serverAddress ?? "-")
        }
    case "uninstall": try uninstall()
    default: fail("usage: splitroute-helper install|apply|start|stop|status|uninstall")
    }
} catch {
    fail("\(error)")
}
