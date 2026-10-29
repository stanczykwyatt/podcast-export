import AppKit
import Foundation
import Testing
@testable import PodcastCore
@testable import PodcastExport

@MainActor
final class RecordedActions: StatusMenuActions {
    var calls: [String] = []
    func exportNow() { calls.append("export") }
    func chooseFolder() { calls.append("choose") }
    func showFolder() { calls.append("show") }
    func saveOPML() { calls.append("opml") }
    func openWindow(show: String?) { calls.append("window:\(show ?? "-")") }
    func openPrivacySettings() { calls.append("privacy") }
    func toggleOpenAtLogin() { calls.append("login") }
    func optionsChanged() { calls.append("options") }
    func showAbout() { calls.append("about") }
}

/// The menu, built into an NSMenu that's never shown.
@MainActor
@Suite("Menu")
struct StatusMenuTests {
    let folder = TestFolder()
    let actions = RecordedActions()

    private func build(_ model: PodcastModel) -> NSMenu {
        let statusMenu = StatusMenu(model: model, actions: actions)
        statusMenu.now = { Gallery.now }
        statusMenu.opensAtLogin = { true }
        statusMenu.home = folder.url
        let menu = NSMenu()
        statusMenu.build(into: menu)
        // Keeps the builder alive for the menu's targets, as the app delegate does.
        objc_setAssociatedObject(menu, "builder", statusMenu, .OBJC_ASSOCIATION_RETAIN)
        return menu
    }

    private func titles(_ menu: NSMenu?) -> [String] {
        menu?.items.map { $0.isSeparatorItem ? "—" : ($0.attributedTitle?.string ?? $0.title) } ?? []
    }

    private func item(_ menu: NSMenu?, _ title: String) throws -> NSMenuItem {
        try #require(menu?.items.first { ($0.attributedTitle?.string ?? $0.title).components(separatedBy: "\n")[0] == title }, "No item titled \(title)")
    }

    private func click(_ item: NSMenuItem) {
        _ = (item.target as? NSObject)?.perform(item.action, with: item)
    }

    @Test func beforeChoosingAFolder() async throws {
        let menu = build(try await Gallery.model(in: folder))
        #expect(titles(menu).first == "6 shows · 84 episodes played")
        let choose = try item(menu, "Choose Export Folder…")
        #expect(choose.isEnabled)
        #expect(choose.keyEquivalent == "e")
        click(choose)
        #expect(actions.calls == ["choose"])
        #expect(!titles(menu).contains { $0.hasPrefix("Export Folder") })
    }

    @Test func withAFolder() async throws {
        let model = try await Gallery.model(in: folder, exportTo: folder.sub("Notes/Podcasts"))
        let menu = build(model)
        click(try item(menu, "Export 84 New Plays"))
        let folderItem = try item(menu, "Export Folder: ~/Notes/Podcasts")
        click(try item(folderItem.submenu, "Show in Finder"))
        click(try item(folderItem.submenu, "Choose Another Folder…"))
        let save = try item(menu, "Save Subscriptions as OPML…")
        #expect(save.isEnabled && save.keyEquivalent == "s")
        click(save)
        click(try item(menu, "Open Podcast Export…"))
        #expect(actions.calls == ["export", "show", "choose", "opml", "window:-"])
    }

    @Test func afterAnExport() async throws {
        let model = try await Gallery.model(in: folder, exportTo: folder.sub("Notes"))
        _ = await model.export(now: Gallery.now.addingTimeInterval(-300))
        let menu = build(model)
        #expect(titles(menu).contains("Last export 5 min ago: added 84 new plays, 6 new shows"))
        #expect(try item(menu, "Export Now").isEnabled)
    }

    @Test func afterAnExportThatKeptYourEdits() async throws {
        let target = folder.sub("Notes")
        let model = try await Gallery.model(in: folder, exportTo: target)
        _ = await model.export(now: Gallery.now)
        try Data("mine".utf8).write(to: target.appendingPathComponent("Podcasts.md"))
        model.preferences.links = .markdown
        _ = await model.export(now: Gallery.now)
        #expect(titles(build(model)).contains("Left Podcasts.md as you edited it."))
    }

    @Test func recentlyPlayed() async throws {
        let menu = build(try await Gallery.model(in: folder))
        let recent = try item(menu, "Recently Played")
        let entries = titles(recent.submenu)
        #expect(entries.count == StatusMenu.recentLimit + 1)
        #expect(entries[1] == "How memories stick\nSynapse After Dark · 2 hr ago · finished")
        #expect(entries[2] == "Bus 16, northbound\nThe Slow Commute · 12 hr ago · finished")
        #expect(entries.contains("Sleep and the hippocampus\nSynapse After Dark · yesterday · 45% played"))
        click(try #require(recent.submenu?.items[1]))
        #expect(actions.calls == ["window:SHOW-SYNAPSE"])
    }

    @Test func options() async throws {
        let model = try await Gallery.model(in: folder)
        let menu = build(model)
        let options = try item(menu, "Export Options")
        #expect(titles(options.submenu) == ["Podcasts.opml is always written", "Markdown Notes", "Listening History (.csv)", "Listening History (.json)", "Obsidian Links"])
        #expect(try item(options.submenu, "Markdown Notes").state == .on)
        #expect(try item(options.submenu, "Listening History (.json)").state == .off)
        click(try item(options.submenu, "Listening History (.json)"))
        click(try item(options.submenu, "Markdown Notes"))
        click(try item(options.submenu, "Listening History (.csv)"))
        click(try item(options.submenu, "Obsidian Links"))
        click(try item(menu, "Export Automatically"))
        #expect(model.preferences.writesJSON && !model.preferences.writesMarkdown && !model.preferences.writesCSV)
        #expect(model.preferences.links == .markdown && model.preferences.exportsAutomatically)
        #expect(actions.calls == Array(repeating: "options", count: 5))
        #expect(try item(build(model), "Export Automatically").state == .on)
    }

    @Test func theRest() async throws {
        let menu = build(try await Gallery.model(in: folder))
        #expect(try item(menu, "Open at Login").state == .on)
        click(try item(menu, "Open at Login"))
        click(try item(menu, "About Podcast Export"))
        #expect(actions.calls == ["login", "about"])
        let quit = try item(menu, "Quit Podcast Export")
        #expect(quit.action == #selector(NSApplication.terminate(_:)) && quit.keyEquivalent == "q")
    }

    @Test func whenAccessIsBlocked() async throws {
        let library = folder.sub("Locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: library.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: library.path) }
        let model = PodcastModel(source: PodcastLibrary(folder: library), preferences: testPreferences(), scratch: folder.sub("s"))
        await model.reload()
        let menu = build(model)
        #expect(titles(menu).first == "Needs Full Disk Access")
        click(try item(menu, "Open Privacy & Security Settings…"))
        #expect(actions.calls == ["privacy"])
        #expect(try !item(menu, "Choose Export Folder…").isEnabled)
        #expect(try !item(menu, "Save Subscriptions as OPML…").isEnabled)
    }

    @Test func whenThereIsNoLibrary() async throws {
        let model = PodcastModel(source: PodcastLibrary(folder: folder.url.appendingPathComponent("none")), preferences: testPreferences(), scratch: folder.sub("s"))
        await model.reload()
        let menu = build(model)
        #expect(Array(titles(menu).prefix(2)) == ["Can't read Apple Podcasts", Describe.problem(LibraryError.notFound)])
    }

    @Test func theIconHasBothStates() {
        let plain = StatusIcon.image(alert: false), alert = StatusIcon.image(alert: true)
        #expect(plain.isTemplate && alert.isTemplate)
        #expect(plain.accessibilityDescription == "Podcast Export")
        #expect(alert.accessibilityDescription == "Podcast Export, needs attention")
        #expect(plain.size == NSSize(width: 20, height: 18))
    }
}
