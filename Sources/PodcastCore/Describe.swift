import Foundation

/// The wording shown in the menu, the window, the command line and the notes.
public enum Describe {
    /// An episode's length, like `52 min` or `1 hr 4 min`.
    public static func duration(_ seconds: Double) -> String {
        let clamped = min(max(0, seconds.isFinite ? seconds : 0), PodcastLibrary.longest)
        let minutes = Int((clamped / 60).rounded())
        if minutes < 60 { return "\(max(minutes, clamped > 0 ? 1 : 0)) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) hr" : "\(h) hr \(m) min"
    }

    /// How long you've listened, like "about 45 min" or "about 210 hours".
    public static func listened(_ seconds: Double) -> String {
        let hours = seconds / 3600
        if hours < 1 { return "about " + duration(seconds) }
        let rounded = hours < 10 ? (hours * 10).rounded() / 10 : hours.rounded()
        let text = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
        return "about \(text) \(rounded == 1 ? "hour" : "hours")"
    }

    public static func count(_ value: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(value) \(value == 1 ? singular : plural ?? singular + "s")"
    }

    /// How long ago, in the menu's words: "just now", "5 min ago", "3 hr ago", "yesterday", "4 days ago".
    public static func relative(_ date: Date, now: Date) -> String {
        let seconds = min(now.timeIntervalSince(date), 1e11)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) hr ago" }
        let days = Int(seconds / 86400)
        return days == 1 ? "yesterday" : "\(days) days ago"
    }

    /// A path with the home folder written as `~`.
    public static func path(_ url: URL, home: URL) -> String {
        let path = url.standardizedFileURL.path, base = home.standardizedFileURL.path
        if path == base { return "~" }
        if path.hasPrefix(base + "/") { return "~" + path.dropFirst(base.count) }
        return path
    }

    /// Finished, how far through, or saved, in the window's words.
    public static func status(_ episode: Episode) -> String {
        if !episode.listened { return "Saved" }
        if episode.finished { return "Finished" }
        guard episode.duration > 0 else { return "Started" }
        return "\(Int((episode.progress * 100).rounded(.down)))% played"
    }

    /// What an export did, in one line.
    public static func summary(_ report: ExportReport) -> String {
        var parts: [String] = []
        if report.newPlays > 0 { parts.append("added \(count(report.newPlays, "new play"))") }
        if report.newShows > 0 { parts.append("\(count(report.newShows, "new show"))") }
        if !report.written.isEmpty && parts.isEmpty { parts.append("updated \(count(report.written.count, "file"))") }
        if !report.kept.isEmpty { parts.append("kept \(count(report.kept.count, "edited file"))") }
        if report.keptOPML { parts.append("kept the last OPML file") }
        if !report.failed.isEmpty { parts.append("\(report.failed.count) failed") }
        if parts.isEmpty { return "Nothing new" }
        return capitalized(parts.joined(separator: ", "))
    }

    static func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    public static func problem(_ error: LibraryError) -> String {
        switch error {
        case .notFound: "No Apple Podcasts library on this Mac yet. Open Apple Podcasts once and follow a show."
        case .noPermission: "Podcast Export needs Full Disk Access to read your Apple Podcasts library."
        case .unrecognized(let detail): detail
        }
    }

    public static func problem(_ error: ExportError) -> String {
        switch error {
        case .insideLibrary: "Choose a folder outside the Apple Podcasts library. Nothing is ever written there."
        case .unreadableRecord: "The folder's \(Exporter.recordName) can't be read, so exporting could lose history it holds. Move it out of the folder to start over."
        case .newerRecord: "This folder was exported by a newer version of Podcast Export. Update to keep exporting to it."
        case .busy: "Another export into this folder is running. Try again once it's done."
        case .cannotWrite(let detail): "Couldn't write to the export folder: \(detail)"
        }
    }
}
