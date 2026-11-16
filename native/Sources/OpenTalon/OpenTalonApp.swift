import AppKit
import Darwin
import Sparkle
import SwiftUI

@main
enum OpenTalonApp {
    @MainActor static func main() {
        // Failed pipe writes are reported as service errors instead of terminating the GUI.
        signal(SIGPIPE, SIG_IGN)
        if CommandLine.arguments.contains("--daily-backup") { exit(runDailyBackup()) }
        if CommandLine.arguments.contains("--background"),
           !CommandLine.arguments.contains("--workspace-launch") {
            exit(launchBackgroundWorkspace())
        }
        let app = NSApplication.shared
        let delegate = AppController()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate, NSToolbarDelegate, SPUUpdaterDelegate {
    private let sidebarTool = NSToolbarItem.Identifier("Sidebar")
    private let titleTool = NSToolbarItem.Identifier("WorkspaceTitle")
    private let dashboardTool = NSToolbarItem.Identifier("Dashboard")
    private let searchTool = NSToolbarItem.Identifier("Search")
    private let settingsTool = NSToolbarItem.Identifier("Settings")
    private let background = CommandLine.arguments.contains("--background")
    private var window: NSWindow?
    private var lock: Int32 = -1
    private var quitting = false
    private var terminationSignal: DispatchSourceSignal?
    private var model: WorkspaceModel!
    private var updaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let profile = workspaceProfile()
        let useDefaults = profile.resolvingSymlinksInPath() == defaultWorkspaceProfile().resolvingSymlinksInPath()
        model = WorkspaceModel(profile: profile, useDefaults: useDefaults)
        model.service.onExit = { [weak self] in
            guard let self, self.background, self.window == nil else { return }
            NSApp.terminate(nil)
        }
        configureTerminationSignal()
        model.appearanceChanged = { [weak self] theme in
            self?.window?.appearance = Self.windowAppearance(theme)
        }
        NSApp.setActivationPolicy(background ? .accessory : .regular)
        model.retryWorkspace = { [weak self] in self?.openWorkspace(profile) }
        openWorkspace(profile)
        if background && lock < 0 {
            NSApp.terminate(nil)
            return
        }
        configureMenus()
        if !background { showWorkspace(nil) }
    }

    private func openWorkspace(_ profile: URL) {
        guard lock < 0 else { return }
        model.startupError = nil
        model.workspaceLocked = false
        do {
            lock = try acquireProfile(profile)
            try model.service.start(profile: profile, visible: !background || window?.isVisible == true)
        } catch let error as ServiceFailure where error.code == "PROFILE_OPEN" {
            model.workspaceLocked = true
        } catch {
            if lock >= 0 {
                close(lock)
                lock = -1
            }
            model.startupError = error.localizedDescription
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showWorkspace(nil)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitting || model == nil { return .terminateNow }
        guard permitClose() else { return .terminateCancel }
        guard model.service.ready else {
            model.service.stop()
            return .terminateNow
        }
        quitting = true
        model.service.onExit = { NSApp.reply(toApplicationShouldTerminate: true) }
        model.service.stop()
        return .terminateLater
    }

    private func configureTerminationSignal() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, self.model.service.ready else { exit(EXIT_SUCCESS) }
            self.model.service.onExit = { exit(EXIT_SUCCESS) }
            self.model.service.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { exit(EXIT_FAILURE) }
        }
        source.resume()
        terminationSignal = source
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { permitClose() }

    func windowWillClose(_ notification: Notification) { reportWindow(visible: false) }

    func windowDidBecomeKey(_ notification: Notification) { model.isWorkspaceWindowKey = true }

    func windowDidResignKey(_ notification: Notification) { model.isWorkspaceWindowKey = false }

    private func reportWindow(visible: Bool) {
        guard model.service.ready else { return }
        Task {
            let _: EmptyResponse? = try? await model.service.call("native_window_state", ["visible": visible])
        }
    }

    private func permitClose() -> Bool {
        guard model?.draftDirty == true else { return true }
        let alert = NSAlert()
        alert.messageText = "Your task has unsaved text"
        alert.informativeText = "Save or discard the task or comment draft before closing."
        alert.addButton(withTitle: "Keep editing")
        if let window, window.isVisible { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
        return false
    }

    private func startUpdaterIfConfigured() {
        guard updaterController == nil,
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        let updater = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil
        )
        updaterController = updater
        configureMenus()
        updater.startUpdater()
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock install: @escaping () -> Void) -> Bool {
        guard updateWouldInterruptWork else { return false }
        Task {
            while updateWouldInterruptWork {
                try? await Task.sleep(for: .seconds(1))
            }
            install()
        }
        return true
    }

    private var updateWouldInterruptWork: Bool {
        model.draftDirty || model.agentChat.busy || model.workspace?.agentRuns.contains(where: \.active) == true
    }

    @objc private func showWorkspace(_ sender: Any?) {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        startUpdaterIfConfigured()
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1480, height: 910),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "OpenTalon"
            window.titleVisibility = .hidden
            window.appearance = Self.windowAppearance(model.workspace?.theme ?? .system)
            window.toolbarStyle = .unified
            let toolbar = NSToolbar(identifier: "Workspace")
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            window.toolbar = toolbar
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentMinSize = NSSize(width: 980, height: 640)
            window.contentView = NSHostingView(rootView: WorkspaceView().environment(model))
            window.center()
            if !model.isolatedProfile {
                window.setFrameAutosaveName("OpenTalonWorkspace")
            }
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        reportWindow(visible: true)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func about(_ sender: Any?) {
        showWorkspace(sender)
        if model.sheet == nil { model.navigate(.about) }
    }

    @objc private func settings(_ sender: Any?) {
        showWorkspace(sender)
        if model.workspace != nil { model.sheet = .settings }
    }

    @objc private func newTask(_ sender: Any?) {
        showWorkspace(sender)
        if model.sheet == nil { model.newTask() }
    }

    @objc private func findTasks(_ sender: Any?) {
        showWorkspace(sender)
        if model.sheet == nil { model.findTasks() }
    }


    private static func windowAppearance(_ theme: Theme) -> NSAppearance? {
        switch theme {
        case .system: nil
        case .graphite: NSAppearance(named: .darkAqua)
        case .paper, .light: NSAppearance(named: .aqua)
        }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [sidebarTool, titleTool, dashboardTool, searchTool, settingsTool, .flexibleSpace]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [sidebarTool, titleTool, .flexibleSpace, dashboardTool, searchTool, settingsTool]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if identifier == titleTool {
            let title = NSTextField(labelWithString: "OpenTalon")
            title.font = .systemFont(ofSize: 13, weight: .semibold)
            title.textColor = .labelColor
            title.sizeToFit()
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = title
            item.visibilityPriority = .high
            return item
        }
        let spec: (label: String, symbol: String, action: Selector)
        switch identifier {
        case sidebarTool: spec = (sidebarActionTitle, "sidebar.left", #selector(toggleSidebar(_:)))
        case dashboardTool: spec = ("Dashboard", "square.grid.2x2", #selector(dashboard(_:)))
        case searchTool: spec = ("Find tasks", "magnifyingglass", #selector(findTasks(_:)))
        case settingsTool: spec = ("Settings", "gearshape", #selector(settings(_:)))
        default: return nil
        }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = spec.label
        item.paletteLabel = identifier == sidebarTool ? "Toggle Sidebar" : spec.label
        item.toolTip = spec.label
        item.image = NSImage(systemSymbolName: spec.symbol, accessibilityDescription: spec.label)
        item.target = self
        item.action = spec.action
        item.isBordered = true
        return item
    }

    private var sidebarActionTitle: String { model.showsSidebar ? "Hide Sidebar" : "Show Sidebar" }

    @objc private func toggleSidebar(_ sender: Any?) {
        model.showsSidebar.toggle()
        if let item = window?.toolbar?.items.first(where: { $0.itemIdentifier == sidebarTool }) {
            item.label = sidebarActionTitle
            item.toolTip = sidebarActionTitle
            item.image?.accessibilityDescription = sidebarActionTitle
        }
    }

    @objc private func dashboard(_ sender: Any?) {
        showWorkspace(sender)
        if model.sheet == nil { model.navigate(.dashboard) }
    }

    private func configureMenus() {
        let main = NSMenu()
        NSApp.mainMenu = main
        let app = menu("OpenTalon", in: main)
        add("About OpenTalon", #selector(about(_:)), "", to: app, target: self)
        if let updaterController {
            add("Check for Updates…", #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                "", to: app, target: updaterController)
        }
        add("Show OpenTalon", #selector(showWorkspace(_:)), "", to: app, target: self)
        app.addItem(.separator())
        add("Settings…", #selector(settings(_:)), ",", to: app, target: self)
        app.addItem(.separator())
        add("Hide OpenTalon", #selector(NSApplication.hide(_:)), "h", to: app)
        let hideOthers = add("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", to: app)
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        add("Show All", #selector(NSApplication.unhideAllApplications(_:)), "", to: app)
        app.addItem(.separator())
        add("Quit OpenTalon", #selector(NSApplication.terminate(_:)), "q", to: app)

        let file = menu("File", in: main)
        add("New task", #selector(newTask(_:)), "n", to: file, target: self)
        add("Find tasks", #selector(findTasks(_:)), "f", to: file, target: self)
        file.addItem(.separator())
        add("Close", #selector(NSWindow.performClose(_:)), "w", to: file)

        let edit = menu("Edit", in: main)
        add("Undo", Selector(("undo:")), "z", to: edit)
        let redo = add("Redo", Selector(("redo:")), "z", to: edit)
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        add("Cut", #selector(NSText.cut(_:)), "x", to: edit)
        add("Copy", #selector(NSText.copy(_:)), "c", to: edit)
        add("Paste", #selector(NSText.paste(_:)), "v", to: edit)
        add("Select All", #selector(NSText.selectAll(_:)), "a", to: edit)

        let view = menu("View", in: main)
        let sidebar = add("Toggle Sidebar", #selector(toggleSidebar(_:)), "s", to: view, target: self)
        sidebar.keyEquivalentModifierMask = [.command, .control]
        let fullscreen = add("Toggle Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", to: view)
        fullscreen.keyEquivalentModifierMask = [.command, .control]
        let window = menu("Window", in: main)
        NSApp.windowsMenu = window
        add("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", to: window)
        add("Zoom", #selector(NSWindow.performZoom(_:)), "", to: window)
        add("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), "", to: window)
    }

    private func menu(_ title: String, in parent: NSMenu) -> NSMenu {
        let item = NSMenuItem()
        let menu = NSMenu(title: title)
        item.submenu = menu
        parent.addItem(item)
        return menu
    }

    @discardableResult
    private func add(_ title: String, _ selector: Selector, _ key: String, to menu: NSMenu, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = target
        menu.addItem(item)
        return item
    }
}

private func workspaceProfile() -> URL {
    if let override = ProcessInfo.processInfo.environment["OPENTALON_PROFILE"] {
        return URL(fileURLWithPath: override, isDirectory: true)
    }
    return defaultWorkspaceProfile()
}

private func defaultWorkspaceProfile() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("OpenTalon Native", isDirectory: true)
}

private func launchBackgroundWorkspace() -> Int32 {
    // Launch through macOS so an MCP client's process context does not initialize AppKit.
    let launcher = Process()
    launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    launcher.arguments = [
        "-g", "-j", "-n", "-a", Bundle.main.bundleURL.path,
        "--env", "OPENTALON_PROFILE=\(workspaceProfile().path)",
        "--args", "--background", "--workspace-launch"
    ]
    do {
        try launcher.run()
        launcher.waitUntilExit()
        return launcher.terminationStatus
    } catch {
        return 1
    }
}

private func acquireProfile(_ profile: URL) throws -> Int32 {
    try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    let legacy = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("OpenTalon Prototype", isDirectory: true)
    guard profile.resolvingSymlinksInPath() != legacy.resolvingSymlinksInPath() else {
        throw ServiceFailure(code: "LEGACY_PROFILE", message: "Copy the Electron workspace from Settings instead of opening it directly.")
    }
    let file = profile.appendingPathComponent(".native-instance.lock")
    let descriptor = open(file.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
        throw ServiceFailure(code: "PROFILE_ACCESS", message: "Could not open the native data folder.")
    }
    while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
        let failure = errno
        if failure == EINTR { continue }
        close(descriptor)
        if failure == EWOULDBLOCK {
            throw ServiceFailure(code: "PROFILE_OPEN", message: "This native workspace is already open.")
        }
        throw ServiceFailure(code: "PROFILE_ACCESS", message: "Could not lock the native data folder.")
    }
    return descriptor
}

private func runDailyBackup() -> Int32 {
    let profile = workspaceProfile()
    guard FileManager.default.fileExists(atPath: profile.appendingPathComponent("opentalon.sqlite").path),
          let resources = Bundle.main.resourceURL else { return 0 }
    do {
        let lock = try acquireProfile(profile)
        defer { close(lock) }
        let process = Process()
        process.executableURL = resources.deletingLastPathComponent().appendingPathComponent("Helpers/node")
        process.arguments = [resources.appendingPathComponent("service/backup-once.cjs").path, profile.path]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "NODE_OPTIONS")
        environment.removeValue(forKey: "NODE_PATH")
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    } catch let error as ServiceFailure where error.code == "PROFILE_OPEN" {
        // The regular app is already responsible for daily snapshots.
        return 0
    } catch {
        return 1
    }
}
