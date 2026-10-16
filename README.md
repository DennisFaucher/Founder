# Founder 

<img width="115" height="101" alt="Flounder" src="https://github.com/user-attachments/assets/a4f41434-dda0-4f81-ac4e-fdb09c8f053d" />


A macOS Finder clone written in Swift and AppKit.

<img width="1256" height="797" alt="Screenshot 2026-10-16 at 10 36 04 AM" src="https://github.com/user-attachments/assets/70562769-19e8-4c21-b743-69c9a9d86150" />

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
- Search with an optional recursive mode. The query is fuzzy (fzf-style): whitespace-separated
  terms that must all match, with `!` to exclude, `'` for an exact substring, and `^`/`$` to
  anchor. Results are ranked best-first with the matched characters highlighted, and recursive
  traversal runs asynchronously and is cancellable, with a spinner and live scan counts.

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

The search field is fuzzy, in the spirit of fzf. Terms are separated by whitespace and
**every** term must match, but the letters only have to appear in order — so `rfp` matches
`ReserveForPlan.pdf`.

| Want | Type |
| --- | --- |
| an exact substring | `'report` |
| must start with | `^2025` |
| must end with | `.pdf$` |
| exclude matches | `!archive` |
| all of several terms | `pr rfp` |

Results are ranked by match quality (word and camelCase boundaries and consecutive runs score
higher, gaps are penalised) and the matched characters are highlighted in the Name column.
Terms containing an uppercase letter are matched case-sensitively; everything else ignores
case. There is no invalid input, so a malformed-looking query simply matches nothing. The `?`
button next to the field shows this syntax in the app.

Search runs on the button (or Return), not as you type, and the status line reports how many
items were **scanned**, not only how many matched — e.g. `5,000 found of 5,401 scanned ·
406 ms` — and stays up after the search finishes. Recursive traversal runs on a background
queue and can be cancelled.
