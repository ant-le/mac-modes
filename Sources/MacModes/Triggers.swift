import AppKit
import Carbon
import MacModesCore

final class Hotkeys {
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    let action: (UInt32) -> Void
    init(action: @escaping (UInt32) -> Void) { self.action = action }
    func register() -> [UInt32] {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context = context, let event = event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            if status == noErr { Unmanaged<Hotkeys>.fromOpaque(context).takeUnretainedValue().action(id.id) }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        var conflicts: [UInt32] = []
        for (id, code) in [(UInt32(1), UInt32(kVK_ANSI_7)), (2, UInt32(kVK_ANSI_6)), (3, UInt32(kVK_ANSI_8)), (4, UInt32(kVK_ANSI_9))] {
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(code, UInt32(cmdKey | controlKey), EventHotKeyID(signature: 0x4D4D4F44, id: id), GetApplicationEventTarget(), 0, &ref)
            if result == noErr, let ref = ref { refs.append(ref) } else { conflicts.append(id) }
        }
        return conflicts
    }
    deinit { refs.forEach { UnregisterEventHotKey($0) }; if let handler = handler { RemoveEventHandler(handler) } }
}

extension ModeBar {
    func startOCR() {
        guard !ocrBusy else { return }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            showOverlay("Allow Screen Recording", detail: "Enable Mac Modes in System Settings → Privacy & Security, then retry OCR.", mode: "normal", failed: true); return
        }
        ocrBusy = true
        panel?.orderOut(nil)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            defer { DispatchQueue.main.async { self.ocrBusy = false } }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mac-modes-ocr-" + UUID().uuidString)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: folder) }
                let file = folder.appendingPathComponent("selection.png")
                let capture = try command(["/usr/sbin/screencapture", "-i", "-s", "-x", file.path], timeout: 120, check: false)
                guard capture.status == 0, FileManager.default.fileExists(atPath: file.path) else { return }
                guard let source = CGImageSourceCreateWithURL(file as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure("Could not read captured image") }
                let text = try recognizeText(in: image)
                DispatchQueue.main.async {
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.showOverlay("No text found", detail: "Clipboard unchanged.", mode: "normal")
                    } else {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        self.showOverlay("Text copied", detail: "Ready to paste.", mode: "normal")
                    }
                }
            } catch {
                DispatchQueue.main.async { self.showOverlay("OCR failed", detail: error.localizedDescription, mode: "normal", failed: true) }
            }
        }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == "macmodes" {
            if url.host == "ocr" { startOCR(); continue }
            guard let verb = url.host, ["toggle", "set"].contains(verb), let mode = url.pathComponents.last, Mode(rawValue: mode) != nil else { continue }
            requestMode(verb, mode, external: true)
        }
    }
    func requestMode(_ operation: String, _ mode: String, external: Bool = false) {
        do { _ = try enqueue(operation, mode, runtime: runtime, external: external) }
        catch { showOverlay("Request failed", detail: error.localizedDescription, mode: mode, failed: true) }
    }
    func setupService() throws {
        let directory = ProcessInfo.processInfo.environment["MAC_MODES_CONFIG_DIR"].map { URL(fileURLWithPath: $0) } ?? Bundle.main.resourceURL!.appendingPathComponent("config")
        let service = ControllerService(runtime: runtime, configDirectory: directory)
        service.stateChanged = { [weak self] value in
            guard let data = try? JSONSerialization.data(withJSONObject: value),
                  let state = try? JSONDecoder().decode(ModeState.self, from: data) else { return }
            DispatchQueue.main.async { self?.currentState = state; self?.refresh() }
        }
        service.confirmation = { message in
            var accepted = false
            DispatchQueue.main.sync {
                let alert = NSAlert()
                alert.messageText = "Mac Modes"
                alert.informativeText = message
                alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Continue")
                NSApp.activate(ignoringOtherApps: true)
                let timeout = Timer(timeInterval: 90, repeats: false) { _ in NSApp.abortModal() }
                RunLoop.main.add(timeout, forMode: .modalPanel)
                accepted = alert.runModal() == .alertSecondButtonReturn
                timeout.invalidate(); alert.window.orderOut(nil)
            }
            return accepted
        }
        service.notification = { [weak self] text, critical in
            DispatchQueue.main.async { self?.showOverlay("Mac Modes", detail: text, mode: "normal", failed: critical) }
        }
        try service.start(); self.service = service
        hotkeys = Hotkeys { [weak self] id in
            guard let self = self else { return }
            switch id {
            case 1: self.requestMode("toggle", "coding")
            case 2: self.requestMode("toggle", "music")
            case 3: self.requestMode("toggle", "private")
            case 4: self.startOCR()
            default: break
            }
        }
        let conflicts = hotkeys?.register() ?? []
        if !conflicts.isEmpty {
            let item = NSMenuItem(title: "Hotkey conflict", action: nil, keyEquivalent: "")
            item.toolTip = "Change the conflicting hotkey binding or use the launcher apps."
            menu.insertItem(item, at: 0)
        }
    }
    func applicationWillTerminate(_ notification: Notification) { service?.stop() }
}
