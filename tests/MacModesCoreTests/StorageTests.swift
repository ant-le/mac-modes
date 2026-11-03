import Foundation
import MacModesCore
final class StorageTests {
    var runtime: URL!
    func setUpWithError() throws { runtime=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:runtime,withIntermediateDirectories:true) }
    func tearDownWithError() throws { try FileManager.default.removeItem(at:runtime) }
    func controller() -> Controller { Controller(platform:Fake(),state:["mode":"normal","requested_mode":"normal","phase":"active"]) { _ in } }
    func testCrashAfterStateSaveDoesNotReverseToggle() throws {
        let result=try enqueue("toggle","music",runtime:runtime), file=runtime.appendingPathComponent("requests/"+result.lastPathComponent), c=controller()
        expectThrows(try processRequest(file,controller:c,runtime:runtime) { object,url in
            if url.deletingLastPathComponent().lastPathComponent=="results" { throw Failure("crash") };try atomicJSON(object,to:url)
        })
        expectEqual(c.state["mode"] as? String,"music")
        try processRequest(file,controller:c,runtime:runtime)
        expectEqual(c.state["mode"] as? String,"music")
    }
    func testDurableTargetSurvivesInterruptedTransition() throws {
        let result=try enqueue("toggle","private",runtime:runtime),file=runtime.appendingPathComponent("requests/"+result.lastPathComponent),c=controller()
        try atomicJSON(["operation":"toggle","mode":"private","target":"private"],to:file)
        try c.update(["phase":"failed","requested_mode":"private"])
        try processRequest(file,controller:c,runtime:runtime)
        expectEqual(c.state["mode"] as? String,"private")
    }
    func testDurableResultNotExecutedTwice() throws {
        let result=try enqueue("toggle","music",runtime:runtime),file=runtime.appendingPathComponent("requests/"+result.lastPathComponent),c=controller()
        try atomicJSON(["phase":"active"],to:result);try processRequest(file,controller:c,runtime:runtime)
        expectEqual(c.state["mode"] as? String,"normal")
    }
    func testMalformedRequestQuarantined() throws {
        let file=runtime.appendingPathComponent("requests/bad.json")
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data("{bad".utf8).write(to:file)
        try processRequest(file,controller:controller(),runtime:runtime)
        expectTrue(FileManager.default.fileExists(atPath:runtime.appendingPathComponent("rejected/bad.json").path))
    }
    func testLockExcludesOtherController() throws {
        var owner: RuntimeLock?=try RuntimeLock(runtime)
        expectTrue(controllerOnline(runtime));expectThrows(try RuntimeLock(runtime))
        expectNotNil(owner);owner=nil;expectFalse(controllerOnline(runtime))
    }
    func testAtomicWriteHasPrivatePermissions() throws {
        let file=runtime.appendingPathComponent("state.json");try atomicJSON(["mode":"music"],to:file)
        try expectEqual(try readJSON(file)["mode"] as? String,"music")
        let attr=try FileManager.default.attributesOfItem(atPath:file.path)
        expectEqual((attr[.posixPermissions] as? NSNumber)?.intValue,0o600)
    }
}
