import Foundation
import CoreFoundation
import Darwin
let fm=FileManager.default
let root=URL(fileURLWithPath:fm.currentDirectoryPath)
let home=fm.homeDirectoryForCurrentUser
let runtime=home.appendingPathComponent("Library/Application Support/MacModes")
let agents=home.appendingPathComponent("Library/LaunchAgents")
let app=home.appendingPathComponent("Applications/Mac Modes.app")
let backup=runtime.appendingPathComponent("backups/swift-migration-"+String(Int(Date().timeIntervalSince1970)))
func run(_ args:[String], check:Bool=true) throws {
    let p=Process();p.executableURL=URL(fileURLWithPath:args[0]);p.arguments=Array(args.dropFirst());try p.run();p.waitUntilExit()
    if check && p.terminationStatus != 0 { throw NSError(domain:args[0],code:Int(p.terminationStatus)) }
}
func json(_ path: URL) throws -> [String:Any] { try JSONSerialization.jsonObject(with:Data(contentsOf:path)) as! [String:Any] }
try fm.createDirectory(at:backup,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
let stateFile=runtime.appendingPathComponent("state.json")
if fm.fileExists(atPath:stateFile.path), try json(stateFile)["phase"] as? String == "starting" { fatalError("Wait for the current transition, then reinstall") }
// Keep both old agents and app for explicit rollback; do not modify network/apps.
for name in ["local.mac-modes.controller","local.mac-modes.menubar"] {
    try run(["/bin/launchctl","bootout","gui/\(getuid())/"+name],check:false)
    let plist=agents.appendingPathComponent(name+".plist")
    if fm.fileExists(atPath:plist.path) { try fm.moveItem(at:plist,to:backup.appendingPathComponent(name+".plist")) }
}
// Wait for the old controller's lock before touching its state or deployment.
let lockFD=open(runtime.appendingPathComponent("daemon.lock").path,O_CREAT|O_RDWR,0o600)
guard lockFD >= 0 else { fatalError("Cannot open controller lock") }
var acquired=false
for _ in 0..<100 { if flock(lockFD,LOCK_EX|LOCK_NB)==0 { acquired=true;break };Thread.sleep(forTimeInterval:0.1) }
guard acquired else { fatalError("Old controller is still running; deployment stopped") }
if fm.fileExists(atPath:stateFile.path) {
    try fm.copyItem(at:stateFile,to:backup.appendingPathComponent("state.json"))
    var state=try json(stateFile)
    // Focus/AirDrop stay as the user left them; the new controller no longer owns them.
    state["dnd_owned"]=false;state["airdrop_owned"]=false
    try JSONSerialization.data(withJSONObject:state,options:[.prettyPrinted,.sortedKeys]).write(to:stateFile,options:.atomic)
}
let legacyApp=runtime.appendingPathComponent("app")
if fm.fileExists(atPath:legacyApp.path) {
    try fm.moveItem(at:legacyApp,to:backup.appendingPathComponent("legacy-deployment"))
}
if fm.fileExists(atPath:app.path) { try fm.moveItem(at:app,to:backup.appendingPathComponent("Mac Modes.app")) }
try fm.createDirectory(at:app.deletingLastPathComponent(),withIntermediateDirectories:true)
try fm.copyItem(at:root.appendingPathComponent("build/standalone/Mac Modes.app"),to:app)
let overrides=root.appendingPathComponent("config/local.json")
if fm.fileExists(atPath:overrides.path) {
    let destination=runtime.appendingPathComponent("config.json")
    if !fm.fileExists(atPath:destination.path) { try fm.copyItem(at:overrides,to:destination) }
}
// Changing resources invalidates an ad-hoc bundle signature.
try run(["/usr/bin/codesign","--force","--sign","-",app.path])
let launchers=home.appendingPathComponent("Applications/Mac Modes Launchers")
if fm.fileExists(atPath:launchers.path) { try fm.moveItem(at:launchers,to:backup.appendingPathComponent("Logitech Launchers")) }
try fm.copyItem(at:root.appendingPathComponent("build/standalone/Logitech Launchers"),to:launchers)
// Preserve all unrelated Services bindings. Release only our four exact old bindings.
let key="NSServicesStatus" as CFString, domain="pbs" as CFString
if var services=CFPreferencesCopyAppValue(key,domain) as? [String:[String:Any]] {
    try PropertyListSerialization.data(fromPropertyList:services,format:.xml,options:0).write(to:backup.appendingPathComponent("NSServicesStatus.plist"))
    let bindings=["177564D5-174D-4AFD-8F8E-DC4BFC2A6707":"@^6","667C78D4-0A32-4A86-9484-73BF4C79D778":"@^7","76F03A68-5769-4A13-9203-BFD2B5A11E6A":"@^8","8CFCCFEA-B8F5-4FC3-A07A-3B8201282F06":"@^9"]
    for (id,equivalent) in bindings {
        let name="(null) - "+id+" - runShortcutAsService"
        if services[name]?["key_equivalent"] as? String == equivalent { services[name]?["key_equivalent"]="" }
    }
    CFPreferencesSetAppValue(key,services as CFPropertyList,domain)
    guard CFPreferencesAppSynchronize(domain) else { fatalError("Could not save migrated hotkeys") }
    try run(["/System/Library/CoreServices/pbs","-update"],check:false)
}
// Compatibility shim for old shell entry points; no Python is invoked.
let oldBin=runtime.appendingPathComponent("app/bin")
try fm.createDirectory(at:oldBin,withIntermediateDirectories:true)
let shim=oldBin.appendingPathComponent("modectl")
let shell="#!/bin/zsh\nexec \"$HOME/Applications/Mac Modes.app/Contents/MacOS/modectl\" \"$@\"\n"
try shell.write(to:shim,atomically:true,encoding:.utf8)
try fm.setAttributes([.posixPermissions:0o755],ofItemAtPath:shim.path)
try run(["/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister","-f",app.path])
try fm.createDirectory(at:agents,withIntermediateDirectories:true)
let agent=agents.appendingPathComponent("local.mac-modes.menubar.plist")
let payload:[String:Any]=["Label":"local.mac-modes.menubar","ProgramArguments":[app.appendingPathComponent("Contents/MacOS/MacModes").path],"RunAtLoad":true,"KeepAlive":true,"ThrottleInterval":10,"ProcessType":"Interactive","LimitLoadToSessionType":"Aqua","StandardOutPath":runtime.appendingPathComponent("controller.log").path,"StandardErrorPath":runtime.appendingPathComponent("controller-error.log").path]
try PropertyListSerialization.data(fromPropertyList:payload,format:.xml,options:0).write(to:agent)
try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:agent.path)
flock(lockFD,LOCK_UN);close(lockFD)
try run(["/bin/launchctl","bootstrap","gui/\(getuid())",agent.path])
print("Installed \(app.path). Previous state/agents saved in \(backup.path)")
