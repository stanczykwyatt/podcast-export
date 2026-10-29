import Foundation
import Testing
@testable import PodcastCore

@Suite("Reading the library")
struct LibraryTests {
    let folder = Fixtures.Folder()
    var libraryURL: URL { folder.url.appendingPathComponent("Podcasts", isDirectory: true) }

    private func read() throws -> Library {
        try PodcastLibrary(folder: libraryURL).read(scratch: folder.sub("scratch"))
    }

    @Test func readsTheShows() throws {
        let library = try Fixtures.read(in: folder)
        #expect(library.shows.map(\.title) == ["Lantern & Ledger", "Paper Moons", "Small Engine Repair Club", "Synapse After Dark", "The Slow Commute"])
        #expect(library.following.map(\.title) == ["Lantern & Ledger", "Synapse After Dark", "The Slow Commute"])
        let synapse = try #require(library.show("SHOW-SYNAPSE"))
        #expect(synapse.author == "Ines Varga")
        #expect(synapse.feedURL == "https://feeds.example.com/synapse.xml")
        #expect(synapse.webURL == "https://synapse.example.com")
        #expect(synapse.appleURL == "https://podcasts.apple.com/podcast/id1000001")
        #expect(synapse.added == Fixtures.date.addingTimeInterval(-200 * 86400))
        #expect(!synapse.hasPrivateFeed)
        #expect(library.show("SHOW-LEDGER")?.hasPrivateFeed == true)
    }

    @Test func readsOnlyEpisodesYouListenedToOrSaved() throws {
        let library = try Fixtures.read(in: folder)
        #expect(Set(library.episodes.map(\.id)) == ["EP-S1", "EP-S2", "EP-S3", "EP-C1", "EP-L1", "EP-E1"])
        #expect(library.history.map(\.id) == ["EP-S1", "EP-S2", "EP-C1", "EP-L1", "EP-E1"])
        #expect(library.saved.map(\.id) == ["EP-S3"])
        let first = try #require(library.episodes.first { $0.id == "EP-S1" })
        #expect(first.showID == "SHOW-SYNAPSE")
        #expect(first.finished && first.playCount == 1)
        #expect(first.guid == "synapse-41")
        #expect(first.season == 3 && first.number == 41)
        #expect(first.appleURL(show: library.show("SHOW-SYNAPSE")) == "https://podcasts.apple.com/podcast/id1000001?i=2000041")
        #expect(first.lastPlayed == Fixtures.date.addingTimeInterval(-2 * 3600))
        let started = try #require(library.episodes.first { $0.id == "EP-S2" })
        #expect(!started.finished)
        #expect(started.progress == 0.45)
    }

    @Test func readsTheLatestPlaysStillInTheLog() throws {
        let library = try Fixtures.read(in: folder, inLog: true)
        #expect(library.history.count == 5)
        #expect(library.shows.count == 5)
    }

    @Test func neverTouchesTheLibrary() throws {
        try Fixtures.library(in: libraryURL, inLog: true)
        func snapshot() throws -> [String: Data] {
            var files: [String: Data] = [:]
            for name in try FileManager.default.contentsOfDirectory(atPath: libraryURL.path) {
                files[name] = try Data(contentsOf: libraryURL.appendingPathComponent(name))
            }
            return files
        }
        let before = try snapshot()
        let dates = try FileManager.default.contentsOfDirectory(atPath: libraryURL.path).map {
            try FileManager.default.attributesOfItem(atPath: libraryURL.appendingPathComponent($0).path)[.modificationDate] as? Date
        }
        _ = try read()
        _ = try read()
        #expect(try snapshot() == before)
        let after = try FileManager.default.contentsOfDirectory(atPath: libraryURL.path).map {
            try FileManager.default.attributesOfItem(atPath: libraryURL.appendingPathComponent($0).path)[.modificationDate] as? Date
        }
        #expect(after == dates)
    }

    @Test func aMissingLibrary() {
        #expect(throws: LibraryError.notFound) {
            try PodcastLibrary(folder: folder.url.appendingPathComponent("nope")).read(scratch: folder.sub("s"))
        }
        let empty = folder.sub("Empty")
        #expect(throws: LibraryError.notFound) {
            try PodcastLibrary(folder: empty).read(scratch: folder.sub("s"))
        }
    }

    @Test func noPermission() throws {
        let locked = folder.sub("Locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        #expect(throws: LibraryError.noPermission) {
            try PodcastLibrary(folder: locked).read(scratch: folder.sub("s"))
        }
    }

    @Test func anUnknownLayoutFailsPolitely() throws {
        try Fixtures.library(in: libraryURL, showColumns: "Z_PK INTEGER PRIMARY KEY, ZTITLE VARCHAR, ZFEEDURL VARCHAR")
        #expect(throws: LibraryError.unrecognized("The Apple Podcasts database has no ZSUBSCRIBED column.")) { try read() }
        try Fixtures.library(in: libraryURL, episodeColumns: "Z_PK INTEGER PRIMARY KEY, ZTITLE VARCHAR, ZLASTDATEPLAYED TIMESTAMP")
        #expect(throws: LibraryError.unrecognized("The Apple Podcasts database doesn't say which show an episode is from.")) { try read() }
        try Fixtures.library(in: libraryURL, episodeColumns: "Z_PK INTEGER PRIMARY KEY, ZTITLE VARCHAR, ZPODCAST INTEGER")
        #expect(throws: LibraryError.unrecognized("The Apple Podcasts database has no ZLASTDATEPLAYED column.")) { try read() }
    }

    @Test func aLeanerLayoutStillReads() throws {
        // Only the columns it needs, as an older or newer Apple Podcasts might have.
        try Fixtures.library(
            in: libraryURL,
            showColumns: "Z_PK INTEGER PRIMARY KEY, ZTITLE VARCHAR, ZFEEDURL VARCHAR, ZSUBSCRIBED INTEGER",
            episodeColumns: "Z_PK INTEGER PRIMARY KEY, ZTITLE VARCHAR, ZPODCAST INTEGER, ZLASTDATEPLAYED TIMESTAMP"
        )
        let library = try read()
        #expect(library.shows.isEmpty && library.episodes.isEmpty)
    }

    @Test func distrustsWhatItReads() throws {
        let shows = [
            Fixtures.ShowRow(pk: 1, uuid: "../../escape", title: "  ", feed: "javascript:alert(1)", web: "ftp://example.com"),
            Fixtures.ShowRow(pk: 2, uuid: "DUP", title: "First", feed: "https://a.example.com/feed"),
            Fixtures.ShowRow(pk: 3, uuid: "DUP", title: "Second", feed: "https://b.example.com/feed"),
            Fixtures.ShowRow(pk: 4, uuid: "SPACES", title: "Spaces", feed: "https://a.example.com/my feed.xml"),
        ]
        let episodes = [
            Fixtures.EpisodeRow(pk: 1, uuid: "E-WILD", show: 2, title: nil, duration: -50, playhead: 1e30, lastPlayed: 1e300, playCount: -4),
            Fixtures.EpisodeRow(pk: 2, uuid: "E-ORPHAN", show: 99, title: "No show", lastPlayed: Fixtures.ago(hours: 1)),
            Fixtures.EpisodeRow(pk: 3, uuid: "E-BYUUID", show: nil, showUUID: "SPACES", title: "Found by its show's ID", lastPlayed: Fixtures.ago(hours: 1)),
            Fixtures.EpisodeRow(pk: 4, uuid: "E-WILD", show: 2, title: "Duplicate", lastPlayed: Fixtures.ago(hours: 1)),
            Fixtures.EpisodeRow(pk: 5, uuid: nil, show: 2, title: "Bookmarked long ago", bookmarked: true, season: -1, number: 9_999_999),
        ]
        try Fixtures.library(in: libraryURL, shows: shows, episodes: episodes)
        let library = try read()
        let weird = try #require(library.show("show-1"))
        #expect(weird.title == "Untitled show")
        #expect(weird.feedURL == nil && weird.webURL == nil)
        #expect(library.show("DUP")?.title == "First")
        #expect(library.show("SPACES")?.feedURL == nil)
        let wild = try #require(library.episodes.first { $0.id == "E-WILD" })
        #expect(wild.title == "Untitled episode")
        #expect(wild.duration == 0 && wild.position == PodcastLibrary.longest)
        #expect(wild.lastPlayed == nil && wild.playCount == 0)
        #expect(!library.episodes.contains { $0.id == "E-ORPHAN" })
        #expect(library.episodes.first { $0.id == "E-BYUUID" }?.showID == "SPACES")
        #expect(library.episodes.filter { $0.id == "E-WILD" }.count == 1)
        let bookmarked = try #require(library.episodes.first { $0.id == "episode-5" })
        #expect(bookmarked.saved && !bookmarked.listened)
        #expect(bookmarked.season == nil && bookmarked.number == nil)
    }

    @Test func tellsWhenTheLibraryChanged() throws {
        try Fixtures.library(in: libraryURL)
        let library = PodcastLibrary(folder: libraryURL)
        let date = Date(timeIntervalSince1970: 1_777_000_000)
        for name in try FileManager.default.contentsOfDirectory(atPath: libraryURL.path) {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: libraryURL.appendingPathComponent(name).path)
        }
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: libraryURL.path)
        #expect(library.lastChange() == date)
        let later = date.addingTimeInterval(120)
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: libraryURL.appendingPathComponent("MTLibrary.sqlite-wal").path)
        #expect(library.lastChange() == later)
    }

    @Test func findsTheLibraryInTheHomeFolder() {
        let library = PodcastLibrary(home: URL(fileURLWithPath: "/Users/someone"))
        #expect(library.folder.path == "/Users/someone/Library/Group Containers/243LU875E5.groups.com.apple.podcasts/Documents")
    }

    @Test func cleansIDs() {
        #expect(PodcastLibrary.cleanID("8C1F2A9E-1111-4444-AAAA-0123456789AB") == "8C1F2A9E-1111-4444-AAAA-0123456789AB")
        #expect(PodcastLibrary.cleanID("a/b") == nil)
        #expect(PodcastLibrary.cleanID("") == nil)
        #expect(PodcastLibrary.cleanID(String(repeating: "a", count: 129)) == nil)
        #expect(PodcastLibrary.cleanID("ünï") == nil)
    }
}
