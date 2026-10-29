import AppKit
import PodcastCore
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, StatusMenuActions {
    private let preferences = Preferences()
    private let menu = NSMenu()
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private lazy var model = PodcastModel(
        source: PodcastLibrary(home: PodcastLibrary.realHome),
        preferences: preferences,
        scratch: FileManager.default.temporaryDirectory
    )
    private lazy var statusMenu = StatusMenu(model: model, actions: self)
    private lazy var window = PodcastWindowController { [unowned self] in
        PodcastView(
            model: model,
            export: { [unowned self] in exportNow() },
            chooseFolder: { [unowned self] in chooseFolder() },
            openPrivacySettings: { [unowned self] in openPrivacySettings() }
        )
    }

    /// How often to look for new plays. Looking is a few file dates unless something changed, and
    /// history doesn't need to be fresher than this.
    static let checkInterval: TimeInterval = 10 * 60

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        statusItem.menu = menu
        updateStatusItem()

        // Gives the keyboard back to the app you were using.
        window.onClose = { NSApp.hide(nil) }
        // Coming back from System Settings after turning on access, or from listening.
        window.onActivate = { [weak self] in self?.check() }

        check()
        let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // The first time, open at login like most menu bar utilities, and show the window so it's
        // clear what the app does and whether it needs Full Disk Access. Turn off login in the menu.
        if !preferences.launchedBefore {
            preferences.launchedBefore = true
            try? SMAppService.mainApp.register()
            openWindow(show: nil)
        }
    }

    /// Reads the library if it changed, then exports if that's turned on.
    private func check(force: Bool = false) {
        Task {
            let changed = await model.reload(force: force || model.status != .ready)
            if preferences.exportsAutomatically, model.folder != nil, changed || force {
                await model.export()
            }
            updateStatusItem()
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let attention = model.status == .problem(.noPermission) || model.exportProblem != nil || !model.failures.isEmpty
        button.image = StatusIcon.image(alert: attention)
        var tip = "Podcast Export"
        if model.status == .ready {
            tip += "\n\(Describe.count(model.following, "show")) followed, \(Describe.count(model.played, "episode")) played."
            if model.pending > 0 { tip += "\n\(Describe.count(model.pending, "new play")) to export." }
        } else if case .problem(let error) = model.status {
            tip += "\n" + Describe.problem(error)
        }
        button.toolTip = tip
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        statusMenu.build(into: menu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        check()
    }

    // MARK: StatusMenuActions

    func exportNow() {
        guard model.folder != nil else {
            chooseFolder()
            return
        }
        Task {
            await model.reload()
            await model.export()
            updateStatusItem()
        }
    }

    func chooseFolder() {
        // Changing folders partway through an export would leave it half in each.
        guard !model.isExporting else { return }
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.title = "Choose Where to Export Podcasts"
        panel.message = "Your subscriptions, a note for each show and your listening history are saved here. A folder in your Obsidian vault works well."
        panel.prompt = "Export Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.folder?.url ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let response = panel.runModal()
        if response == .OK, let url = panel.url {
            if model.source.protectedFolders.contains(where: { Exporter.isInside(url, $0) }) {
                refuseLibraryFolder()
            } else {
                Task {
                    await model.setFolder(url)
                    exportNow()
                }
            }
        }
        if !window.isVisible {
            NSApp.hide(nil)
        }
    }

    func saveOPML() {
        NSApp.activate()
        let panel = NSSavePanel()
        panel.title = "Save Subscriptions as OPML"
        panel.message = "Import this file into another podcast app to follow the same shows there."
        panel.nameFieldStringValue = "Podcasts.opml"
        panel.allowedContentTypes = [UTType(filenameExtension: "opml") ?? .xml]
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK, let url = panel.url {
            if model.source.protectedFolders.contains(where: { Exporter.isInside(url, $0) }) {
                refuseLibraryFolder()
            } else if let problem = model.saveOPML(to: url) {
                let alert = NSAlert()
                alert.messageText = "Couldn't save the OPML file"
                alert.informativeText = problem
                alert.runModal()
            }
        }
        if !window.isVisible {
            NSApp.hide(nil)
        }
    }

    private func refuseLibraryFolder() {
        let alert = NSAlert()
        alert.messageText = "Choose a folder outside Apple Podcasts"
        alert.informativeText = "Podcast Export never writes inside the Apple Podcasts library."
        alert.runModal()
    }

    func showFolder() {
        guard let url = model.folder?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openWindow(show: String?) {
        if let show { model.selection = show }
        window.show()
    }

    func openPrivacySettings() {
        // The one page the app ever opens: where you turn on Full Disk Access.
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    func toggleOpenAtLogin() {
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        } else {
            try? SMAppService.mainApp.register()
        }
    }

    func optionsChanged() {
        // New options can mean files to write that weren't before.
        check(force: preferences.exportsAutomatically)
    }

    func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(
                string: "Free and open source. No internet access.\ngithub.com/stanczykwyatt/podcast-export",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
            ),
        ])
    }
}
