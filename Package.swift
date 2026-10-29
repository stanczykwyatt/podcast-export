// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PodcastExport",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PodcastExport", targets: ["PodcastExport"]),
        .executable(name: "podcast-export", targets: ["PodcastExportCLI"]),
    ],
    targets: [
        // Reading the Apple Podcasts library, and writing the OPML, notes, history files and
        // export record, with nothing tied to the app, so it can be tested against made-up
        // libraries in throwaway folders.
        .target(name: "PodcastCore"),
        .executableTarget(name: "PodcastExport", dependencies: ["PodcastCore"]),
        .executableTarget(name: "PodcastExportCLI", dependencies: ["PodcastCore"]),
        .testTarget(name: "PodcastCoreTests", dependencies: ["PodcastCore"]),
        // The app's glue, tested with a made-up library and windows that are never shown.
        .testTarget(name: "PodcastExportTests", dependencies: ["PodcastExport", "PodcastCore"]),
    ]
)
