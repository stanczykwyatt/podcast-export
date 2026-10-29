import Foundation
import Testing
@testable import PodcastCore

@Suite("Shows and episodes")
struct ShowsTests {
    @Test func progressAndTimeListened() {
        var episode = Fixtures.episode(duration: 3000, position: 750, finished: false)
        #expect(episode.listened)
        #expect(episode.progress == 0.25)
        #expect(episode.timeListened == 750)
        episode.finished = true
        #expect(episode.progress == 1 && episode.timeListened == 3000)
        let marked = Fixtures.episode(hoursAgo: nil, duration: 3000, position: 0, finished: true)
        #expect(marked.playCount == 1)
        let unheard = Episode(id: "X", showID: "S1", title: "Marked played", duration: 3000, finished: true)
        #expect(!unheard.listened && unheard.timeListened == 0)
        let unknownLength = Episode(id: "Y", showID: "S1", title: "No length yet", position: 120, lastPlayed: Fixtures.date)
        #expect(unknownLength.progress == 0 && unknownLength.timeListened == 120)
        let past = Episode(id: "Z", showID: "S1", title: "Past the end", duration: 100, position: 500, lastPlayed: Fixtures.date)
        #expect(past.progress == 1 && past.timeListened == 100)
    }

    @Test func spotsPrivateFeeds() {
        #expect(Links.looksPrivate("https://members.example.net/feed?auth=abc"))
        #expect(Links.looksPrivate("https://example.com/rss?api_key=abc"))
        #expect(Links.looksPrivate("https://user:pw@example.com/rss"))
        #expect(Links.looksPrivate("https://example.com/rss?Token=abc&format=xml"))
        #expect(Links.looksPrivate("https://example.com/rss?id=0123456789abcdef0123"))
        #expect(!Links.looksPrivate("https://example.com/rss?format=xml"))
        #expect(!Links.looksPrivate("https://example.com/rss?id=42"))
        #expect(!Links.looksPrivate("https://feeds.example.com/show.xml"))
        let show = Fixtures.show(feed: "https://members.example.net/feed?auth=abc")
        #expect(show.hasPrivateFeed && show.publicFeedURL == nil)
        #expect(show.redacted.feedURL == nil && show.redacted.hasPrivateFeed)
        #expect(Fixtures.show().redacted == Fixtures.show())
    }

    @Test func acceptsOnlyPlainWebLinks() {
        #expect(Links.web(" https://example.com/feed.xml\n") == "https://example.com/feed.xml")
        #expect(Links.web("HTTP://EXAMPLE.COM") == "HTTP://EXAMPLE.COM")
        for bad in ["", "example.com/feed", "javascript:alert(1)", "file:///etc/passwd", "https://", "https://exa mple.com",
                    "https://example.com/a>b", "https://example.com/\u{202E}gpj", "https://example.com/\n/x", "feed://example.com/rss"] {
            #expect(Links.web(bad) == nil, "Accepted \(bad)")
        }
        #expect(Links.web("https://example.com/" + String(repeating: "a", count: 5000)) == nil)
    }

    @Test func statsPerShow() {
        let episodes = [
            Fixtures.episode("A", hoursAgo: 2, duration: 3600, finished: true),
            Fixtures.episode("B", hoursAgo: 30, duration: 3600, position: 1800, finished: false),
            Fixtures.episode("C", hoursAgo: nil, duration: 3600, finished: false, saved: true),
            Fixtures.episode("D", show: "S2", hoursAgo: 5, duration: 600, finished: true),
        ]
        let stats = ShowStats.all(episodes)
        let first = stats["S1"]!
        #expect(first.played == 2 && first.finished == 1 && first.saved == 1)
        #expect(first.timeListened == 5400)
        #expect(first.lastPlayed == Fixtures.date.addingTimeInterval(-2 * 3600))
        #expect(first.firstPlayed == Fixtures.date.addingTimeInterval(-30 * 3600))
        #expect(stats["S2"]?.played == 1)
        #expect(stats["S3"] == nil)
    }

    @Test func ordersHistoryAndTitles() {
        let library = Library(
            shows: [Fixtures.show("B", title: "show 10"), Fixtures.show("A", title: "Show 9"), Fixtures.show("C", title: "Apple", following: false)],
            episodes: [Fixtures.episode("old", hoursAgo: 10), Fixtures.episode("new", hoursAgo: 1), Fixtures.episode("tie2", hoursAgo: 5), Fixtures.episode("tie1", hoursAgo: 5)]
        )
        #expect(library.following.map(\.title) == ["Show 9", "show 10"])
        #expect(library.history.map(\.id) == ["new", "tie2", "tie1", "old"])
    }
}

@Suite("Wording")
struct DescribeTests {
    @Test func durations() {
        #expect(Describe.duration(0) == "0 min")
        #expect(Describe.duration(20) == "1 min")
        #expect(Describe.duration(52 * 60) == "52 min")
        #expect(Describe.duration(3600) == "1 hr")
        #expect(Describe.duration(3600 + 4 * 60 + 10) == "1 hr 4 min")
        #expect(Describe.duration(.infinity) == "0 min")
        #expect(Describe.duration(1e20) == "720 hr")
    }

    @Test func timeListened() {
        #expect(Describe.listened(45 * 60) == "about 45 min")
        #expect(Describe.listened(3600) == "about 1 hour")
        #expect(Describe.listened(5400) == "about 1.5 hours")
        #expect(Describe.listened(210 * 3600 + 1000) == "about 210 hours")
    }

    @Test func summaries() {
        var report = ExportReport()
        #expect(Describe.summary(report) == "Nothing new")
        report.written = ["Podcasts.md"]
        #expect(Describe.summary(report) == "Updated 1 file")
        report.newPlays = 3
        report.newShows = 1
        report.kept = ["Podcasts.opml"]
        report.failed = [.init(file: "x", reason: "y")]
        #expect(Describe.summary(report) == "Added 3 new plays, 1 new show, kept 1 edited file, 1 failed")
    }

    @Test func relativeDates() {
        let now = Fixtures.date
        #expect(Describe.relative(now, now: now) == "just now")
        #expect(Describe.relative(now.addingTimeInterval(-300), now: now) == "5 min ago")
        #expect(Describe.relative(now.addingTimeInterval(-3 * 3600), now: now) == "3 hr ago")
        #expect(Describe.relative(now.addingTimeInterval(-30 * 3600), now: now) == "yesterday")
        #expect(Describe.relative(now.addingTimeInterval(-4 * 86400), now: now) == "4 days ago")
    }

    @Test func paths() {
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(Describe.path(URL(fileURLWithPath: "/Users/someone/Notes/Podcasts"), home: home) == "~/Notes/Podcasts")
        #expect(Describe.path(home, home: home) == "~")
        #expect(Describe.path(URL(fileURLWithPath: "/Users/someone2/x"), home: home) == "/Users/someone2/x")
    }

    @Test func episodeStatus() {
        #expect(Describe.status(Fixtures.episode(finished: true)) == "Finished")
        #expect(Describe.status(Fixtures.episode(duration: 1000, position: 333, finished: false)) == "33% played")
        #expect(Describe.status(Fixtures.episode(hoursAgo: nil, finished: false, saved: true)) == "Saved")
        #expect(Describe.status(Episode(id: "x", showID: "S1", title: "t", position: 10, lastPlayed: Fixtures.date)) == "Started")
    }
}
