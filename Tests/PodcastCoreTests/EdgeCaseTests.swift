import Foundation
import Testing
@testable import PodcastCore

/// Libraries and folders that are odd in ways real ones can be: half synced, rebuilt under new
/// IDs, or holding private feeds in unusual shapes.
@Suite("Edge cases")
struct EdgeCaseTests {
    let folder = Fixtures.Folder()
    var destination: URL { folder.url.appendingPathComponent("Export", isDirectory: true) }

    private func exporter() -> Exporter {
        Exporter(destination: destination, options: ExportOptions(renderer: Fixtures.renderer))
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: destination.appendingPathComponent(path), encoding: .utf8)
    }

    /// Six shows you follow, each with a played episode with a feed ID, and one saved episode.
    private var library: Library {
        let shows = (1...6).map { Fixtures.show("S\($0)", title: "Show \($0)", feed: "https://feeds.example.com/\($0).xml") }
        var episodes = (1...6).map { index -> Episode in
            var episode = Fixtures.episode("E\(index)", show: "S\(index)", title: "Episode \(index)", hoursAgo: Double(index))
            episode.guid = "guid-\(index)"
            return episode
        }
        var saved = Fixtures.episode("SAVED", show: "S1", title: "For later", hoursAgo: nil, finished: false, saved: true)
        saved.guid = "guid-saved"
        episodes.append(saved)
        return Library(shows: shows.enumerated().map { index, show in
            var show = show
            show.appleID = Int64(1000 + index)
            return show
        }, episodes: episodes)
    }

    // MARK: Private feeds

    @Test func privateFeedsWithTheKeyInThePath() {
        for feed in [
            "https://show.supercast.com/feeds/Ab3dEf9hIj2kLm4nOp6qRs8t",
            "https://api.substack.com/feed/podcast/123/private/0b5f8a3e-7c1d-4e2a-9f60-1a2b3c4d5e6f.rss",
            "https://example.com/premium/feed.xml",
            "https://example.com/members/rss",
            "https://example.com/rss/0b5f8a3e-7c1d-4e2a-9f60-1a2b3c4d5e6f",
        ] {
            #expect(Links.looksPrivate(feed), "Missed \(feed)")
        }
        for feed in [
            "https://feeds.acast.com/public/shows/5f3a9b2c1d4e6f7a8b9c0d1e",
            "https://feeds.megaphone.fm/GLT1412515089",
            "https://feeds.simplecast.com/54nAGcIl",
            "https://anchor.fm/s/1a2b3c4d/podcast/rss",
            "https://feeds.buzzsprout.com/123456.rss",
            "https://feeds.example.com/the-long-and-winding-show-name.xml",
        ] {
            #expect(!Links.looksPrivate(feed), "Flagged \(feed)")
        }
    }

    @Test func aRecordFromAWeakerCheckIsCleanedWhenRead() throws {
        // A show saved by a version that didn't spot this feed as private.
        let json = """
            {"id": "S1", "title": "Members", "feedURL": "https://show.supercast.com/feeds/Ab3dEf9hIj2kLm4nOp6qRs8t", "following": true, "hasPrivateFeed": false}
            """
        let old = try JSONDecoder().decode(Show.self, from: Data(json.utf8))
        #expect(!old.hasPrivateFeed)
        var record = ExportRecord()
        record.shows["S1"] = old
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try exporter().saveRecord(record)
        let loaded = try exporter().loadRecord()
        #expect(loaded.shows["S1"]?.feedURL == nil)
        #expect(loaded.shows["S1"]?.hasPrivateFeed == true)
    }

    // MARK: Libraries still loading

    @Test func aHalfSyncedLibraryKeepsTheOPML() throws {
        _ = try exporter().export(library, now: Fixtures.date)
        let opml = try read("Podcasts.opml")
        var partial = library
        partial.shows = Array(partial.shows.prefix(2))
        partial.episodes = partial.episodes.filter { ["S1", "S2"].contains($0.showID) }
        let report = try exporter().export(partial, now: Fixtures.date)
        #expect(report.keptOPML)
        #expect(Describe.summary(report) == "Kept the last OPML file")
        #expect(try read("Podcasts.opml") == opml)
        #expect(try exporter().loadRecord().shows.values.allSatisfy(\.following))
        #expect(try read("Shows/Show 6.md").contains("following: true"))
        // Delete the OPML file, and the library is taken as it is.
        try FileManager.default.removeItem(at: destination.appendingPathComponent("Podcasts.opml"))
        let again = try exporter().export(partial, now: Fixtures.date)
        #expect(!again.keptOPML)
        #expect(try exporter().loadRecord().shows.values.filter(\.following).count == 2)
        #expect(try read("Shows/Show 6.md").contains("following: false"))
    }

    @Test func unfollowingAFewShowsIsTakenAsIs() throws {
        _ = try exporter().export(library, now: Fixtures.date)
        var fewer = library
        fewer.shows.removeLast(2)
        let report = try exporter().export(fewer, now: Fixtures.date)
        #expect(!report.keptOPML)
        #expect(!(try read("Podcasts.opml")).contains("Show 6"))
    }

    @Test func noEpisodesAtAllKeepsSavedEpisodes() throws {
        _ = try exporter().export(library, now: Fixtures.date)
        var loading = library
        loading.episodes = []
        _ = try exporter().export(loading, now: Fixtures.date)
        #expect(try exporter().loadRecord().episodes["SAVED"]?.saved == true)
    }

    // MARK: New IDs

    @Test func aRebuiltLibraryIsTheSameLibrary() throws {
        _ = try exporter().export(library, now: Fixtures.date)
        // A new Mac: every show and episode has a new ID, but the same Apple Podcasts IDs and feed IDs.
        var rebuilt = library
        for index in rebuilt.shows.indices { rebuilt.shows[index].id = "NEW-" + rebuilt.shows[index].id }
        for index in rebuilt.episodes.indices {
            rebuilt.episodes[index].id = "NEW-" + rebuilt.episodes[index].id
            rebuilt.episodes[index].showID = "NEW-" + rebuilt.episodes[index].showID
        }
        rebuilt.episodes[0].lastPlayed = Fixtures.date
        #expect(try exporter().newPlays(rebuilt) == 0)
        let report = try exporter().export(rebuilt, now: Fixtures.date)
        #expect(report.newPlays == 0 && report.newShows == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.appendingPathComponent("Shows").path).count == 6)
        let record = try exporter().loadRecord()
        #expect(record.episodes.count == 7 && record.shows.count == 6)
        #expect(record.episodes["E1"]?.lastPlayed == Fixtures.date)
        #expect(try read("Listening History.csv").components(separatedBy: "Episode 1\"").count == 2)
    }

    @Test func twoShowsThatAreBothThereAreNeverMerged() throws {
        _ = try exporter().export(library, now: Fixtures.date)
        var more = library
        var twin = Fixtures.show("S7", title: "Same feed, different show", feed: "https://feeds.example.com/1.xml")
        twin.appleID = 1000
        more.shows.append(twin)
        let report = try exporter().export(more, now: Fixtures.date)
        #expect(report.newShows == 1)
        #expect(try exporter().loadRecord().shows.count == 7)
    }

    // MARK: Odd libraries

    @Test func duplicateShowRowsKeepTheirEpisodes() throws {
        let url = folder.url.appendingPathComponent("Podcasts", isDirectory: true)
        try Fixtures.library(in: url, shows: [
            Fixtures.ShowRow(pk: 2, uuid: "DUP", title: "First", feed: "https://a.example.com/feed"),
            Fixtures.ShowRow(pk: 3, uuid: "DUP", title: "Second", feed: "https://b.example.com/feed"),
        ], episodes: [
            Fixtures.EpisodeRow(pk: 1, uuid: "E1", show: 3, title: "From the second row", lastPlayed: Fixtures.ago(hours: 1)),
        ])
        let library = try PodcastLibrary(folder: url).read(scratch: folder.sub("scratch"))
        #expect(library.shows.count == 1)
        #expect(library.episodes.map(\.showID) == ["DUP"])
    }

    @Test func aZeroDateIsNoDate() throws {
        let url = folder.url.appendingPathComponent("Podcasts", isDirectory: true)
        try Fixtures.library(in: url, shows: [Fixtures.ShowRow(pk: 1, uuid: "S", title: "Show", feed: "https://a.example.com/feed")], episodes: [
            Fixtures.EpisodeRow(pk: 1, uuid: "UNPLAYED", show: 1, title: "Stored as zero", lastPlayed: 0),
            Fixtures.EpisodeRow(pk: 2, uuid: "STARTED", show: 1, title: "Started", playhead: 60, lastPlayed: 0),
        ])
        let library = try PodcastLibrary(folder: url).read(scratch: folder.sub("scratch"))
        #expect(library.episodes.map(\.id) == ["STARTED"])
        #expect(library.episodes.first?.lastPlayed == nil)
    }

    @Test func theScratchCopyIsEmptiedAfterReading() throws {
        let scratch = folder.sub("scratch")
        _ = try Fixtures.read(in: folder)
        for name in ["MTLibrary.sqlite", "MTLibrary.sqlite-wal", "MTLibrary.sqlite-shm"] {
            let url = scratch.appendingPathComponent("Podcasts/\(name)")
            #expect(try Data(contentsOf: url).isEmpty, "\(name) still holds the library")
        }
        // And reading again still works.
        #expect(try PodcastLibrary(folder: folder.url.appendingPathComponent("Podcasts")).read(scratch: scratch).shows.count == 5)
    }

    @Test func aPipeInAShowTitleStaysInItsCell() {
        let show = Fixtures.show(title: "This | That")
        let obsidian = Fixtures.renderer.overview(shows: [show], episodes: [], notes: ["S1": "Shows/This That"])
        #expect(obsidian.contains("| [[Shows/This That\\|This \\| That]] | yes | 0 |  |  |"))
        let markdown = Renderer(timeZone: Fixtures.central, links: .markdown).overview(shows: [show], episodes: [], notes: ["S1": "Shows/This That"])
        #expect(markdown.contains("| [This \\| That](<Shows/This That.md>) | yes |"))
    }

    // MARK: Apple Podcasts' own folders

    @Test func theWholeGroupContainerIsProtected() throws {
        let home = folder.sub("home")
        let library = PodcastLibrary(home: home)
        #expect(library.protectedFolders.map(\.lastPathComponent) == ["Documents", "243LU875E5.groups.com.apple.podcasts"])
        #expect(PodcastLibrary(folder: folder.sub("Backup")).protectedFolders.count == 1)
        try Fixtures.library(in: library.folder)
        var out: [String] = [], err: [String] = []
        let container = library.folder.deletingLastPathComponent().appendingPathComponent("Export").path
        let status = Command.run(["export", container], home: home, workingDirectory: folder.url, scratch: folder.sub("s"),
                                 out: { out.append($0) }, err: { err.append($0) })
        #expect(status == 1)
        #expect(err == [Describe.problem(ExportError.insideLibrary)])
    }

    @Test func theCommandLineToolDropsTerminalEscapes() throws {
        let home = folder.sub("home")
        try Fixtures.library(in: PodcastLibrary(home: home).folder, shows: [
            Fixtures.ShowRow(pk: 1, uuid: "S", title: "Sneaky\u{1B}]52;c;aGk=\u{07} show", feed: "https://a.example.com/feed"),
        ], episodes: [])
        var out: [String] = []
        _ = Command.run(["shows"], home: home, workingDirectory: folder.url, scratch: folder.sub("s"), out: { out.append($0) }, err: { _ in })
        #expect(out == ["Sneaky]52;c;aGk= show  (0 played)"])
    }
}
