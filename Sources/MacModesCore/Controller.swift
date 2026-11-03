import Foundation

public protocol ModePlatform: AnyObject {
    func preflight() throws
    func closeLegacy() throws
    func disconnectProton() throws
    func quitProton() throws
    func stopTailscale() throws
    func stopCoding() throws
    func codingServices() throws -> [String: Bool]
    func startCoding() throws
    func rollbackCoding(_ before: [String: Bool]) throws
    func openApp(_ mode: Mode, previous: OwnedApp?) throws -> OwnedApp?
    func closeApp(_ mode: Mode) throws
    func focus(_ enabled: Bool, owned: Bool) throws -> Bool
    func airDrop(_ disabled: Bool) throws
    func layout(_ mode: Mode) throws
    func connectProton() throws
    func verifyVPN(egress: Bool) throws
    func openZen() throws
    func verifyCoding() throws
    func verifyIdle() throws
    func t3Running() -> Bool
    func confirm(_ message: String) -> Bool
    func notify(_ message: String)
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
    public func request(_ operation: String, _ mode: Mode) throws {
        guard ["set", "toggle"].contains(operation) else { throw Failure("Invalid operation") }
        let s = state
        let target: Mode = operation == "toggle" && s["requested_mode"] as? String == mode.rawValue ? .normal : mode
        let previous = Mode(rawValue: s["mode"] as? String ?? "normal") ?? .normal
        if target == previous && s["phase"] as? String == "active" {
            // Re-selecting an active mode also reconciles its unused VPN apps.
            do {
                if target != .private { try platform.disconnectProton(); try platform.quitProton() }
                if target != .coding { try platform.stopTailscale() }
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
            var owned = state["owned_apps"] as? [String: JSON] ?? [:]
            // Exit policy applies even to apps that were already open on entry.
            // Include interrupted entries and legacy ownership records for recovery.
            var leaving = Set(owned.keys)
            leaving.insert(previous.rawValue)
            if s["phase"] as? String != "active", let requested = s["requested_mode"] as? String {
                leaving.insert(requested)
            }
            for name in leaving.sorted() where name != target.rawValue {
                if let mode = Mode(rawValue: name), [.coding, .music].contains(mode) {
                    try platform.closeApp(mode)
                }
                owned.removeValue(forKey: name); try update(["owned_apps": owned])
            }
            try platform.closeLegacy()
            if previous == .private || state["airdrop_owned"] as? Bool == true {
                try optional { try self.platform.airDrop(false) }
                try update(["airdrop_owned": false])
            }
            try monitor(false)
            if target != .private { try platform.disconnectProton(); try platform.quitProton() }
            if target != .coding { try platform.stopCoding() }
            switch target {
            case .coding:
                before = try platform.codingServices()
                try platform.startCoding(); try open(.coding); try dnd(true)
                try optional { try self.platform.layout(.coding) }
            case .music:
                try dnd(true); try open(.music)
                try optional { try self.platform.layout(.music) }
            case .private:
                try dnd(false); try platform.connectProton(); try platform.verifyVPN(egress: true)
                try optional { try self.platform.airDrop(true) }
                try monitor(true); try platform.openZen()
            case .normal: try dnd(false)
            }
            lock.lock()
            do {
                defer { lock.unlock() }
                if target == .private, let error = privacyError { throw Failure(error) }
                try update(["mode": target.rawValue, "requested_mode": target.rawValue, "phase": "active", "last_error": NSNull(), "vpn_verified": target == .private])
                try feedback("active", target, target.rawValue.capitalized + " active")
            }
        } catch {
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
        var owned = state["owned_apps"] as? [String: JSON] ?? [:]
        let app = try platform.openApp(mode, previous: owned[mode.rawValue].flatMap(OwnedApp.init))
        owned[mode.rawValue] = app?.json
        try update(["owned_apps": owned])
    }
    private func dnd(_ enabled: Bool) throws {
        try optional {
            let owned = try self.platform.focus(enabled, owned: self.state["dnd_owned"] as? Bool ?? false)
            try self.update(["dnd_owned": owned])
        }
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
            if changed { platform.notify("Private VPN needs attention. Pause browsing and check Proton.") }
        }
    }
    public func health() throws {
        let s = state
        guard s["phase"] as? String == "active", s["mode"] as? String != "private" else { return }
        do {
            if s["mode"] as? String == "coding" { try platform.verifyCoding() } else { try platform.verifyIdle() }
        } catch { try update(["phase": "failed", "last_error": error.localizedDescription, "vpn_verified": false]) }
    }
}
