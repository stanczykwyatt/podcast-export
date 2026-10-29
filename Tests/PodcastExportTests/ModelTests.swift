import AppKit
import Foundation
import SQLite3
import Testing
@testable import PodcastCore
@testable import PodcastExport

@MainActor
@Suite("Model")
struct ModelTests {
    let folder = TestFolder()

    @Test func readsTheLibrary() async throws {
        let model = try await Gallery.model(in: folder)
        #expect(model.status == .ready)
        #expect(model.following == 6)
        #expect(model.played == 84)
        #expect(model.library.history.first?.title == "How memories stick")
        #expect(model.stats["SHOW-SYNAPSE"]?.played == 40)
        #expect(model.timeListened > 50 * 3600)
    }

    @Test func aMissingLibrary() async {
        let model = PodcastModel(source: PodcastLibrary(folder: folder.url.appendingPathComponent("nope")), preferences: testPreferences(), scratch: folder.sub("s"))
        await model.reload()
        #expect(model.status == .problem(.notFound))
    }

    @Test func noPermission() async throws {
        let library = folder.sub("Locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: library.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: library.path) }
        let model = PodcastModel(source: PodcastLibrary(folder: library), preferences: testPreferences(), scratch: folder.sub("s"))
        await model.reload()
        #expect(model.status == .problem(.noPermission))
    }

    @Test func readsAgainOnlyWhenTheLibraryChanges() async throws {
        let model = try await Gallery.model(in: folder)
        let source = model.source.folder
        let database = source.appendingPathComponent("MTLibrary.sqlite")
        // A whole second, since file dates set by hand lose their fractions.
        let date = Date(timeIntervalSince1970: 1_777_000_000)
        func settle() throws {
            for name in try FileManager.default.contentsOfDirectory(atPath: source.path) {
                try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: source.appendingPathComponent(name).path)
            }
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: source.path)
        }
        try settle()
        await model.reload(force: true)
        // Every episode deleted behind the model's back, keeping the dates it checks.
        var db: OpaquePointer?
        sqlite3_open(database.path, &db)
        sqlite3_exec(db, "DELETE FROM ZMTEPISODE", nil, nil, nil)
        sqlite3_close(db)
        try settle()
        #expect(await !model.reload())
        #expect(model.played == 84)
        // Once a date moves, it reads again.
        try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(60)], ofItemAtPath: database.path)
        #expect(await model.reload())
        #expect(model.played == 0)
    }

    @Test func exportsAndCountsWhatsNew() async throws {
        let model = try await Gallery.model(in: folder, exportTo: folder.sub("Vault/Podcasts"))
        #expect(model.pending == 84)
        var reported: ExportReport?
        model.onExport = { reported = $0 }
        let report = try #require(await model.export(now: Gallery.now))
        #expect(report.newPlays == 84 && report.newShows == 6)
        #expect(reported == report)
        #expect(model.pending == 0)
        #expect(model.lastExport?.summary == "Added 84 new plays, 6 new shows")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.url.appendingPathComponent("Vault/Podcasts/Shows").path)
        #expect(files.count == 7)
        #expect(await model.export(now: Gallery.now)?.written.isEmpty == true)
    }

    @Test func noExportWithoutAFolder() async throws {
        let model = try await Gallery.model(in: folder)
        #expect(await model.export() == nil)
        #expect(model.pending == 0)
    }

    @Test func reportsAFolderItCantUse() async throws {
        let target = folder.sub("Vault")
        try Data("broken".utf8).write(to: target.appendingPathComponent(".podcast-export.json"))
        let model = try await Gallery.model(in: folder, exportTo: target)
        #expect(model.exportProblem?.hasPrefix("The folder's .podcast-export.json can't be read") == true)
        #expect(await model.export() == nil)
        #expect(model.exportProblem != nil)
    }

    @Test func reportsFilesYouEdited() async throws {
        let target = folder.sub("Vault")
        let model = try await Gallery.model(in: folder, exportTo: target)
        _ = await model.export(now: Gallery.now)
        try Data("mine".utf8).write(to: target.appendingPathComponent("Podcasts.md"))
        model.preferences.writesJSON = true
        model.preferences.links = .markdown
        _ = await model.export(now: Gallery.now)
        #expect(model.kept == ["Podcasts.md"])
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("Listening History.json").path))
    }

    @Test func remembersTheFolder() async throws {
        let preferences = testPreferences()
        let target = folder.sub("Vault")
        let model = PodcastModel(source: PodcastLibrary(folder: folder.sub("Podcasts")), preferences: preferences, scratch: folder.sub("s"))
        await model.setFolder(target)
        #expect(model.folder?.url.standardizedFileURL.path == target.standardizedFileURL.path)
        let again = PodcastModel(source: PodcastLibrary(folder: folder.sub("Podcasts")), preferences: preferences, scratch: folder.sub("s"))
        #expect(again.folder?.url.standardizedFileURL.resolvingSymlinksInPath().path == target.resolvingSymlinksInPath().path)
    }

    @Test func savesOPMLAndCopiesFeeds() async throws {
        let model = try await Gallery.model(in: folder)
        let url = folder.url.appendingPathComponent("Subscriptions.opml")
        #expect(model.saveOPML(to: url, now: Gallery.now) == nil)
        let document = try XMLDocument(contentsOf: url)
        // Paper Moons has no public feed, so five of the six shows you follow.
        #expect(try document.nodes(forXPath: "/opml/body/outline").count == 5)
        #expect(model.saveOPML(to: model.source.folder.appendingPathComponent("x.opml")) == Describe.problem(ExportError.insideLibrary))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PodcastExportTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let synapse = try #require(model.library.show("SHOW-SYNAPSE"))
        #expect(model.copyFeed(synapse, to: pasteboard))
        #expect(pasteboard.string(forType: .string) == "https://feeds.example.com/synapse.xml")
        #expect(!model.copyFeed(try #require(model.library.show("SHOW-MOONS")), to: pasteboard))
    }

    @Test func twoReadsAtOnceBothFinish() async throws {
        let model = try await Gallery.model(in: folder)
        // As on first launch, when the window opening asks for a read while one is running.
        async let first = model.reload(force: true)
        async let second = model.reload(force: true)
        async let third = model.reload()
        let results = await [first, second, third]
        #expect(results.filter { $0 }.count >= 2)
        #expect(model.status == .ready && model.played == 84)
    }

    @Test func aPrivateFeedIsCopiedConcealed() async throws {
        let model = try await Gallery.model(in: folder)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PodcastExportTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        #expect(model.copyFeed(try #require(model.library.show("SHOW-LEDGER")), to: pasteboard))
        #expect(pasteboard.types?.contains(concealed) == true)
        #expect(pasteboard.string(forType: .string) == "https://members.example.net/feed?auth=madeup")
        #expect(model.copyFeed(try #require(model.library.show("SHOW-SYNAPSE")), to: pasteboard))
        #expect(pasteboard.types?.contains(concealed) == false)
    }

    @Test func forgetsASelectionThatsGone() async throws {
        let model = try await Gallery.model(in: folder)
        model.selection = "SHOW-GONE"
        await model.reload(force: true)
        #expect(model.selection == nil)
    }

    @Test func preferencesHaveSensibleDefaults() {
        let preferences = testPreferences()
        #expect(preferences.writesMarkdown && preferences.writesCSV && !preferences.writesJSON)
        #expect(preferences.links == .obsidian)
        #expect(!preferences.exportsAutomatically && !preferences.launchedBefore)
        #expect(preferences.lastExport == nil)
        preferences.writesCSV = false
        #expect(preferences.options == ExportOptions(markdown: true, csv: false, json: false))
    }
}
