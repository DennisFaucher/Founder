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
   (array of `{path, depth}` dictionaries; a legacy array of path strings is migrated on
   load). `depth` drives sidebar indentation. `onSelect` closure navigates on click.
   Nesting (context-menu Indent/Unindent) follows the classic outliner rule: a row may sit
   at most one level deeper than the row directly above it (`canIndent`), and indent/
   unindent drag the subtree along (`shift`). Depth is purely cosmetic — not validated
   against the filesystem.
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
- Symbolic links: `FileManager.contentsOfDirectory(at:)` fails with `ENOTDIR` ("Not a
  directory") when the URL is a symlink to a directory. `loadDirectory` therefore
  enumerates with `contentsOfDirectory(atPath:)` (which follows the link) and rebuilds
  child URLs against the link, and uses `fileExists(atPath:isDirectory:)` (also
  link-following) for the directory flag. Child `resourceValues` are read with `try?` so
  one unreadable child (e.g. cloud-storage placeholders) can't blank the whole listing.
- "Open in Finder" (file context menu): single directory → `NSWorkspace.open`, otherwise
  `NSWorkspace.activateFileViewerSelecting`; no selection → opens the current directory.
- Image thumbnails: `QLThumbnailGenerator` (QuickLookThumbnailing) with a per-URL cache;
  only for files whose `UTType` conforms to `.image`. `viewFor` returns the generic
  `NSWorkspace.icon` immediately and the async result triggers `onThumbnailReady`, which
  reloads just that row (`reloadData(forRowIndexes:columnIndexes:)`).
- Bundles/packages (`.app`, `.bundle`, `.rtfd`, …) are presented as **files**, like Finder
  does: the folder flag is computed as `isDirectory && !isPackage(url)` in `loadDirectory`
  and the recursive search, so they sort with files, launch on double-click
  (`navigateTo` sends non-directories to `NSWorkspace.open`) and can't be drop targets.
  `isPackage` resolves symlinks first — `/Applications/Safari.app` is a link and the flag
  isn't reported for the link itself. Want to browse a bundle's innards? Use Open in Finder.
- Top-level `let`s in `main.swift` (e.g. the fuzzy scoring weights) are initialised as
  part of the executable's top-level code, so they read as zero for anything that
  `@testable import`s the module — i.e. the tests — even though the app is fine. Put such
  constants on a type (e.g. `enum FuzzyScoring { static let match = 16 }`), which is
  initialised lazily and works in both contexts.
- Long names wrap *and* then get clipped by the 24 pt row: `NSTextField` needs
  `usesSingleLineMode = true`, `maximumNumberOfLines = 1` (and `cell.wraps = false`) to
  truncate rather than wrap. Worse, an **attributed** string carries its own paragraph
  style, so `highlightedName` was wrapping every fuzzy-search result (those are the rows
  that are highlighted) even though the plain `stringValue` path truncated fine — the
  paragraph style has to be set explicitly. `allowsExpansionToolTips` (on `NSControl`)
  makes the `url.path` tooltip show in full instead of being cut off itself; relative
  paths in the Name column during a recursive search routinely need 600 pt+.
- `relativeName(for:base:)` builds its prefix from `base` alone, because `base` already
  ends in `/` when a search is rooted at `/` — appending another `/` compared against
  `//` and silently degraded every row to its bare file name.

## Conventions

- Single-file app for now; split into multiple files only if requested.
- Menu shortcuts mirror Finder (⌘N new folder, ⌘O open, ⌘I info, ⇧⌘. hidden files, etc.).
- Minimum target: macOS 13 (see `Package.swift`).

## Status / TODO

Draft 0.1 is functional: browse, navigate (back/forward, Go menu, enclosing folder,
path bar), favorites with add/remove/reorder (drag & drop in the sidebar + Move Up/Down)
and nesting (context-menu Indent/Unindent, classic outliner rule as described above),
open / open with / trash / delete / rename / info, cut-copy-paste, create folder/file,
hidden files toggle, drag & drop (move/copy within the app and to/from Finder; drop
onto a folder row to move into it), "Open in Finder", column sorting (click Name/Size/Date
header to sort and click again to reverse; folders always grouped first; the active column's
header title gets a ▲/▼ suffix via `FileTreeDataSource.updateHeaderTitles`). The sort choice is
global and remembered: `FileTreeDataSource.sortKey`/`sortAscending` persist to UserDefaults
(`sortKey`/`sortAscending`) and are applied to every directory load, so the same sort sticks
across navigation and launches, and `syncSortIndicator` keeps the header in sync.
Quick Look (context menu item
+ Spacebar; `QLPreviewPanel` with the app delegate as dataSource), image thumbnails in
the Name column, and filtering search
(current folder, plus a "Recursive" checkbox that searches subfolders when a query is
present). Search runs on an explicit button/Enter (not live) and recursive traversal is
async + cancellable with a spinner and live scan/match counts. The status line reports
items **scanned**, not just matches (a match-gated report left it stuck on "Searching…"
for selective queries), and it deliberately stays on screen after the search with the
totals ("5,000 found of 5,401 scanned · 406 ms", or just "N found of M scanned" for a
plain filtered listing, "Search cancelled · N found" after Cancel) — a fuzzy crawl over a
big tree finishes in a couple of hundred milliseconds, so hiding the line on completion
meant it flashed by unreadably. `onSearchFinished` therefore carries
`(scanned, found, elapsed, cancelled)` and `lastScannedCount` holds the plain-listing
count. The recursive results also reload the table themselves
(`onDirectoryChanged?()`) — otherwise they only appeared when the 2 s metadata timer
fired — and `isCrawling` makes `watchDirectory` ignore events while a crawl is running,
so a crawl rooted at a busy directory (cloud sync, caches) no longer restarts itself.
The query is fuzzy,
fzf-style (`FuzzyQuery` / `fuzzySubsequenceMatch` in main.swift): whitespace-separated
terms that must all match, with `!` to exclude, `'` for an exact substring, `^`/`$` to
anchor, and smart-case (a term containing an uppercase letter matches case-sensitively).
There is no invalid input, so no error path. Matches are scored (word/camelCase
boundaries and consecutive runs score higher, gaps are penalised) and the list is ranked
best-first whenever a query is active — the column sort only breaks ties. Matched
characters are highlighted in the Name column via `matchPositions` +
`highlightedName`; the "?" button next to the search field (`showSearchSyntax`) explains
the syntax. Note the search matches `displayName(for:)` (the relative path while
recursively searching) so highlight offsets line up with the rendered row.
Possible next steps: drop files onto a sidebar favorite to move them there, column/icon
view modes, better Get Info window, status bar.
