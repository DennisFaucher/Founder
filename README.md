# Founder 

<img width="115" height="101" alt="Flounder" src="https://github.com/user-attachments/assets/a4f41434-dda0-4f81-ac4e-fdb09c8f053d" />


A macOS Finder clone written in Swift and AppKit.

<img width="1258" height="891" alt="Screenshot 2026-10-15 at 5 13 31 PM" src="https://github.com/user-attachments/assets/e429a8d9-3428-4f9c-ad3d-daca4bdaf4c0" />

## Features

- Two-pane layout: favorites sidebar (left) and file browser (right) with Name, Size,
  and Date Modified columns.
- Real filesystem browsing with back/forward history, a Go menu, enclosing folder, and a
  path bar.
- Favorites stored in `UserDefaults`, with add/remove and reordering (drag & drop in the
  sidebar, plus Move Up/Move Down).
- Open, open with, move to trash, delete, rename, Get Info, cut/copy/paste, and
  create folder/file.
- Drag and drop: move/copy within the app and to/from Finder, drop onto a folder row to
  move into it, and drop onto a sidebar favorite to move files there.
- Column sorting: click the Name, Size, or Date header to sort, click again to reverse.
  Folders are always grouped first.
- Quick Look via the context menu or the Spacebar.
- Hidden-file toggle.
- Search with an optional recursive mode. The query is a case-insensitive regular
  expression; recursive traversal runs asynchronously and is cancellable, with a spinner
  and live scan/match counts.

## Requirements

- macOS 13 or later
- Swift 5.9+ toolchain (Xcode or the standalone Swift toolchain)

## Build and run

```bash
swift build              # debug build
swift test               # run tests
./build_app.sh           # release build, assembles dist/Founder.app
open dist/Founder.app    # launch the app
```

The app is designed to run as a `.app` bundle. `build_app.sh` builds the release binary,
assembles `dist/Founder.app` with an `Info.plist`, copies the icon, and ad-hoc signs it.
Regenerate the icon with `./make_icon.sh`, which produces `Assets/Founder.icns` from
`Assets/icon-source.png`.

## Project structure

```
Package.swift                 SwiftPM manifest (executable target + test target)
Sources/Founder/main.swift    the entire app (entry point, app delegate, data sources)
Tests/FounderTests/           XCTest unit tests
Assets/icon-source.png        app icon source art
Assets/Founder.icns           generated app icon
build_app.sh                  release build + .app assembly
make_icon.sh                  regenerate the .icns from the source PNG
AGENTS.md                     notes and conventions for agents working on the project
```

## Search syntax

The search field accepts a case-insensitive regular expression. Because the pattern is
unanchored, a plain word like `report` matches any name containing "report".

| Want | Type |
| --- | --- |
| any characters | `.*` |
| any single character | `.` |
| names ending in `.txt` | `.*\.txt$` |
| names starting with `img_` then digits | `^img_\d+` |

An invalid pattern (for example `*.txt` or a lone `(`) shows an inline error instead of
running the search.
