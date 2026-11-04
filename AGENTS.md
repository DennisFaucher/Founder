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
- Drag & drop: the source is `tableView(_:pasteboardWriterForRow:)` returning one
  `NSURL` per dragged row — NSTableView calls it for every row in the selection and
  merges them into a single drag session, which is what makes multi-file drags
  work (it supersedes `tableView(_:writeRowsWith:to:)`, which AppKit stops calling
  as soon as this method exists). Both
  destinations (`FileTreeDataSource` for folder rows, `FavoritesDataSource` for
  sidebar favorites) loop over every URL from `droppedFileURLs(from:)`, so drops
  move/copy the whole selection; register the tables with
  `registerForDraggedTypes([.fileURL])`.
- Quick Look: `QLPreviewPanel` + `previewItemAt` returning `url as NSURL`; the
  `accepts/begin/endPreviewPanelControl` methods DO need `override` even though the
  app delegate is a plain `NSObject`. Spacebar is caught by the `FileTreeTableView`
  subclass overriding `keyDown`.
- **Edit menu actions must use the standard selectors** `cut(_:)`, `copy(_:)`,
  `paste(_:)`, `selectAll(_:)` — not `copyItem`/`cutItem`-style custom names. Menu
  key equivalents are dispatched by target resolution: a nil-target item is enabled
  (and performed) as soon as *anything* in the key window's responder chain
  implements the action, else it falls through to the app delegate. Nobody but the
  delegate implements a custom selector, so ⌘C/⌘X/⌘V/⌘A always hit the delegate —
  even when the first responder is a text field's field editor or the Quick Look
  panel's text view, which is why selected text in a preview (or in the search
  field) could never be copied. With the standard selectors the focused text view
  answers first and the delegate's file-level implementation is just the fallback.
  Note `NSResponder` declares `selectAll:`, so ⌘A resolves to `NSTableView`'s own
  `selectAll:` and never reaches the delegate.
- Copy writes real `public.file-url` items with
  `NSPasteboard.general.writeObjects(urls as [NSURL])`, like Finder, so files can be
  pasted into other apps; the private `clipboard` array only adds cut-vs-copy intent
  (the pasteboard can't express "move"). `clipboardChangeCount` tracks
  `NSPasteboard.changeCount` so ⌘V ignores that array (and pastes whatever file URLs
  another app copied) once something else has replaced the pasteboard.
- ⌘C inside a key Quick Look panel is handled by a `keyDown` local monitor
  (`installQuickLookCopyMonitor`) rather than left to the responder chain: the panel
  is its own window, and in some states the key equivalent resolved to the app
  delegate's `copy(_:)` (files) while the preview's text view still held the
  selection — so ⌘A-selected text never reached the pasteboard, even though
  mouse-selected text worked. The monitor copies the panel's `NSTextView` selection
  (Quick Look text previews use `QLTextView`, an `NSTextView` subclass) and lets the
  event through untouched when there is no selection, which keeps Finder's behaviour
  of copying the selected files.
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
- `NSTableView.reloadData()` **clears the selection** — row indexes are not carried over
  across a full reload — so any refresh that must keep the selection has to capture the
  selected URLs first and re-select them afterwards (`refreshMetadata`,
  `refreshCurrentDirectory`, the `onDirectoryChanged` handler). Missing it in the 2 s
  metadata timer made a just-clicked file deselect a second or two later;
  `MetadataRefreshTests` covers that case.
- `setupMainWindow` sizes the default window *before* `setFrameAutosaveName`: setting the
  name restores the saved frame, and the `setContentSize` that used to sit below the panes
  ran afterwards, so every launch opened at 900×620 and saved that over the user's size.
  The window tests call `setFrameAutosaveName("")` right after building the window so they
  don't rewrite the app's saved frame.
- The sidebar could not be widened past a point when the path footer was deep: an
  `NSPathControl`'s intrinsic width is the whole path and it has default compression
  resistance, so it set a hard minimum width on the file pane (~975 pt for a path under
  `1273 Washington Street Gloucester/AirBnB/Business Card/Claude/v1.1`). Dragging the
  divider was not broken at all — the pane simply could not get narrower, and the window
  grew instead. The footer now shows only the last two folders behind an ellipsis
  (`updatePathBar`), keeps the full path in the tooltip, maps clicks back to the real
  folders (`realURL(forPathBarURL:)`, the ellipsis goes to the folder holding the first
  shown one), and its compression resistance is dropped to `.defaultLow` so no path can
  set a floor. `PathBarTests.testVeryLongFolderNameDoesNotPinTheSidebar` is the
  regression test: without the resistance change the sidebar collapses to 0 pt.
- The divider is also easier to grab than AppKit's default: `GrabbySplitView` widens the
  hit band from the 1 pt line to ±4 pt, draws the resize cursor across it, and returns
  `true` from `acceptsFirstMouse(for:)`, since the press that activates an inactive
  window otherwise only activates Founder. Without the wider band, a slightly-off grab
  landed on the favorites table and started a row drag.
- The Finder Favorites mirror ("Sync Favorites to Finder" in the View menu) is a
  one-way copy of Founder's favorites into Finder's own Favorites list — the one
  open/save panels show. It has to use `LSSharedFileList` (`CoreServices`), because
  the `.sfl4` file in Application Support belongs to `sharedfilelistd` and writing it
  directly gets clobbered. That API has been marked "no longer supported" since
  10.11 but still works on macOS 26, so every call is best-effort (a failure just
  means the sync skips that round). Three macOS 26 traps, all hit during testing:
  * `kLSSharedFileListItemLast` / `…BeforeFirst` **segfault** when passed to
    `LSSharedFileListInsertItemURL`. Anchor new items after a *real* item from a
    fresh snapshot; chaining ("insert after the one I just added") keeps Founder's
    order. A completely empty Finder sidebar therefore can't be appended to — the
    sync reports that instead of crashing.
  * Paths must be compared with `resolvingSymlinksInPath()`: Founder stores
    `~/OneDrive - WWT/Customer` while Finder resolves
    `~/Library/CloudStorage/OneDrive-WWT/Customer`, so without it every cloud
    favorite looks missing and is re-inserted (the daemon de-duplicates by
    **moving** the existing entry to the end, which silently reshuffles the sidebar).
  * Don't re-read the list immediately after inserting to decide what you own —
    `sharedfilelistd` lags behind the inserts and half the new entries vanish from
    that snapshot. Record ownership from the insert results instead.
- Sync ownership: `finderManagedFavoritePaths` (UserDefaults) lists the entries
  Founder itself added. Only those are ever removed — switching the sync off (or
  launching with it off, which finishes a cleanup the app never got to) deletes the
  owned entries and leaves hand-made Finder favorites untouched. `FinderFavoritesPlan`
  holds the add/remove rules and is unit tested; `FinderFavoritesList` is the thin,
  untested IO layer. The sync never runs under XCTest (`isRunningTests`) so a test
  run can't rewrite the developer's sidebar.
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
Multi-file drag & drop: drag any selection onto a folder row in the list or onto a
folder in the Favorites sidebar (moves within the app, copies from Finder), and
drag out to Finder.
Finder Favorites mirror: View ▸ Sync Favorites to Finder (a checkable item, off by
default) copies Founder's list into Finder's own Favorites so open/save panels show the
same folders. One-way, add/remove only for entries Founder created, nesting flattened
(Finder's sidebar is flat), new entries appended in Founder's order, re-synced after
every favorites change and at launch. Turning it off removes the entries it added.
Possible next steps: column/icon view modes, better Get Info
window, status bar.
