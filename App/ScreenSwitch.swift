import AppKit
import SwiftUI
import Carbon

enum ProjectionMode: String, CaseIterable, Identifiable {
    case internalOnly = "internal", duplicate, extend, externalOnly = "external"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .internalOnly: return L10n.text("Built-in Only")
        case .duplicate: return L10n.text("Mirror")
        case .extend: return L10n.text("Extend")
        case .externalOnly: return L10n.text("External Only")
        }
    }
    var detail: String {
        switch self {
        case .internalOnly: return L10n.text("Use only the built-in Mac display")
        case .duplicate: return L10n.text("Show the same content on both displays")
        case .extend: return L10n.text("Extend your desktop onto the second display")
        case .externalOnly: return L10n.text("Use only the selected external display")
        }
    }
}

struct Display: Decodable, Identifiable {
    let id: UInt32
    let name: String
    let builtin: Bool
    let enabled: Bool
    let virtual: Bool
    let remembered: Bool
    let mirror: Bool
    let mirrorOf: UInt32?
    let uuid: String?
    enum CodingKeys: String, CodingKey { case id, name, builtin, enabled, virtual, remembered, mirror, mirrorOf, uuid }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func flag(_ key: CodingKeys) -> Bool {
            (try? values.decode(Bool.self, forKey: key)) ?? ((try? values.decode(Int.self, forKey: key)) ?? 0 != 0)
        }
        id = try values.decode(UInt32.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        builtin = flag(.builtin); enabled = flag(.enabled); virtual = flag(.virtual)
        remembered = flag(.remembered); mirror = flag(.mirror)
        mirrorOf = try? values.decode(UInt32.self, forKey: .mirrorOf)
        uuid = try? values.decode(String.self, forKey: .uuid)
    }
}

struct CommandResult {
    let code: Int32
    let output: String
}

func currentProjection(_ displays: [Display], externalID: UInt32) -> ProjectionMode? {
    guard let internalDisplay = displays.first(where: { $0.builtin && !$0.virtual }) else { return nil }
    let enabledExternal = displays.filter { !$0.builtin && !$0.virtual && $0.enabled }
    let second = displays.first { $0.id == externalID && !$0.builtin && !$0.virtual }
    if internalDisplay.enabled && enabledExternal.isEmpty { return .internalOnly }
    if !internalDisplay.enabled && second?.enabled == true && enabledExternal.count == 1 { return .externalOnly }
    if internalDisplay.enabled, let second, second.enabled, enabledExternal.count == 1 {
        let paired = second.mirrorOf == internalDisplay.id || internalDisplay.mirrorOf == second.id
        return paired ? .duplicate : (!second.mirror && !internalDisplay.mirror ? .extend : nil)
    }
    return nil
}

enum Backend {
    static var resources: URL { Bundle.main.resourceURL! }
    static func run(_ arguments: [String], executable: String = "displayctl") async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = resources.appendingPathComponent(executable)
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["MACDISPLAYCTL_LANGUAGE"] = L10n.language
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return CommandResult(code: process.terminationStatus,
                                     output: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            } catch { return CommandResult(code: -1, output: error.localizedDescription) }
        }.value
    }
}

@MainActor
final class ScreenModel: ObservableObject {
    @Published var displays: [Display] = []
    @Published var externalID: UInt32 = 0
    @Published var selected: ProjectionMode?
    @Published var busy = false
    @Published var loading = true
    @Published var guardRunning = false
    @Published var guardBusy = false
    @Published var message = L10n.text("Reading displays…")
    @Published var hasError = false
    private var refreshing = false
    private var persistentMessage = false
    private var externalUUID: String?
    private var timer: Timer?

    var externals: [Display] { displays.filter { !$0.builtin && !$0.virtual } }
    var builtIn: Display? { displays.first { $0.builtin && !$0.virtual } }
    var target: Display? { externals.first { $0.id == externalID } }
    var connectedText: String {
        let live = displays.filter { $0.enabled && !$0.virtual }
        return live.isEmpty ? L10n.text("No usable displays detected") : live.map(\.name).joined(separator: " · ")
    }
    init() {
        Task {
            await refresh(); await updateGuardStatus()
            // Update the existing monitor to the bundled helper so projection uses
            // the same lock as the monitor. Do not enable a deliberately stopped guard.
            if guardRunning && !CommandLine.arguments.contains("--render-preview") {
                let installed = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support/displayctl/displayctl")
                let bundled = Backend.resources.appendingPathComponent("displayctl")
                if (try? Data(contentsOf: installed)) != (try? Data(contentsOf: bundled)) {
                    let result = await Backend.run(["start"], executable: "guardctl")
                    if result.code != 0 { hasError = true; persistentMessage = true; message = result.output }
                    await updateGuardStatus()
                }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.busy else { return }
                await self.refresh()
            }
        }
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false; loading = false }
        let result = await Backend.run(["list", "--json"])
        guard result.code == 0,
              let data = result.output.data(using: .utf8),
              let rows = try? JSONDecoder().decode([Display].self, from: data) else {
            hasError = true
            message = result.output.isEmpty ? L10n.text("Unable to read displays. Click Refresh to retry.") : result.output
            return
        }
        displays = rows
        let candidates = externals
        if let uuid = externalUUID, let matched = candidates.first(where: { $0.uuid == uuid && !$0.remembered }) {
            externalID = matched.id
        } else if !candidates.contains(where: { $0.id == externalID }) {
            externalID = candidates.first(where: { $0.enabled })?.id
                ?? candidates.first(where: { !$0.remembered })?.id ?? candidates.first?.id ?? 0
        }
        externalUUID = target?.uuid
        updateSelectedMode()
        if !persistentMessage {
            hasError = false
            message = connectedText
        }
    }

    func chooseExternal(_ id: UInt32) {
        externalID = id
        externalUUID = target?.uuid
        updateSelectedMode()
    }

    func updateSelectedMode() {
        selected = currentProjection(displays, externalID: externalID)
    }

    func canApply(_ mode: ProjectionMode) -> Bool {
        !busy && !loading && builtIn != nil && (mode == .internalOnly || target != nil)
    }

    func apply(_ mode: ProjectionMode) {
        guard canApply(mode) else { return }
        busy = true
        hasError = false
        persistentMessage = true
        message = L10n.format("Switching to %@…", mode.title)
        let id = externalID
        Task {
            var arguments = ["project", mode.rawValue]
            if mode != .internalOnly && id != 0 { arguments.append(String(id)) }
            let result = await Backend.run(arguments)
            busy = false
            hasError = result.code != 0
            message = result.code == 0 ? L10n.format("Switched to %@", mode.title) : result.output
            await refresh()
            if result.code == 0 {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if !busy { persistentMessage = false; message = connectedText }
            }
        }
    }

    func updateGuardStatus() async {
        let result = await Backend.run(["status"], executable: "guardctl")
        guardRunning = result.output.contains("state = running")
    }

    func toggleGuard() {
        guard !guardBusy && !busy else { return }
        guardBusy = true
        Task {
            let result = await Backend.run([guardRunning ? "stop" : "start"], executable: "guardctl")
            if result.code != 0 { hasError = true; persistentMessage = true; message = result.output }
            await updateGuardStatus()
            guardBusy = false
        }
    }
}

struct ScreenPair: View {
    let mode: ProjectionMode
    var body: some View {
        Canvas { context, size in
            let firstActive = mode != .externalOnly
            let secondActive = mode != .internalOnly
            func drawScreen(_ rect: CGRect, laptop: Bool, active: Bool, opposite: Bool) {
                let color = Color.primary.opacity(active ? 0.84 : 0.32)
                context.stroke(Path(roundedRect: rect, cornerRadius: 3.5), with: .color(color), lineWidth: 1.65)
                if active {
                    var arc = Path()
                    if opposite {
                        arc.move(to: CGPoint(x: rect.minX + 2, y: rect.minY + 2))
                        arc.addQuadCurve(to: CGPoint(x: rect.maxX - 2, y: rect.maxY - 2),
                                         control: CGPoint(x: rect.maxX - 1, y: rect.minY + 2))
                        arc.addLine(to: CGPoint(x: rect.minX + 2, y: rect.maxY - 2))
                    } else {
                        arc.move(to: CGPoint(x: rect.maxX - 2, y: rect.minY + 3))
                        arc.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.maxY - 2),
                                         control: CGPoint(x: rect.midX, y: rect.minY + 4))
                        arc.addLine(to: CGPoint(x: rect.maxX - 2, y: rect.maxY - 2))
                    }
                    context.stroke(arc, with: .color(color), lineWidth: 1.3)
                }
                if laptop {
                    var base = Path()
                    base.move(to: CGPoint(x: rect.minX - 2, y: rect.maxY + 4))
                    base.addLine(to: CGPoint(x: rect.maxX + 2, y: rect.maxY + 4))
                    context.stroke(base, with: .color(color), lineWidth: 1.65)
                }
            }
            drawScreen(CGRect(x: 2, y: 11, width: 23, height: 15), laptop: true, active: firstActive, opposite: false)
            drawScreen(CGRect(x: 33, y: 6, width: 26, height: 21), laptop: false, active: secondActive, opposite: mode == .extend)
        }
        .frame(width: 62, height: 38)
        .accessibilityHidden(true)
    }
}

struct ProjectionRow: View {
    let mode: ProjectionMode
    let selected: Bool
    let enabled: Bool
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 19) {
                ScreenPair(mode: mode)
                Text(mode.title).font(.system(size: 23, weight: .regular))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .frame(height: 88)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Color.primary.opacity(0.065) : hovered ? Color.primary.opacity(0.035) : .clear)
            }
            .overlay(alignment: .leading) {
                if selected { Capsule().fill(Color(red: 0.12, green: 0.43, blue: 0.47)).frame(width: 3, height: 30) }
            }
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovered = $0 }
        .help(mode.detail)
        .accessibilityLabel(mode.title)
        .accessibilityValue(selected ? L10n.text("Current mode") : L10n.text("Not selected"))
    }
}

struct AcrylicBackground: View {
    @Environment(\.colorScheme) var scheme
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            LinearGradient(colors: [Color.white.opacity(scheme == .dark ? 0.02 : 0.38),
                                    Color(red: 0.98, green: 0.88, blue: 0.73).opacity(0.22),
                                    Color(red: 0.79, green: 0.88, blue: 0.62).opacity(0.24),
                                    Color(red: 0.63, green: 0.89, blue: 0.93).opacity(0.27)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }.ignoresSafeArea()
    }
}

struct ProjectionPanel: View {
    @ObservedObject var model: ScreenModel
    private var recoveryHelp: String {
        L10n.text("When enabled, if no screen remains usable after unplugging external displays, the built-in screen turns on while the laptop lid is open. Reconnecting an external display restores the built-in screen's previous on/off state. Runs at login and continues after you quit the app.")
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 15) {
                Button { NSApp.keyWindow?.orderOut(nil) } label: {
                    Image(systemName: "arrow.left").font(.system(size: 20, weight: .regular))
                        .frame(width: 24, height: 28)
                }.buttonStyle(.plain).help(L10n.text("Hide panel"))
                Text(L10n.text("Project")).font(.system(size: 25, weight: .medium))
                HStack(spacing: 4) {
                    Text("⌃⌥").font(.system(size: 13))
                    Text("P").font(.system(size: 14))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.3)))
                .help(L10n.text("Open the panel with Control + Option + P"))
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                else {
                    Button { Task { await model.refresh(); await model.updateGuardStatus() } } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 15)).foregroundStyle(.secondary)
                    }.buttonStyle(.plain).help(L10n.text("Refresh display status"))
                }
            }
            .padding(.horizontal, 24).padding(.top, 25).padding(.bottom, 23)
            VStack(spacing: 7) {
                ForEach(Array(ProjectionMode.allCases.enumerated()), id: \.element.id) { index, mode in
                    ProjectionRow(mode: mode, selected: model.selected == mode,
                                  enabled: model.canApply(mode)) { model.apply(mode) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [])
                }
            }
            Spacer(minLength: 14)
            VStack(alignment: .leading, spacing: 13) {
                if model.externals.count > 1 {
                    HStack {
                        Text(L10n.text("Second display")).font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        Picker(L10n.text("Second display"), selection: Binding(get: { model.externalID }, set: { model.chooseExternal($0) })) {
                            ForEach(model.externals) { display in
                                Text(display.name + (display.remembered ? L10n.text(" (Disconnected)") : "")).tag(display.id)
                            }
                        }.labelsHidden().pickerStyle(.menu).fixedSize()
                        .disabled(model.busy)
                    }
                }
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: model.hasError ? "exclamationmark.circle" : "display")
                        .foregroundStyle(model.hasError ? Color.orange : Color.secondary)
                    Text(model.message).lineLimit(3).textSelection(.enabled)
                        .foregroundStyle(model.hasError ? Color.primary : Color.secondary)
                }.font(.system(size: 11.5)).frame(minHeight: 28, alignment: .topLeading)
                Divider().opacity(0.45)
                HStack {
                    Image(systemName: "laptopcomputer")
                        .foregroundStyle(model.guardRunning ? Color(red: 0.12, green: 0.43, blue: 0.47) : .secondary)
                    Text(L10n.text("Turn on built-in screen when unplugged"))
                        .font(.system(size: 11))
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .help(recoveryHelp)
                        .accessibilityLabel(L10n.text("About automatic screen recovery"))
                        .accessibilityValue(recoveryHelp)
                    Spacer(minLength: 2)
                    if model.guardBusy { ProgressView().controlSize(.mini) }
                    else {
                        Toggle(L10n.text("Turn on built-in screen when unplugged"),
                               isOn: Binding(get: { model.guardRunning }, set: { _ in model.toggleGuard() }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                            .disabled(model.busy)
                    }
                }
            }.padding(.horizontal, 24).padding(.bottom, 21)
        }
        .frame(width: 414, height: 610)
        .background { AcrylicBackground() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var item: NSStatusItem!
    private var hotKey: EventHotKeyRef?
    private var model: ScreenModel!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appMenu = NSMenuItem()
        let sub = NSMenu()
        sub.addItem(withTitle: L10n.text("About macDisplayCtl"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        sub.addItem(.separator())
        sub.addItem(withTitle: L10n.text("Quit macDisplayCtl"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.submenu = sub
        menu.addItem(appMenu)
        let edit = NSMenuItem(title: L10n.text("Edit"), action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: L10n.text("Edit"))
        editMenu.addItem(withTitle: L10n.text("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.submenu = editMenu; menu.addItem(edit)
        NSApp.mainMenu = menu
        model = ScreenModel()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 414, height: 610),
                          styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = L10n.text("macDisplayCtl")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.contentView = NSHostingView(rootView: ProjectionPanel(model: model))
        window.center()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: L10n.text("macDisplayCtl"))
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        item.button?.toolTip = L10n.text("macDisplayCtl · ⌃⌥P")
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in delegate.togglePanel() }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), nil)
        RegisterEventHotKey(UInt32(kVK_ANSI_P), UInt32(controlKey | optionKey),
                           EventHotKeyID(signature: 0x53435754, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        showPanel()
        if let index = CommandLine.arguments.firstIndex(of: "--render-preview"),
           CommandLine.arguments.indices.contains(index + 1) {
            let path = CommandLine.arguments[index + 1]
            Task {
                await model.refresh(); await model.updateGuardStatus()
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard let view = window.contentView else { NSApp.terminate(nil); return }
                view.layoutSubtreeIfNeeded()
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    if let png = bitmap.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: path))
                    }
                }
                print("Rendered \(Int(view.bounds.width))×\(Int(view.bounds.height)); selected=\(model.selected?.rawValue ?? "custom"); displays=\(model.displays.count)")
                NSApp.terminate(nil)
            }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel(); return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    @objc func togglePanel() {
        if window.isVisible && NSApp.isActive { window.orderOut(nil) }
        else { showPanel() }
    }
    func showPanel() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { await model.refresh(); await model.updateGuardStatus() }
    }
}

@main
struct ScreenSwitchApplication {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--self-test") {
            func fixture(_ internalOn: Bool, _ externalOn: Bool, mirror: Bool = false,
                         extra: Bool = false, virtual: Bool = false) -> [Display] {
                var rows: [[String: Any]] = [
                    ["id": 1, "name": "Built-in", "builtin": true, "enabled": internalOn ? 1 : 0,
                     "virtual": 0, "remembered": false, "mirror": mirror, "mirrorOf": 0],
                    ["id": 2, "name": "External", "builtin": false, "enabled": externalOn ? 1 : 0,
                     "virtual": 0, "remembered": false, "mirror": mirror, "mirrorOf": mirror ? 1 : 0]
                ]
                if extra {
                    rows.append(["id": 3, "name": "Third display", "builtin": false, "enabled": true,
                                 "virtual": virtual, "remembered": false, "mirror": false])
                }
                return try! JSONDecoder().decode([Display].self, from: JSONSerialization.data(withJSONObject: rows))
            }
            precondition(currentProjection(fixture(true, false), externalID: 2) == .internalOnly)
            precondition(currentProjection(fixture(false, true), externalID: 2) == .externalOnly)
            precondition(currentProjection(fixture(true, true), externalID: 2) == .extend)
            precondition(currentProjection(fixture(true, true, mirror: true), externalID: 2) == .duplicate)
            precondition(currentProjection(fixture(false, false), externalID: 2) == nil)
            precondition(currentProjection(fixture(true, true, extra: true), externalID: 2) == nil)
            precondition(currentProjection(fixture(true, true, extra: true, virtual: true), externalID: 2) == .extend)
            precondition(currentProjection(fixture(false, true), externalID: 999) == nil)
            let expectedTitles = L10n.language == "zh-Hans"
                ? ["仅电脑屏幕", "复制", "扩展", "仅第二屏幕"]
                : ["Built-in Only", "Mirror", "Extend", "External Only"]
            precondition(ProjectionMode.allCases.map(\.title) == expectedTitles)
            precondition(L10n.text("macDisplayCtl") == (L10n.language == "zh-Hans" ? "屏幕切换" : "macDisplayCtl"))
            precondition(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String == L10n.text("macDisplayCtl"))
            print("GUI state and localization checks passed (\(L10n.language)).")
            return
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
    }
}
