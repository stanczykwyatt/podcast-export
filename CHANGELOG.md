# Changelog

## 0.1.0 (2026-11-07)

First release.

- **Save your Apple Podcasts subscriptions as OPML,** the file Overcast, Pocket Casts, Castro, AntennaPod and most other podcast apps import.
- **Export to a folder you choose:** the OPML file, an overview note of every show with how much you've listened, a note for each show with every episode you've played and saved, and `Listening History.csv`. `Listening History.json` too, if you turn it on.
- **Only what's new on each run,** with a record in the export folder so nothing is duplicated, and plays stay in the export even after Apple Podcasts forgets them.
- **Never overwrites your edits:** a file you've changed is left alone, and files already in the folder are never touched.
- **Private feeds stay in the OPML file:** feed addresses with a personal key are left out of the notes, the history and the record.
- **Automatic export,** off until you turn it on.
- **Obsidian-friendly notes,** with front matter, tags and links between notes, or standard Markdown links.
- **A window to search your shows and episodes,** with how far you got in each, and a button to copy a show's feed.
- **The `podcast-export` command line tool** to list shows and plays, print the OPML and export.
- **Open at login**, on by default and easy to turn off.
- Runs in the App Sandbox with no network access, read-only access to Apple Podcasts, and write access only to the folder or file you choose.
