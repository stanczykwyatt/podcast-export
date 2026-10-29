import Foundation
import Testing
@testable import PodcastCore

@Suite("Command line")
struct CommandTests {
    let folder = Fixtures.Folder()

    /// A made-up home folder with the small library where Apple Podcasts keeps its own.
    private func home() throws -> URL {
        let home = folder.sub("home")
        try Fixtures.library(in: home.appendingPathComponent(PodcastLibrary.relativePath, isDirectory: true))
        return home
    }

    private func run(_ arguments: [String], home: URL? = nil) throws -> (status: Int32, out: String, err: String) {
        var out: [String] = [], err: [String] = []
        let status = Command.run(
            arguments, home: try home ?? self.home(), workingDirectory: folder.url, scratch: folder.sub("scratch"),
            renderer: Fixtures.renderer, now: Fixtures.date, out: { out.append($0) }, err: { err.append($0) }
        )
        return (status, out.joined(separator: "\n"), err.joined(separator: "\n"))
    }

    @Test func parsesCommands() throws {
        #expect(try Command.parse(["shows"]).0 == .shows(json: false))
        #expect(try Command.parse(["shows", "--json"]).0 == .shows(json: true))
        #expect(try Command.parse(["history", "--limit", "5"]).0 == .history(json: false, limit: 5))
        #expect(try Command.parse(["opml", "--library", "/tmp/backup"]) == (.opml, "/tmp/backup"))
        #expect(try Command.parse([]).0 == .help)
        #expect(try Command.parse(["-h"]).0 == .help)
        #expect(try Command.parse(["export", "x", "--version"]).0 == .version)
        let export = try Command.parse(["export", "~/Notes", "--no-markdown", "--json", "--markdown-links"]).0
        #expect(export == .export(folder: "~/Notes", options: ExportOptions(markdown: false, csv: true, json: true, renderer: Renderer(links: .markdown))))
    }

    @Test func explainsMistakes() {
        let mistakes: [([String], String)] = [
            (["dance"], "Unknown command dance. See podcast-export --help."),
            (["shows", "--srt"], "Unknown option --srt for shows. See podcast-export --help."),
            (["export"], "export needs one folder to export into."),
            (["history", "--limit", "zero"], "--limit needs a number above 0."),
            (["history", "--limit"], "--limit needs a value."),
            (["opml", "extra"], "opml takes no arguments. To save it, use podcast-export opml > Podcasts.opml"),
            (["shows", "--limit", "3"], "Unknown option --limit for shows. See podcast-export --help."),
        ]
        for (arguments, message) in mistakes {
            #expect(throws: Command.ParseError.message(message)) { try Command.parse(arguments) }
        }
    }

    @Test func listsShows() throws {
        let result = try run(["shows"])
        #expect(result.status == 0)
        #expect(result.out.components(separatedBy: "\n") == [
            "Lantern & Ledger  (1 played, 15 min, private feed)",
            "Small Engine Repair Club  (1 played, 20 min, not following)",
            "Synapse After Dark  (2 played, 1 hr 14 min)",
            "The Slow Commute  (1 played, 25 min)",
        ])
        let json = try #require(try JSONSerialization.jsonObject(with: Data(try run(["shows", "--json"]).out.utf8)) as? [[String: Any]])
        #expect(json.count == 4)
        #expect(json[0]["feed_url"] is NSNull && json[0]["private_feed"] as? Bool == true)
    }

    @Test func listsHistory() throws {
        let result = try run(["history", "--limit", "2"])
        #expect(result.out == """
            2026-04-30  Synapse After Dark · How memories stick  (finished)
            2026-04-29  Synapse After Dark · Sleep and the hippocampus  (45% played)
            """)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(try run(["history", "--json"]).out.utf8)) as? [String: Any])
        #expect((json["episodes"] as? [Any])?.count == 6)
        #expect(!(try run(["history", "--json"]).out.contains("s3cr3tK3y")))
    }

    @Test func printsOPML() throws {
        let result = try run(["opml"])
        #expect(result.status == 0)
        let document = try XMLDocument(data: Data(result.out.utf8))
        #expect(try document.nodes(forXPath: "/opml/body/outline").count == 3)
        #expect(result.out.contains("auth=s3cr3tK3y"))
    }

    @Test func exportsToAFolder() throws {
        let result = try run(["export", "Notes"])
        #expect(result.status == 0)
        #expect(result.out.hasPrefix("Added 5 new plays, 3 new shows."))
        #expect(result.out.contains("  + Podcasts.opml"))
        #expect(result.out.contains("  ! Podcasts.opml holds 1 private feed. Treat it like a password."))
        #expect(FileManager.default.fileExists(atPath: folder.url.appendingPathComponent("Notes/Shows/Synapse After Dark.md").path))
        #expect(try run(["export", "Notes"]).out == "Nothing new.\n  ! Podcasts.opml holds 1 private feed. Treat it like a password.")
    }

    @Test func neverExportsIntoTheLibrary() throws {
        let home = try home()
        let result = try run(["export", home.appendingPathComponent(PodcastLibrary.relativePath + "/Export").path], home: home)
        #expect(result.status == 1)
        #expect(result.err == "Choose a folder outside the Apple Podcasts library. Nothing is ever written there.")
        // Reading a backup, it still won't write into the real library.
        let backup = folder.sub("backup")
        try Fixtures.library(in: backup)
        let fromBackup = try run(["export", home.appendingPathComponent(PodcastLibrary.relativePath).path, "--library", backup.path], home: home)
        #expect(fromBackup.status == 1)
    }

    @Test func explainsFullDiskAccess() throws {
        let home = folder.sub("locked-home")
        let library = home.appendingPathComponent(PodcastLibrary.relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: library.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: library.path) }
        let result = try run(["shows"], home: home)
        #expect(result.status == 1)
        #expect(result.err.hasPrefix("Your terminal needs Full Disk Access"))
    }

    @Test func helpAndVersion() throws {
        #expect(try run(["--help"], home: folder.url).out == Command.usage)
        #expect(try run(["--version"], home: folder.url).out == "podcast-export 0.1.0")
        #expect(try run(["bogus"], home: folder.url).status == 2)
    }

    @Test func anEmptyLibrary() throws {
        let home = folder.sub("empty-home")
        try Fixtures.library(in: home.appendingPathComponent(PodcastLibrary.relativePath, isDirectory: true), shows: [], episodes: [])
        #expect(try run(["shows"], home: home).out == "No shows.")
        #expect(try run(["history"], home: home).out == "No episodes played yet.")
    }
}

@Suite("Search")
struct SearchTests {
    private var library: Library {
        Library(
            shows: [Fixtures.show(), Fixtures.show("S2", title: "The Slow Commute"), Fixtures.show("S3", title: "Never played, not followed", following: false)],
            episodes: [
                Fixtures.episode("E1", title: "How memories stick", hoursAgo: 2),
                Fixtures.episode("E2", title: "Sleep and the hippocampus", hoursAgo: 30),
                Fixtures.episode("E3", show: "S2", title: "Bus 16, northbound", hoursAgo: 1),
            ]
        )
    }

    @Test func everythingWithoutAQuery() {
        let results = Search.run("", in: library)
        #expect(results.map(\.show.id) == ["S2", "S1"])
        #expect(results[1].episodes.map(\.id) == ["E1", "E2"])
    }

    @Test func byEpisodeTitle() {
        let results = Search.run("HIPPOCAMPUS", in: library)
        #expect(results.map(\.show.id) == ["S1"])
        #expect(results[0].episodes.map(\.id) == ["E2"])
        #expect(!results[0].showMatches)
    }

    @Test func byShowAndEpisodeTogether() {
        #expect(Search.run("synapse memories", in: library).first?.episodes.map(\.id) == ["E1"])
        let byAuthor = Search.run("ines", in: library).first { $0.show.id == "S1" }
        #expect(byAuthor?.showMatches == true)
        #expect(byAuthor?.episodes.count == 2)
        #expect(Search.run("nothing like this", in: library).isEmpty)
    }

    @Test func highlights() {
        let text = "Sleep and the hippocampus, then sleep"
        #expect(Search.ranges(of: "sleep", in: text).map { text.distance(from: text.startIndex, to: $0.lowerBound) } == [0, 32])
    }
}
