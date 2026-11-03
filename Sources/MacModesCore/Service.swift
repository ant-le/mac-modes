import Foundation

public func bootID() throws -> String { try command(["/usr/sbin/sysctl", "-n", "kern.bootsessionuuid"]).output }
public func baseline(boot: String) -> JSON { ["mode": "normal", "requested_mode": "normal", "phase": "pending", "last_error": NSNull(), "dnd_owned": false, "airdrop_owned": false, "boot_id": boot] }
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
    try controller.request("set", Mode(rawValue: data["target"] as! String)!)
    try persist(controller.state, result)
    try FileManager.default.removeItem(at: url)
}
public final class ControllerService {
    public let runtime: URL, configDirectory: URL
    private var runtimeLock: RuntimeLock?
    private let lifecycleLock = NSLock()
    private var stopped = false
    private var watcher: DispatchSourceTimer?
    public var confirmation: ((String) -> Bool)?
    public var notification: ((String) -> Void)?
    public init(runtime: URL, configDirectory: URL) { self.runtime = runtime; self.configDirectory = configDirectory }
    public func stop() { lifecycleLock.lock(); stopped = true; lifecycleLock.unlock() }
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
            state.merge(["mode": "normal", "requested_mode": "normal", "phase": "pending", "boot_id": boot, "privacy_monitoring": false, "vpn_verified": false, "owned_apps": JSON()]) { _, new in new }
            for file in try files("requests") { try FileManager.default.removeItem(at: file) }
            try? FileManager.default.removeItem(at: runtime.appendingPathComponent("suspended.json"))
        }
        let controller = Controller(platform: platform, state: state) { try atomicJSON($0, to: stateURL) }
        if state["phase"] as? String == "starting" { try controller.update(["phase": "failed", "last_error": "Controller restarted during a transition; select a mode to recover"]) }
        let checker = MacPlatform(config: config, runtime: runtime)
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "mac-modes.privacy", qos: .utility))
        timer.schedule(deadline: .now(), repeating: max(0.5, config["poll_seconds"] as? Double ?? 2))
        timer.setEventHandler { [weak self] in
            guard let self = self, !self.shouldStop else { return }
            do { checker.config = try readConfig(self.configDirectory); try controller.privacyHealth(checker) }
            catch { fputs("Privacy monitor: \(error.localizedDescription)\n", stderr) }
        }
        watcher = timer; timer.resume()
        DispatchQueue(label: "mac-modes.transitions", qos: .userInitiated).async { [self] in
            defer { watcher?.cancel(); runtimeLock = nil }
            do {
                if controller.state["phase"] as? String == "pending" { try controller.request("set", .normal) }
                var lastT3 = platform.t3Running()
                while !shouldStop {
                    do {
                        platform.config = try readConfig(configDirectory)
                        for file in try files("requests") {
                            if shouldStop { break }
                            try processRequest(file, controller: controller, runtime: runtime)
                            lastT3 = platform.t3Running()
                        }
                        let current = platform.t3Running(), s = controller.state
                        if s["phase"] as? String == "active" {
                            if current && !lastT3 && platform.config["auto_coding_on_t3_launch"] as? Bool != false {
                                if s["mode"] as? String == "normal" || platform.confirm("T3 opened. Switch to Coding mode?") { try controller.request("set", .coding) }
                            } else if lastT3 && !current && s["mode"] as? String == "coding" && platform.config["normal_on_t3_quit"] as? Bool != false {
                                try controller.request("set", .normal)
                            }
                        }
                        lastT3 = current
                        try controller.health(); try controller.update(["heartbeat": Date().timeIntervalSince1970])
                        for file in try files("results").dropLast(100) { try FileManager.default.removeItem(at: file) }
                    } catch { try controller.update(["phase": "failed", "last_error": error.localizedDescription]) }
                    Thread.sleep(forTimeInterval: max(0.5, platform.config["poll_seconds"] as? Double ?? 2))
                }
            } catch { fputs("Controller stopped: \(error.localizedDescription)\n", stderr); notification?("Controller stopped: " + error.localizedDescription) }
        }
    }
    private func files(_ directory: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: runtime.appendingPathComponent(directory), includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
