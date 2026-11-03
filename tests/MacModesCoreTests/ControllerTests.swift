import Foundation
import MacModesCore

final class Fake: ModePlatform {
    var calls: [String] = []
    var fail: String?
    var busy = false
    var checker: (() throws -> Void)?
    var onStopTailscale: (() throws -> Void)?
    func call(_ name: String) throws { calls.append(name); if fail == name { throw Failure(name + " failed") } }
    func preflight() throws { try call("preflight"); if busy { throw Cancelled() } }
    func disconnectProton() throws { try call("disconnect") }
    func quitProton() throws { try call("quitProton") }
    func stopTailscale() throws { try call("stopTailscale"); try onStopTailscale?() }
    func stopCoding() throws { try call("stopCoding"); try stopTailscale() }
    func codingServices() throws -> [String: Bool] { ["tailscale": true, "orbstack": true] }
    func startCoding() throws { try call("startCoding") }
    func rollbackCoding(_ before: [String: Bool]) throws { try call("rollback") }
    func openApp(_ mode: Mode) throws { try call("open_" + mode.rawValue) }
    func closeApp(_ mode: Mode) throws { try call("close_" + mode.rawValue) }
    func layout(_ mode: Mode) throws { try call("layout") }
    func connectProton() throws { try call("connect") }
    func verifyVPN(egress: Bool) throws { try call("verify"); try checker?() }
    func openZen() throws { try call("zen") }
    func verifyCoding() throws { try call("healthCoding") }
    func verifyIdle() throws { try call("healthIdle") }
    func t3Running() -> Bool { false }
    func confirm(_ message: String) -> Bool { !busy }
    func notify(_ message: String, critical: Bool) { calls.append("notify") }
}
final class ControllerTests {
    func controller(_ mode: Mode = .normal) -> (Controller, Fake) {
        let p = Fake()
        let c = Controller(platform: p, state: ["mode": mode.rawValue, "requested_mode": mode.rawValue, "phase": "active"]) { _ in }
        return (c,p)
    }
    func testAllModePairsAndToggles() throws {
        for from in Mode.allCases { for to in Mode.allCases {
            let (c, _) = controller(from); try c.request("set", to)
            expectEqual(c.state["mode"] as? String,to.rawValue)
            expectEqual(c.state["phase"] as? String,"active")
        } }
        for mode in [Mode.coding,.music,.private] {
            let (c, _) = controller(mode); try c.request("toggle",mode)
            expectEqual(c.state["mode"] as? String,"normal")
        }
    }
    func testPrivateOrderAndGate() throws {
        let (c,p) = controller(.coding); try c.request("set",.private)
        for (a,b) in [("stopCoding","connect"),("connect","verify"),("verify","zen")] { expectLess(p.calls.firstIndex(of:a)!,p.calls.firstIndex(of:b)!) }
        let (d,q) = controller(); q.fail="verify"; try d.request("set",.private)
        expectFalse(q.calls.contains("zen")); expectEqual(d.state["phase"] as? String,"failed")
    }
    func testPrivateExitCancellationKeepsVPN() throws {
        let (c,p)=controller(.private); p.busy=true
        try c.request("set",.normal)
        expectFalse(p.calls.contains("disconnect")); expectEqual(c.state["mode"] as? String,"private")
    }
    func testCancellationLeavesServicesAndClearsOnNoop() throws {
        let (c,p)=controller(.coding);p.busy=true;try c.request("set",.music)
        expectEqual(p.calls,["preflight"]);expectEqual(c.state["mode"] as? String,"coding")
        expectEqual((c.state["feedback"] as? JSON)?["kind"] as? String,"cancelled")
        try c.request("set",.coding);expectTrue(c.state["last_error"] is NSNull)
    }
    func testSameModeVerifiesServices() throws {
        for mode in [Mode.coding, .private] {
            let (c,p)=controller(mode); p.fail = mode == .coding ? "healthCoding" : "verify"
            try c.request("set",mode)
            expectEqual(c.state["phase"] as? String,"failed")
        }
    }
    func testIdleHealthIsWarning() throws {
        let (c,p)=controller(); p.fail="healthIdle"; try c.health()
        expectEqual(c.state["phase"] as? String,"active"); expectNotNil(c.state["last_warning"] as? String)
    }
    func testLayoutFailureIsWarning() throws {
        let (c,p)=controller();p.fail="layout";try c.request("set",.coding)
        expectEqual(c.state["phase"] as? String,"active");expectNotNil(c.state["last_warning"] as? String);expectFalse(p.calls.contains("rollback"))
    }
    func testStartupFailureRollsBack() throws {
        let (c,p)=controller();p.fail="open_coding";try c.request("set",.coding)
        expectTrue(p.calls.contains("rollback"));expectEqual(c.state["phase"] as? String,"failed")
    }
    func testOwnershipAndRefusedQuit() throws {
        let (c,p)=controller()
        try c.request("set",.coding)
        expectTrue((c.state["recovery_modes"] as? [String] ?? []).contains("coding"))
        p.calls=[];p.fail="close_coding";try c.request("set",.normal)
        expectFalse(p.calls.contains("stopCoding"));expectFalse(p.calls.contains("disconnect"))
        expectTrue((c.state["recovery_modes"] as? [String] ?? []).contains("coding"))
    }
    func testPreexistingAppClosesOnModeExit() throws {
        for mode in [Mode.coding, .music] {
            let (c,p) = controller(mode)
            try c.request("set", .normal)
            expectTrue(p.calls.contains("close_" + mode.rawValue))
            expectLess(p.calls.firstIndex(of: "close_" + mode.rawValue)!, p.calls.firstIndex(of: "disconnect")!)
        }
    }
    func testPreexistingQuitRefusalPreservesServices() throws {
        let (c,p) = controller(.music); p.fail = "close_music"
        try c.request("set", .coding)
        expectEqual(c.state["phase"] as? String, "failed")
        expectFalse(p.calls.contains("disconnect")); expectFalse(p.calls.contains("startCoding"))
    }
    func testFailedEntryIsClosedWhenAbandoned() throws {
        let (c,p) = controller()
        try c.update(["requested_mode": "music", "phase": "failed"])
        try c.request("set", .normal)
        expectTrue(p.calls.contains("close_music"))
    }
    func testRetryDoesNotCloseTargetApp() throws {
        let (c,p) = controller(.coding)
        try c.update(["phase": "failed"])
        try c.request("set", .coding)
        expectFalse(p.calls.contains("close_coding"))
    }
    func testDisabledPlatformFlagsAndZenAreNoops() throws {
        let p = MacPlatform(config: [:], runtime: URL(fileURLWithPath: "/tmp"))
        // Missing bundle config would throw if either disabled action reached app lookup.
        try p.closeApp(.coding); try p.closeApp(.music)
        p.config = ["close_apps_on_exit": ["private": true, "normal": true]]
        try p.closeApp(.private); try p.closeApp(.normal)
    }
    func testVPNAppCleanupByMode() throws {
        for from in Mode.allCases { for target in Mode.allCases {
            let (c,p) = controller(from); try c.request("set",target)
            expectEqual(p.calls.contains("quitProton"),target != .private)
            expectEqual(p.calls.contains("stopTailscale"),target != .coding)
            if target != .private {
                expectLess(p.calls.firstIndex(of:"disconnect")!,p.calls.firstIndex(of:"quitProton")!)
            }
        } }
    }
    func testFailedDisconnectNeverQuitsProton() throws {
        let (c,p) = controller(.private); p.fail="disconnect"
        try c.request("set",.coding)
        expectFalse(p.calls.contains("quitProton"));expectFalse(p.calls.contains("startCoding"))
        expectEqual(c.state["phase"] as? String,"failed")
    }
    func testRefusedVPNQuitBlocksNextMode() throws {
        let (c,p) = controller(.private);p.fail="quitProton"
        try c.request("set",.coding)
        expectEqual(c.state["phase"] as? String,"failed");expectFalse(p.calls.contains("startCoding"))
    }
    func testTailscaleStopFailurePreventsPrivateEntry() throws {
        let (c,p)=controller(.coding);p.fail="stopTailscale"
        try c.request("set",.private)
        expectFalse(p.calls.contains("connect"));expectFalse(p.calls.contains("zen"))
        expectEqual(c.state["phase"] as? String,"failed")
    }
    func testPrivateReselectPreservesMonitorFailure() throws {
        let (c,p) = controller(.private)
        let checker = Fake(); checker.fail = "verify"
        var activeFeedbackCount = 0
        let monitored = Controller(platform: p, state: c.state) { state in
            if (state["feedback"] as? JSON)?["kind"] as? String == "active" { activeFeedbackCount += 1 }
        }
        p.onStopTailscale = { try monitored.privacyHealth(checker) }
        try monitored.request("set", .private)
        expectEqual(monitored.state["phase"] as? String, "failed")
        expectEqual(monitored.state["last_error"] as? String, "verify failed")
        expectEqual(monitored.state["vpn_verified"] as? Bool, false)
        expectEqual(activeFeedbackCount, 0)
        expectTrue(p.calls.contains("notify"))
    }
    func testSameModeReconcileFailureIsReported() throws {
        for mode in Mode.allCases {
            let (c,p) = controller(mode)
            p.fail = mode == .private ? "stopTailscale" : "quitProton"
            try c.request("set", mode)
            expectEqual(c.state["phase"] as? String, "failed")
            expectEqual(c.state["last_error"] as? String, p.fail! + " failed")
            expectEqual((c.state["feedback"] as? JSON)?["kind"] as? String, "failed")
            expectFalse(p.calls.contains("close_" + mode.rawValue))
        }
    }
    func testPreflightFailureDoesNotCloseUnenteredApp() throws {
        let (c,p) = controller(.coding); p.fail = "preflight"
        try c.request("set", .music)
        expectEqual(p.calls, ["preflight"])
        expectEqual(c.state["phase"] as? String, "failed")
        expectEqual(c.state["requested_mode"] as? String, "coding")
        expectEqual((c.state["feedback"] as? JSON)?["mode"] as? String, "music")
        p.fail = nil; p.calls = []
        try c.request("set", .coding)
        expectFalse(p.calls.contains("close_music"))
        expectEqual(c.state["phase"] as? String, "active")
    }
    func testPreflightFailurePreservesAbandonedEntryCleanup() throws {
        let (c,p) = controller(.normal)
        try c.update(["requested_mode": "music", "phase": "failed"])
        p.fail = "preflight"
        try c.request("set", .private)
        expectEqual(c.state["requested_mode"] as? String, "music")
        p.fail = nil; p.calls = []
        try c.request("set", .normal)
        expectTrue(p.calls.contains("close_music"))
        expectEqual(c.state["phase"] as? String, "active")
    }
    func testEverydayBrowserNotOwnedOrClosed() throws {
        let (c,p)=controller();try c.request("set",.private);try c.health();try c.request("set",.normal)
        expectFalse(p.calls.contains("close_private"));expectFalse((c.state["recovery_modes"] as? [String] ?? []).contains("private"))
    }
    func testMonitorContinuesAfterFailedExit() throws {
        let (c,p)=controller(.private);p.fail="disconnect";try c.request("set",.normal)
        p.fail="verify";try c.privacyHealth();expectTrue(p.calls.contains("verify"));expectTrue(p.calls.contains("notify"))
    }
    func testStaleMonitorResultDoesNotFailNewMode() throws {
        let (c,p)=controller(.private)
        p.checker={try c.monitor(false);throw Failure("old sample")}
        try c.privacyHealth();expectEqual(c.state["phase"] as? String,"active")
    }
    func testMonitorDoesNotWaitForPlatformDialog() throws {
        let (c,_) = controller(.private)
        let checker=Fake();checker.fail="verify"
        let done=DispatchSemaphore(value:0)
        DispatchQueue.global().async { try? c.privacyHealth(checker);done.signal() }
        expectEqual(done.wait(timeout:.now()+1),.success)
        expectEqual(c.state["phase"] as? String,"failed")
    }
    func testExternalExitRequiresConfirmation() throws {
        for mode in [Mode.coding, .music, .private] {
            let (c,p) = controller(mode); p.busy = true
            try c.request("set", .normal, external: true)
            expectTrue(p.calls.isEmpty)
            expectEqual(c.state["mode"] as? String, mode.rawValue)
        }
    }
    func testPrivateRetryFailurePreservesMonitoring() throws {
        let (c,p) = controller(.private)
        try c.update(["phase": "failed", "privacy_monitoring": true])
        p.fail = "connect"; try c.request("set", .private)
        p.fail = "verify"; try c.privacyHealth()
        expectTrue(p.calls.contains("notify"))
        expectEqual(c.state["privacy_monitoring"] as? Bool, true)
    }
    func testQuitFailurePreservesMonitoring() throws {
        let (c,p) = controller(.private)
        p.fail = "quitProton"; try c.request("set", .normal)
        p.fail = "verify"; try c.privacyHealth()
        expectTrue(p.calls.contains("notify"))
    }
    func testLegacyRecoveryMigrates() throws {
        let p = Fake()
        let c = Controller(platform:p,state:["mode":"normal", "phase":"failed", "owned_apps":["music":["pid":123]]]) { _ in }
        try c.request("set", .normal)
        expectTrue(p.calls.contains("close_music")); expectNil(c.state["owned_apps"])
    }

    func testT3RestartDebounceAndProtectedModes() throws {
        var automation = T3Automation(running: true)
        func tick(_ running: Bool, _ mode: Mode, _ time: Double) -> Mode? {
            automation.target(running: running, mode: mode, active: true, now: time, launchEnabled: true, quitEnabled: true, debounce: 8)
        }
        expectNil(tick(false, .coding, 0))
        expectNil(tick(false, .coding, 7))
        expectNil(tick(true, .coding, 7.5))
        expectNil(tick(false, .coding, 8))
        expectNil(tick(false, .coding, 15))
        expectEqual(tick(false, .coding, 16), .normal)
        expectNil(tick(true, .private, 17))
        expectNil(tick(false, .music, 18))
        expectNil(tick(true, .music, 19))
        expectNil(tick(false, .normal, 20))
        expectEqual(tick(true, .normal, 21), .coding)
    }

    func testBadConfigStillChecksPrivacy() throws {
        let (c,p) = controller(.private); p.fail = "verify"
        var reported = false
        try privacyTick(controller:c,checker:p,reload:{ throw Failure("bad config") },report:{ _ in reported = true })
        expectTrue(reported); expectTrue(p.calls.contains("verify")); expectTrue(p.calls.contains("notify"))
        expectEqual(c.state["phase"] as? String,"failed")
    }

}
