# AGENTS

Instructions for AI agents working on the Founder project (macOS Finder clone in Swift).

## Build & Run

```bash
swift build              # debug build
swift test               # run tests
./build_app.sh           # release build + assemble dist/Founder.app
./make_icon.sh           # regenerate Assets/Founder.icns from Assets/icon-source.png
open dist/Founder.app    # launch the app
```

The app MUST run as a `.app` bundle (use `build_app.sh`) — a bare executable works but
`open dist/Founder.app` is the intended test path.

## Project Structure

- `Package.swift` — SwiftPM manifest; executable target `Founder`, test target `FounderTests`
- `Sources/Founder/main.swift` — **the entire app** (entry point, app delegate, data sources)
- `Tests/FounderTests/` — XCTest unit tests
- `build_app.sh` — builds release binary and assembles `dist/Founder.app` with Info.plist (ad-hoc signed)
- `Assets/icon-source.png` — square source art for the app icon; `Assets/Founder.icns` is generated
- `make_icon.sh` — regenerates `Assets/Founder.icns` from the source PNG (pads to square, `iconutil`)
- `dist/Founder.app` — build output (do not edit by hand)

## Architecture (all in main.swift)

1. **Entry point** — top-level code in `main.swift` (NOT `@main`; the file name `main.swift`
   makes it top-level-code entry, `@main` will not compile here).
2. **`FounderAppDelegate`** — owns window, split view, both table views, menu construction,
   navigation history, clipboard, and all `@objc` action methods (menu bar + context menus
   dispatch to it through the responder chain — keep actions `@objc` on the delegate).
3. **`FavoritesDataSource`** — favorites list backed by `UserDefaults` key `favorites`
   (array of absolute path strings). `onSelect` closure navigates on click.
4. **`FileTreeDataSource`** — loads real directory contents via `FileManager` into
   `entries: [URL]`; supports hidden-file toggle; caches `FileAttributeKey` attributes
   per URL for size/date columns.

## AppKit Gotchas Hit in This Project

- `NSMenu.addItem(withTitle:submenu:)` does **not** exist; create
  `NSMenuItem(title:action:keyEquivalent:"")`, set `.submenu`, then `addItem`.
- `NSSplitView.vertical` was renamed to `isVertical`.
- Use `FileAttributeKey` (not `String`) as the attribute-dictionary key type.
- Curly quotes (“ ”) are fine inside string literals but are compile errors inside
  `\(...)` interpolations — use straight `"` there.
- Context menus: use `NSMenuDelegate.menuNeedsUpdate` to select the clicked row and
  enable/disable items; `tableView.clickedRow` identifies the right-clicked row.
- `NSTableView.setDraggingSourceOperationMask(_:forLocation:)` is now
  `...(_:forLocal:)` in the macOS 26/27 SDK.
- Drag & drop: implement `writeRowsWith` (source) plus
  `validateDrop`/`acceptDrop` (destination) on `FileTreeDataSource`; register the
  table with `registerForDraggedTypes([.fileURL])`.
- Quick Look: `QLPreviewPanel` + `previewItemAt` returning `url as NSURL`; the
  `accepts/begin/endPreviewPanelControl` methods DO need `override` even though the
  app delegate is a plain `NSObject`. Spacebar is caught by the `FileTreeTableView`
  subclass overriding `keyDown`.
- Column sorting: set `sortDescriptorPrototype` on each `NSTableColumn` and implement
  `tableView(_:sortDescriptorsDidChange:)` on the data source; re-sort in place so it
  also works on async recursive-search results.

## Conventions

- Single-file app for now; split into multiple files only if requested.
- Menu shortcuts mirror Finder (⌘N new folder, ⌘O open, ⌘I info, ⇧⌘. hidden files, etc.).
- Minimum target: macOS 13 (see `Package.swift`).

## Status / TODO

Draft 0.1 is functional: browse, navigate (back/forward, Go menu, enclosing folder,
path bar), favorites with add/remove/reorder (drag & drop in the sidebar + Move Up/Down),
open / open with / trash / delete / rename / info, cut-copy-paste, create folder/file,
hidden files toggle, drag & drop (move/copy within the app and to/from Finder; drop
onto a folder row to move into it), column sorting (click Name/Size/Date header to sort
and click again to reverse; folders always grouped first), Quick Look (context menu item
+ Spacebar; `QLPreviewPanel` with the app delegate as dataSource), and filtering search
(current folder, plus a "Recursive" checkbox that searches subfolders when a query is
present). Search runs on an explicit button/Enter (not live) and recursive traversal is
async + cancellable with a spinner and live scan/match counts. The query is a
case-insensitive regular expression (compiled once per search via `compileSearchPattern`
/ `matchesSearchPattern`; plain substrings still match because regex is unanchored).
Invalid patterns surface an inline error instead of running the search.
Possible next steps: drop files onto a sidebar favorite to move them there, column/icon
view modes, better Get Info window, status bar.
