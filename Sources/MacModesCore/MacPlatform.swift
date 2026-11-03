import AppKit
import Foundation
import ApplicationServices
import Darwin

public struct CommandResult { public let output: String; public let status: Int32 }
public func command(_ arguments: [String], timeout: TimeInterval = 30, check: Bool = true) throws -> CommandResult {
    guard let executable = arguments.first else { throw Failure("Missing command") }
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("mac-modes-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: temp) }
    let out = temp.appendingPathComponent("stdout"), err = temp.appendingPathComponent("stderr")
    FileManager.default.createFile(atPath: out.path, contents: nil, attributes: [.posixPermissions: 0o600])
    FileManager.default.createFile(atPath: err.path, contents: nil, attributes: [.posixPermissions: 0o600])
    let stdout = try FileHandle(forWritingTo: out), stderr = try FileHandle(forWritingTo: err)
    defer { try? stdout.close(); try? stderr.close() }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable); process.arguments = Array(arguments.dropFirst())
    process.environment = ProcessInfo.processInfo.environment.merging(["TAILSCALE_BE_CLI": "1", "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"]) { _, new in new }
    process.standardOutput = stdout; process.standardError = stderr
    let done = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in done.signal() }
    try process.run()
    if done.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        if done.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL); _ = done.wait(timeout: .now() + 2) }
        throw Failure(URL(fileURLWithPath: executable).lastPathComponent + " timed out")
    }
    if check && process.terminationStatus != 0 { throw Failure(URL(fileURLWithPath: executable).lastPathComponent + " failed; check the app and permissions") }
    return CommandResult(output: (try String(contentsOf: out, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines), status: process.terminationStatus)
}
public final class MacPlatform: ModePlatform {
    public var config: JSON
    public let runtime: URL
    public var confirmation: ((String) -> Bool)?
    public var notification: ((String, Bool) -> Void)?
    public init(config: JSON, runtime: URL) { self.config = config; self.runtime = runtime }
    func string(_ key: String) throws -> String { guard let s = config[key] as? String else { throw Failure("Missing config: " + key) }; return s }
    func run(_ args: [String], timeout: Double = 30, check: Bool = true) throws -> String { try command(args, timeout: timeout, check: check).output }
    public func notify(_ message: String, critical: Bool = false) { notification?(message, critical) }
    public func confirm(_ message: String) -> Bool { confirmation?(message) ?? false }
    public func t3Running() -> Bool { NSRunningApplication.runningApplications(withBundleIdentifier: config["t3_bundle"] as? String ?? "").contains { !$0.isTerminated } }
    func bundle(_ mode: Mode) throws -> String { try string(mode == .coding ? "t3_bundle" : "music_bundle") }
    public func openApp(_ mode: Mode) throws {
        let id = try bundle(mode)
        _ = try run(["/usr/bin/open", "-b", id])
        for _ in 0..<40 {
            if NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { !$0.isTerminated }) { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw Failure("App did not launch: " + id)
    }
    public func closeApp(_ mode: Mode) throws {
        guard [.coding, .music].contains(mode),
              (config["close_apps_on_exit"] as? [String: Bool])?[mode.rawValue] == true else { return }
        let id = try bundle(mode)
        // Use native application objects, not persisted PIDs, for every current instance.
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { !$0.isTerminated }
        for app in running {
            guard app.terminate() else { throw Failure("App refused to quit; respond to its dialog") }
        }
        for _ in 0..<60 {
            if NSRunningApplication.runningApplications(withBundleIdentifier: id).allSatisfy({ $0.isTerminated }) { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw Failure("App is still open. Respond to its save/quit dialog, then retry")
    }
    func quitBundle(_ bundle: String) throws {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundle) where !app.isTerminated {
            guard app.terminate() else { throw Failure("App refused to quit: " + bundle) }
        }
    }
    func quitBundleAndWait(_ bundle: String) throws {
        try quitBundle(bundle)
        for _ in 0..<60 {
            if NSRunningApplication.runningApplications(withBundleIdentifier: bundle).allSatisfy({ $0.isTerminated }) { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw Failure("App is still running after quit: " + bundle)
    }
    public func quitProton() throws {
        guard try protonServices().allSatisfy({ $0.1 == "Disconnected" }) else {
            throw Failure("Proton must disconnect safely before its app quits")
        }
        try quitBundleAndWait(string("proton_bundle"))
        guard try protonServices().allSatisfy({ $0.1 == "Disconnected" }) else {
            throw Failure("Proton reconnected while quitting")
        }
    }
    public func stopTailscale() throws {
        try tailscaleDown()
        try quitBundleAndWait(config["tailscale_bundle"] as? String ?? "io.tailscale.ipn.macsys")
        guard ["Stopped", "NeedsLogin", "NoState"].contains(try tailscaleState()) else {
            throw Failure("Tailscale reconnected while quitting")
        }
    }
    public func tailscaleState() throws -> String {
        let data = try run([string("tailscale"), "status", "--json"])
        guard let obj = try JSONSerialization.jsonObject(with: Data(data.utf8)) as? JSON, let state = obj["BackendState"] as? String else { throw Failure("Invalid Tailscale status") }
        return state
    }
    func tailscaleDown() throws {
        _ = try run([string("tailscale"), "down"])
        for _ in 0..<20 {
            if ["Stopped", "NeedsLogin", "NoState"].contains(try tailscaleState()) { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw Failure("Tailscale did not disconnect")
    }
    public func orbRunning() throws -> Bool {
        let status = try run([string("orbctl"), "status"]).lowercased()
        guard ["running", "stopped"].contains(status) else { throw Failure("Unknown OrbStack status: " + status) }
        return status == "running"
    }
    public func preflight() throws {
        guard config["confirm_stop_workloads"] as? Bool != false, try orbRunning() else { return }
        let containers = try run([string("docker"), "--context", "orbstack", "ps", "-q"])
        let machines = try run([string("orbctl"), "list", "-r", "-q"])
        let count = containers.split(separator: "\n").count + machines.split(separator: "\n").count
        if count > 0 && !confirm("\(count) OrbStack workloads are running. Stop them gracefully and switch modes?") { throw Cancelled() }
    }
    public func codingServices() throws -> [String: Bool] { try ["tailscale": tailscaleState() == "Running", "orbstack": orbRunning()] }
    public func startCoding() throws {
        guard try protonServices().allSatisfy({ $0.1 == "Disconnected" }) else { throw Failure("Disconnect Proton before connecting Tailscale") }
        _ = try run([string("orbctl"), "start"], timeout: 90)
        if try tailscaleState() != "Running" { _ = try run([string("tailscale"), "up", "--timeout=30s"], timeout: 35) }
        try verifyCoding()
    }
    public func stopCoding() throws {
        try stopTailscale()
        if try orbRunning() { _ = try run([string("orbctl"), "stop"], timeout: 90); if try orbRunning() { throw Failure("OrbStack is still running") } }
        try quitBundle("dev.kdrag0n.MacVirt")
    }
    public func rollbackCoding(_ before: [String: Bool]) throws {
        if try before["orbstack"] != true && orbRunning() {
            try preflight(); _ = try run([string("orbctl"), "stop"], timeout: 90)
            if try orbRunning() { throw Failure("OrbStack is still running") }
        }
        if before["tailscale"] != true { try tailscaleDown() }
    }
    public func verifyCoding() throws {
        guard try protonServices().allSatisfy({ $0.1 == "Disconnected" }), try tailscaleState() == "Running", try orbRunning() else { throw Failure("Coding requires Tailscale and OrbStack running, and Proton disconnected") }
    }
    public func verifyIdle() throws {
        if try !protonServices().allSatisfy({ $0.1 == "Disconnected" }) || tailscaleState() == "Running" || orbRunning() { throw Failure("Services running outside their mode; choose a mode to reconcile") }
    }
    public static func parseProton(_ text: String) throws -> [(String, String)] {
        let regex = try NSRegularExpression(pattern: #"\(([^)]+)\)\s+([0-9A-Fa-f-]{36})"#)
        return try text.components(separatedBy: .newlines).filter { $0.lowercased().contains("proton") }.map { line in
            guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let a = Range(match.range(at: 1), in: line), let b = Range(match.range(at: 2), in: line) else { throw Failure("Unrecognized Proton service status") }
            return (String(line[b]), String(line[a]))
        }
    }
    func protonServices() throws -> [(String, String)] { try Self.parseProton(run(["/usr/sbin/scutil", "--nc", "list"])) }
    public func protonConnected() throws -> Bool { try protonServices().contains { $0.1 == "Connected" } }
    public func connectProton() throws {
        guard config["proton_kill_switch_setup_verified"] as? Bool == true else { throw Failure("Verify Proton kill switch before Private mode") }
        if try protonConnected() { return }
        _ = try run(["/usr/bin/open", "-b", string("proton_bundle")])
        _ = try run(["/usr/sbin/scutil", "--nc", "start", string("proton_service")])
        let deadline = Date().addingTimeInterval(config["connection_timeout_seconds"] as? Double ?? 60)
        while Date() < deadline { if try protonConnected() { return }; Thread.sleep(forTimeInterval: 1) }
        throw Failure("Proton did not connect. Connect once in its app, then retry")
    }
    public func disconnectProton() throws {
        for (service, state) in try protonServices() where state != "Disconnected" { _ = try run(["/usr/sbin/scutil", "--nc", "stop", service]) }
        for _ in 0..<20 { if try protonServices().allSatisfy({ $0.1 == "Disconnected" }) { return }; Thread.sleep(forTimeInterval: 0.5) }
        throw Failure("Proton is still connected")
    }
    func route(_ address: String, v6: Bool = false) throws -> String? {
        let text = try run(["/sbin/route", "-n", "get"] + (v6 ? ["-inet6"] : []) + [address], check: false)
        return text.components(separatedBy: .newlines).first { $0.contains("interface:") }?.components(separatedBy: "interface:").last?.trimmingCharacters(in: .whitespaces)
    }
    public static func validateVPN(connected: Bool, tailscale: String, ipv4: String?, ipv6: String?, egress: String?) throws {
        guard connected, tailscale != "Running" else { throw Failure("Private requires Proton connected and Tailscale disconnected") }
        guard ipv4?.hasPrefix("utun") == true else { throw Failure("IPv4 is not using a VPN tunnel") }
        if let ipv6 = ipv6, !ipv6.hasPrefix("utun") { throw Failure("IPv6 may bypass the VPN") }
        if let egress = egress {
            let data = try JSONSerialization.jsonObject(with: Data(egress.utf8)) as? JSON
            guard data?["Code"] as? Int == 86081 else { throw Failure("Proton did not recognize a VPN exit") }
        }
    }
    public func verifyVPN(egress: Bool) throws {
        let connected = try protonConnected(), tailscale = try tailscaleState()
        guard connected, tailscale != "Running" else { throw Failure("Private requires Proton connected and Tailscale disconnected") }
        let v4 = try route("1.1.1.1"), v6 = try route("2606:4700:4700::1111", v6: true)
        try Self.validateVPN(connected: connected, tailscale: tailscale, ipv4: v4, ipv6: v6, egress: nil)
        if egress {
            let reply = try run(["/usr/bin/curl", "--silent", "--show-error", "--ipv4", "--max-time", "10", string("egress_check_url")], timeout: 12)
            try Self.validateVPN(connected: connected, tailscale: tailscale, ipv4: v4, ipv6: v6, egress: reply)
        }
    }
    public func openZen() throws {
        try verifyVPN(egress: false)
        let app = URL(fileURLWithPath: try string("zen_executable")).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        _ = try run(["/usr/bin/open", "-a", app.path]); notify("Proton verified. Select your Privacy container in Zen.")
    }
    public func layout(_ mode: Mode) throws {
        guard AXIsProcessTrusted() else { throw Failure("Allow Mac Modes in Accessibility to resize windows") }
        let id = try bundle(mode)
        for _ in 0..<40 {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                let element = AXUIElementCreateApplication(app.processIdentifier)
                var result: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXMainWindowAttribute as CFString, &result) != .success {
                    _ = AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &result)
                }
                if let result = result, CFGetTypeID(result) == AXUIElementGetTypeID() {
                    let window = unsafeBitCast(result, to: AXUIElement.self)
                    var position: CFTypeRef?
                    _ = AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position)
                    var point = CGPoint.zero
                    guard let position = position, CFGetTypeID(position) == AXValueGetTypeID(), AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point) else { throw Failure("Could not read window position") }
                    let frames: [CGRect] = DispatchQueue.main.sync { NSScreen.screens.map { $0.visibleFrame } }
                    let primaryHeight: CGFloat = DispatchQueue.main.sync { NSScreen.screens.first?.frame.maxY ?? 0 }
                    let frame = frames.first { $0.contains(CGPoint(x: point.x + 20, y: primaryHeight - point.y - 20)) } ?? frames.first ?? .zero
                    var origin = CGPoint(x: frame.minX, y: primaryHeight - frame.maxY), size = frame.size
                    guard let pos = AXValueCreate(.cgPoint, &origin), let dimensions = AXValueCreate(.cgSize, &size),
                          AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, dimensions) == .success,
                          AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pos) == .success,
                          AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, dimensions) == .success else { throw Failure("App does not allow this window layout") }
                    _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString); return
                }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw Failure("No app window became available for layout")
    }
}
