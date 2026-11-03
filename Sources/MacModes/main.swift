import AppKit
import Foundation
import Darwin
import MacModesCore
import ApplicationServices

struct ModeState: Decodable {
    struct Feedback: Decodable {
        let id: String
        let kind: String
        let mode: String
        let message: String
    }
    let mode: String
    let requested_mode: String
    let phase: String
    let last_error: String?
    let last_warning: String?
    let feedback: Feedback?
}

final class ModeBar: NSObject, NSApplicationDelegate {
    let runtime: URL
    let controller: URL
    var status: NSStatusItem!
    let menu = NSMenu()
    let settingsMenu = NSMenu()
    let statusSeparator = NSMenuItem.separator()
    let summary = NSMenuItem(title: "Connecting…", action: nil, keyEquivalent: "")
    let detail = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let failureWarning = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let warning = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var modeItems: [String: NSMenuItem] = [:]
    var service: ControllerService?
    var hotkeys: Hotkeys?
    var ocrBusy = false
    var currentState: ModeState?
    var hideTimer: Timer?
    var panel: NSPanel?
    var lastFeedback: String?
    var lastProblem: String?
    var lastStatusIcon: String?
    var lastStatusLabel: String?
    var initialized = false
    let defaults = UserDefaults.standard
    let modes = ["normal", "coding", "music", "private"]

    init(runtime: URL, controller: URL) {
        self.runtime = runtime
        self.controller = controller
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu.addItem(summary)
        menu.addItem(detail)
        menu.addItem(failureWarning)
        menu.addItem(statusSeparator)
        for mode in modes {
            let item = NSMenuItem(title: mode.capitalized, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode
            menu.addItem(item)
            modeItems[mode] = item
        }
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.submenu = settingsMenu
        menu.addItem(settingsItem)
        settingsMenu.addItem(warning)
        let overlays = NSMenuItem(title: "Show switching overlays", action: #selector(toggleOverlays(_:)), keyEquivalent: "")
        overlays.target = self
        overlays.state = overlaysEnabled ? .on : .off
        settingsMenu.addItem(overlays)
        let permissions = NSMenuItem(title: "Allow window resizing…", action: #selector(windowPermission), keyEquivalent: "")
        permissions.target = self; settingsMenu.addItem(permissions)
        status.menu = menu
        do { try setupService() }
        catch { fputs("Mac Modes: \(error.localizedDescription)\n", stderr); NSApp.terminate(nil); return }

    }

    var overlaysEnabled: Bool { !defaults.bool(forKey: "hideOverlays") }

    func symbol(_ mode: String) -> String {
        switch mode {
        case "coding": return "chevron.left.forwardslash.chevron.right"
        case "music": return "music.note"
        case "private": return "lock.shield"
        default: return "circle"
        }
    }

    func setStatusIcon(_ name: String, label: String) {
        guard name != lastStatusIcon || label != lastStatusLabel else { return }
        lastStatusIcon = name
        lastStatusLabel = label
        let icon = NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        icon?.isTemplate = true
        status.button?.title = ""
        status.button?.image = icon
        status.button?.imagePosition = .imageOnly
        status.button?.toolTip = label
        status.button?.setAccessibilityLabel(label)
    }

    func refresh() {
        let connected = service != nil
        let state = currentState
        guard let state = state else {
            setStatusIcon("questionmark.circle", label: "Mac Modes: state unavailable")
            summary.title = "Mode state unavailable"
            summary.isHidden = false
            statusSeparator.isHidden = false
            detail.isHidden = true
            warning.isHidden = true
            failureWarning.isHidden = true
            modeItems.values.forEach { $0.isEnabled = false }
            return
        }
        let pending = state.feedback?.kind == "starting" && state.last_error == nil
        let switching = state.phase == "starting" || pending
        let problem = !connected ? "Controller offline" : state.last_error
        let label = problem ?? (switching ? "Switching modes" : state.mode.capitalized + " mode")
        let statusSymbol = !connected ? "circle.slash" : (state.phase == "failed" ? "exclamationmark.triangle" : (switching ? "arrow.triangle.2.circlepath" : symbol(state.mode)))
        setStatusIcon(statusSymbol, label: label)
        summary.isHidden = connected && !switching && problem == nil
        statusSeparator.isHidden = summary.isHidden
        summary.title = !connected ? "Controller offline" : (switching ? "Switching to \((state.feedback?.mode ?? state.requested_mode).capitalized)…" : "\(state.mode.capitalized) · \(state.phase)")
        detail.title = String((problem ?? "").prefix(65))
        detail.toolTip = problem
        detail.isHidden = problem == nil
        warning.title = String((state.last_warning ?? "").prefix(65))
        warning.toolTip = state.last_warning
        warning.isHidden = state.last_warning == nil || state.phase == "failed"
        failureWarning.title = warning.title
        failureWarning.toolTip = state.last_warning
        failureWarning.isHidden = state.last_warning == nil || state.phase != "failed"
        for (mode, item) in modeItems {
            item.state = state.mode == mode && state.phase == "active" ? .on : .off
            item.isEnabled = connected
        }
        if initialized {
            if let feedback = state.feedback, feedback.id != lastFeedback, connected {
                let title: String
                switch feedback.kind {
                case "starting": title = "Switching to \(feedback.mode.capitalized)…"
                case "cancelled": title = "Switch cancelled"
                case "failed": title = "Mode needs attention"
                default: title = "\(feedback.mode.capitalized) active"
                }
                showOverlay(title, detail: feedback.kind == "failed" ? feedback.message : (state.last_warning ?? ""), mode: feedback.mode, failed: feedback.kind == "failed")
            } else if let problem = problem, problem != lastProblem {
                showOverlay("Mode needs attention", detail: problem, mode: state.mode, failed: true)
            }
        }
        initialized = true
        lastFeedback = state.feedback?.id
        lastProblem = problem
    }

    func showOverlay(_ title: String, detail: String, mode: String, failed: Bool = false) {
        guard overlaysEnabled || failed else { return }
        hideTimer?.invalidate()
        panel?.orderOut(nil)
        let size = NSSize(width: 390, height: detail.isEmpty ? 90 : 124)
        let hud = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hud.isOpaque = false
        hud.backgroundColor = .clear
        hud.hasShadow = true
        hud.level = .floating
        hud.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hud.ignoresMouseEvents = true
        let glass = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 20
        glass.layer?.masksToBounds = true
        let icon = NSImageView(frame: NSRect(x: 22, y: (size.height - 34) / 2, width: 34, height: 34))
        icon.image = NSImage(systemSymbolName: failed ? "exclamationmark.triangle" : symbol(mode), accessibilityDescription: nil)
        icon.contentTintColor = failed ? .systemOrange : .controlAccentColor
        glass.addSubview(icon)
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 18, weight: .semibold)
        heading.frame = NSRect(x: 74, y: detail.isEmpty ? 33 : 77, width: 296, height: 25)
        glass.addSubview(heading)
        if !detail.isEmpty {
            let subtitle = NSTextField(wrappingLabelWithString: detail)
            subtitle.font = .systemFont(ofSize: 12)
            subtitle.textColor = .secondaryLabelColor
            subtitle.maximumNumberOfLines = 3
            subtitle.frame = NSRect(x: 74, y: 19, width: 294, height: 52)
            glass.addSubview(subtitle)
        }
        hud.contentView = glass
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            hud.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 64))
        }
        hud.orderFrontRegardless()
        panel = hud
        hideTimer = Timer(timeInterval: failed ? 5 : 2, repeats: false) { [weak self] _ in self?.panel?.orderOut(nil) }
        RunLoop.main.add(hideTimer!, forMode: .common)
    }

    @objc func selectMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        requestMode("set", mode)
    }

    @objc func toggleOverlays(_ sender: NSMenuItem) {
        defaults.set(overlaysEnabled, forKey: "hideOverlays")
        sender.state = overlaysEnabled ? .on : .off
        if !overlaysEnabled { panel?.orderOut(nil) }
    }

    @objc func windowPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            showOverlay("Accessibility enabled", detail: "Window layout is available.", mode: "normal")
        }
    }
}

let app = NSApplication.shared
let delegate = ModeBar(runtime: defaultRuntime, controller: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/modectl"))
app.delegate = delegate
app.run()
