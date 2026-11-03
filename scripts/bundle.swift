import Foundation
let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let binaries = URL(fileURLWithPath: CommandLine.arguments[1])
let build = root.appendingPathComponent("build/standalone")
func run(_ args: [String]) throws {
    let p=Process();p.executableURL=URL(fileURLWithPath:args[0]);p.arguments=Array(args.dropFirst());try p.run();p.waitUntilExit()
    if p.terminationStatus != 0 { throw NSError(domain:"Build",code:Int(p.terminationStatus)) }
}
func bundle(_ path: URL, executable: String, info: [String:Any]) throws {
    if fm.fileExists(atPath:path.path) { try fm.removeItem(at:path) }
    try fm.createDirectory(at:path.appendingPathComponent("Contents/MacOS"),withIntermediateDirectories:true)
    try fm.copyItem(at:binaries.appendingPathComponent(executable),to:path.appendingPathComponent("Contents/MacOS/"+executable))
    var plist: [String:Any] = ["CFBundleExecutable":executable,"CFBundlePackageType":"APPL","CFBundleVersion":"2","CFBundleShortVersionString":"2.0","LSUIElement":true,"LSMinimumSystemVersion":"13.0","NSHighResolutionCapable":true]
    plist.merge(info) { _,new in new }
    try PropertyListSerialization.data(fromPropertyList:plist,format:.xml,options:0).write(to:path.appendingPathComponent("Contents/Info.plist"))
}
try fm.createDirectory(at:build,withIntermediateDirectories:true)
let app=build.appendingPathComponent("Mac Modes.app")
try bundle(app,executable:"MacModes",info:["CFBundleName":"Mac Modes","CFBundleIdentifier":"local.mac-modes.menubar","CFBundleURLTypes":[["CFBundleURLName":"Mac Modes actions","CFBundleURLSchemes":["macmodes"]]]])
let resources=app.appendingPathComponent("Contents/Resources")
try fm.createDirectory(at:resources,withIntermediateDirectories:true)
try fm.copyItem(at:root.appendingPathComponent("config"),to:resources.appendingPathComponent("config"))
// Local machine overrides are installed separately, never included in the distributable.
try? fm.removeItem(at:resources.appendingPathComponent("config/local.json"))
try fm.copyItem(at:root.appendingPathComponent("README.md"),to:resources.appendingPathComponent("README.md"))
try fm.copyItem(at:binaries.appendingPathComponent("modectl"),to:app.appendingPathComponent("Contents/MacOS/modectl"))
try run(["/usr/bin/codesign","--force","--sign","-",app.path])
for action in ["normal","coding","music","private","ocr"] {
    let name=action=="ocr" ? "Copy Screen Text" : "Mode "+action.capitalized
    let launcher=build.appendingPathComponent("Logitech Launchers/"+name+".app")
    try bundle(launcher,executable:"ModeLauncher",info:["CFBundleName":name,"CFBundleIdentifier":"local.mac-modes.launcher."+action,"MacModesAction":action])
    try run(["/usr/bin/codesign","--force","--sign","-",launcher.path])
}
try run(["/usr/bin/ditto","-c","-k","--sequesterRsrc","--keepParent",build.path,root.appendingPathComponent("build/MacModes-standalone.zip").path])
print("Built \(app.path)")
