# Contributing

Thanks for helping out! Bug reports, ideas and pull requests are all welcome.

## Reporting a show or episode it read wrong

If a show is missing from the OPML file, an episode has the wrong date or progress, or another podcast app won't import the file, open a [bug report](https://github.com/stanczykwyatt/podcast-export/issues/new?template=bug.yml) with your macOS version and what you expected. Please don't attach your OPML file or paste a feed's address: describe it instead, like "a show from a paid membership" or "a show I follow on my iPhone but not this Mac".

If Apple Podcasts changes how it stores your library in a new macOS version, the output of this command helps the most. It lists only the database's table and column names, nothing you've listened to:

```bash
sqlite3 -readonly "file:$HOME/Library/Group Containers/243LU875E5.groups.com.apple.podcasts/Documents/MTLibrary.sqlite?immutable=1" ".schema ZMTPODCAST" ".schema ZMTEPISODE"
```

## Getting started

You need macOS 14 or later and Swift 6 (Xcode 16 or the Command Line Tools).

```bash
swift test                # run the tests
scripts/build-app.sh      # build "Podcast Export.app" and podcast-export into ./build
open "build/Podcast Export.app"
```

Reading the library, the OPML, notes and history files, the export record, search, the command line tool and all the wording live in `Sources/PodcastCore`, with tests in `Tests/PodcastCoreTests`. Those tests build made-up libraries in throwaway folders: databases shaped like Apple Podcasts' own. Changes to what goes in a file belong in `Render.swift`; changes to what's kept between runs belong in `Exporter.swift`, with a test that describes what you listened to.

The menu bar app, the menu and the window are in `Sources/PodcastExport`, tested in `Tests/PodcastExportTests` with a made-up library and windows that are never shown. No test reads your Apple Podcasts library, writes outside a throwaway folder or puts anything on screen.

To redraw the art: `swift scripts/make-icon.swift`, `swift scripts/make-art.swift`, and `SCREENSHOT_DIR=docs swift test --filter Window` for the screenshots.

## Ground rules

- **No network access, ever.** Pull requests that fetch feeds, add a network entitlement or add third-party analytics won't be merged.
- **Read-only.** Podcast Export never changes, moves or deletes anything in Apple Podcasts, and never deletes anything anywhere.
- **Your files win.** Never overwrite a file the exporter didn't write, or one you've changed.
- **Private feeds go in the OPML file only.** A feed address with a key in it is a password.
- **No show notes or transcripts.** They belong to the shows. The app reads titles, dates, progress and links, and CI checks it reads nothing more.
- **Least access.** No new entitlements or folders without a very good reason.
- **No new dependencies** without a very good reason. The app has none today, which keeps it easy to audit.
- **Made-up shows only** in screenshots, art, tests and bug reports.
- Run `swift test` before opening a pull request, and add tests for changes to `PodcastCore`.
- Keep commits small, with a short message saying what changed and why.

## Security issues

Please don't open public issues for vulnerabilities. See [SECURITY.md](SECURITY.md).
