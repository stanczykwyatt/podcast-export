import Foundation
import Testing
@testable import PodcastCore

@Suite("Exporting")
struct ExporterTests {
    let folder = Fixtures.Folder()
    var destination: URL { folder.url.appendingPathComponent("Vault/Podcasts", isDirectory: true) }

    private func exporter(_ options: ExportOptions = ExportOptions(renderer: Fixtures.renderer)) -> Exporter {
        Exporter(destination: destination, options: options)
    }

    private var library: Library {
        Library(
            shows: [
                Fixtures.show(),
                Fixtures.show("S2", title: "Lantern & Ledger", feed: "https://members.example.net/feed?auth=s3cr3t"),
                Fixtures.show("S3", title: "Apple-only show", feed: nil),
            ],
            episodes: [
                Fixtures.episode("E1", hoursAgo: 2),
                Fixtures.episode("E2", show: "S2", title: "Members only", hoursAgo: 30, duration: 3600, position: 900, finished: false),
            ]
        )
    }

    private func files(_ sub: String = "") throws -> [String] {
        // The lock file is always there once an export has run, and never holds anything.
        try FileManager.default.contentsOfDirectory(atPath: destination.appendingPathComponent(sub).path).filter { $0 != ".podcast-export.lock" }.sorted()
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: destination.appendingPathComponent(path), encoding: .utf8)
    }

    private func write(_ text: String, to path: String) throws {
        try Data(text.utf8).write(to: destination.appendingPathComponent(path))
    }

    @Test func exportsEverything() throws {
        let report = try exporter().export(library, now: Fixtures.date)
        #expect(report.newPlays == 2 && report.newShows == 3)
        #expect(try files() == [".podcast-export.json", "Listening History.csv", "Podcasts.md", "Podcasts.opml", "Shows"])
        #expect(try files("Shows") == ["Apple-only show.md", "Lantern & Ledger.md", "Synapse After Dark.md"])
        #expect(Set(report.written) == ["Podcasts.opml", "Podcasts.md", "Listening History.csv", "Shows/Apple-only show.md", "Shows/Lantern & Ledger.md", "Shows/Synapse After Dark.md"])
        #expect(report.withoutFeed == ["Apple-only show"])
        #expect(report.privateFeeds == 1)
        #expect(try read("Podcasts.opml").contains("xmlUrl=\"https://members.example.net/feed?auth=s3cr3t\""))
        #expect(try read("Podcasts.md").contains("[[Shows/Synapse After Dark\\|Synapse After Dark]]"))
        #expect(Describe.summary(report) == "Added 2 new plays, 3 new shows")
    }

    @Test func aPrivateFeedOnlyGoesInTheOPML() throws {
        _ = try exporter(ExportOptions(json: true, renderer: Fixtures.renderer)).export(library, now: Fixtures.date)
        for path in [".podcast-export.json", "Listening History.csv", "Listening History.json", "Podcasts.md", "Shows/Lantern & Ledger.md"] {
            #expect(!(try read(path)).contains("s3cr3t"), "The private feed is in \(path)")
        }
    }

    @Test func aRerunWithNothingNewWritesNothing() throws {
        _ = try exporter().export(library, now: Fixtures.date)
        let opml = try read("Podcasts.opml")
        let report = try exporter().export(library, now: Fixtures.date.addingTimeInterval(3600))
        #expect(report.written.isEmpty && report.newPlays == 0 && report.newShows == 0)
        #expect(Describe.summary(report) == "Nothing new")
        // The OPML file's date only moves when its shows do.
        #expect(try read("Podcasts.opml") == opml)
    }

    @Test func aRerunAddsWhatsNew() throws {
        _ = try exporter().export(library, now: Fixtures.date)
        var next = library
        next.episodes.append(Fixtures.episode("E3", title: "Glia, finally", hoursAgo: 1))
        let report = try exporter().export(next, now: Fixtures.date)
        #expect(report.newPlays == 1)
        #expect(Set(report.written) == ["Podcasts.md", "Listening History.csv", "Shows/Synapse After Dark.md"])
        #expect(try read("Shows/Synapse After Dark.md").contains("Glia, finally"))
        #expect(try read("Listening History.csv").contains("Glia, finally"))
        #expect(try exporter().newPlays(next) == 0)
    }

    @Test func countsNewPlaysBeforeExporting() throws {
        #expect(try exporter().newPlays(library) == 2)
        _ = try exporter().export(library, now: Fixtures.date)
        var next = library
        next.episodes.append(Fixtures.episode("E3", hoursAgo: 1))
        next.episodes.append(Fixtures.episode("E4", hoursAgo: nil, finished: false, saved: true))
        #expect(try exporter().newPlays(next) == 1)
    }

    @Test func neverOverwritesYourEdits() throws {
        _ = try exporter().export(library, now: Fixtures.date)
        try write("My own notes", to: "Shows/Synapse After Dark.md")
        try write("<opml>mine</opml>", to: "Podcasts.opml")
        var next = library
        next.shows.append(Fixtures.show("S4", title: "Weather for Gardeners", feed: "https://weather.example.com/rss"))
        next.episodes.append(Fixtures.episode("E3", hoursAgo: 1))
        let report = try exporter().export(next, now: Fixtures.date)
        #expect(Set(report.kept) == ["Shows/Synapse After Dark.md", "Podcasts.opml"])
        #expect(try read("Shows/Synapse After Dark.md") == "My own notes")
        #expect(try read("Podcasts.opml") == "<opml>mine</opml>")
        #expect(report.written.contains("Shows/Weather for Gardeners.md"))
        #expect(try read("Podcasts.md").contains("Weather for Gardeners"))
        // Still left alone next time, and said so again only when there's something it would change.
        #expect(try exporter().export(next, now: Fixtures.date).kept.isEmpty)
        next.episodes.append(Fixtures.episode("E4", hoursAgo: 0.5))
        #expect(try exporter().export(next, now: Fixtures.date).kept == ["Shows/Synapse After Dark.md"])
        #expect(try read("Shows/Synapse After Dark.md") == "My own notes")
    }

    @Test func remakesDeletedFilesButNotDeletedShowNotes() throws {
        _ = try exporter().export(library, now: Fixtures.date)
        for path in ["Podcasts.opml", "Listening History.csv", "Shows/Apple-only show.md"] {
            try FileManager.default.removeItem(at: destination.appendingPathComponent(path))
        }
        let report = try exporter().export(library, now: Fixtures.date)
        #expect(Set(report.written) == ["Podcasts.opml", "Listening History.csv"])
        #expect(try files("Shows") == ["Lantern & Ledger.md", "Synapse After Dark.md"])
    }

    @Test func neverWritesOverFilesThatWereAlreadyThere() throws {
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("Shows"), withIntermediateDirectories: true)
        try write("someone else's", to: "Podcasts.opml")
        try write("mine", to: "Shows/synapse after dark.md")
        let report = try exporter().export(library, now: Fixtures.date)
        #expect(report.written.contains("Podcasts (2).opml"))
        #expect(report.written.contains("Shows/Synapse After Dark (2).md"))
        #expect(try read("Podcasts.opml") == "someone else's")
        #expect(try read("Shows/synapse after dark.md") == "mine")
        #expect(try read("Podcasts.md").contains("[[Shows/Synapse After Dark (2)\\|Synapse After Dark]]"))
        // And they stay where they went.
        var next = library
        next.episodes.append(Fixtures.episode("E3", hoursAgo: 1))
        #expect(try exporter().export(next, now: Fixtures.date).written.contains("Shows/Synapse After Dark (2).md"))
    }

    @Test func twoShowsWithOneName() throws {
        let twins = Library(shows: [Fixtures.show("A", title: "Field Notes"), Fixtures.show("B", title: "field notes")], episodes: [])
        _ = try exporter().export(twins, now: Fixtures.date)
        #expect(try files("Shows") == ["Field Notes.md", "field notes (2).md"])
    }

    @Test func keepsHistoryApplePodcastsForgets() throws {
        _ = try exporter().export(library, now: Fixtures.date)
        // You unfollow Lantern & Ledger, and Apple Podcasts drops its episodes.
        var next = library
        next.shows.removeAll { $0.id == "S2" }
        next.episodes.removeAll { $0.showID == "S2" }
        let report = try exporter().export(next, now: Fixtures.date)
        #expect(report.newPlays == 0)
        #expect(try read("Listening History.csv").contains("Members only"))
        let note = try read("Shows/Lantern & Ledger.md")
        #expect(note.contains("following: false") && note.contains("Members only"))
        #expect(!(try read("Podcasts.opml")).contains("members.example.net"))
        #expect(try read("Podcasts.md").contains("| no | 1 |"))
    }

    @Test func anEmptyLibraryChangesNothing() throws {
        _ = try exporter().export(library, now: Fixtures.date)
        let before = try ["Podcasts.opml", "Podcasts.md", "Listening History.csv"].map(read)
        let report = try exporter().export(Library(), now: Fixtures.date)
        #expect(report.keptOPML)
        #expect(report.written.isEmpty)
        #expect(try ["Podcasts.opml", "Podcasts.md", "Listening History.csv"].map(read) == before)
    }

    @Test func mergesPlaysWithoutLosingAny() {
        var record = ExportRecord()
        var report = ExportReport()
        var first = Fixtures.episode("E1", hoursAgo: 2, duration: 3000)
        first.playCount = 3
        first.guid = "guid-1"
        Exporter.merge(Library(shows: [Fixtures.show()], episodes: [first, Fixtures.episode("E2", hoursAgo: nil, finished: false, saved: true)]), into: &record, report: &report)
        // You mark it unplayed to hear it again, and its old date is all Apple Podcasts still has.
        var again = Episode(id: "E1", showID: "S1", title: "How memories stick (remastered)", duration: 0, position: 60,
                            lastPlayed: Fixtures.date.addingTimeInterval(-5 * 3600))
        again.playCount = 0
        Exporter.merge(Library(shows: [Fixtures.show()], episodes: [again]), into: &record, report: &report)
        let merged = record.episodes["E1"]!
        #expect(merged.title == "How memories stick (remastered)")
        #expect(merged.finished && merged.playCount == 3)
        #expect(merged.lastPlayed == Fixtures.date.addingTimeInterval(-2 * 3600))
        #expect(merged.duration == 3000 && merged.position == 60 && merged.guid == "guid-1")
        // E2 left your saved episodes.
        #expect(record.episodes["E2"]?.saved == false)
        #expect(report.newPlays == 1)
    }

    @Test func optionsChooseTheFiles() throws {
        let options = ExportOptions(markdown: false, csv: false, json: true, renderer: Fixtures.renderer)
        _ = try exporter(options).export(library, now: Fixtures.date)
        #expect(try files() == [".podcast-export.json", "Listening History.json", "Podcasts.opml"])
        let markdown = ExportOptions(renderer: Renderer(timeZone: Fixtures.central, links: .markdown))
        _ = try exporter(markdown).export(library, now: Fixtures.date)
        #expect(try read("Podcasts.md").contains("[Synapse After Dark](<Shows/Synapse After Dark.md>)"))
    }

    @Test func refusesTheLibraryFolder() throws {
        let podcasts = folder.sub("Podcasts")
        #expect(throws: ExportError.insideLibrary) {
            try Exporter(destination: podcasts.appendingPathComponent("Export")).export(library, protected: [podcasts])
        }
        #expect(throws: ExportError.insideLibrary) {
            try Exporter(destination: podcasts).export(library, protected: [podcasts])
        }
        #expect(!FileManager.default.fileExists(atPath: podcasts.appendingPathComponent("Export").path))
    }

    @Test func refusesALinkBackIntoTheLibrary() throws {
        let podcasts = folder.sub("Podcasts")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: destination.appendingPathComponent("Shows"), withDestinationURL: podcasts)
        let report = try exporter().export(library, protected: [podcasts], now: Fixtures.date)
        #expect(report.failed.count == 3)
        #expect(try FileManager.default.contentsOfDirectory(atPath: podcasts.path).isEmpty)
        #expect(report.written.contains("Podcasts.opml"))
    }

    @Test func stopsOnARecordItCantRead() throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try write("not json", to: ".podcast-export.json")
        #expect(throws: ExportError.unreadableRecord) { try exporter().export(library) }
        #expect(throws: ExportError.unreadableRecord) { try exporter().newPlays(library) }
        try write("{\"version\": 99}", to: ".podcast-export.json")
        #expect(throws: ExportError.newerRecord) { try exporter().export(library) }
        #expect(try files() == [".podcast-export.json"])
    }

    @Test func refusesARecordThatPointsOutside() throws {
        _ = try exporter().export(library, now: Fixtures.date)
        let good = try exporter().loadRecord()
        for path in ["../escape.md", "/etc/x", "Shows/../../x.md", "a/b/c.md", ".hidden", "", "Shows\\x.md"] {
            var record = good
            record.files["opml"]?.path = path
            try exporter().saveRecord(record)
            #expect(throws: ExportError.unreadableRecord, "Accepted \(path)") { try exporter().export(library) }
        }
    }

    @Test func refusesARecordWithMismatchedIDs() throws {
        _ = try exporter().export(library, now: Fixtures.date)
        var record = try exporter().loadRecord()
        record.episodes["E9"] = record.episodes["E1"]
        try exporter().saveRecord(record)
        #expect(throws: ExportError.unreadableRecord) { try exporter().export(library) }
    }

    @Test func oneExportAtATime() throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let held = try FileLock.run(at: destination.appendingPathComponent(".podcast-export.lock"), wait: false) {
            #expect(throws: ExportError.busy) { try exporter().export(library) }
            return true
        }
        #expect(held == true)
        #expect(try exporter().export(library, now: Fixtures.date).written.count == 6)
    }

    @Test func savesOPMLOnItsOwn() throws {
        let url = folder.url.appendingPathComponent("Subscriptions.opml")
        try Exporter.saveOPML(library, to: url, protected: [], renderer: Fixtures.renderer, now: Fixtures.date)
        #expect(try String(contentsOf: url, encoding: .utf8) == Fixtures.renderer.opml(library.shows, created: Fixtures.date))
        let podcasts = folder.sub("Podcasts")
        #expect(throws: ExportError.insideLibrary) {
            try Exporter.saveOPML(library, to: podcasts.appendingPathComponent("x.opml"), protected: [podcasts])
        }
    }

    @Test func safePaths() {
        #expect(Exporter.isSafePath("Podcasts.opml"))
        #expect(Exporter.isSafePath("Shows/Synapse After Dark.md"))
        #expect(!Exporter.isSafePath("Shows/.hidden.md"))
        #expect(!Exporter.isSafePath("a\0b"))
    }
}
