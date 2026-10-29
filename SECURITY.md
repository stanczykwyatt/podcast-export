# Security

Podcast Export reads what you listen to, which says a lot about you, and the feed addresses of shows you pay for, which work like passwords. So it's built to do that with as little access as possible, and to change nothing.

## Reporting a vulnerability

Please report security problems privately through **Security → Report a vulnerability** on this repository, not in a public issue. You'll get a reply within a few days.

## What Podcast Export can access

| | |
|---|---|
| **The Apple Podcasts library, read-only** | `~/Library/Group Containers/243LU875E5.groups.com.apple.podcasts/Documents`, through one read-only sandbox exception. It reads the shows and the episodes you've played or saved from Apple Podcasts' database. macOS blocks it from writing there. |
| **Full Disk Access** | macOS protects Apple Podcasts' library, so reading it needs Full Disk Access, which you turn on yourself. The sandbox still applies on top of it, so this doesn't widen what the app can reach. |
| **The folder you choose** | Read and write, after you pick it in the standard macOS folder picker. It's remembered with a security-scoped bookmark, which only works for this app. |
| **The file you save** | When you choose Save Subscriptions as OPML…, the one file you name in the save dialog. |
| **Its own temporary folder** | Where it copies Apple Podcasts' database to read it. See below. |
| **Two small files in the export folder** | `.podcast-export.json`, the record of what's been exported, and `.podcast-export.lock`, an empty file that keeps two exports into the same folder from running at once. |
| **Its own settings** | Your export folder and options, stored in the app's sandbox container. |

## What it can't access

- **The internet.** The app runs in the App Sandbox without a network entitlement, so macOS blocks every connection. It never fetches a feed or artwork. CI checks every build for this, and that the app never starts another program, which could send something out another way. The one page it ever opens is the Full Disk Access page in System Settings.
- **The rest of your files.** Documents, downloads, desktop, photos and everything else are blocked by the sandbox, even with Full Disk Access on. A sandboxed copy with the same exception was tested reading Apple Podcasts' folder and then Documents: the first worked and the second was denied.
- **Other apps.** It has no Apple Events entitlement and no Accessibility permission, so it can't read or control other apps, Apple Podcasts included.
- **Show notes, transcripts and audio.** It reads only titles, dates, lengths, progress, IDs and web links. CI checks that the columns holding descriptions, transcripts, audio addresses and downloads are never named in the code.
- **Changing or deleting anything.** Its access to Apple Podcasts is read-only, and its code never deletes a file; CI checks for that. In the export folder, it never overwrites a file it didn't write, and only rewrites one it wrote if something in it changed and you haven't touched it since. (SQLite tidies up its own journal next to the scratch copy in the app's temporary folder. That's the only file that ever goes away.)

Check it yourself on any copy of the app:

```bash
codesign -d --entitlements - "/Applications/Podcast Export.app"
```

The only entitlements are `com.apple.security.app-sandbox`, the read-only Apple Podcasts folder, `com.apple.security.files.user-selected.read-write` for the folder or file you choose, and `com.apple.security.files.bookmarks.app-scope` to remember the folder.

## How it handles things

- **Apple Podcasts' database is never opened in place.** Apple Podcasts writes your latest plays to a journal next to its database before folding them in. Opening that database with SQLite, even read-only, can create or change those journal files. So Podcast Export copies the database and its journal into its own temporary folder and opens only the copy. If Apple Podcasts folds the journal in or starts a new one while they're being copied, it copies them again, so the pair always matches. Reads take turns, so the app and the command line tool never share a half-written copy. The copy is emptied as soon as it's been read, since it holds everything in the library, private feeds included. It never leaves your Mac.
- **Only episodes with a sign of listening or saving are read,** so a library holding every episode of every show isn't loaded in full.
- **Private feeds stay in one file.** A feed address with a user name or password, a query item that looks like a key or token, a members' word like `private` or `premium` in its path, or a long random-looking part like a personal token is a secret: anyone with it can listen as you. The check errs on the side of private. A record written by an older version is checked again when it's read. It's written only to the OPML file you asked for. It's left out of the notes, the CSV and JSON history, the command line tool's lists and the export record. The menu and the command line tool say when the OPML file holds one.
- **What's in the library is treated as untrusted.** The command line tool strips control characters from titles before printing them, so a title can't send your terminal an escape sequence. Links are kept only if they're plain `http` or `https` addresses with no spaces, quotes, angle brackets, control characters or invisible marks. IDs are kept only if they're letters, digits, dashes and dots. Titles have path separators and anything a file name or Obsidian link can't hold removed from file names, which can't start with a dot. In notes, front matter is quoted and Markdown and Obsidian formatting in titles is escaped. In the OPML file, XML's special characters are escaped and anything XML can't hold is removed. In the CSV file, a title that would start a spreadsheet formula, like `=`, `+`, `-` or `@`, gets a leading apostrophe. Dates, lengths and counts far outside any real episode's are treated as damage and clamped or dropped, so they can't crash it.
- **The export record is treated as untrusted too.** It lives in a folder you might sync or share, so every path in it must be a plain file name, or a folder and a file name, inside the export folder. A record that points anywhere else, or whose entries don't match their own IDs, is refused, and nothing is exported until it's fixed. Before anything is written, its folder is checked again to be inside the export folder and outside Apple Podcasts' library, after following links.
- **Records it can't read stop the export.** If the folder's `.podcast-export.json` is damaged or from a newer version, it stops rather than starting over, which would lose history only the record still holds.
- **A library that's still loading changes nothing.** If Apple Podcasts lists no shows at all, or fewer than half the shows you followed last time, as it can while it's still loading, syncing or signed out, the export adds what's there but keeps the last OPML file and marks no show unfollowed. If you really did unfollow them, delete `Podcasts.opml` and export again. A new Mac or a rebuilt library, where Apple Podcasts gives everything new IDs, is recognized by its Apple Podcasts IDs and feeds, so nothing is exported twice.
- **Nothing is written inside the Apple Podcasts library,** or anywhere in the group container that holds it. The export folder, or the file you save, can't be in it. The command line tool checks against both the library it reads and your real one, so reading a backup can't write into the original.
- **The command line tool isn't sandboxed,** since it runs as you in your terminal. It uses the same code as the app, so it reads Apple Podcasts the same way, through a copy, and writes only into the folder you give it. `podcast-export opml` prints to your terminal, so private feeds appear there; that's the point of it. CI checks that only the export code writes files.
- It has no dependencies. Every line that runs is in this repository.
