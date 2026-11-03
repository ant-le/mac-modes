import Foundation
import MacModesCore
import Darwin

let runtime = defaultRuntime
let args = Array(CommandLine.arguments.dropFirst())
func output(_ json: JSON) throws { print(String(data: try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!) }
do {
    switch args.first {
    case "set", "toggle":
        guard args.count >= 2 else { throw Failure("Expected mode") }
        let result = try enqueue(args[0], args[1], runtime: runtime)
        if args.contains("--wait") {
            let deadline = Date().addingTimeInterval(240)
            while Date() < deadline {
                if FileManager.default.fileExists(atPath: result.path) {
                    let state = try readJSON(result); try output(state)
                    exit(state["phase"] as? String == "active" && !(state["last_error"] is String) ? 0 : 1)
                }
                Thread.sleep(forTimeInterval: 0.25)
            }
            throw Failure("Request is still pending. Check the menu bar and any app dialog")
        }
        print("Requested \(args[0]) \(args[1])")
    case "status":
        var state = try (try? readJSON(runtime.appendingPathComponent("state.json"))) ?? baseline(boot: try bootID())
        state["controller_online"] = controllerOnline(runtime); try output(state)
    case "doctor":
        let directory = ProcessInfo.processInfo.environment["MAC_MODES_CONFIG_DIR"].map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/config")
        let platform = MacPlatform(config: try readConfig(directory), runtime: runtime)
        try output(["tailscale": platform.tailscaleState(), "orbstack_running": platform.orbRunning(), "proton_connected": platform.protonConnected(), "t3_running": platform.t3Running(), "controller": readJSON(runtime.appendingPathComponent("state.json"))])
    case "ocr":
        _ = try command(["/usr/bin/open", "macmodes://ocr"])
    default: throw Failure("Usage: modectl set|toggle MODE [--wait] | status | doctor | ocr")
    }
} catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
