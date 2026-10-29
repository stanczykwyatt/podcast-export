import AppKit
import Foundation
import SQLite3
@testable import PodcastCore
@testable import PodcastExport

/// A throwaway folder that's removed when the test ends.
final class TestFolder {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("PodcastExportAppTests-\(UUID().uuidString)", isDirectory: true)
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

/// Settings in a suite of their own, so tests never touch the app's real ones.
func testPreferences() -> Preferences {
    let name = "PodcastExportTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return Preferences(defaults: defaults)
}

/// A made-up Apple Podcasts library: a database shaped like Apple Podcasts' own, in a throwaway
/// folder. Every show, host and episode here is invented.
enum Gallery {
    struct Played {
        var title: String
        var hoursAgo: Double?
        var minutes: Double
        /// How far through, from 0 to 1; 1 is finished.
        var progress: Double
        var saved = false
    }

    struct Program {
        var id: String
        var title: String
        var author: String
        var feed: String?
        var following = true
        var daysFollowed: Double = 120
        var episodes: [Played]
    }

    static let now = Date(timeIntervalSince1970: 1_777_560_060)

    /// Episodes for a show you listen to every week, a finished one every `every` days.
    static func weekly(_ titles: [String], count: Int, every: Double, minutes: Double, from start: Double) -> [Played] {
        (0..<count).map { (index: Int) -> Played in
            let part = index >= titles.count ? ", part \(index / titles.count + 1)" : ""
            let days: Double = start + Double(index) * every
            return Played(title: titles[index % titles.count] + part, hoursAgo: days * 24, minutes: minutes + Double(index % 5) * 3, progress: 1)
        }
    }

    static let synapse: [Played] = [
        Played(title: "How memories stick", hoursAgo: 2, minutes: 52, progress: 1),
        Played(title: "Sleep and the hippocampus", hoursAgo: 30, minutes: 48, progress: 0.45),
        Played(title: "Glia, finally", hoursAgo: nil, minutes: 40, progress: 0, saved: true),
        Played(title: "The dopamine myth", hoursAgo: 24 * 6, minutes: 61, progress: 1),
        Played(title: "What anesthesia turns off", hoursAgo: 24 * 13, minutes: 57, progress: 1, saved: true),
        Played(title: "Mapping a fly's brain", hoursAgo: 24 * 20, minutes: 44, progress: 1),
        Played(title: "Phantom limbs", hoursAgo: 24 * 27, minutes: 50, progress: 0.8),
        Played(title: "Why we yawn", hoursAgo: 24 * 34, minutes: 33, progress: 1),
    ]

    static let programs: [Program] = {
        var programs: [Program] = []
        let older: [Played] = weekly(["Neurons in a dish", "The binding problem", "Smell and memory"], count: 33, every: 7, minutes: 45, from: 41)
        programs.append(Program(id: "SHOW-SYNAPSE", title: "Synapse After Dark", author: "Ines Varga", feed: "https://feeds.example.com/synapse.xml",
                                daysFollowed: 412, episodes: synapse + older))
        programs.append(Program(id: "SHOW-COMMUTE", title: "The Slow Commute", author: "Driftwood Radio", feed: "https://slowcommute.example.org/rss",
                                daysFollowed: 300, episodes: weekly(["Bus 16, northbound", "The night train", "Ferry weather", "Walking the long way"], count: 23, every: 3.5, minutes: 24, from: 0.5)))
        programs.append(Program(id: "SHOW-WEATHER", title: "Weather for Gardeners", author: "Moss & Rain Studio", feed: "https://weather.example.com/rss",
                                daysFollowed: 200, episodes: weekly(["First frost", "Reading the clouds", "A wet spring"], count: 9, every: 9, minutes: 28, from: 3)))
        programs.append(Program(id: "SHOW-PHYSICS", title: "Night Shift Physics", author: "Halcyon Audio", feed: "https://nightshift.example.com/feed",
                                daysFollowed: 90, episodes: weekly(["Why ice floats", "Lasers, slowly", "The arrow of time"], count: 6, every: 11, minutes: 38, from: 5)))
        programs.append(Program(id: "SHOW-LEDGER", title: "Lantern & Ledger", author: "Pell Bros.", feed: "https://members.example.net/feed?auth=madeup",
                                daysFollowed: 45, episodes: weekly(["Members only: the ledger", "Old maps, new money"], count: 4, every: 8, minutes: 70, from: 4)))
        programs.append(Program(id: "SHOW-ENGINES", title: "Small Engine Repair Club", author: "Teo Marsh", feed: "https://engines.example.com/feed",
                                following: false, episodes: weekly(["Two-stroke basics", "Carburetor day"], count: 2, every: 5, minutes: 31, from: 15)))
        programs.append(Program(id: "SHOW-MOONS", title: "Paper Moons", author: "Ada Quill", feed: nil, daysFollowed: 10, episodes: []))
        return programs
    }()

    /// Writes the library into `folder`, the way Apple Podcasts lays it out.
    static func write(to folder: URL, now: Date = now) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(folder.appendingPathComponent("MTLibrary.sqlite").path, &db) == SQLITE_OK else { throw Failure.sqlite }
        defer { sqlite3_close(db) }
        func exec(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Failure.sqlite }
        }
        func quote(_ value: String?) -> String {
            value.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" } ?? "NULL"
        }
        try exec("""
            CREATE TABLE ZMTPODCAST (Z_PK INTEGER PRIMARY KEY, ZHIDDEN INTEGER, ZISIMPLICITLYFOLLOWED INTEGER, ZSTORECOLLECTIONID INTEGER,
            ZSUBSCRIBED INTEGER, ZADDEDDATE TIMESTAMP, ZAUTHOR VARCHAR, ZFEEDURL VARCHAR, ZTITLE VARCHAR, ZUUID VARCHAR, ZWEBPAGEURL VARCHAR)
            """)
        try exec("""
            CREATE TABLE ZMTEPISODE (Z_PK INTEGER PRIMARY KEY, ZHASBEENPLAYED INTEGER, ZPLAYCOUNT INTEGER, ZSAVED INTEGER, ZPODCAST INTEGER,
            ZDURATION FLOAT, ZLASTBOOKMARKEDDATE TIMESTAMP, ZLASTDATEPLAYED TIMESTAMP, ZPLAYHEAD FLOAT, ZPUBDATE TIMESTAMP, ZGUID VARCHAR,
            ZTITLE VARCHAR, ZUUID VARCHAR)
            """)
        var episodePK = 1
        for (index, program) in programs.enumerated() {
            let pk = index + 1
            let added = now.addingTimeInterval(-program.daysFollowed * 86400).timeIntervalSinceReferenceDate
            try exec("""
                INSERT INTO ZMTPODCAST VALUES (\(pk), 0, \(program.following ? 0 : 1), \(1_000_000 + pk), 1, \(added), \(quote(program.author)),
                \(quote(program.feed)), \(quote(program.title)), \(quote(program.id)), NULL)
                """)
            for (number, played) in program.episodes.enumerated() {
                let duration = played.minutes * 60
                let last = played.hoursAgo.map { String(now.addingTimeInterval(-$0 * 3600).timeIntervalSinceReferenceDate) } ?? "NULL"
                let published = now.addingTimeInterval(-((played.hoursAgo ?? 30) + 40) * 3600).timeIntervalSinceReferenceDate
                let finished = played.progress >= 1 && played.hoursAgo != nil
                let savedDate = played.saved ? String(now.addingTimeInterval(-Double(number + 1) * 86400).timeIntervalSinceReferenceDate) : "NULL"
                try exec("""
                    INSERT INTO ZMTEPISODE VALUES (\(episodePK), \(finished ? 1 : 0), \(finished ? 1 : 0), \(played.saved ? 1 : 0), \(pk), \(duration),
                    \(savedDate), \(last), \(finished ? 0 : duration * played.progress), \(published), \(quote("\(program.id)-\(number)")),
                    \(quote(played.title)), \(quote("EP-\(program.id)-\(number)")))
                    """)
                episodePK += 1
            }
        }
    }

    enum Failure: Error { case sqlite }

    /// A model reading the made-up library, already loaded.
    @MainActor
    static func model(in folder: TestFolder, exportTo: URL? = nil) async throws -> PodcastModel {
        let library = folder.url.appendingPathComponent("Podcasts", isDirectory: true)
        try write(to: library)
        let model = PodcastModel(
            source: PodcastLibrary(folder: library), preferences: testPreferences(), scratch: folder.sub("scratch"),
            folder: exportTo.map { ExportFolder(url: $0, scoped: false) }
        )
        await model.reload()
        return model
    }
}
