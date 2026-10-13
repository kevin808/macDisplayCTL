import AppKit
import SwiftUI
import Carbon

enum ProjectionMode: String, CaseIterable, Identifiable {
    case internalOnly = "internal", extend, duplicate, externalOnly = "external"
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
    let connected: Bool?
    var available: Bool { enabled || connected != false }
    enum CodingKeys: String, CodingKey { case id, name, builtin, enabled, virtual, remembered, mirror, mirrorOf, uuid, connected }
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
        connected = (try? values.decode(Bool.self, forKey: .connected))
            ?? (try? values.decode(Int.self, forKey: .connected)).map { $0 != 0 }
    }
}

struct CommandResult {
    let code: Int32
    let output: String
}

func modeAvailable(_ mode: ProjectionMode, builtin: Display?, external: Display?) -> Bool {
    builtin != nil && (mode == .internalOnly || external?.available == true)
}

func projectionError(_ result: CommandResult, mode: ProjectionMode, externalAvailable: Bool) -> String? {
    guard result.code != 0 else { return nil }
    if mode != .internalOnly && !externalAvailable { return L10n.text("No external display detected") }
    if result.output.contains("CGError=1001") {
        return L10n.text("The display connection is changing. Wait a moment and try again.")
    }
    return result.output
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
    static func run(_ arguments: [String], executable: String = "macDisplayCtl") async -> CommandResult {
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
    @Published var errorMessage: String?
    private var guardRunning = false
    private var lastReadError: String?
    private var refreshing = false
    private var externalUUID: String?
    private var timer: Timer?

    var externals: [Display] { displays.filter { !$0.builtin && !$0.virtual } }
    var builtIn: Display? { displays.first { $0.builtin && !$0.virtual } }
    var target: Display? { externals.first { $0.id == externalID } }
    init() {
        Task {
            await refresh()
            if !CommandLine.arguments.contains("--render-preview") {
                await enableDefaultRecovery()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.busy else { return }
                await self.refresh()
            }
        }
    }

    func refresh() async {
        while refreshing {
            do { try await Task.sleep(nanoseconds: 25_000_000) }
            catch { return }
        }
        refreshing = true
        defer { refreshing = false; loading = false }
        let result = await Backend.run(["list", "--json"])
        guard result.code == 0,
              let data = result.output.data(using: .utf8),
              let rows = try? JSONDecoder().decode([Display].self, from: data) else {
            let error = result.output.isEmpty ? L10n.text("Unable to read displays. Reopen the panel to retry.") : result.output
            if error != lastReadError { errorMessage = error }
            lastReadError = error
            return
        }
        lastReadError = nil
        displays = rows
        let candidates = externals
        if let uuid = externalUUID, let matched = candidates.first(where: { $0.uuid == uuid && $0.available }) {
            externalID = matched.id
        } else if !candidates.contains(where: { $0.id == externalID && $0.available }) {
            externalID = candidates.first(where: { $0.enabled })?.id
                ?? candidates.first(where: { $0.available })?.id ?? candidates.first?.id ?? 0
        }
        externalUUID = target?.uuid
        updateSelectedMode()
    }

    func chooseExternal(_ id: UInt32) {
        externalID = id
        externalUUID = target?.uuid
        updateSelectedMode()
    }

    func updateSelectedMode() {
        selected = currentProjection(displays, externalID: externalID)
    }

    func canApply() -> Bool {
        !busy && !loading && lastReadError == nil && builtIn != nil
    }

    func apply(_ mode: ProjectionMode, completion: (() -> Void)? = nil) {
        guard canApply() else { return }
        busy = true
        Task {
            defer { busy = false; completion?() }
            // Hot-unplug can occur between the last refresh and the click.
            await refresh()
            guard lastReadError == nil else { return }
            guard modeAvailable(mode, builtin: builtIn, external: target) else {
                if mode != .internalOnly { errorMessage = L10n.text("No external display detected") }
                return
            }
            let id = externalID, uuid = target?.uuid
            var arguments = ["project", mode.rawValue]
            if mode != .internalOnly && id != 0 { arguments.append(String(id)) }
            let result = await Backend.run(arguments)
            await refresh()
            let requestedDisplay = externals.first { uuid != nil ? $0.uuid == uuid : $0.id == id }
            if let message = projectionError(result, mode: mode, externalAvailable: requestedDisplay?.available == true) {
                errorMessage = message
            }
        }
    }

    private func enableDefaultRecovery() async {
        let result = await Backend.run(["status"], executable: "macDisplayCtl-guard")
        guardRunning = result.output.contains("state = running")
        let installed = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/macDisplayCtl/macDisplayCtl")
        let bundled = Backend.resources.appendingPathComponent("macDisplayCtl")
        let helperChanged = (try? Data(contentsOf: installed)) != (try? Data(contentsOf: bundled))
        let defaults = UserDefaults.standard
        let initializedKey = "automaticRecoveryInitialized"
        if shouldStartRecovery(initialized: defaults.bool(forKey: initializedKey),
                               running: guardRunning, helperChanged: helperChanged) {
            let start = await Backend.run(["start"], executable: "macDisplayCtl-guard")
            guard start.code == 0 else { errorMessage = start.output; return }
            guardRunning = true
        }
        if guardRunning { defaults.set(true, forKey: initializedKey) }
    }
}

// Start on first launch, update a running helper, and retain later explicit CLI stops.
func shouldStartRecovery(initialized: Bool, running: Bool, helperChanged: Bool) -> Bool {
    (!initialized && !running) || (running && helperChanged)
}

// Original vector artwork: device silhouettes, matching tiles, and a shared desktop link.
struct ScreenPair: View {
    let mode: ProjectionMode
    var body: some View {
        Canvas { context, _ in
            let accent = Color(red: 0.12, green: 0.48, blue: 0.51)
            let laptop = CGRect(x: 3, y: 13, width: 22, height: 15)
            let monitor = CGRect(x: 37, y: 6, width: 23, height: 20)
            let firstActive = mode != .externalOnly
            let secondActive = mode != .internalOnly

            func stroke(_ points: [CGPoint], active: Bool) {
                var path = Path()
                path.addLines(points)
                context.stroke(path, with: .color(.primary.opacity(active ? 0.8 : 0.25)),
                               style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
            func screen(_ rect: CGRect, active: Bool) {
                let outline = Path(roundedRect: rect, cornerRadius: 2.5)
                if active { context.fill(outline, with: .color(accent.opacity(0.12))) }
                context.stroke(outline, with: .color(.primary.opacity(active ? 0.8 : 0.25)),
                               style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                if active {
                    let tile: CGRect
                    switch mode {
                    case .duplicate:
                        tile = CGRect(x: rect.midX - 4, y: rect.midY - 3, width: 8, height: 6)
                    case .extend:
                        let isLaptop = rect == laptop
                        tile = CGRect(x: isLaptop ? rect.maxX - 10 : rect.minX + 3,
                                      y: rect.midY - 3, width: 7, height: 6)
                    default:
                        tile = CGRect(x: rect.midX - 3, y: rect.midY - 3, width: 6, height: 6)
                    }
                    context.fill(Path(roundedRect: tile, cornerRadius: 1.2), with: .color(accent))
                }
            }
            screen(laptop, active: firstActive)
            screen(monitor, active: secondActive)
            // A tapered keyboard base distinguishes the Mac from the external monitor.
            stroke([CGPoint(x: 1, y: 31), CGPoint(x: 5, y: 33),
                    CGPoint(x: 23, y: 33), CGPoint(x: 27, y: 31)], active: firstActive)
            stroke([CGPoint(x: 48.5, y: 26), CGPoint(x: 48.5, y: 32)], active: secondActive)
            stroke([CGPoint(x: 43, y: 32), CGPoint(x: 54, y: 32)], active: secondActive)
            if mode == .duplicate {
                // Equal content on both displays.
                stroke([CGPoint(x: 29, y: 18), CGPoint(x: 33, y: 18)], active: true)
                stroke([CGPoint(x: 29, y: 22), CGPoint(x: 33, y: 22)], active: true)
            } else if mode == .extend {
                // One desktop continues between two distinct screens.
                stroke([CGPoint(x: 27, y: 20), CGPoint(x: 35, y: 20)], active: true)
                stroke([CGPoint(x: 29, y: 18), CGPoint(x: 27, y: 20), CGPoint(x: 29, y: 22)], active: true)
                stroke([CGPoint(x: 33, y: 18), CGPoint(x: 35, y: 20), CGPoint(x: 33, y: 22)], active: true)
            }
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
        .accessibilityHint(mode.detail)
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
    let onClose: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(L10n.text("Project")).font(.system(size: 25, weight: .medium))
                HStack(spacing: 4) {
                    Text("⌃⇧").font(.system(size: 13))
                    Text("P").font(.system(size: 14))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.3)))
                .help(L10n.text("Open the panel with Ctrl + Shift + P"))
                Spacer(minLength: 4)
                if model.busy { ProgressView().controlSize(.small) }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 22, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .background(.primary.opacity(0.08), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(L10n.text("Close panel"))
                .accessibilityLabel(L10n.text("Close panel"))
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 18)
            if model.externals.count > 1 {
                Picker(L10n.text("Second display"), selection: Binding(get: { model.externalID }, set: { model.chooseExternal($0) })) {
                    ForEach(model.externals) { display in
                        Text(display.name + (!display.available ? L10n.text(" (Disconnected)") : "")).tag(display.id)
                    }
                }
                .pickerStyle(.menu)
                .disabled(model.busy)
                .padding(.horizontal, 24).padding(.bottom, 12)
            }
            VStack(spacing: 7) {
                ForEach(Array(ProjectionMode.allCases.enumerated()), id: \.element.id) { index, mode in
                    ProjectionRow(mode: mode, selected: model.selected == mode,
                                  enabled: model.canApply()) { model.apply(mode) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [])
                }
            }
            .padding(.bottom, 18)
        }
        .frame(width: 414, height: model.externals.count > 1 ? 508 : 470)
        .background { AcrylicBackground() }
        .onExitCommand(perform: onClose)
        .alert(errorMessageTitle, isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button(L10n.text("OK"), role: .cancel) { model.errorMessage = nil }
        } message: {
            if model.errorMessage != L10n.text("No external display detected") {
                Text(model.errorMessage ?? "")
            }
        }
    }

    private var errorMessageTitle: String {
        model.errorMessage == L10n.text("No external display detected")
            ? L10n.text("No external display detected") : L10n.text("Unable to complete the operation")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let displayChanged: CGDisplayReconfigurationCallBack = { _, flags, context in
        guard !flags.contains(.beginConfigurationFlag), let context else { return }
        let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
        Task { @MainActor in await delegate.model.refresh() }
    }
    private var window: NSWindow!
    private var item: NSStatusItem!
    private var hotKeys: [EventHotKeyRef] = []
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
        CGDisplayRegisterReconfigurationCallback(Self.displayChanged, Unmanaged.passUnretained(self).toOpaque())
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 414, height: 470),
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
        window.contentView = NSHostingView(rootView: ProjectionPanel(model: model) { [weak self] in
            self?.hidePanel()
        })
        window.center()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: L10n.text("macDisplayCtl"))
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp])
        item.button?.toolTip = L10n.text("macDisplayCtl · ⌃⇧P")
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr, identifier.signature == 0x53435754 else {
                return OSStatus(eventNotHandledErr)
            }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            let id = identifier.id
            Task { @MainActor in
                if id == 1 { delegate.togglePanel() }
                else if (2...5).contains(id) {
                    delegate.applyMode(ProjectionMode.allCases[Int(id - 2)])
                }
            }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), nil)
        let keys = [kVK_ANSI_P, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4]
        for (index, key) in keys.enumerated() {
            var reference: EventHotKeyRef?
            let result = RegisterEventHotKey(UInt32(key), UInt32(controlKey | shiftKey),
                                            EventHotKeyID(signature: 0x53435754, id: UInt32(index + 1)),
                                            GetApplicationEventTarget(), 0, &reference)
            if result == noErr, let reference { hotKeys.append(reference) }
            else { NSLog("Unable to register shortcut %d: %d", index + 1, result) }
        }
        showPanel()
        if let index = CommandLine.arguments.firstIndex(of: "--render-preview"),
           CommandLine.arguments.indices.contains(index + 1) {
            let path = CommandLine.arguments[index + 1]
            Task {
                await model.refresh()
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
    func applicationWillTerminate(_ notification: Notification) {
        CGDisplayRemoveReconfigurationCallback(Self.displayChanged, Unmanaged.passUnretained(self).toOpaque())
        for reference in hotKeys { UnregisterEventHotKey(reference) }
    }
    func applicationDidResignActive(_ notification: Notification) { hidePanel() }
    func hidePanel() { window?.orderOut(nil) }
    @objc func statusItemClicked(_ sender: NSStatusBarButton) {
        guard NSApp.currentEvent?.modifierFlags.contains(.control) != true else { return }
        hidePanel()
        let menu = NSMenu()
        menu.autoenablesItems = false
        let show = NSMenuItem(title: L10n.text("Show Main Window"),
                              action: #selector(showMainWindow), keyEquivalent: "p")
        show.keyEquivalentModifierMask = [.control, .shift]
        show.target = self
        menu.addItem(show)
        menu.addItem(.separator())
        for (index, mode) in ProjectionMode.allCases.enumerated() {
            let entry = NSMenuItem(title: mode.title, action: #selector(selectMenuMode(_:)), keyEquivalent: String(index + 1))
            entry.keyEquivalentModifierMask = [.control, .shift]
            entry.target = self
            entry.representedObject = mode.rawValue
            entry.state = model.selected == mode ? .on : .off
            entry.isEnabled = model.canApply()
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L10n.text("Quit"),
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        item.menu = menu
        sender.performClick(nil)
        item.menu = nil
    }
    @objc private func showMainWindow() { showPanel() }
    @objc private func selectMenuMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = ProjectionMode(rawValue: raw) else { return }
        applyMode(mode)
    }
    private func applyMode(_ mode: ProjectionMode) {
        model.apply(mode) { [weak self] in
            guard let self, self.model.errorMessage != nil else { return }
            self.showPanel()
        }
    }
    @objc func togglePanel() {
        if window.isVisible && NSApp.isActive { hidePanel() }
        else { showPanel() }
    }
    func showPanel() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { await model.refresh() }
    }
}

@main
struct MacDisplayCtlApplication {
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
            let builtin = fixture(true, false)[0]
            func cachedExternal(_ connected: Any) -> Display {
                let row: [String: Any] = ["id": 2, "name": "External", "builtin": false,
                    "enabled": false, "remembered": true, "connected": connected]
                return try! JSONDecoder().decode(Display.self, from: JSONSerialization.data(withJSONObject: row))
            }
            let unplugged = cachedExternal(false), softDisabled = cachedExternal(true)
            for mode in ProjectionMode.allCases where mode != .internalOnly {
                precondition(!modeAvailable(mode, builtin: builtin, external: unplugged))
                precondition(!modeAvailable(mode, builtin: builtin, external: nil))
                precondition(modeAvailable(mode, builtin: builtin, external: softDisabled))
            }
            precondition(modeAvailable(.internalOnly, builtin: builtin, external: unplugged))
            precondition(!modeAvailable(.internalOnly, builtin: nil, external: softDisabled))
            precondition(cachedExternal(NSNull()).available)
            precondition(!cachedExternal(0).available && cachedExternal(1).available)
            let disconnectFailure = CommandResult(code: 1, output: "CGError=1001")
            for mode in ProjectionMode.allCases where mode != .internalOnly {
                precondition(projectionError(disconnectFailure, mode: mode, externalAvailable: false)
                    == L10n.text("No external display detected"))
            }
            precondition(projectionError(disconnectFailure, mode: .extend, externalAvailable: true)
                == L10n.text("The display connection is changing. Wait a moment and try again."))
            precondition(projectionError(disconnectFailure, mode: .internalOnly, externalAvailable: false) != nil)
            precondition(projectionError(CommandResult(code: 1, output: "Permission denied"), mode: .extend,
                externalAvailable: true) == "Permission denied")
            precondition(projectionError(CommandResult(code: 0, output: "Done"), mode: .extend,
                externalAvailable: true) == nil)
            let expectedTitles = L10n.language == "zh-Hans"
                ? ["仅电脑屏幕", "扩展", "复制", "仅第二屏幕"]
                : ["Built-in Only", "Extend", "Mirror", "External Only"]
            precondition(ProjectionMode.allCases.map(\.title) == expectedTitles)
            precondition(L10n.text("macDisplayCtl") == (L10n.language == "zh-Hans" ? "屏幕切换" : "macDisplayCtl"))
            precondition(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String == L10n.text("macDisplayCtl"))
            precondition(shouldStartRecovery(initialized: false, running: false, helperChanged: false))
            precondition(shouldStartRecovery(initialized: false, running: false, helperChanged: true))
            precondition(!shouldStartRecovery(initialized: false, running: true, helperChanged: false))
            precondition(shouldStartRecovery(initialized: true, running: true, helperChanged: true))
            precondition(!shouldStartRecovery(initialized: true, running: false, helperChanged: true))
            precondition(!shouldStartRecovery(initialized: true, running: true, helperChanged: false))
            precondition(L10n.text("No external display detected") == (L10n.language == "zh-Hans"
                ? "未发现外接显示器" : "No external display detected"))
            print("GUI state, missing display prompts, recovery startup policy, and localization checks passed (\(L10n.language)).")
            return
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}
