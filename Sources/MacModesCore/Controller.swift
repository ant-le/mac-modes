import Foundation

public protocol ModePlatform: AnyObject {
    func preflight() throws
    func disconnectProton() throws
    func quitProton() throws
    func stopTailscale() throws
    func stopCoding() throws
    func codingServices() throws -> [String: Bool]
    func startCoding() throws
    func rollbackCoding(_ before: [String: Bool]) throws
    func openApp(_ mode: Mode) throws
    func closeApp(_ mode: Mode) throws
    func layout(_ mode: Mode) throws
    func connectProton() throws
    func verifyVPN(egress: Bool) throws
    func openZen() throws
    func verifyCoding() throws
    func verifyIdle() throws
    func t3Running() -> Bool
    func confirm(_ message: String) -> Bool
    func notify(_ message: String, critical: Bool)
}
public final class Controller {
    public let platform: ModePlatform
    private var value: JSON
    private let save: (JSON) throws -> Void
    private let lock = NSRecursiveLock()
    private var privacyEpoch = 0
    private var privacyError: String?
    public init(platform: ModePlatform, state: JSON, save: @escaping (JSON) throws -> Void) {
        self.platform = platform; value = state; self.save = save
        let legacy = state["owned_apps"] as? JSON ?? [:]
        value["recovery_modes"] = Array(Set((state["recovery_modes"] as? [String] ?? []) + Array(legacy.keys))).sorted()
        for key in ["owned_apps", "dnd_owned", "airdrop_owned", "heartbeat"] { value.removeValue(forKey: key) }
    }
    public var state: JSON { lock.lock(); defer { lock.unlock() }; return value }
    public func update(_ fields: JSON) throws {
        lock.lock(); defer { lock.unlock() }
        value.merge(fields) { _, new in new }
        value["updated_at"] = Date().timeIntervalSince1970
        try save(value)
    }
    public func feedback(_ kind: String, _ mode: Mode, _ message: String) throws {
        try update(["feedback": ["id": UUID().uuidString, "kind": kind, "mode": mode.rawValue, "message": message]])
    }
    public func monitor(_ enabled: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        privacyEpoch += 1; privacyError = nil
        try update(["privacy_monitoring": enabled, "vpn_verified": false])
    }
    public func request(_ operation: String, _ mode: Mode, external: Bool = false) throws {
        guard ["set", "toggle"].contains(operation) else { throw Failure("Invalid operation") }
        let s = state
        let target: Mode = operation == "toggle" && s["requested_mode"] as? String == mode.rawValue ? .normal : mode
        let previous = Mode(rawValue: s["mode"] as? String ?? "normal") ?? .normal
        let privateExposure = previous == .private || s["privacy_monitoring"] as? Bool == true || s["requested_mode"] as? String == "private"
        if target != .private && privateExposure && !platform.confirm("Close your Zen Privacy container tabs before disconnecting ProtonVPN. Continue?") {
            try feedback("cancelled", previous, "Switch cancelled"); return
        }
        if external && target != previous && [.coding, .music].contains(previous),
           !platform.confirm("External request to leave " + previous.rawValue.capitalized + ". This may close apps and stop services. Continue?") {
            try feedback("cancelled", previous, "Switch cancelled"); return
        }
        if target == previous && s["phase"] as? String == "active" {
            // Re-selecting an active mode also reconciles its unused VPN apps.
            do {
                if target != .private { try platform.disconnectProton(); try platform.quitProton() }
                if target != .coding { try platform.stopTailscale() }
                switch target {
                case .private: try platform.verifyVPN(egress: true)
                case .coding: try platform.verifyCoding()
                default: try optional { try self.platform.verifyIdle() }
                }
                lock.lock(); defer { lock.unlock() }
                // The privacy monitor may have failed the mode during reconciliation.
                guard value["phase"] as? String == "active" else { return }
                try update(["last_error": NSNull()])
                try feedback("active", target, target.rawValue.capitalized + " active")
            } catch { try failed(error, target: target) }
            return
        }
        try feedback("starting", target, "Switching to " + target.rawValue.capitalized + "…")
        do { if target != .coding { try platform.preflight() } }
        catch is Cancelled {
            try update(["last_error": "Kept current mode; workload stop cancelled"])
            try feedback("cancelled", previous, "Switch cancelled"); return
        } catch {
            // No entry started; preserve the previous recovery target for app cleanup.
            try update(["phase": "failed", "last_error": error.localizedDescription, "vpn_verified": false])
            try feedback("failed", target, error.localizedDescription); return
        }
        try update(["requested_mode": target.rawValue, "phase": "starting", "last_error": NSNull(), "last_warning": NSNull()])
        var before: [String: Bool]?
        do {
            var owned = Set(state["recovery_modes"] as? [String] ?? [])
            // Exit policy applies even to apps that were already open on entry.
            // Include interrupted entries and legacy ownership records for recovery.
            var leaving = owned
            leaving.insert(previous.rawValue)
            if s["phase"] as? String != "active", let requested = s["requested_mode"] as? String {
                leaving.insert(requested)
            }
            for name in leaving.sorted() where name != target.rawValue {
                if let mode = Mode(rawValue: name), [.coding, .music].contains(mode) {
                    try platform.closeApp(mode)
                }
                owned.remove(name); try update(["recovery_modes": owned.sorted()])
            }
            if target != .private {
                try platform.disconnectProton(); try platform.quitProton()
                try monitor(false)
            }
            if target != .coding { try platform.stopCoding() }
            switch target {
            case .coding:
                before = try platform.codingServices()
                try platform.startCoding(); try open(.coding)
                try optional { try self.platform.layout(.coding) }
            case .music:
                try open(.music)
                try optional { try self.platform.layout(.music) }
            case .private:
                try platform.connectProton(); try platform.verifyVPN(egress: true)
                try monitor(true); try platform.openZen()
            case .normal: break
            }
            lock.lock()
            do {
                defer { lock.unlock() }
                if target == .private, let error = privacyError { throw Failure(error) }
                try update(["mode": target.rawValue, "requested_mode": target.rawValue, "phase": "active", "last_error": NSNull(), "vpn_verified": target == .private])
                try feedback("active", target, target.rawValue.capitalized + " active")
            }
        } catch {
            // A failed initial connection may still leave Proton connecting.
            if target == .private && state["privacy_monitoring"] as? Bool != true { try monitor(true) }
            if let before = before {
                do { try platform.rollbackCoding(before) }
                catch { try update(["last_warning": "Kept services after startup failure: " + error.localizedDescription]) }
            }
            try failed(error, target: target)
        }
    }
    private func failed(_ error: Error, target: Mode) throws {
        try update(["requested_mode": target.rawValue, "phase": "failed", "last_error": error.localizedDescription, "vpn_verified": false])
        try feedback("failed", target, error.localizedDescription)
    }
    private func open(_ mode: Mode) throws {
        var modes = Set(state["recovery_modes"] as? [String] ?? [])
        modes.insert(mode.rawValue)
        try update(["recovery_modes": modes.sorted()])
        try platform.openApp(mode)
    }
    private func optional(_ action: () throws -> Void) throws {
        do { try action() }
        catch {
            let previous = state["last_warning"] as? String
            try update(["last_warning": [previous, error.localizedDescription].compactMap { $0 }.joined(separator: "; ")])
        }
    }
    public func privacyHealth(_ checker: ModePlatform? = nil) throws {
        lock.lock()
        let enabled = value["privacy_monitoring"] as? Bool ?? (value["mode"] as? String == "private")
        let epoch = privacyEpoch
        lock.unlock()
        guard enabled else { return }
        do { try (checker ?? platform).verifyVPN(egress: false) }
        catch {
            lock.lock(); defer { lock.unlock() }
            guard epoch == privacyEpoch else { return }
            let changed = privacyError != error.localizedDescription
            privacyError = error.localizedDescription
            try update(["phase": "failed", "last_error": error.localizedDescription, "vpn_verified": false])
            if changed { platform.notify("Private VPN needs attention. Pause browsing and check Proton.", critical: true) }
        }
    }
    public func health() throws {
        let s = state
        guard s["phase"] as? String == "active", s["mode"] as? String != "private" else { return }
        do {
            if s["mode"] as? String == "coding" { try platform.verifyCoding() } else { try platform.verifyIdle() }
        } catch {
            if s["mode"] as? String == "coding" {
                try failed(error, target: .coding)
            } else if s["last_warning"] as? String != error.localizedDescription {
                try update(["last_warning": error.localizedDescription])
            }
        }
    }
}
