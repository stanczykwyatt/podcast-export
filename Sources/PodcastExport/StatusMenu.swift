import AppKit
import PodcastCore
import ServiceManagement

/// What the menu's items do. The app delegate does them; tests record them.
@MainActor
protocol StatusMenuActions: AnyObject {
    func exportNow()
    func chooseFolder()
    func showFolder()
    func saveOPML()
    func openWindow(show: String?)
    func openPrivacySettings()
    func toggleOpenAtLogin()
    func optionsChanged()
    func showAbout()
}

/// Builds the menu bar menu fresh each time it opens.
@MainActor
final class StatusMenu: NSObject {
    private let model: PodcastModel
    private weak var actions: StatusMenuActions?
    var now: () -> Date = Date.init
    var opensAtLogin: () -> Bool = { SMAppService.mainApp.status == .enabled }
    var home = PodcastLibrary.realHome

    static let recentLimit = 8

    init(model: PodcastModel, actions: StatusMenuActions) {
        self.model = model
        self.actions = actions
    }

    func build(into menu: NSMenu) {
        menu.removeAllItems()
        switch model.status {
        case .loading:
            menu.addItem(disabled("Reading Apple Podcasts…"))
        case .problem(.noPermission):
            menu.addItem(disabled("Needs Full Disk Access"))
            menu.addItem(disabled("Turn on Podcast Export in Full Disk Access to read your library. It can still only read Apple Podcasts.", small: true))
            menu.addItem(item("Open Privacy & Security Settings…", #selector(openPrivacySettings)))
        case .problem(let error):
            menu.addItem(disabled("Can't read Apple Podcasts"))
            menu.addItem(disabled(Describe.problem(error), small: true))
        case .ready:
            let empty = model.following == 0 && model.played == 0
            menu.addItem(disabled(empty ? "No shows yet" : "\(Describe.count(model.following, "show")) · \(Describe.count(model.played, "episode")) played"))
            if let last = model.lastExport {
                menu.addItem(disabled("Last export \(Describe.relative(last.date, now: now())): \(last.summary.prefix(1).lowercased() + last.summary.dropFirst())", small: true))
            }
        }
        if let problem = model.exportProblem {
            menu.addItem(disabled(problem, small: true, warning: true))
        } else if !model.failures.isEmpty {
            let names = model.failures.prefix(3).map(\.file).joined(separator: ", ")
            menu.addItem(disabled("Couldn't write \(names)\(model.failures.count > 3 ? " and \(model.failures.count - 3) more" : ""). \(model.failures[0].reason)", small: true, warning: true))
        } else if model.keptOPML {
            menu.addItem(disabled("Apple Podcasts lists far fewer shows than last time, so the OPML file was kept. If you unfollowed them, delete it and export again.", small: true, warning: true))
        } else if !model.kept.isEmpty {
            let names = model.kept.prefix(2).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            menu.addItem(disabled("Left \(names)\(model.kept.count > 2 ? " and \(model.kept.count - 2) more" : "") as you edited \(model.kept.count == 1 ? "it" : "them").", small: true))
        }
        menu.addItem(.separator())

        let ready = model.status == .ready && !model.isExporting
        if model.folder == nil {
            let choose = item("Choose Export Folder…", #selector(chooseFolder), key: "e")
            choose.isEnabled = ready
            menu.addItem(choose)
        } else {
            let title = model.isExporting ? "Exporting…" : model.pending > 0 ? "Export \(Describe.count(model.pending, "New Play"))" : "Export Now"
            let export = item(title, #selector(exportNow), key: "e")
            export.isEnabled = ready
            menu.addItem(export)
            menu.addItem(folderItem())
        }
        let save = item("Save Subscriptions as OPML…", #selector(saveOPML), key: "s")
        save.isEnabled = model.status == .ready && model.following > 0
        save.toolTip = "Saves the shows you follow as one OPML file, to import into another podcast app."
        menu.addItem(save)
        menu.addItem(item("Open Podcast Export…", #selector(openWindow), key: "o"))
        menu.addItem(recentItem())

        menu.addItem(.separator())
        menu.addItem(optionsItem())
        let automatic = item("Export Automatically", #selector(toggleAutomatic))
        automatic.state = model.preferences.exportsAutomatically ? .on : .off
        automatic.toolTip = "Exports new plays and shows a few minutes after they appear, while Podcast Export is running."
        menu.addItem(automatic)
        let login = item("Open at Login", #selector(toggleOpenAtLogin))
        login.state = opensAtLogin() ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(item("About Podcast Export", #selector(showAbout)))
        let quit = NSMenuItem(title: "Quit Podcast Export", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    // MARK: Parts

    private func folderItem() -> NSMenuItem {
        let path = model.folder.map { Describe.path($0.url, home: home) } ?? ""
        let item = NSMenuItem(title: "Export Folder: \(path)", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        let submenu = NSMenu()
        submenu.addItem(self.item("Show in Finder", #selector(showFolder)))
        let change = self.item("Choose Another Folder…", #selector(chooseFolder))
        change.isEnabled = !model.isExporting
        submenu.addItem(change)
        item.submenu = submenu
        return item
    }

    private func recentItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Recently Played", action: nil, keyEquivalent: "")
        let recent = model.library.history.prefix(Self.recentLimit)
        item.isEnabled = !recent.isEmpty
        let submenu = NSMenu()
        submenu.addItem(disabled("Click to see the show", small: true))
        for episode in recent {
            let show = model.library.show(episode.showID)
            var detail = [show?.title ?? "Unknown show"]
            if let date = episode.lastPlayed { detail.append(Describe.relative(date, now: now())) }
            detail.append(Describe.status(episode).lowercased())
            let entry = twoLine(episode.title, detail.joined(separator: " · "), #selector(openShow(_:)))
            entry.representedObject = episode.showID
            entry.image = NSImage(systemSymbolName: episode.finished ? "checkmark.circle" : "circle.lefthalf.filled", accessibilityDescription: nil)
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    private func optionsItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Export Options", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let preferences = model.preferences
        submenu.addItem(disabled("Podcasts.opml is always written", small: true))
        let options: [(String, Bool, Selector, String)] = [
            ("Markdown Notes", preferences.writesMarkdown, #selector(toggleMarkdown), "Podcasts.md, with every show and your latest plays, and a note for each show."),
            ("Listening History (.csv)", preferences.writesCSV, #selector(toggleCSV), "Every episode you've played or saved, for spreadsheets."),
            ("Listening History (.json)", preferences.writesJSON, #selector(toggleJSON), "Every show and episode, for scripts and other apps."),
            ("Obsidian Links", preferences.links == .obsidian, #selector(toggleLinks), "On: [[Shows/Show|Show]], which Obsidian and Logseq follow. Off: a standard Markdown link."),
        ]
        for (title, on, action, tip) in options {
            let option = self.item(title, action)
            option.state = on ? .on : .off
            option.toolTip = tip
            submenu.addItem(option)
        }
        item.submenu = submenu
        return item
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func twoLine(_ title: String, _ detail: String, _ action: Selector) -> NSMenuItem {
        let item = self.item(title, action)
        let text = NSMutableAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
        text.append(NSAttributedString(string: "\n" + detail, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        item.attributedTitle = text
        return item
    }

    private func disabled(_ title: String, small: Bool = false, warning: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if small || warning {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            item.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: warning ? NSColor.systemOrange : NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ])
            if title.count > 44 { item.view = wrapping(item.attributedTitle!) }
        }
        return item
    }

    /// Long notes in the menu wrap instead of making it as wide as the screen.
    private func wrapping(_ text: NSAttributedString) -> NSView {
        let label = NSTextField(wrappingLabelWithString: "")
        label.attributedStringValue = text
        label.preferredMaxLayoutWidth = 270
        label.frame.size = label.fittingSize
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: label.frame.height + 6))
        label.frame.origin = NSPoint(x: 14, y: 3)
        view.addSubview(label)
        return view
    }

    // MARK: Actions

    @objc private func exportNow() { actions?.exportNow() }
    @objc private func chooseFolder() { actions?.chooseFolder() }
    @objc private func showFolder() { actions?.showFolder() }
    @objc private func saveOPML() { actions?.saveOPML() }
    @objc private func openWindow() { actions?.openWindow(show: nil) }
    @objc private func openShow(_ sender: NSMenuItem) { actions?.openWindow(show: sender.representedObject as? String) }
    @objc private func openPrivacySettings() { actions?.openPrivacySettings() }
    @objc private func toggleOpenAtLogin() { actions?.toggleOpenAtLogin() }
    @objc private func showAbout() { actions?.showAbout() }

    @objc private func toggleAutomatic() {
        model.preferences.exportsAutomatically.toggle()
        actions?.optionsChanged()
    }

    @objc private func toggleMarkdown() {
        model.preferences.writesMarkdown.toggle()
        actions?.optionsChanged()
    }

    @objc private func toggleCSV() {
        model.preferences.writesCSV.toggle()
        actions?.optionsChanged()
    }

    @objc private func toggleJSON() {
        model.preferences.writesJSON.toggle()
        actions?.optionsChanged()
    }

    @objc private func toggleLinks() {
        model.preferences.links = model.preferences.links == .obsidian ? .markdown : .obsidian
        actions?.optionsChanged()
    }
}
