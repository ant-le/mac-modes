import Foundation
import Darwin

public enum Mode: String, CaseIterable { case normal, coding, music, `private` }
public struct Failure: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
public struct Cancelled: Error { public init() {} }
public typealias JSON = [String: Any]
public func readJSON(_ url: URL) throws -> JSON {
    guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? JSON else { throw Failure("Expected JSON object: \(url.lastPathComponent)") }
    return value
}
public func atomicJSON(_ object: JSON, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let temp = url.deletingLastPathComponent().appendingPathComponent(".write-" + UUID().uuidString)
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw Failure("Cannot write \(temp.path)") }
    defer { try? FileManager.default.removeItem(at: temp) }
    let fd = open(temp.path, O_RDONLY)
    guard fd >= 0 else { throw Failure("Cannot sync state") }
    let synced = fsync(fd); close(fd)
    guard synced == 0, rename(temp.path, url.path) == 0 else { throw Failure("Cannot persist \(url.lastPathComponent)") }
    let directory = open(url.deletingLastPathComponent().path, O_RDONLY)
    if directory >= 0 { _ = fsync(directory); close(directory) }
}
public var defaultRuntime: URL {
    URL(fileURLWithPath: ProcessInfo.processInfo.environment["MAC_MODES_RUNTIME"] ?? NSHomeDirectory() + "/Library/Application Support/MacModes", isDirectory: true)
}
public func readConfig(_ directory: URL) throws -> JSON {
    var result = try readJSON(directory.appendingPathComponent("default.json"))
    let local = directory.appendingPathComponent("local.json")
    if FileManager.default.fileExists(atPath: local.path) { result.merge(try readJSON(local)) { _, new in new } }
    let userConfig = defaultRuntime.appendingPathComponent("config.json")
    if FileManager.default.fileExists(atPath: userConfig.path) { result.merge(try readJSON(userConfig)) { _, new in new } }
    return result
}
public func enqueue(_ operation: String, _ mode: String, runtime: URL) throws -> URL {
    guard ["set", "toggle"].contains(operation), Mode(rawValue: mode) != nil else { throw Failure("Invalid mode request") }
    let id = String(format: "%020llu", UInt64(Date().timeIntervalSince1970 * 1_000_000_000)) + "-" + UUID().uuidString + ".json"
    try atomicJSON(["operation": operation, "mode": mode], to: runtime.appendingPathComponent("requests/" + id))
    return runtime.appendingPathComponent("results/" + id)
}
public final class RuntimeLock {
    private var fd: Int32 = -1
    public init(_ runtime: URL) throws {
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        fd = open(runtime.appendingPathComponent("daemon.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { if fd >= 0 { close(fd); fd = -1 }; throw Failure("Controller already running") }
    }
    deinit { if fd >= 0 { close(fd) } }
}
public func controllerOnline(_ runtime: URL) -> Bool {
    let fd = open(runtime.appendingPathComponent("daemon.lock").path, O_RDWR)
    guard fd >= 0 else { return false }; defer { close(fd) }
    if flock(fd, LOCK_EX | LOCK_NB) == 0 { flock(fd, LOCK_UN); return false }
    return errno == EWOULDBLOCK
}
public struct OwnedApp: Codable, Equatable {
    public let bundle: String
    public let pid: Int32
    public let launched_at: Double
    public init(bundle: String, pid: Int32, launchedAt: Double) { self.bundle = bundle; self.pid = pid; self.launched_at = launchedAt }
    public var json: JSON { ["bundle": bundle, "pid": pid, "launched_at": launched_at] }
    public init?(_ json: JSON) {
        guard let bundle = json["bundle"] as? String, let pid = json["pid"] as? NSNumber, let time = json["launched_at"] as? Double, time > 0 else { return nil }
        self.init(bundle: bundle, pid: pid.int32Value, launchedAt: time)
    }
}
