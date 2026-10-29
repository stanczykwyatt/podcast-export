import Foundation
import SQLite3
@testable import PodcastCore

/// Made-up shows, episodes and libraries, built in throwaway folders. Nothing here reads the real
/// Apple Podcasts library, and every show, person and episode is invented.
enum Fixtures {
    /// A throwaway folder that's removed when the test ends.
    final class Folder {
        let url: URL

        init() {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("PodcastExportTests-\(UUID().uuidString)", isDirectory: true)
            try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        deinit {
            try? FileManager.default.removeItem(at: url)
        }

        func sub(_ name: String) -> URL {
            let sub = url.appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            return sub
        }
    }

    // MARK: Rows

    struct ShowRow {
        var pk: Int
        var uuid: String?
        var title: String?
        var author: String? = nil
        var feed: String? = nil
        var web: String? = nil
        var appleID: Int64? = nil
        var subscribed = true
        var implicit = false
        var hidden = false
        var added: Date? = nil
    }

    struct EpisodeRow {
        var pk: Int
        var uuid: String?
        var show: Int?
        var showUUID: String? = nil
        var title: String?
        var guid: String? = nil
        var published: Date? = nil
        var duration: Double? = 1800
        var playhead: Double? = 0
        var lastPlayed: Double? = nil
        var playCount: Int = 0
        var played = false
        var saved = false
        var bookmarked = false
        var savedDate: Date? = nil
        var web: String? = nil
        var appleID: Int64? = nil
        var season: Int64? = nil
        var number: Int64? = nil
    }

    /// 9:41 AM on April 30, 2026, in Minneapolis.
    static let date = Date(timeIntervalSince1970: 1_777_560_060)
    static let central = TimeZone(identifier: "America/Chicago")!
    static let renderer = Renderer(timeZone: central, locale: Locale(identifier: "en_US_POSIX"))

    /// A Core Data date `hours` before `date`.
    static func ago(hours: Double) -> Double {
        date.addingTimeInterval(-hours * 3600).timeIntervalSinceReferenceDate
    }

    /// A small library: three shows you follow (one with a private feed), one Apple Podcasts added
    /// when you played it, one hidden, and their episodes.
    static let shows: [ShowRow] = [
        ShowRow(pk: 1, uuid: "SHOW-SYNAPSE", title: "Synapse After Dark", author: "Ines Varga", feed: "https://feeds.example.com/synapse.xml",
                web: "https://synapse.example.com", appleID: 1_000_001, added: date.addingTimeInterval(-200 * 86400)),
        ShowRow(pk: 2, uuid: "SHOW-COMMUTE", title: "The Slow Commute", author: "Driftwood Radio", feed: "https://slowcommute.example.org/rss",
                appleID: 1_000_002, added: date.addingTimeInterval(-90 * 86400)),
        ShowRow(pk: 3, uuid: "SHOW-LEDGER", title: "Lantern & Ledger", author: "Pell Bros.", feed: "https://members.example.net/feed?auth=s3cr3tK3y",
                added: date.addingTimeInterval(-30 * 86400)),
        ShowRow(pk: 4, uuid: "SHOW-ENGINES", title: "Small Engine Repair Club", feed: "https://engines.example.com/feed", subscribed: true, implicit: true),
        ShowRow(pk: 5, uuid: "SHOW-MOONS", title: "Paper Moons", feed: "https://moons.example.com/feed", hidden: true),
    ]

    static let episodes: [EpisodeRow] = [
        EpisodeRow(pk: 10, uuid: "EP-S1", show: 1, title: "How memories stick", guid: "synapse-41", published: date.addingTimeInterval(-5 * 86400),
                   duration: 3120, playhead: 0, lastPlayed: ago(hours: 2), playCount: 1, played: true, web: "https://synapse.example.com/41",
                   appleID: 2_000_041, season: 3, number: 41),
        EpisodeRow(pk: 11, uuid: "EP-S2", show: 1, title: "Sleep and the hippocampus", guid: "synapse-40", duration: 2880, playhead: 1296,
                   lastPlayed: ago(hours: 30)),
        EpisodeRow(pk: 12, uuid: "EP-S3", show: 1, title: "Glia, finally", duration: 2400, saved: true, savedDate: date.addingTimeInterval(-86400)),
        EpisodeRow(pk: 13, uuid: "EP-S4", show: 1, title: "Never played", duration: 2000),
        EpisodeRow(pk: 20, uuid: "EP-C1", show: 2, title: "Bus 16, northbound", duration: 1500, playhead: 0, lastPlayed: ago(hours: 50), playCount: 2, played: true),
        EpisodeRow(pk: 21, uuid: "EP-C2", show: 2, title: "Marked played, never heard", duration: 1500, played: true),
        EpisodeRow(pk: 30, uuid: "EP-L1", show: 3, title: "Members only: the ledger", duration: 3600, playhead: 900, lastPlayed: ago(hours: 75)),
        EpisodeRow(pk: 40, uuid: "EP-E1", show: 4, title: "Two-stroke basics", duration: 1200, lastPlayed: ago(hours: 100), playCount: 1, played: true),
    ]

    static let columns = (
        show: """
            Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZAUTODOWNLOAD INTEGER, ZHIDDEN INTEGER, ZISIMPLICITLYFOLLOWED INTEGER,
            ZSTORECOLLECTIONID INTEGER, ZSUBSCRIBED INTEGER, ZADDEDDATE TIMESTAMP, ZLASTDATEPLAYED TIMESTAMP, ZAUTHOR VARCHAR,
            ZFEEDURL VARCHAR, ZIMAGEURL VARCHAR, ZITEMDESCRIPTION VARCHAR, ZTITLE VARCHAR, ZUPDATEDFEEDURL VARCHAR, ZUUID VARCHAR, ZWEBPAGEURL VARCHAR
            """,
        episode: """
            Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZEPISODENUMBER INTEGER, ZHASBEENPLAYED INTEGER, ZISBOOKMARKED INTEGER,
            ZPLAYCOUNT INTEGER, ZSAVED INTEGER, ZSEASONNUMBER INTEGER, ZSTORETRACKID INTEGER, ZPODCAST INTEGER, ZDURATION FLOAT,
            ZLASTBOOKMARKEDDATE TIMESTAMP, ZLASTDATEPLAYED TIMESTAMP, ZPLAYHEAD FLOAT, ZPUBDATE TIMESTAMP, ZENCLOSUREURL VARCHAR,
            ZFREETRANSCRIPTSNIPPET VARCHAR, ZGUID VARCHAR, ZITEMDESCRIPTION VARCHAR, ZPODCASTUUID VARCHAR, ZTITLE VARCHAR, ZUUID VARCHAR,
            ZWEBPAGEURL VARCHAR
            """
    )

    /// An Apple Podcasts library: a database shaped like Apple Podcasts' own, with its tables'
    /// Core Data names. With `inLog`, the rows stay in the write-ahead log, as the latest plays do
    /// until Apple Podcasts folds the log into the database. `showColumns` and `episodeColumns`
    /// replace the tables' columns, for libraries laid out differently.
    static func library(
        in folder: URL, shows: [ShowRow] = shows, episodes: [EpisodeRow] = episodes, inLog: Bool = false,
        showColumns: String? = nil, episodeColumns: String? = nil
    ) throws {
        // Built beside the library, then copied in while the database is still open, as Apple
        // Podcasts' is. Closing it first would fold the log into the database.
        let work = folder.deletingLastPathComponent().appendingPathComponent("build-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(work.appendingPathComponent("MTLibrary.sqlite").path, &db) == SQLITE_OK else { throw Failure.sqlite("open") }
        defer {
            sqlite3_close(db)
            try? FileManager.default.removeItem(at: work)
        }
        func exec(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Failure.sqlite(String(cString: sqlite3_errmsg(db))) }
        }
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA wal_autocheckpoint=0")
        try exec("CREATE TABLE ZMTPODCAST (\(showColumns ?? columns.show))")
        try exec("CREATE TABLE ZMTEPISODE (\(episodeColumns ?? columns.episode))")
        try exec("CREATE TABLE ZMTCHANNEL (Z_PK INTEGER PRIMARY KEY, ZNAME VARCHAR)")
        try exec("PRAGMA wal_checkpoint(TRUNCATE)")
        if showColumns == nil {
            for s in shows {
                try exec("""
                    INSERT INTO ZMTPODCAST (Z_PK, Z_ENT, ZHIDDEN, ZISIMPLICITLYFOLLOWED, ZSTORECOLLECTIONID, ZSUBSCRIBED, ZADDEDDATE, ZAUTHOR,
                    ZFEEDURL, ZITEMDESCRIPTION, ZTITLE, ZUUID, ZWEBPAGEURL)
                    VALUES (\(s.pk), 9, \(s.hidden ? 1 : 0), \(s.implicit ? 1 : 0), \(s.appleID.map(String.init) ?? "NULL"), \(s.subscribed ? 1 : 0),
                    \(s.added.map { String($0.timeIntervalSinceReferenceDate) } ?? "NULL"), \(quote(s.author)), \(quote(s.feed)),
                    'A made-up show description that is never read.', \(quote(s.title)), \(quote(s.uuid)), \(quote(s.web)))
                    """)
            }
        }
        if episodeColumns == nil {
            for e in episodes {
                try exec("""
                    INSERT INTO ZMTEPISODE (Z_PK, Z_ENT, ZEPISODENUMBER, ZHASBEENPLAYED, ZISBOOKMARKED, ZPLAYCOUNT, ZSAVED, ZSEASONNUMBER,
                    ZSTORETRACKID, ZPODCAST, ZDURATION, ZLASTBOOKMARKEDDATE, ZLASTDATEPLAYED, ZPLAYHEAD, ZPUBDATE, ZENCLOSUREURL,
                    ZFREETRANSCRIPTSNIPPET, ZGUID, ZITEMDESCRIPTION, ZPODCASTUUID, ZTITLE, ZUUID, ZWEBPAGEURL)
                    VALUES (\(e.pk), 5, \(e.number.map(String.init) ?? "NULL"), \(e.played ? 1 : 0), \(e.bookmarked ? 1 : 0), \(e.playCount),
                    \(e.saved ? 1 : 0), \(e.season.map(String.init) ?? "NULL"), \(e.appleID.map(String.init) ?? "NULL"),
                    \(e.show.map(String.init) ?? "NULL"), \(e.duration.map { String($0) } ?? "NULL"),
                    \(e.savedDate.map { String($0.timeIntervalSinceReferenceDate) } ?? "NULL"), \(e.lastPlayed.map { String($0) } ?? "NULL"),
                    \(e.playhead.map { String($0) } ?? "NULL"), \(e.published.map { String($0.timeIntervalSinceReferenceDate) } ?? "NULL"),
                    'https://cdn.example.com/audio/\(e.pk).mp3', 'A made-up transcript snippet that is never read.', \(quote(e.guid)),
                    'Made-up show notes that are never read.', \(quote(e.showUUID)), \(quote(e.title)), \(quote(e.uuid)), \(quote(e.web)))
                    """)
            }
        }
        if !inLog { try exec("PRAGMA wal_checkpoint(TRUNCATE)") }
        for name in try FileManager.default.contentsOfDirectory(atPath: work.path) {
            let target = folder.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: work.appendingPathComponent(name), to: target)
        }
    }

    enum Failure: Error { case sqlite(String) }

    static func quote(_ value: String?) -> String {
        guard let value else { return "NULL" }
        return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// The small library, read through the real reader.
    static func read(in folder: Folder, inLog: Bool = false) throws -> Library {
        let url = folder.url.appendingPathComponent("Podcasts", isDirectory: true)
        try library(in: url, inLog: inLog)
        return try PodcastLibrary(folder: url).read(scratch: folder.sub("scratch"))
    }

    // MARK: Values

    static func show(_ id: String = "S1", title: String = "Synapse After Dark", feed: String? = "https://feeds.example.com/synapse.xml", following: Bool = true) -> Show {
        Show(id: id, title: title, author: "Ines Varga", feedURL: feed, webURL: "https://synapse.example.com", appleID: 1_000_001,
             following: following, added: date.addingTimeInterval(-200 * 86400))
    }

    static func episode(
        _ id: String = "E1", show: String = "S1", title: String = "How memories stick", hoursAgo: Double? = 2, duration: Double = 3120,
        position: Double = 0, finished: Bool = true, saved: Bool = false
    ) -> Episode {
        Episode(id: id, showID: show, title: title, duration: duration, position: position,
                lastPlayed: hoursAgo.map { date.addingTimeInterval(-$0 * 3600) }, playCount: finished ? 1 : 0, finished: finished, saved: saved)
    }
}
