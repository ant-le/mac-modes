import Foundation
import AppKit
import Darwin

public func bootID() throws -> String { try command(["/usr/sbin/sysctl", "-n", "kern.bootsessionuuid"]).output }
public func baseline(boot: String) -> JSON { ["mode": "normal", "requested_mode": "normal", "phase": "pending", "last_error": NSNull(), "boot_id": boot] }
public func processRequest(_ url: URL, controller: Controller, runtime: URL, persist: (JSON, URL) throws -> Void = atomicJSON) throws {
    let result = runtime.appendingPathComponent("results/" + url.lastPathComponent)
    if FileManager.default.fileExists(atPath: result.path) { try FileManager.default.removeItem(at: url); return }
    var data: JSON
    do {
        data = try readJSON(url)
        guard let operation = data["operation"] as? String, ["set", "toggle"].contains(operation),
              let name = data["mode"] as? String, Mode(rawValue: name) != nil else { throw Failure("Invalid request") }
        if data["target"] == nil {
            data["target"] = operation == "toggle" && controller.state["requested_mode"] as? String == name ? "normal" : name
        }
        guard let target = data["target"] as? String, Mode(rawValue: target) != nil else { throw Failure("Invalid resolved target") }
    } catch {
        try persist(["phase": "failed", "last_error": error.localizedDescription], result)
        let rejected = runtime.appendingPathComponent("rejected", isDirectory: true)
        try FileManager.default.createDirectory(at: rejected, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: rejected.appendingPathComponent(url.lastPathComponent))
        return
    }
    // Persist outside the validation catch: I/O failure must never discard a valid click.
    try persist(data, url)
    try controller.request("set", Mode(rawValue: data["target"] as! String)!, external: data["external"] as? Bool == true)
    try persist(controller.state, result)
    try FileManager.default.removeItem(at: url)
}
/// Transition-loop state; injected uptime makes restarts deterministic to test.
public struct T3Automation {
    private var running: Bool
    private var quitAt: TimeInterval?
    public init(running: Bool) { self.running = running }
    public mutating func reconcile(running: Bool) { self.running = running; quitAt = nil }
    public mutating func target(running current: Bool, mode: Mode, active: Bool, now: TimeInterval,
                                launchEnabled: Bool, quitEnabled: Bool, debounce: TimeInterval) -> Mode? {
        defer { running = current }
        if current || mode != .coding || !active { quitAt = nil }
        guard active else { return nil }
        if current && !running && mode == .normal && launchEnabled { return .coding }
        if running && !current && mode == .coding { quitAt = now }
        if let quit = quitAt, !current, mode == .coding, quitEnabled, now - quit >= max(1, debounce) {
            quitAt = nil; return .normal
        }
        return nil
    }
}

public func privacyTick(controller: Controller, checker: ModePlatform, reload: () throws -> Void, report: (Error) -> Void) throws {
    do { try reload() } catch { report(error) }
    // A failed reload must never suppress the health check using the last good config.
    try controller.privacyHealth(checker)
}

public final class ControllerService {
    public let runtime: URL, configDirectory: URL
    private var runtimeLock: RuntimeLock?
    private let lifecycleLock = NSLock()
    private var stopped = false
    private var watcher: DispatchSourceTimer?
    private let wake = DispatchSemaphore(value: 0)
    private var requestsWatcher: DispatchSourceFileSystemObject?
    private var appObservers: [NSObjectProtocol] = []
    public var stateChanged: ((JSON) -> Void)?
    public var confirmation: ((String) -> Bool)?
    public var notification: ((String, Bool) -> Void)?
    public init(runtime: URL, configDirectory: URL) { self.runtime = runtime; self.configDirectory = configDirectory }
    public func stop() { lifecycleLock.lock(); stopped = true; lifecycleLock.unlock(); wake.signal() }
    private var shouldStop: Bool { lifecycleLock.lock(); defer { lifecycleLock.unlock() }; return stopped }
    public func start() throws {
        runtimeLock = try RuntimeLock(runtime)
        for name in ["requests", "results"] { try FileManager.default.createDirectory(at: runtime.appendingPathComponent(name), withIntermediateDirectories: true) }
        let config = try readConfig(configDirectory)
        let platform = MacPlatform(config: config, runtime: runtime)
        platform.confirmation = confirmation; platform.notification = notification
        let boot = try bootID(), stateURL = runtime.appendingPathComponent("state.json")
        var state = FileManager.default.fileExists(atPath: stateURL.path) ? try readJSON(stateURL) : baseline(boot: boot)
        if state["boot_id"] as? String != boot {
            state.merge(["mode": "normal", "requested_mode": "normal", "phase": "pending", "boot_id": boot, "privacy_monitoring": false, "vpn_verified": false, "recovery_modes": [String]()]) { _, new in new }
            state.removeValue(forKey: "owned_apps")
            for file in try files("requests") { try FileManager.default.removeItem(at: file) }
            try? FileManager.default.removeItem(at: runtime.appendingPathComponent("suspended.json"))
        }
        let controller = Controller(platform: platform, state: state) { [weak self] value in
            try atomicJSON(value, to: stateURL)
            self?.stateChanged?(value)
        }
        stateChanged?(controller.state)
        if state["phase"] as? String == "starting" { try controller.update(["phase": "failed", "last_error": "Controller restarted during a transition; select a mode to recover"]) }
        let checker = MacPlatform(config: config, runtime: runtime)
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "mac-modes.privacy", qos: .utility))
        timer.schedule(deadline: .now(), repeating: max(0.5, config["poll_seconds"] as? Double ?? 2))
        timer.setEventHandler { [weak self] in
            guard let self = self, !self.shouldStop else { return }
            do {
                try privacyTick(controller: controller, checker: checker, reload: {
                    checker.config = try readConfig(self.configDirectory)
                }, report: { fputs("Privacy monitor using last good config: \($0.localizedDescription)\n", stderr) })
            }
            catch { fputs("Privacy monitor: \(error.localizedDescription)\n", stderr) }
        }
        watcher = timer; timer.resume()
        let fd = open(runtime.appendingPathComponent("requests").path, O_EVTONLY)
        guard fd >= 0 else { timer.cancel(); throw Failure("Cannot watch request directory") }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .global(qos: .userInitiated))
        source.setEventHandler { [weak self] in self?.wake.signal() }
        source.setCancelHandler { close(fd) }
        requestsWatcher = source; source.resume()
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            appObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.wake.signal() })
        }
        DispatchQueue(label: "mac-modes.transitions", qos: .userInitiated).async { [self] in
            defer {
                watcher?.cancel(); requestsWatcher?.cancel()
                appObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
                appObservers.removeAll(); runtimeLock = nil
            }
            do {
                if controller.state["phase"] as? String == "pending" { try controller.request("set", .normal) }
                var automation = T3Automation(running: platform.t3Running())
                var nextHealth: TimeInterval = 0
                while !shouldStop {
                    do {
                        platform.config = try readConfig(configDirectory)
                        for file in try files("requests") {
                            if shouldStop { break }
                            try processRequest(file, controller: controller, runtime: runtime)
                            automation.reconcile(running: platform.t3Running())
                        }
                        let current = platform.t3Running(), s = controller.state
                        let now = ProcessInfo.processInfo.systemUptime
                        if let target = automation.target(running: current, mode: Mode(rawValue: s["mode"] as? String ?? "") ?? .normal,
                                                          active: s["phase"] as? String == "active", now: now,
                                                          launchEnabled: platform.config["auto_coding_on_t3_launch"] as? Bool != false,
                                                          quitEnabled: platform.config["normal_on_t3_quit"] as? Bool != false,
                                                          debounce: platform.config["t3_quit_debounce_seconds"] as? Double ?? 8) {
                            try controller.request("set", target)
                        }
                        if now >= nextHealth {
                            try controller.health()
                            nextHealth = now + max(0.5, platform.config["poll_seconds"] as? Double ?? 2)
                        }
                        for file in try files("results").dropLast(100) { try FileManager.default.removeItem(at: file) }
                    } catch { try controller.update(["phase": "failed", "last_error": error.localizedDescription, "vpn_verified": false]) }
                    _ = wake.wait(timeout: .now() + max(0.5, platform.config["poll_seconds"] as? Double ?? 2))
                }
            } catch { fputs("Controller stopped: \(error.localizedDescription)\n", stderr); notification?("Controller stopped: " + error.localizedDescription, true) }
        }
    }
    private func files(_ directory: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: runtime.appendingPathComponent(directory), includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
