import Foundation
import Testing
@testable import PodcastCore

@Suite("Rendering")
struct RenderTests {
    let renderer = Fixtures.renderer

    private var shows: [Show] {
        [
            Fixtures.show(),
            Fixtures.show("S2", title: "Lantern & Ledger <\"Members\">", feed: "https://members.example.net/feed?auth=s3cr3t&x=1"),
            Fixtures.show("S3", title: "Apple-only show", feed: nil),
            Fixtures.show("S4", title: "Gone quiet", following: false),
        ]
    }

    // MARK: OPML

    @Test func opmlOtherAppsCanImport() throws {
        let text = renderer.opml(shows, created: Fixtures.date)
        let document = try XMLDocument(data: Data(text.utf8))
        let outlines = try document.nodes(forXPath: "/opml/body/outline").compactMap { $0 as? XMLElement }
        #expect(document.rootElement()?.attribute(forName: "version")?.stringValue == "2.0")
        #expect(outlines.map { $0.attribute(forName: "text")?.stringValue } == ["Lantern & Ledger <\"Members\">", "Synapse After Dark"])
        #expect(outlines.map { $0.attribute(forName: "xmlUrl")?.stringValue } == ["https://members.example.net/feed?auth=s3cr3t&x=1", "https://feeds.example.com/synapse.xml"])
        #expect(outlines.allSatisfy { $0.attribute(forName: "type")?.stringValue == "rss" })
        #expect(outlines[1].attribute(forName: "htmlUrl")?.stringValue == "https://synapse.example.com")
        #expect(text.contains("<dateCreated>Thu, 30 Apr 2026 09:41:00 -0500</dateCreated>"))
        #expect(!renderer.opml(shows, created: nil).contains("dateCreated"))
    }

    @Test func opmlDropsWhatXMLCantHold() throws {
        let text = renderer.opml([Fixtures.show(title: "Bell\u{07}s & \u{202E}whistles\u{FFFE}\nand more")], created: nil)
        let document = try XMLDocument(data: Data(text.utf8))
        let outline = try #require(try document.nodes(forXPath: "/opml/body/outline").first as? XMLElement)
        #expect(outline.attribute(forName: "title")?.stringValue == "Bells & whistles and more")
    }

    @Test func anEmptyOPMLIsStillValid() throws {
        let document = try XMLDocument(data: Data(renderer.opml([], created: nil).utf8))
        #expect(try document.nodes(forXPath: "/opml/body/outline").isEmpty)
    }

    // MARK: Notes

    @Test func theOverview() {
        let episodes = [
            Fixtures.episode("E1", hoursAgo: 2, duration: 3600),
            Fixtures.episode("E2", show: "S2", title: "Members | only", hoursAgo: 30, duration: 3600, position: 900, finished: false),
            Fixtures.episode("E3", hoursAgo: nil, finished: false, saved: true),
        ]
        let notes = ["S1": "Shows/Synapse After Dark", "S2": "Shows/Lantern & Ledger Members", "S4": "Shows/Gone quiet"]
        let text = renderer.overview(shows: shows, episodes: episodes, notes: notes)
        #expect(text.hasPrefix("---\ntitle: \"Podcasts\"\nshows-followed: 3\nepisodes-played: 2\nhours-listened: 1.3\n"))
        #expect(text.contains("3 shows followed · 2 episodes played · about 1.3 hours listened"))
        #expect(text.contains("| [[Shows/Synapse After Dark\\|Synapse After Dark]] | yes | 1 | 1 hr | 2026-04-30 |"))
        #expect(text.contains("| [[Shows/Lantern & Ledger Members\\|Lantern & Ledger \\<\"Members\"\\>]] | yes | 1 | 15 min | 2026-04-29 |"))
        #expect(text.contains("| [[Shows/Gone quiet\\|Gone quiet]] | no | 0 |  |  |"))
        #expect(!text.contains("Apple-only show |"))
        #expect(text.contains("- **2026-04-30** · Synapse After Dark · How memories stick · finished"))
        #expect(text.contains("- **2026-04-29** · Lantern & Ledger \\<\"Members\"\\> · Members \\| only · 25% played"))
        #expect(text.contains("## Saved\n\n- Synapse After Dark · How memories stick"))
        let order = ["Synapse After Dark\\|", "Lantern & Ledger Members\\|", "Gone quiet\\|"].map { text.range(of: $0)!.lowerBound }
        #expect(order == order.sorted())
    }

    @Test func overviewLinksInPlainMarkdown() {
        let text = Renderer(timeZone: Fixtures.central, links: .markdown).overview(shows: [Fixtures.show()], episodes: [], notes: ["S1": "Shows/Synapse After Dark"])
        #expect(text.contains("| [Synapse After Dark](<Shows/Synapse After Dark.md>) | yes | 0 |"))
    }

    @Test func overviewListsOnlyTheLatestPlays() {
        let episodes = (0..<80).map { Fixtures.episode("E\($0)", title: "Episode \($0)", hoursAgo: Double($0) + 1) }
        let text = renderer.overview(shows: [Fixtures.show()], episodes: episodes, notes: [:])
        #expect(text.contains("Episode 49 ·"))
        #expect(!text.contains("Episode 50 ·"))
    }

    @Test func anEmptyOverview() {
        let text = renderer.overview(shows: [], episodes: [], notes: [:])
        #expect(text.contains("*Nothing yet."))
    }

    @Test func aShowNote() {
        var episodes = [
            Fixtures.episode("E1", hoursAgo: 2, duration: 3120),
            Fixtures.episode("E2", title: "Sleep and the *hippocampus*", hoursAgo: 30, duration: 2880, position: 1296, finished: false),
            Fixtures.episode("E3", title: "Glia, finally", hoursAgo: nil, finished: false, saved: true),
            Fixtures.episode("E9", show: "S2", title: "Someone else's"),
        ]
        episodes[0].webURL = "https://synapse.example.com/41"
        episodes[0].playCount = 3
        episodes[2].appleID = 77
        let text = renderer.showNote(Fixtures.show(), episodes: episodes)
        #expect(text.hasPrefix("""
            ---
            title: "Synapse After Dark"
            author: "Ines Varga"
            feed: "https://feeds.example.com/synapse.xml"
            website: "https://synapse.example.com"
            apple-podcasts: "https://podcasts.apple.com/podcast/id1000001"
            following: true
            following-since: 2025-10-12
            episodes-played: 2
            hours-listened: 1.2
            last-played: 2026-04-30
            source: Apple Podcasts
            podcast-id: "S1"
            tags:
              - podcast
            ---

            # Synapse After Dark

            By Ines Varga · following since October 12, 2025

            2 episodes played · about 1.2 hours listened · last played April 30, 2026
            """))
        #expect(text.contains("- **2026-04-30** · [How memories stick](<https://synapse.example.com/41>) · 52 min · finished, played 3 times"))
        #expect(text.contains("- **2026-04-29** · Sleep and the \\*hippocampus\\* · 48 min · 45% played"))
        #expect(text.contains("## Saved\n\n- [Glia, finally](<https://podcasts.apple.com/podcast/id1000001?i=77>)"))
        #expect(!text.contains("Someone else"))
    }

    @Test func aShowNoteKeepsAPrivateFeedOut() {
        let show = Fixtures.show(feed: "https://members.example.net/feed?auth=s3cr3t")
        let text = renderer.showNote(show, episodes: [])
        #expect(!text.contains("s3cr3t"))
        #expect(!text.contains("feed: "))
        #expect(text.contains("private feed, in the OPML file only"))
        #expect(text.contains("*No episodes played yet.*"))
    }

    @Test func aShowYouNoLongerFollow() {
        let text = renderer.showNote(Fixtures.show(following: false), episodes: [Fixtures.episode()])
        #expect(text.contains("following: false"))
        #expect(!text.contains("following-since"))
        #expect(text.contains("By Ines Varga · not following"))
    }

    // MARK: History files

    @Test func csvForSpreadsheets() {
        var episodes = [
            Fixtures.episode("E1", title: "Commas, \"quotes\"\nand lines", hoursAgo: 2, duration: 3120),
            Fixtures.episode("E2", title: "=HYPERLINK(\"https://evil.example\")", hoursAgo: 30, duration: 1000, position: 250, finished: false),
            Fixtures.episode("E3", title: "-3 degrees", hoursAgo: nil, finished: false, saved: true),
        ]
        episodes[0].guid = "synapse-41"
        let text = renderer.csv(shows: shows, episodes: episodes)
        let lines = text.components(separatedBy: "\r\n")
        #expect(lines[0] == Renderer.csvColumns.joined(separator: ","))
        #expect(lines.count == 5 && lines[4].isEmpty)
        #expect(lines[1].hasPrefix("\"2026-04-30T07:41:00-05:00\",\"Synapse After Dark\",\"Commas, \"\"quotes\"\" and lines\",\"finished\",\"100\",\"3120\",\"3120\",\"1\",\"no\""))
        #expect(lines[1].contains("\"synapse-41\""))
        #expect(lines[1].contains("\"https://feeds.example.com/synapse.xml\",\"S1\",\"E1\""))
        #expect(lines[2].contains("\"'=HYPERLINK(\"\"https://evil.example\"\")\",\"in progress\",\"25\",\"250\""))
        #expect(lines[3].hasPrefix("\"\",\"Synapse After Dark\",\"'-3 degrees\",\"saved\",\"\",\"\""))
        #expect(Renderer.csvField("-12") == "\"-12\"")
        #expect(Renderer.csvField("@SUM(A1)") == "\"'@SUM(A1)\"")
    }

    @Test func csvKeepsAPrivateFeedOut() {
        let text = renderer.csv(shows: shows, episodes: [Fixtures.episode(show: "S2")])
        #expect(!text.contains("s3cr3t"))
    }

    @Test func jsonForScripts() throws {
        var saved = Fixtures.episode("E2", show: "S2", hoursAgo: nil, finished: false, saved: true)
        saved.savedDate = Fixtures.date
        let text = renderer.json(shows: shows, episodes: [Fixtures.episode(), saved])
        #expect(!text.contains("s3cr3t"))
        let root = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(root["format"] as? String == "podcast-export history 1")
        let showList = try #require(root["shows"] as? [[String: Any]])
        #expect(showList.map { $0["title"] as? String } == ["Apple-only show", "Gone quiet", "Lantern & Ledger <\"Members\">", "Synapse After Dark"])
        let ledger = showList[2]
        #expect(ledger["private_feed"] as? Bool == true)
        #expect(ledger["feed_url"] == nil)
        let synapse = showList[3]
        #expect(synapse["episodes_played"] as? Int == 1)
        #expect(synapse["seconds_listened"] as? Int == 3120)
        #expect(synapse["apple_podcasts_url"] as? String == "https://podcasts.apple.com/podcast/id1000001")
        let episodeList = try #require(root["episodes"] as? [[String: Any]])
        #expect(episodeList.map { $0["id"] as? String } == ["E1", "E2"])
        #expect(episodeList[0]["last_played"] as? String == "2026-04-30T07:41:00-05:00")
        #expect(episodeList[0]["progress_percent"] as? Int == 100)
        #expect(episodeList[1]["saved_date"] as? String == "2026-04-30T09:41:00-05:00")
        #expect(episodeList[1]["show"] as? String == "Lantern & Ledger <\"Members\">")
    }

    // MARK: Text

    @Test func yamlStrings() {
        #expect(Renderer.yaml("Plain") == "\"Plain\"")
        #expect(Renderer.yaml("Say \"hi\" \\ bye") == "\"Say \\\"hi\\\" \\\\ bye\"")
        #expect(Renderer.yaml("Line\nbreak\tand\u{202E}flip") == "\"Line\\nbreak\\tand\\u202Eflip\"")
        #expect(Renderer.yaml("\u{E0001}") == "\"\\U000E0001\"")
    }

    @Test func markdownEscaping() {
        #expect(Renderer.inline("Episode #4: *the* [best] <one> | `code` $5") == "Episode \\#4: \\*the\\* \\[best\\] \\<one\\> \\| \\`code\\` \\$5")
        #expect(Renderer.inline("50% off, ==highlight== and ~~gone~~ %%hidden%%") == "50% off, \\=\\=highlight\\=\\= and \\~\\~gone\\~\\~ \\%\\%hidden\\%\\%")
        #expect(Renderer.inline("Fish &amp; chips & peas") == "Fish \\&amp; chips & peas")
        #expect(Renderer.inline("Two\nlines\u{202E}") == "Two lines")
        #expect(Renderer.heading("  ") == "Untitled show")
    }

    @Test func safeFileNames() {
        #expect(Renderer.safeName("Lantern & Ledger: Members/Only?") == "Lantern & Ledger Members Only")
        #expect(Renderer.safeName("...hidden") == "hidden")
        #expect(Renderer.safeName("[[link]] #tag ^block") == "link tag block")
        #expect(Renderer.safeName("   ") == "Untitled show")
        #expect(Renderer.safeName(String(repeating: "é", count: 200)).utf8.count <= 180)
        #expect(Renderer.safeName("a\u{202E}b\u{0}c") == "a b c")
    }

    @Test func days() {
        #expect(renderer.day(Fixtures.date) == "2026-04-30")
        #expect(Renderer(timeZone: TimeZone(identifier: "Asia/Tokyo")!).day(Fixtures.date) == "2026-04-30")
        #expect(Renderer(timeZone: TimeZone(identifier: "Pacific/Honolulu")!).day(Fixtures.date.addingTimeInterval(-6 * 3600)) == "2026-04-29")
        #expect(Renderer.hours(0) == "0.0" && Renderer.hours(5400) == "1.5")
    }
}
