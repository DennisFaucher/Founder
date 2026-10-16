//
//  main.swift
//  Founder
//
//  Created by Dennis Faucher on 10/15/2026.
//

import AppKit
import Quartz
import QuickLookThumbnailing
import UniformTypeIdentifiers

let favoriteRowPasteboardType = NSPasteboard.PasteboardType("com.dennisfaucher.founder.favoriteRow")

// MARK: - Fuzzy search (fzf-style)

struct FuzzyMatch {
    var score: Int
    var positions: [Int]
}

/// One whitespace-separated piece of a query. `exact`/`fromStart`/`toEnd` mark
/// the non-fuzzy anchor operators (`'`, `^`, `$`); `negate` is the `!` prefix.
private struct FuzzyTerm {
    var negate = false
    var exact = false
    var fromStart = false
    var toEnd = false
    var text = ""
    var caseSensitive = false
}

/// A query in the spirit of fzf's search syntax: whitespace-separated terms that
/// must all match (AND). A term may be prefixed with `!` to exclude matches and
/// `'` for an exact substring, `^` to anchor at the start, or suffixed with `$`
/// to anchor at the end. Terms containing an uppercase letter match
/// case-sensitively; everything else is case-insensitive.
struct FuzzyQuery {
    private var terms: [FuzzyTerm] = []

    var isEmpty: Bool { terms.isEmpty }

    init(_ raw: String) {
        for token in raw.split(whereSeparator: { $0.isWhitespace }) {
            var term = FuzzyTerm()
            var text = String(token)
            if text.hasPrefix("!") {
                term.negate = true
                text.removeFirst()
            }
            if text.hasPrefix("'") {
                term.exact = true
                text.removeFirst()
            } else {
                if text.hasPrefix("^") {
                    term.fromStart = true
                    text.removeFirst()
                }
                if text.count > 1, text.hasSuffix("$") {
                    term.toEnd = true
                    text.removeLast()
                }
            }
            guard !text.isEmpty else { continue }
            term.text = text
            term.caseSensitive = text.contains { $0.isUppercase }
            terms.append(term)
        }
    }

    /// Returns the combined score and highlighted character offsets when every
    /// term matches, or nil when any required term misses or any `!` term hits.
    func match(_ candidate: String) -> FuzzyMatch? {
        var score = 0
        var positions: Set<Int> = []
        for term in terms {
            let result = matchTerm(term, candidate: candidate)
            if term.negate {
                if result != nil { return nil }
                continue
            }
            guard let result = result else { return nil }
            score += result.score
            positions.formUnion(result.positions)
        }
        return FuzzyMatch(score: score, positions: positions.sorted())
    }

    private func matchTerm(_ term: FuzzyTerm, candidate: String) -> FuzzyMatch? {
        if term.exact || term.fromStart || term.toEnd {
            return anchoredMatch(term, candidate: candidate)
        }

        let original = Array(candidate)
        let folded = Array(candidate.lowercased())
        let query = Array(term.caseSensitive ? term.text : term.text.lowercased())
        if term.caseSensitive || folded.count != original.count {
            return fuzzySubsequenceMatch(query: query, candidate: original, original: original)
        }
        return fuzzySubsequenceMatch(query: query, candidate: folded, original: original)
    }

    private func anchoredMatch(_ term: FuzzyTerm, candidate: String) -> FuzzyMatch? {
        var options: String.CompareOptions = term.caseSensitive ? [] : [.caseInsensitive]
        if term.fromStart || term.toEnd { options.insert(.anchored) }
        // `.anchored` alone pins the start; adding `.backwards` also pins the
        // end, so `^foo$` requires the whole string to equal the term.
        if term.toEnd { options.insert(.backwards) }
        guard let range = candidate.range(of: term.text, options: options) else { return nil }
        let start = candidate.distance(from: candidate.startIndex, to: range.lowerBound)
        let length = candidate.distance(from: range.lowerBound, to: range.upperBound)
        var score = FuzzyScoring.match * length
        if start == 0 { score += FuzzyScoring.boundary }
        return FuzzyMatch(score: score, positions: Array(start..<(start + length)))
    }
}

/// Scoring weights, fzf-inspired. These live in a type rather than as file-scope
/// `let`s on purpose: top-level `let`s in main.swift are initialised as part of
/// the executable's top-level code, so they stay zero for anyone that imports
/// the module (e.g. the test bundle) instead of running the app.
private enum FuzzyScoring {
    static let match = 16
    static let gapStart = -3
    static let gapExtension = -1
    static let boundary = 8
    static let camel = 7
    static let consecutive = 8
}

/// Greedy fzf-style fuzzy match: every character of `query` must appear in
/// `candidate` in order. Prefers word and camelCase boundaries and consecutive
/// runs, and penalises gaps. `candidate` may be a lowercased copy of
/// `original`, which is used to classify characters.
private func fuzzySubsequenceMatch(query: [Character], candidate: [Character], original: [Character]) -> FuzzyMatch? {
    guard !query.isEmpty, candidate.count >= query.count else { return nil }

    var score = 0
    var queryIndex = 0
    var previousMatch = -1
    var consecutive = 0
    var positions: [Int] = []

    for index in candidate.indices {
        if queryIndex == query.count { break }
        guard candidate[index] == query[queryIndex] else { continue }

        score += FuzzyScoring.match

        if previousMatch >= 0, index - previousMatch > 1 {
            let gap = index - previousMatch - 1
            score += FuzzyScoring.gapStart + FuzzyScoring.gapExtension * (gap - 1)
            consecutive = 0
        }

        var bonus = 0
        if index == 0 {
            bonus = FuzzyScoring.boundary
        } else {
            let previous = original[index - 1]
            if !previous.isLetter && !previous.isNumber {
                bonus = FuzzyScoring.boundary
            } else if previous.isNumber != original[index].isNumber {
                bonus = FuzzyScoring.camel
            } else if original[index].isUppercase {
                bonus = FuzzyScoring.camel
            }
        }
        if consecutive > 0 { bonus = max(bonus, FuzzyScoring.consecutive) }
        score += bonus

        consecutive += 1
        previousMatch = index
        positions.append(index)
        queryIndex += 1
    }

    guard queryIndex == query.count else { return nil }
    return FuzzyMatch(score: score, positions: positions)
}

struct FavoriteEntry {
    var path: String
    var depth: Int
}

/// Whether `url` is a bundle/package (an `.app`, `.bundle`, `.rtfd`, …). Finder
/// presents packages as single files rather than folders, so we treat them as
/// files for listing, sorting and opening.
func isPackage(_ url: URL) -> Bool {
    // Resolve first: some bundles (e.g. /Applications/Safari.app) are symlinks,
    // and the flag isn't reported for the link itself.
    let resolved = url.resolvingSymlinksInPath()
    return (try? resolved.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
}

class FileTreeTableView: NSTableView {
    var onQuickLook: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            onQuickLook?()
            return
        }
        super.keyDown(with: event)
    }
}

func uniqueDestinationURL(in directory: URL, name: String) -> URL {
    var destination = directory.appendingPathComponent(name)
    if !FileManager.default.fileExists(atPath: destination.path) { return destination }

    let base = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    var counter = 1
    repeat {
        let newName = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
        destination = directory.appendingPathComponent(newName)
        counter += 1
    } while FileManager.default.fileExists(atPath: destination.path)
    return destination
}

// MARK: - Entry point

let app = NSApplication.shared
let appDelegate = FounderAppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.regular)
app.run()

// MARK: - App Delegate

class FounderAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSSearchFieldDelegate,
                           QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var window: NSWindow!
    var splitView: NSSplitView!
    var favoritesListView: NSTableView!
    var fileTreeTableView: FileTreeTableView!

    var favoritesDataSource: FavoritesDataSource!
    var fileTreeDataSource: FileTreeDataSource!

    var showHiddenItem: NSMenuItem!
    var goBackItem: NSMenuItem!
    var goForwardItem: NSMenuItem!
    var pathControl: NSPathControl!
    var searchField: NSSearchField!
    var searchButton: NSButton!
    var searchHelpButton: NSButton!
    var recursiveCheckbox: NSButton!
    var searchStatusView: NSView!
    var searchSpinner: NSProgressIndicator!
    var searchStatusLabel: NSTextField!
    var cancelSearchButton: NSButton!
    var searchStatusHeightConstraint: NSLayoutConstraint!

    var clipboard: [(url: URL, isCut: Bool)] = []
    var navigationHistory: [URL] = []
    var historyIndex: Int = -1

    let favoritesPaneTag = 1
    let fileTreePaneTag = 2

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupMainWindow()

        fileTreeDataSource.onDirectoryChanged = { [weak self] in
            guard let self = self else { return }
            // Preserve selection by URL across reloads
            let selectedURLs = self.selectedFileURLs
            self.fileTreeTableView.reloadData()
            var newIndexes: IndexSet = []
            for url in selectedURLs {
                if let idx = self.fileTreeDataSource.entries.firstIndex(where: { $0 == url }) {
                    newIndexes.insert(idx)
                }
            }
            if !newIndexes.isEmpty {
                self.fileTreeTableView.selectRowIndexes(newIndexes, byExtendingSelection: false)
            }
        }

        fileTreeDataSource.onSearchStarted = { [weak self] in
            self?.showSearchStatus()
        }
        fileTreeDataSource.onSearchProgress = { [weak self] visited, matches in
            guard let self = self else { return }
            self.searchStatusLabel.stringValue = "Searching… \(Self.formattedCount(visited)) items scanned · \(Self.formattedCount(matches)) found"
        }
        fileTreeDataSource.onSearchFinished = { [weak self] scanned, found, elapsed, cancelled in
            self?.showSearchResult(scanned: scanned, found: found, elapsed: elapsed, cancelled: cancelled)
        }
        fileTreeDataSource.onSelectionChanged = {
            guard QLPreviewPanel.sharedPreviewPanelExists(),
                  let panel = QLPreviewPanel.shared(),
                  panel.isVisible else { return }
            panel.reloadData()
        }
        fileTreeDataSource.onThumbnailReady = { [weak self] url in
            guard let self = self,
                  let row = self.fileTreeDataSource.entries.firstIndex(of: url) else { return }
            self.fileTreeTableView.reloadData(
                forRowIndexes: IndexSet(integer: row),
                columnIndexes: IndexSet(integer: 0)
            )
        }

        // Periodic metadata refresh so external file edits (size/date) show up
        // even when the directory itself didn't change on disk.
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, self.window?.isKeyWindow == true else { return }
            // Preserve selection across periodic metadata refresh
            let selectedURLs = self.selectedFileURLs
            self.fileTreeDataSource.attributeCache.removeAll()
            self.fileTreeTableView.reloadData()
            var newIndexes: IndexSet = []
            for url in selectedURLs {
                if let idx = self.fileTreeDataSource.entries.firstIndex(where: { $0 == url }) {
                    newIndexes.insert(idx)
                }
            }
            if !newIndexes.isEmpty {
                self.fileTreeTableView.selectRowIndexes(newIndexes, byExtendingSelection: false)
            }
        }
        RunLoop.main.add(timer, forMode: .common)

        navigateTo(url: FileManager.default.homeDirectoryForCurrentUser)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: Window & panes

    func setupMainWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 900, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Founder"
        window.center()
        window.setFrameAutosaveName("FounderWindow")

        splitView = NSSplitView(frame: NSRect(x: 0, y: 0, width: 900, height: 620))
        splitView.dividerStyle = .thin
        splitView.isVertical = true

        let leftPane = createLeftPane()
        let rightPane = createRightPane()
        splitView.addSubview(leftPane)
        splitView.addSubview(rightPane)

        window.contentView = splitView
        window.setContentSize(NSSize(width: 900, height: 620))
        splitView.setPosition(220, ofDividerAt: 0)
    }

    func createLeftPane() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 620))

        let scrollView = NSScrollView(frame: view.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        favoritesListView = NSTableView(frame: view.bounds)
        favoritesListView.autoresizingMask = [.width]
        favoritesListView.allowsMultipleSelection = false
        favoritesListView.allowsEmptySelection = true
        favoritesListView.headerView = nil
        favoritesListView.rowHeight = 24
        favoritesListView.backgroundColor = .windowBackgroundColor
        favoritesListView.tag = favoritesPaneTag

        let column = NSTableColumn(identifier: .init("name"))
        column.title = "Favorites"
        column.width = 220
        favoritesListView.addTableColumn(column)

        favoritesDataSource = FavoritesDataSource()
        favoritesDataSource.onSelect = { [weak self] path in
            self?.navigateTo(path: path)
        }
        favoritesDataSource.onFilesDropped = { [weak self] destination, urls, isMove in
            self?.moveDroppedFiles(urls, into: destination, isMove: isMove)
        }
        favoritesListView.dataSource = favoritesDataSource
        favoritesListView.delegate = favoritesDataSource
        favoritesListView.registerForDraggedTypes([favoriteRowPasteboardType, .fileURL])
        favoritesListView.setDraggingSourceOperationMask([], forLocal: false)
        favoritesListView.setDraggingSourceOperationMask(.move, forLocal: true)

        let favoritesMenu = makeFavoritesContextMenu()
        favoritesMenu.delegate = self
        favoritesListView.menu = favoritesMenu

        scrollView.documentView = favoritesListView
        view.addSubview(scrollView)
        return view
    }

    func createRightPane() -> NSView {
        let view = NSView(frame: NSRect(x: 220, y: 0, width: 680, height: 620))

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        fileTreeTableView = FileTreeTableView(frame: .zero)
        fileTreeTableView.onQuickLook = { [weak self] in self?.toggleQuickLook(nil) }
        fileTreeTableView.autoresizingMask = [.width]
        fileTreeTableView.allowsMultipleSelection = true
        fileTreeTableView.allowsEmptySelection = true
        fileTreeTableView.rowHeight = 24
        fileTreeTableView.usesAlternatingRowBackgroundColors = true
        fileTreeTableView.allowsColumnReordering = false
        fileTreeTableView.allowsColumnResizing = true
        fileTreeTableView.tag = fileTreePaneTag

        let nameColumn = NSTableColumn(identifier: .init("name"))
        nameColumn.title = "Name"
        nameColumn.width = 400
        nameColumn.minWidth = 160
        nameColumn.sortDescriptorPrototype = NSSortDescriptor(key: "name", ascending: true)
        fileTreeTableView.addTableColumn(nameColumn)

        let sizeColumn = NSTableColumn(identifier: .init("size"))
        sizeColumn.title = "Size"
        sizeColumn.width = 90
        sizeColumn.minWidth = 70
        sizeColumn.sortDescriptorPrototype = NSSortDescriptor(key: "size", ascending: true)
        fileTreeTableView.addTableColumn(sizeColumn)

        let dateColumn = NSTableColumn(identifier: .init("date"))
        dateColumn.title = "Date Modified"
        dateColumn.width = 160
        dateColumn.minWidth = 130
        dateColumn.sortDescriptorPrototype = NSSortDescriptor(key: "date", ascending: true)
        fileTreeTableView.addTableColumn(dateColumn)

        fileTreeDataSource = FileTreeDataSource()
        fileTreeTableView.dataSource = fileTreeDataSource
        fileTreeTableView.delegate = fileTreeDataSource
        fileTreeTableView.sortDescriptors = [fileTreeDataSource.currentSortDescriptor]
        fileTreeDataSource.updateHeaderTitles(fileTreeTableView)
        fileTreeTableView.doubleAction = #selector(openDoubleClickedRow)
        fileTreeTableView.target = self
        fileTreeTableView.registerForDraggedTypes([.fileURL, .string])
        fileTreeTableView.setDraggingSourceOperationMask([.move, .copy, .delete], forLocal: false)
        fileTreeTableView.setDraggingSourceOperationMask([.move, .copy], forLocal: true)

        let fileMenu = makeFileContextMenu()
        fileMenu.delegate = self
        fileTreeTableView.menu = fileMenu

        scrollView.documentView = fileTreeTableView

        pathControl = NSPathControl()
        pathControl.translatesAutoresizingMaskIntoConstraints = false
        pathControl.pathStyle = .standard
        pathControl.backgroundColor = .clear
        pathControl.target = self
        pathControl.action = #selector(pathControlClicked(_:))

        searchField = NSSearchField()
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search (fuzzy)"
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = true
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(performSearch)

        searchButton = NSButton(title: "Search", target: self, action: #selector(performSearch))
        searchButton.translatesAutoresizingMaskIntoConstraints = false
        searchButton.bezelStyle = .rounded

        searchHelpButton = NSButton(title: "?", target: self, action: #selector(showSearchSyntax))
        searchHelpButton.translatesAutoresizingMaskIntoConstraints = false
        searchHelpButton.bezelStyle = .circular
        searchHelpButton.toolTip = "Fuzzy search syntax"

        recursiveCheckbox = NSButton(
            checkboxWithTitle: "Recursive",
            target: self,
            action: #selector(recursiveToggled(_:))
        )
        recursiveCheckbox.translatesAutoresizingMaskIntoConstraints = false
        recursiveCheckbox.state = .off

        searchStatusView = NSView()
        searchStatusView.translatesAutoresizingMaskIntoConstraints = false
        searchStatusView.isHidden = true

        searchSpinner = NSProgressIndicator()
        searchSpinner.translatesAutoresizingMaskIntoConstraints = false
        searchSpinner.style = .spinning
        searchSpinner.controlSize = .small
        searchSpinner.isIndeterminate = true

        searchStatusLabel = NSTextField(labelWithString: "")
        searchStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        searchStatusLabel.font = .systemFont(ofSize: 11)
        searchStatusLabel.textColor = .secondaryLabelColor
        searchStatusLabel.lineBreakMode = .byTruncatingMiddle

        cancelSearchButton = NSButton(title: "Cancel", target: self, action: #selector(cancelSearch))
        cancelSearchButton.translatesAutoresizingMaskIntoConstraints = false
        cancelSearchButton.bezelStyle = .rounded
        cancelSearchButton.controlSize = .small

        searchStatusView.addSubview(searchSpinner)
        searchStatusView.addSubview(searchStatusLabel)
        searchStatusView.addSubview(cancelSearchButton)

        view.addSubview(searchField)
        view.addSubview(searchButton)
        view.addSubview(searchHelpButton)
        view.addSubview(recursiveCheckbox)
        searchStatusHeightConstraint = searchStatusView.heightAnchor.constraint(equalToConstant: 0)
        view.addSubview(searchStatusView)
        view.addSubview(scrollView)
        view.addSubview(pathControl)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            searchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            searchField.heightAnchor.constraint(equalToConstant: 24),

            searchButton.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 8),
            searchButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),

            searchHelpButton.leadingAnchor.constraint(equalTo: searchButton.trailingAnchor, constant: 6),
            searchHelpButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),

            recursiveCheckbox.leadingAnchor.constraint(equalTo: searchHelpButton.trailingAnchor, constant: 8),
            recursiveCheckbox.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            recursiveCheckbox.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),

            searchStatusView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 4),
            searchStatusView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            searchStatusView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            searchStatusHeightConstraint,

            searchSpinner.leadingAnchor.constraint(equalTo: searchStatusView.leadingAnchor, constant: 8),
            searchSpinner.centerYAnchor.constraint(equalTo: searchStatusView.centerYAnchor),

            searchStatusLabel.leadingAnchor.constraint(equalTo: searchSpinner.trailingAnchor, constant: 6),
            searchStatusLabel.centerYAnchor.constraint(equalTo: searchStatusView.centerYAnchor),
            searchStatusLabel.trailingAnchor.constraint(lessThanOrEqualTo: cancelSearchButton.leadingAnchor, constant: -8),

            cancelSearchButton.trailingAnchor.constraint(equalTo: searchStatusView.trailingAnchor, constant: -8),
            cancelSearchButton.centerYAnchor.constraint(equalTo: searchStatusView.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: searchStatusView.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: pathControl.topAnchor, constant: -4),

            pathControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            pathControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            pathControl.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),
            pathControl.heightAnchor.constraint(equalToConstant: 24),
        ])
        return view
    }

    @objc func pathControlClicked(_ sender: NSPathControl) {
        guard let item = sender.clickedPathItem, let url = item.url else { return }
        navigateTo(url: url)
    }

    @objc func performSearch() {
        fileTreeDataSource.filterQuery = searchField.stringValue
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)

        let recursive = fileTreeDataSource.recursiveSearch && !query.isEmpty
        if !recursive {
            hideSearchStatus()
        }
        fileTreeDataSource.loadDirectory(fileTreeDataSource.currentDirectory)
        fileTreeTableView.reloadData()
        if !recursive, !query.isEmpty {
            // Not a recursive scan, so there's no crawl to time or cancel, but the
            // summary line still reports what the query matched.
            showSearchResult(
                scanned: fileTreeDataSource.lastScannedCount,
                found: fileTreeDataSource.entries.count,
                elapsed: nil,
                cancelled: false
            )
        }
    }

    @objc func showSearchSyntax() {
        let alert = NSAlert()
        alert.messageText = "Fuzzy Search"
        alert.informativeText = """
            Type one or more terms; every term must match (fuzzy, so letters just \
            have to appear in order). Results are ranked by match quality, best first.

              rfp          matches "ReserveForPlan.pdf"
              pr rfp       all terms must match
              'report      exact substring
              ^2025        must start with
              .pdf$        must end with
              !archive     exclude matches

            Terms with an uppercase letter are matched case-sensitively; \
            everything else ignores case.
            """
        alert.addButton(withTitle: "OK")
        if let window = window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    @objc func cancelSearch() {
        fileTreeDataSource.cancelSearch()
    }

    func showSearchStatus() {
        searchSpinner.isHidden = false
        cancelSearchButton.isHidden = false
        searchStatusLabel.textColor = .secondaryLabelColor
        searchStatusLabel.stringValue = "Searching…"
        searchStatusView.isHidden = false
        searchStatusHeightConstraint.constant = 20
        searchSpinner.startAnimation(nil)
        searchButton.isEnabled = false
    }

    /// Shown once a search is done. The line deliberately stays put: a fuzzy crawl
    /// over a big tree can take a couple of hundred milliseconds, which is enough
    /// to flash the "Searching…" line by without ever being readable. `elapsed` is
    /// nil for a plain filtered listing, which has no crawl to time.
    func showSearchResult(scanned: Int, found: Int, elapsed: TimeInterval?, cancelled: Bool) {
        searchSpinner.stopAnimation(nil)
        searchSpinner.isHidden = true
        cancelSearchButton.isHidden = true
        searchStatusLabel.textColor = .secondaryLabelColor

        let foundText = Self.formattedCount(found)
        if cancelled {
            searchStatusLabel.stringValue = "Search cancelled · \(foundText) found"
        } else if scanned > found {
            let counts = "\(foundText) found of \(Self.formattedCount(scanned)) scanned"
            searchStatusLabel.stringValue = elapsed.map { counts + " · " + Self.formattedDuration($0) } ?? counts
        } else {
            searchStatusLabel.stringValue = found == 1 ? "1 match" : "\(foundText) matches"
        }

        searchStatusView.isHidden = false
        searchStatusHeightConstraint.constant = 20
        searchButton.isEnabled = true
    }

    static func formattedCount(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    static func formattedDuration(_ elapsed: TimeInterval) -> String {
        elapsed < 1 ? String(format: "%.0f ms", elapsed * 1000) : String(format: "%.1f s", elapsed)
    }

    func hideSearchStatus() {
        searchSpinner.stopAnimation(nil)
        searchSpinner.isHidden = true
        cancelSearchButton.isHidden = true
        searchStatusLabel.textColor = .secondaryLabelColor
        searchStatusHeightConstraint.constant = 0
        searchStatusView.isHidden = true
        searchStatusLabel.stringValue = ""
        searchButton.isEnabled = true
    }

    @objc func focusSearchField() {
        window.makeFirstResponder(searchField)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField, field === searchField else { return }
        if field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty,
           !fileTreeDataSource.filterQuery.isEmpty {
            performSearch()
        }
    }

    @objc func recursiveToggled(_ sender: NSButton) {
        fileTreeDataSource.recursiveSearch = sender.state == .on
    }

    // MARK: Navigation

    func navigateTo(url: URL, pushHistory: Bool = true) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        guard isDir.boolValue, !isPackage(url) else {
            NSWorkspace.shared.open(url)
            return
        }

        if pushHistory {
            if historyIndex < navigationHistory.count - 1 {
                navigationHistory.removeSubrange((historyIndex + 1)...)
            }
            navigationHistory.append(url)
            historyIndex = navigationHistory.count - 1
        }

        if !fileTreeDataSource.filterQuery.isEmpty {
            fileTreeDataSource.filterQuery = ""
            searchField.stringValue = ""
            hideSearchStatus()
        }

        fileTreeDataSource.loadDirectory(url)
        syncSortIndicator()
        fileTreeTableView.reloadData()
        fileTreeTableView.deselectAll(nil)
        pathControl.url = url
        window.title = "Founder — " + (url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent)
        updateGoBackItem()
    }

    func navigateTo(path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        navigateTo(url: URL(fileURLWithPath: expanded))
    }

    func updateGoBackItem() {
        goBackItem?.isEnabled = historyIndex > 0
        goForwardItem?.isEnabled = historyIndex < navigationHistory.count - 1
    }

    // MARK: Selection helpers

    var selectedFileURLs: [URL] {
        let rows = fileTreeTableView.selectedRowIndexes
        return rows.compactMap { fileTreeDataSource.entry(at: $0) }
    }

    var primarySelection: URL? {
        selectedFileURLs.first
    }

    // MARK: Quick Look

    @objc func toggleQuickLook(_ sender: Any?) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else if !selectedFileURLs.isEmpty {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        selectedFileURLs.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let urls = selectedFileURLs
        guard urls.indices.contains(index) else { return nil }
        return urls[index] as NSURL
    }

    var selectedFavoriteIndex: Int {
        let row = favoritesListView.selectedRow
        return row >= 0 ? row : -1
    }

    var targetDirectoryForNewItems: URL {
        if let sel = primarySelection {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: sel.path, isDirectory: &isDir),
               isDir.boolValue, !isPackage(sel) {
                return sel
            }
        }
        return fileTreeDataSource.currentDirectory
    }

    // MARK: Menus

    func setupMenuBar() {
        let menubar = NSMenu()

        // Founder menu
        let founderMenu = NSMenu(title: "Founder")
        founderMenu.addItem(withTitle: "About Founder", action: #selector(showAbout), keyEquivalent: "")
        founderMenu.addItem(.separator())
        founderMenu.addItem(withTitle: "Hide Founder", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = founderMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        founderMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        founderMenu.addItem(.separator())
        founderMenu.addItem(withTitle: "Quit Founder", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let founderMenuTopItem = NSMenuItem(title: "Founder", action: nil, keyEquivalent: "")
        founderMenuTopItem.submenu = founderMenu
        menubar.addItem(founderMenuTopItem)

        // File menu
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Folder", action: #selector(newFolder), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "New File", action: #selector(newFile), keyEquivalent: "f")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Open", action: #selector(openItem), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Open With...", action: #selector(openWith), keyEquivalent: "")
        fileMenu.addItem(withTitle: "Get Info", action: #selector(getInfo), keyEquivalent: "i")
        fileMenu.addItem(withTitle: "Rename", action: #selector(renameItem), keyEquivalent: "")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Move to Trash", action: #selector(moveToTrash), keyEquivalent: "")
        let deleteItem = fileMenu.addItem(withTitle: "Delete Permanently...", action: #selector(deletePermanently), keyEquivalent: "")
        deleteItem.keyEquivalentModifierMask = [.command, .option]
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Add to Favorites", action: #selector(addToFavorites), keyEquivalent: "t")
        let fileMenuTopItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileMenuTopItem.submenu = fileMenu
        menubar.addItem(fileMenuTopItem)

        // Edit menu
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(cutItem), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(copyItem), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(pasteItem), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(selectAll), keyEquivalent: "a")
        let editMenuTopItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editMenuTopItem.submenu = editMenu
        menubar.addItem(editMenuTopItem)

        // View menu
        let viewMenu = NSMenu(title: "View")
        showHiddenItem = viewMenu.addItem(withTitle: "Show Hidden Files", action: #selector(toggleShowHidden), keyEquivalent: ".")
        showHiddenItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Find", action: #selector(focusSearchField), keyEquivalent: "f")
        let viewMenuTopItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        viewMenuTopItem.submenu = viewMenu
        menubar.addItem(viewMenuTopItem)

        // Go menu
        let goMenu = NSMenu(title: "Go")
        goBackItem = goMenu.addItem(withTitle: "Back", action: #selector(goBack), keyEquivalent: "[")
        goBackItem.isEnabled = false
        goForwardItem = goMenu.addItem(withTitle: "Forward", action: #selector(goForward), keyEquivalent: "]")
        goForwardItem.isEnabled = false
        let enclosingItem = goMenu.addItem(
            withTitle: "Enclosing Folder",
            action: #selector(goToEnclosingFolder),
            keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!)
        )
        enclosingItem.keyEquivalentModifierMask = [.command]
        goMenu.addItem(.separator())
        let goToFolderItem = goMenu.addItem(withTitle: "Go to Folder...", action: #selector(goToFolder), keyEquivalent: "g")
        goToFolderItem.keyEquivalentModifierMask = [.command, .shift]
        goMenu.addItem(.separator())
        let homeItem = goMenu.addItem(withTitle: "Home", action: #selector(goHome), keyEquivalent: "h")
        homeItem.keyEquivalentModifierMask = [.command, .shift]
        let desktopItem = goMenu.addItem(withTitle: "Desktop", action: #selector(goDesktop), keyEquivalent: "d")
        desktopItem.keyEquivalentModifierMask = [.command, .shift]
        let documentsItem = goMenu.addItem(withTitle: "Documents", action: #selector(goDocuments), keyEquivalent: "o")
        documentsItem.keyEquivalentModifierMask = [.command, .shift]
        let downloadsItem = goMenu.addItem(withTitle: "Downloads", action: #selector(goDownloads), keyEquivalent: "l")
        downloadsItem.keyEquivalentModifierMask = [.command, .option]
        let goMenuTopItem = NSMenuItem(title: "Go", action: nil, keyEquivalent: "")
        goMenuTopItem.submenu = goMenu
        menubar.addItem(goMenuTopItem)

        NSApp.mainMenu = menubar
    }

    func makeFileContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Context Menu")
        menu.addItem(withTitle: "Open", action: #selector(openItem), keyEquivalent: "")
        menu.addItem(withTitle: "Open With...", action: #selector(openWith), keyEquivalent: "")
        menu.addItem(withTitle: "Quick Look", action: #selector(toggleQuickLook(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Open Enclosing Folder", action: #selector(goToEnclosingFolder), keyEquivalent: "")
        menu.addItem(withTitle: "Open in Finder", action: #selector(openInFinder), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Move to Trash", action: #selector(moveToTrash), keyEquivalent: "")
        menu.addItem(withTitle: "Delete Permanently...", action: #selector(deletePermanently), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Get Info", action: #selector(getInfo), keyEquivalent: "")
        menu.addItem(withTitle: "Rename", action: #selector(renameItem), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(cutItem), keyEquivalent: "")
        menu.addItem(withTitle: "Copy", action: #selector(copyItem), keyEquivalent: "")
        menu.addItem(withTitle: "Paste", action: #selector(pasteItem), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Create Folder", action: #selector(createFolder), keyEquivalent: "")
        menu.addItem(withTitle: "Create File", action: #selector(createFile), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Add to Favorites", action: #selector(addToFavorites), keyEquivalent: "")
        return menu
    }

    func makeFavoritesContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Favorites")
        menu.addItem(withTitle: "Open", action: #selector(openFavorite), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Remove from Favorites", action: #selector(removeFromFavorites), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Move Up", action: #selector(moveFavoriteUp), keyEquivalent: "")
        menu.addItem(withTitle: "Move Down", action: #selector(moveFavoriteDown), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Indent", action: #selector(indentFavorite), keyEquivalent: "")
        menu.addItem(withTitle: "Unindent", action: #selector(unindentFavorite), keyEquivalent: "")
        return menu
    }

    // MARK: NSMenuDelegate — validation

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === favoritesListView.menu {
            let index = favoriteActionRow
            for item in menu.items {
                switch item.action {
                case #selector(indentFavorite):
                    item.isEnabled = favoritesDataSource.canIndent(at: index)
                case #selector(unindentFavorite):
                    item.isEnabled = favoritesDataSource.canUnindent(at: index)
                default:
                    item.isEnabled = index >= 0
                }
            }
            return
        }

        guard menu === fileTreeTableView.menu else { return }

        // Ensure the clicked row becomes the primary selection before
        // the submenu/selection gets a chance to change focus.
        let row = fileTreeTableView.clickedRow
        if row >= 0 {
            if !fileTreeTableView.selectedRowIndexes.contains(row) {
                fileTreeTableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            _ = fileTreeTableView.window?.makeFirstResponder(fileTreeTableView)
        }

        let hasSelection = !selectedFileURLs.isEmpty
        let pasteboardHasFiles = !clipboard.isEmpty

        for item in menu.items {
            switch item.action {
            case #selector(openItem), #selector(openWith), #selector(getInfo),
                 #selector(renameItem), #selector(cutItem), #selector(copyItem),
                 #selector(moveToTrash), #selector(deletePermanently),
                 #selector(addToFavorites), #selector(toggleQuickLook(_:)):
                item.isEnabled = hasSelection
            case #selector(pasteItem):
                item.isEnabled = pasteboardHasFiles
            default:
                item.isEnabled = true
            }
        }
    }

    // MARK: Actions — About

    @objc func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Founder"
        alert.informativeText = "A macOS Finder clone built with Swift.\nVersion 0.5 (draft)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: Actions — File operations

    @objc func openDoubleClickedRow() {
        let row = fileTreeTableView.clickedRow
        guard row >= 0, let url = fileTreeDataSource.entry(at: row) else { return }
        navigateTo(url: url)
    }

    @objc func openItem() {
        for url in selectedFileURLs {
            navigateTo(url: url)
        }
    }

    @objc func openWith() {
        guard let url = primarySelection else { return }
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
        guard !apps.isEmpty else {
            presentError("No applications found to open this file.")
            return
        }

        // Snapshot the selection NOW — the table selection may change
        // while the menu is being tracked.
        let fileURLs = selectedFileURLs

        let menu = NSMenu(title: "Open With")
        menu.autoenablesItems = false

        // De-duplicate by absolute path
        var seen = Set<String>()
        let uniqueApps = apps.filter { app in
            let path = app.standardizedFileURL.path
            defer { seen.insert(path) }
            return !seen.contains(path)
        }

        for appURL in uniqueApps {
            let name = appURL.deletingPathExtension().lastPathComponent
            let item = NSMenuItem(title: name, action: #selector(openWithApplication(_:)), keyEquivalent: "")
            item.representedObject = OpenWithContext(appURL: appURL, fileURLs: fileURLs)
            item.target = self
            item.isEnabled = true
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }

        if let window = fileTreeTableView.window {
            let screenPoint = NSEvent.mouseLocation
            let windowPoint = window.convertFromScreen(NSRect(origin: screenPoint, size: .zero)).origin
            let viewPoint = fileTreeTableView.convert(windowPoint, from: nil)
            menu.popUp(positioning: nil, at: viewPoint, in: fileTreeTableView)
        }
    }

    @objc func openWithApplication(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? OpenWithContext else {
            NSLog("Open With: could not unwrap menu item context")
            return
        }
        NSLog("Open With: opening [%@] with %@",
              context.fileURLs.map(\.lastPathComponent).joined(separator: ", "),
              context.appURL.lastPathComponent)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(context.fileURLs, withApplicationAt: context.appURL, configuration: config) { app, error in
            DispatchQueue.main.async {
                if let error = error {
                    NSLog("Open With failed: %@", error.localizedDescription)
                    self.presentError("Could not open file: \(error.localizedDescription)")
                } else {
                    NSLog("Open With success: %@", app?.localizedName ?? "unknown")
                }
            }
        }
    }

    @objc func moveToTrash() {
        let urls = selectedFileURLs
        guard !urls.isEmpty else { return }
        for url in urls {
            do {
                _ = try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                presentError("Could not move \(url.lastPathComponent) to Trash: \(error.localizedDescription)")
            }
        }
        refreshCurrentDirectory()
    }

    @objc func deletePermanently() {
        let urls = selectedFileURLs
        guard !urls.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = urls.count == 1
            ? "Delete “\(urls[0].lastPathComponent)”?"
            : "Delete \(urls.count) items?"
        alert.informativeText = "This item will be deleted immediately. You can't undo this action."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        for url in urls {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                presentError("Could not delete \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        refreshCurrentDirectory()
    }

    @objc func getInfo() {
        let urls = selectedFileURLs
        guard !urls.isEmpty else { return }

        for url in urls {
            let fm = FileManager.default
            let attrs = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]

            var lines: [String] = []
            lines.append("Name: \(url.lastPathComponent)")
            lines.append("Path: \(url.path)")

            if let type = attrs[.type] as? FileAttributeType {
                switch type {
                case .typeDirectory: lines.append("Kind: Folder")
                case .typeSymbolicLink: lines.append("Kind: Symbolic Link")
                case .typeRegular:
                    let ext = url.pathExtension
                    lines.append("Kind: \(ext.isEmpty ? "Document" : ext.uppercased() + " document")")
                default: lines.append("Kind: Other")
                }
            }

            if let size = attrs[.size] as? Int {
                lines.append("Size: \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) (\(size) bytes)")
            }
            if let modDate = attrs[.modificationDate] as? Date {
                lines.append("Modified: \(modDate)")
            }
            if let createdDate = attrs[.creationDate] as? Date {
                lines.append("Created: \(createdDate)")
            }

            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                if let items = try? fm.contentsOfDirectory(atPath: url.path) {
                    lines.append("Items: \(items.count)")
                }
            }

            let alert = NSAlert()
            alert.messageText = "Info: \(url.lastPathComponent)"
            alert.informativeText = lines.joined(separator: "\n")
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @objc func renameItem() {
        guard let url = primarySelection else { return }

        let alert = NSAlert()
        alert.messageText = "Rename “\(url.lastPathComponent)”"
        alert.informativeText = "Enter a new name:"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.stringValue = url.lastPathComponent
        textField.placeholderString = "New name"
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField
        textField.selectText(nil)

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != url.lastPathComponent else { return }

        let destination = url.deletingLastPathComponent().appendingPathComponent(newName)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            presentError("An item named “\(newName)” already exists in this folder.")
            return
        }

        do {
            try FileManager.default.moveItem(at: url, to: destination)
            refreshCurrentDirectory()
        } catch {
            presentError("Could not rename: \(error.localizedDescription)")
        }
    }

    @objc func cutItem() {
        let urls = selectedFileURLs
        guard !urls.isEmpty else { return }
        clipboard = urls.map { ($0, true) }
    }

    @objc func copyItem() {
        let urls = selectedFileURLs
        guard !urls.isEmpty else { return }
        clipboard = urls.map { ($0, false) }
    }

    @objc func pasteItem() {
        guard !clipboard.isEmpty else { return }
        let destinationDir = targetDirectoryForNewItems

        for entry in clipboard {
            let destination = uniqueDestination(in: destinationDir, name: entry.url.lastPathComponent)
            do {
                if entry.isCut {
                    try FileManager.default.moveItem(at: entry.url, to: destination)
                } else {
                    try FileManager.default.copyItem(at: entry.url, to: destination)
                }
            } catch {
                presentError("Could not paste \(entry.url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if clipboard.allSatisfy({ $0.isCut }) {
            clipboard = []
        }
        refreshCurrentDirectory()
    }

    func uniqueDestination(in directory: URL, name: String) -> URL {
        uniqueDestinationURL(in: directory, name: name)
    }

    @objc func selectAll() {
        fileTreeTableView.selectAll(nil)
    }

    // MARK: Actions — Create

    @objc func newFolder() { createFolder() }

    @objc func newFile() { createFile() }

    @objc func createFolder() {
        createItem(isDirectory: true)
    }

    @objc func createFile() {
        createItem(isDirectory: false)
    }

    func createItem(isDirectory: Bool) {
        let directory = targetDirectoryForNewItems
        let defaultName = isDirectory ? "untitled folder" : "untitled file.txt"

        let alert = NSAlert()
        alert.messageText = isDirectory ? "New Folder" : "New File"
        alert.informativeText = "The item will be created in “\(directory.lastPathComponent)”."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.stringValue = defaultName
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField
        textField.selectText(nil)

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        let newItem = uniqueDestination(in: directory, name: name)
        do {
            if isDirectory {
                try FileManager.default.createDirectory(at: newItem, withIntermediateDirectories: false)
            } else {
                guard FileManager.default.createFile(atPath: newItem.path, contents: Data()) else {
                    presentError("Could not create “\(name)”.")
                    return
                }
            }
            refreshCurrentDirectory()
        } catch {
            presentError("Could not create item: \(error.localizedDescription)")
        }
    }

    // MARK: Actions — Favorites

    @objc func openFavorite() {
        let index = favoritesListView.clickedRow >= 0 ? favoritesListView.clickedRow : favoritesListView.selectedRow
        guard index >= 0, index < favoritesDataSource.favorites.count else { return }
        navigateTo(path: favoritesDataSource.favorites[index].path)
    }

    @objc func addToFavorites() {
        let path: String
        if fileTreeTableView.window?.firstResponder === fileTreeTableView, let url = primarySelection {
            path = url.path
        } else {
            path = fileTreeDataSource.currentDirectory.path
        }
        favoritesDataSource.add(path: path)
        favoritesListView.reloadData()
    }

    @objc func removeFromFavorites() {
        let index = favoritesListView.clickedRow >= 0 ? favoritesListView.clickedRow : favoritesListView.selectedRow
        guard index >= 0 else { return }
        favoritesDataSource.remove(at: index)
        favoritesListView.reloadData()
    }

    @objc func moveFavoriteUp() {
        let index = favoritesListView.clickedRow >= 0 ? favoritesListView.clickedRow : favoritesListView.selectedRow
        guard index > 0 else { return }
        favoritesDataSource.move(from: index, to: index - 1)
        favoritesListView.reloadData()
        favoritesListView.selectRowIndexes(IndexSet(integer: index - 1), byExtendingSelection: false)
    }

    @objc func moveFavoriteDown() {
        let index = favoritesListView.clickedRow >= 0 ? favoritesListView.clickedRow : favoritesListView.selectedRow
        guard index >= 0, index < favoritesDataSource.favorites.count - 1 else { return }
        favoritesDataSource.move(from: index, to: index + 1)
        favoritesListView.reloadData()
        favoritesListView.selectRowIndexes(IndexSet(integer: index + 1), byExtendingSelection: false)
    }

    /// Row the favorites context-menu actions should target: the right-clicked
    /// row when there is one, otherwise the current selection.
    var favoriteActionRow: Int {
        let clicked = favoritesListView.clickedRow
        return clicked >= 0 ? clicked : favoritesListView.selectedRow
    }

    @objc func indentFavorite() {
        let index = favoriteActionRow
        guard favoritesDataSource.canIndent(at: index) else { NSSound.beep(); return }
        favoritesDataSource.indent(at: index)
        favoritesListView.reloadData()
        favoritesListView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }

    @objc func unindentFavorite() {
        let index = favoriteActionRow
        guard favoritesDataSource.canUnindent(at: index) else { NSSound.beep(); return }
        favoritesDataSource.unindent(at: index)
        favoritesListView.reloadData()
        favoritesListView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }

    // MARK: Actions — View & Go

    @objc func toggleShowHidden() {
        fileTreeDataSource.showHidden.toggle()
        showHiddenItem.title = fileTreeDataSource.showHidden ? "Hide Hidden Files" : "Show Hidden Files"
        showHiddenItem.state = fileTreeDataSource.showHidden ? .on : .off
        refreshCurrentDirectory()
    }

    @objc func goBack() {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        navigateTo(url: navigationHistory[historyIndex], pushHistory: false)
    }

    @objc func goForward() {
        guard historyIndex < navigationHistory.count - 1 else { return }
        historyIndex += 1
        navigateTo(url: navigationHistory[historyIndex], pushHistory: false)
    }

    @objc func goToEnclosingFolder() {
        let parent = fileTreeDataSource.currentDirectory.deletingLastPathComponent()
        guard parent.path != fileTreeDataSource.currentDirectory.path else { return }
        navigateTo(url: parent)
    }

    @objc func openInFinder() {
        let urls = selectedFileURLs
        guard !urls.isEmpty else {
            NSWorkspace.shared.open(fileTreeDataSource.currentDirectory)
            return
        }
        // A single selected folder opens in Finder; files (or a multi-selection)
        // are revealed and selected in their containing folder.
        if urls.count == 1, let url = urls.first {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
               isDir.boolValue, !isPackage(url) {
                NSWorkspace.shared.open(url)
                return
            }
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc func goToFolder() {
        let alert = NSAlert()
        alert.messageText = "Go to Folder"
        alert.informativeText = "Enter the path of the folder you want to open:"
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.stringValue = fileTreeDataSource.currentDirectory.path
        textField.placeholderString = "~/Documents"
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField
        textField.selectText(nil)

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let path = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }

        let expanded = (path as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else {
            presentError("The folder “\(path)” does not exist.")
            return
        }
        navigateTo(url: URL(fileURLWithPath: expanded))
    }

    @objc func goHome() {
        navigateTo(url: FileManager.default.homeDirectoryForCurrentUser)
    }

    @objc func goDesktop() {
        navigateTo(path: "~/Desktop")
    }

    @objc func goDocuments() {
        navigateTo(path: "~/Documents")
    }

    @objc func goDownloads() {
        navigateTo(path: "~/Downloads")
    }

    // MARK: Helpers

    func refreshCurrentDirectory() {
        let current = fileTreeDataSource.currentDirectory
        fileTreeDataSource.loadDirectory(current)
        syncSortIndicator()
        fileTreeTableView.reloadData()
    }

    /// Keeps the header's sort arrow in sync with the app-wide sort choice, and
    /// re-applies it if something cleared the table's descriptors.
    func syncSortIndicator() {
        let desired = [fileTreeDataSource.currentSortDescriptor]
        if fileTreeTableView.sortDescriptors != desired {
            fileTreeTableView.sortDescriptors = desired
        }
    }

    func moveDroppedFiles(_ urls: [URL], into destinationDir: URL, isMove: Bool) {
        let fm = FileManager.default
        var changed = false
        for source in urls {
            if isMove && source.deletingLastPathComponent().standardizedFileURL == destinationDir.standardizedFileURL {
                continue
            }
            let destination = uniqueDestinationURL(in: destinationDir, name: source.lastPathComponent)
            do {
                if isMove {
                    try fm.moveItem(at: source, to: destination)
                } else {
                    try fm.copyItem(at: source, to: destination)
                }
                changed = true
            } catch {
                presentError("Could not \(isMove ? "move" : "copy") \(source.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if changed {
            refreshCurrentDirectory()
        }
    }

    func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Open With context

private final class OpenWithContext: NSObject {
    let appURL: URL
    let fileURLs: [URL]

    init(appURL: URL, fileURLs: [URL]) {
        self.appURL = appURL
        self.fileURLs = fileURLs
    }
}

// MARK: - Favorites Data Source

class FavoritesDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var favorites: [FavoriteEntry] = []
    var onSelect: ((String) -> Void)?
    var onFilesDropped: ((URL, [URL], Bool) -> Void)?
    private var suppressSelectionCallback = false

    /// Horizontal offset applied per nesting level, in points.
    static let indentWidth: CGFloat = 14

    override init() {
        super.init()
        loadFavorites()
    }

    func loadFavorites() {
        let defaults = UserDefaults.standard
        if let saved = defaults.array(forKey: "favorites") as? [[String: Any]] {
            favorites = saved.compactMap { dict in
                guard let path = dict["path"] as? String else { return nil }
                let depth = dict["depth"] as? Int ?? 0
                return FavoriteEntry(path: path, depth: max(0, depth))
            }
        } else if let legacy = defaults.stringArray(forKey: "favorites") {
            // Migrate the original flat array of path strings.
            favorites = legacy.map { FavoriteEntry(path: $0, depth: 0) }
            saveFavorites()
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            favorites = [
                home + "/Desktop",
                home + "/Documents",
                home + "/Downloads",
                home + "/Movies",
                home + "/Music",
                home + "/Pictures",
            ].map { FavoriteEntry(path: $0, depth: 0) }
            saveFavorites()
        }
    }

    func saveFavorites() {
        let stored = favorites.map { ["path": $0.path, "depth": $0.depth] as [String: Any] }
        UserDefaults.standard.set(stored, forKey: "favorites")
    }

    func add(path: String) {
        guard !favorites.contains(where: { $0.path == path }) else { return }
        favorites.append(FavoriteEntry(path: path, depth: 0))
        saveFavorites()
    }

    func remove(at index: Int) {
        guard favorites.indices.contains(index) else { return }
        favorites.remove(at: index)
        saveFavorites()
    }

    func move(from source: Int, to destination: Int) {
        guard favorites.indices.contains(source), favorites.indices.contains(destination) else { return }
        let item = favorites.remove(at: source)
        favorites.insert(item, at: destination)
        saveFavorites()
    }

    // MARK: Nesting

    /// Whether the item at `index` can be nested one level deeper. Follows the
    /// classic outliner rule: a row may sit at most one level deeper than the row
    /// directly above it. Depth is purely cosmetic — it is not checked against the
    /// filesystem.
    func canIndent(at index: Int) -> Bool {
        guard index > 0, favorites.indices.contains(index) else { return false }
        return favorites[index].depth < favorites[index - 1].depth + 1
    }

    func canUnindent(at index: Int) -> Bool {
        favorites.indices.contains(index) && favorites[index].depth > 0
    }

    func indent(at index: Int) {
        guard canIndent(at: index) else { return }
        shift(at: index, by: 1)
    }

    func unindent(at index: Int) {
        guard canUnindent(at: index) else { return }
        shift(at: index, by: -1)
    }

    /// Moves the row at `index` by `levels` and drags its subtree (the following
    /// rows deeper than it) along, so structure is preserved.
    private func shift(at index: Int, by levels: Int) {
        let oldDepth = favorites[index].depth
        guard oldDepth + levels >= 0 else { return }
        favorites[index].depth = oldDepth + levels
        var i = index + 1
        while i < favorites.count, favorites[i].depth > oldDepth {
            favorites[i].depth += levels
            i += 1
        }
        saveFavorites()
    }

    func displayName(at index: Int) -> String {
        let path = favorites[index].path
        let name = (path as NSString).lastPathComponent
        if name.isEmpty {
            return (path as NSString).abbreviatingWithTildeInPath
        }
        return name
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        favorites.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("favCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier

            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.imageScaling = .scaleProportionallyUpOrDown
            cell.addSubview(imageView)
            cell.imageView = imageView

            let textField = NSTextField()
            textField.isBordered = false
            textField.isEditable = false
            textField.isSelectable = false
            textField.backgroundColor = .clear
            textField.lineBreakMode = .byTruncatingMiddle
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(textField)
            cell.textField = textField

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),

                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        cell.textField?.stringValue = displayName(at: row)
        let expanded = (favorites[row].path as NSString).expandingTildeInPath
        cell.imageView?.image = NSWorkspace.shared.icon(forFile: expanded)
        cell.imageView?.frame.size = NSSize(width: 16, height: 16)

        // Indent nested favorites.
        if let leading = cell.constraints.first(where: {
            $0.firstAttribute == .leading && ($0.firstItem as? NSImageView) === cell.imageView
        }) {
            leading.constant = 6 + CGFloat(favorites[row].depth) * FavoritesDataSource.indentWidth
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionCallback else { return }
        let tableView = notification.object as? NSTableView
        guard let row = tableView?.selectedRow, row >= 0, row < favorites.count else { return }
        onSelect?(favorites[row].path)
    }

    // MARK: Drag & drop — reorder

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard favorites.indices.contains(row) else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(row), forType: favoriteRowPasteboardType)
        return item
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        if info.draggingSource as? NSTableView === tableView,
           info.draggingPasteboard.string(forType: favoriteRowPasteboardType) != nil {
            tableView.setDropRow(row, dropOperation: .above)
            return .move
        }

        if let sourceURLs = droppedFileURLs(from: info), let target = folderFavorite(at: row) {
            for source in sourceURLs {
                let srcPath = source.standardizedFileURL.path
                let dstPath = target.standardizedFileURL.path
                if dstPath == srcPath { return [] }
                if dstPath.hasPrefix(srcPath + "/") { return [] }
            }
            tableView.setDropRow(row, dropOperation: .on)
            return info.draggingSourceOperationMask.contains(.move) ? .move : .copy
        }

        return []
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        if info.draggingSource as? NSTableView === tableView,
           let rowString = info.draggingPasteboard.string(forType: favoriteRowPasteboardType),
           let source = Int(rowString),
           favorites.indices.contains(source) {
            var destination = row > source ? row - 1 : row
            destination = max(0, min(destination, favorites.count - 1))
            guard destination != source else { return false }

            suppressSelectionCallback = true
            move(from: source, to: destination)
            tableView.reloadData()
            tableView.selectRowIndexes(IndexSet(integer: destination), byExtendingSelection: false)
            suppressSelectionCallback = false
            return true
        }

        if let sourceURLs = droppedFileURLs(from: info), let target = folderFavorite(at: row) {
            let isMove = info.draggingSourceOperationMask.contains(.move)
            onFilesDropped?(target, sourceURLs, isMove)
            return true
        }

        return false
    }

    private func folderFavorite(at row: Int) -> URL? {
        guard favorites.indices.contains(row) else { return nil }
        let url = URL(fileURLWithPath: (favorites[row].path as NSString).expandingTildeInPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue, !isPackage(url) else {
            return nil
        }
        return url
    }

    private func droppedFileURLs(from info: NSDraggingInfo) -> [URL]? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) as? [URL], !urls.isEmpty else { return nil }
        return urls
    }
}

// MARK: - File Tree Data Source

class FileTreeDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var currentDirectory: URL
    var entries: [URL] = []
    var entryIsDirectory: [Bool] = []
    var showHidden = false
    var attributeCache: [URL: [FileAttributeKey: Any]] = [:]
    var filterQuery: String = ""
    var recursiveSearch = false
    /// The parsed form of `filterQuery`, and the per-URL score/offsets from the
    /// last search. While a query is active the list is ranked by match score
    /// instead of by the column sort.
    private(set) var activeQuery = FuzzyQuery("")
    private var matchScores: [URL: Int] = [:]
    private var matchPositions: [URL: [Int]] = [:]
    var sortKey: String {
        didSet { UserDefaults.standard.set(sortKey, forKey: "sortKey") }
    }
    var sortAscending: Bool {
        didSet { UserDefaults.standard.set(sortAscending, forKey: "sortAscending") }
    }

    /// The single sort descriptor representing the current (app-wide) sort choice.
    var currentSortDescriptor: NSSortDescriptor {
        NSSortDescriptor(key: sortKey, ascending: sortAscending)
    }
    var onDirectoryChanged: (() -> Void)?
    var onSearchStarted: (() -> Void)?
    var onSearchProgress: ((Int, Int) -> Void)?
    /// Called with `scanned`, `found`, elapsed seconds and whether the crawl was
    /// cancelled, so the UI can leave a summary on screen.
    var onSearchFinished: ((_ scanned: Int, _ found: Int, _ elapsed: TimeInterval, _ cancelled: Bool) -> Void)?
    /// Number of directory entries the last (non-recursive) listing looked at, so
    /// a filtered listing can still report "N matches of M scanned".
    private(set) var lastScannedCount = 0
    private var searchStartTime = Date()
    /// True while a recursive crawl is running, so directory-watcher events can be
    /// ignored instead of restarting the crawl.
    private var isCrawling = false
    var onSelectionChanged: (() -> Void)?
    var onThumbnailReady: ((URL) -> Void)?
    private var thumbnailCache: [URL: NSImage] = [:]
    private var thumbnailRequests: Set<URL> = []
    private var directorySource: DispatchSourceFileSystemObject?
    private let searchQueue = DispatchQueue(label: "com.dennisfaucher.founder.search", qos: .userInitiated)
    private let stateLock = NSLock()
    private var searchGeneration = 0
    private var cancelledGeneration = -1

    override init() {
        currentDirectory = FileManager.default.homeDirectoryForCurrentUser
        // The sort choice is global (applies to every folder) and remembered
        // across launches.
        let defaults = UserDefaults.standard
        sortKey = defaults.string(forKey: "sortKey") ?? "name"
        sortAscending = (defaults.object(forKey: "sortAscending") as? Bool) ?? true
        super.init()
        loadDirectory(currentDirectory)
    }

    deinit {
        directorySource?.cancel()
    }

    func loadDirectory(_ url: URL) {
        currentDirectory = url
        attributeCache.removeAll()

        let fileManager = FileManager.default

        let query = filterQuery.trimmingCharacters(in: .whitespaces)
        activeQuery = FuzzyQuery(query)
        matchScores.removeAll()
        matchPositions.removeAll()

        if recursiveSearch && !query.isEmpty {
            beginRecursiveSearch()
            return
        }

        invalidateSearch()
        // Any crawl has been superseded by this plain listing.
        isCrawling = false


        do {
            // `contentsOfDirectory(at:)` fails with ENOTDIR when `url` is a
            // symbolic link to a directory, so enumerate by path (which follows
            // the link) and rebuild child URLs against the link itself.
            let names = try fileManager.contentsOfDirectory(atPath: url.path)
            lastScannedCount = names.count

            var filtered: [(url: URL, isDir: Bool)] = []
            for name in names {
                let item = url.appendingPathComponent(name)
                let isHidden = name.hasPrefix(".") ||
                    ((try? item.resourceValues(forKeys: [.isHiddenKey]))?.isHidden ?? false)
                if !showHidden && isHidden { continue }
                if !activeQuery.isEmpty {
                    guard let match = activeQuery.match(name) else { continue }
                    matchScores[item] = match.score
                    matchPositions[item] = match.positions
                }
                var isDir: ObjCBool = false
                _ = fileManager.fileExists(atPath: item.path, isDirectory: &isDir)
                filtered.append((item, isDir.boolValue && !isPackage(item)))
            }

            filtered = sortedForDisplay(filtered)

            entries = filtered.map { $0.url }
            entryIsDirectory = filtered.map { $0.isDir }
        } catch {
            entries = []
            entryIsDirectory = []
            NSLog("Failed to read directory %@: %@", url.path, error.localizedDescription)
        }
        watchDirectory()
    }

    private func watchDirectory() {
        directorySource?.cancel()
        directorySource = nil

        let fd = open(currentDirectory.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            // A crawl watching its own root would restart on every write anywhere
            // under it (cloud sync, caches, …), so let the in-flight one finish.
            guard !self.isCrawling else { return }
            guard FileManager.default.fileExists(atPath: self.currentDirectory.path) else {
                self.directorySource?.cancel()
                self.directorySource = nil
                self.entries = []
                self.entryIsDirectory = []
                self.onDirectoryChanged?()
                return
            }
            self.loadDirectory(self.currentDirectory)
            self.onDirectoryChanged?()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        directorySource = source
    }

    func entry(at row: Int) -> URL? {
        guard entries.indices.contains(row) else { return nil }
        return entries[row]
    }

    func isDirectory(at row: Int) -> Bool {
        guard entryIsDirectory.indices.contains(row) else { return false }
        return entryIsDirectory[row]
    }
    // MARK: Recursive search (async, cancellable)

    func beginRecursiveSearch() {
        let rawQuery = filterQuery.trimmingCharacters(in: .whitespaces)
        guard recursiveSearch, !rawQuery.isEmpty else { return }
        let query = FuzzyQuery(rawQuery)
        activeQuery = query

        let generation: Int
        stateLock.lock()
        searchGeneration += 1
        generation = searchGeneration
        stateLock.unlock()

        let root = currentDirectory.resolvingSymlinksInPath()
        let base = currentDirectory.standardizedFileURL.path
        let includeHidden = showHidden

        entries = []
        entryIsDirectory = []
        matchScores.removeAll()
        matchPositions.removeAll()
        searchStartTime = Date()
        isCrawling = true
        onSearchStarted?()
        onDirectoryChanged?()
        watchDirectory()

        searchQueue.async { [weak self] in
            guard let self = self else { return }

            let fm = FileManager.default
            var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
            if !includeHidden { options.insert(.skipsHiddenFiles) }

            let maxResults = 5000
            let maxVisited = 500_000
            var visited = 0
            var matches: [(url: URL, isDir: Bool)] = []
            var scores: [URL: Int] = [:]
            var positions: [URL: [Int]] = [:]

            if let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: options,
                errorHandler: { _, _ in true }
            ) {
                var lastReported = 0
                for case let item as URL in enumerator {
                    if self.searchShouldStop(generation) { break }
                    visited += 1
                    if visited >= maxVisited || matches.count >= maxResults { break }

                    // Report on items *scanned*, not just items matched: a query
                    // that matches rarely would otherwise leave the line stuck on
                    // "Searching…" for the whole crawl.
                    if visited - lastReported >= 250 {
                        lastReported = visited
                        let visitedSnapshot = visited
                        let matchCount = matches.count
                        DispatchQueue.main.async {
                            guard self.generationIsCurrent(generation) else { return }
                            self.onSearchProgress?(visitedSnapshot, matchCount)
                        }
                    }

                    // Match against the same relative path the row will display,
                    // so highlight offsets always line up.
                    let name = FileTreeDataSource.relativeName(for: item, base: base)
                    guard let match = query.match(name) else { continue }
                    var itemIsDir: ObjCBool = false
                    _ = fm.fileExists(atPath: item.path, isDirectory: &itemIsDir)
                    matches.append((item, itemIsDir.boolValue && !isPackage(item)))
                    scores[item] = match.score
                    if !match.positions.isEmpty { positions[item] = match.positions }

                    if visited - lastReported >= 250 {
                        lastReported = visited
                        let visitedSnapshot = visited
                        let matchCount = matches.count
                        DispatchQueue.main.async {
                            guard self.generationIsCurrent(generation) else { return }
                            self.onSearchProgress?(visitedSnapshot, matchCount)
                        }
                    }
                }
            }

            DispatchQueue.main.async {
                guard self.generationIsCurrent(generation) else {
                    // Superseded: whichever search replaced this one owns `isCrawling`.
                    return
                }
                self.isCrawling = false
                self.lastScannedCount = visited
                self.entries = matches.map { $0.url }
                self.entryIsDirectory = matches.map { $0.isDir }
                self.matchScores = scores
                self.matchPositions = positions
                self.resortCurrentEntries()
                // The results are only visible once the table reloads, so do it here
                // rather than waiting for the periodic metadata refresh to notice.
                self.onDirectoryChanged?()
                // Only a cancel can still show up here as "stopped": a superseded
                // search has already been filtered out by the generation check.
                let cancelled = self.searchShouldStop(generation)
                let elapsed = Date().timeIntervalSince(self.searchStartTime)
                self.onSearchFinished?(visited, matches.count, elapsed, cancelled)
            }
        }
    }

    func cancelSearch() {
        stateLock.lock()
        cancelledGeneration = searchGeneration
        stateLock.unlock()
    }

    private func invalidateSearch() {
        stateLock.lock()
        searchGeneration += 1
        stateLock.unlock()
    }

    private func generationIsCurrent(_ generation: Int) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return generation == searchGeneration
    }

    private func searchShouldStop(_ generation: Int) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return generation != searchGeneration || cancelledGeneration == generation
    }

    /// The string shown for `url` in the list: path relative to the current
    /// directory while recursively searching, otherwise the file name. The
    /// recursive search matches against this same string, so the highlight
    /// offsets it records always line up with the rendered row.
    func displayName(for url: URL) -> String {
        guard recursiveSearch, !activeQuery.isEmpty else { return url.lastPathComponent }
        return FileTreeDataSource.relativeName(for: url, base: currentDirectory.standardizedFileURL.path)
    }

    static func relativeName(for url: URL, base: String) -> String {
        // `base` already ends in "/" when the search is rooted at "/", so don't
        // blindly append another one (that made every path look absolute-mismatched
        // and fall back to the bare file name).
        let prefix = base.hasSuffix("/") ? base : base + "/"
        let path = url.path
        if path.hasPrefix(prefix), path.count > prefix.count {
            return String(path.dropFirst(prefix.count))
        }
        return url.lastPathComponent
    }

    /// Renders `name` with the characters the query matched emphasised, mapping
    /// the matcher's character offsets onto UTF-16 ranges for the attributed string.
    func highlightedName(_ name: String, positions: [Int], color: NSColor, font: NSFont?) -> NSAttributedString {
        let baseFont = font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let highlighted = Set(positions)
        // An attributed string brings its own paragraph style, and without one the
        // cell wraps long (relative) search paths instead of truncating them — the
        // second line then falls outside the row height and gets cut off.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let attributed = NSMutableAttributedString(string: name, attributes: [
            .foregroundColor: color,
            .font: baseFont,
            .paragraphStyle: paragraph,
        ])

        var offset = 0
        for (index, character) in name.enumerated() {
            if highlighted.contains(index) {
                let range = NSRange(location: offset, length: character.utf16.count)
                attributed.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: range)
                attributed.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: baseFont.pointSize), range: range)
            }
            offset += character.utf16.count
        }
        return attributed
    }

    func attributes(for url: URL) -> [FileAttributeKey: Any] {
        if let cached = attributeCache[url] { return cached }
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        attributeCache[url] = attrs
        return attrs
    }

    // MARK: Thumbnails

    private func isImageFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    func thumbnail(for url: URL, isDir: Bool) -> NSImage? {
        guard !isDir, isImageFile(url) else { return nil }
        if let cached = thumbnailCache[url] { return cached }
        requestThumbnail(for: url)
        return nil
    }

    private func requestThumbnail(for url: URL) {
        guard !thumbnailRequests.contains(url) else { return }
        thumbnailRequests.insert(url)

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: NSSize(width: 32, height: 32),
            scale: 2.0,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.thumbnailRequests.remove(url)
                guard let image = representation?.nsImage else { return }
                if self.thumbnailCache.count > 500 { self.thumbnailCache.removeAll() }
                self.thumbnailCache[url] = image
                self.onThumbnailReady?(url)
            }
        }
    }

    private func size(for url: URL, isDir: Bool) -> Int64 {
        guard !isDir else { return 0 }
        if let size = attributes(for: url)[.size] as? NSNumber { return size.int64Value }
        return 0
    }

    private func date(for url: URL) -> Date? {
        attributes(for: url)[.modificationDate] as? Date
    }

    private func nameComparison(_ a: URL, _ b: URL) -> ComparisonResult {
        a.lastPathComponent.localizedCaseInsensitiveCompare(b.lastPathComponent)
    }

    private func compare(_ a: URL, _ b: URL, isDir: Bool) -> ComparisonResult {
        switch sortKey {
        case "size":
            let sa = size(for: a, isDir: isDir)
            let sb = size(for: b, isDir: isDir)
            if sa == sb { return nameComparison(a, b) }
            return sa < sb ? .orderedAscending : .orderedDescending
        case "date":
            let da = date(for: a) ?? .distantPast
            let db = date(for: b) ?? .distantPast
            if da == db { return nameComparison(a, b) }
            return da < db ? .orderedAscending : .orderedDescending
        default:
            return nameComparison(a, b)
        }
    }

    private func sortedForDisplay(_ items: [(url: URL, isDir: Bool)]) -> [(url: URL, isDir: Bool)] {
        let ascending = sortAscending
        if !activeQuery.isEmpty {
            // Best match first while searching; the column sort breaks ties.
            return items.sorted { a, b in
                let sa = matchScores[a.url] ?? 0
                let sb = matchScores[b.url] ?? 0
                if sa != sb { return sa > sb }
                let result = compare(a.url, b.url, isDir: a.isDir)
                return ascending ? result == .orderedAscending : result == .orderedDescending
            }
        }
        return items.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir }
            let result = compare(a.url, b.url, isDir: a.isDir)
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private func resortCurrentEntries() {
        let items = zip(entries, entryIsDirectory).map { (url: $0.0, isDir: $0.1) }
        let sorted = sortedForDisplay(items)
        entries = sorted.map { $0.url }
        entryIsDirectory = sorted.map { $0.isDir }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else { return }
        sortKey = key
        sortAscending = descriptor.ascending
        updateHeaderTitles(tableView)
        resortCurrentEntries()
        onDirectoryChanged?()
    }

    /// Marks the sorted column's header with ▲ (ascending) or ▼ (descending) so
    /// the active sort is obvious.
    func updateHeaderTitles(_ tableView: NSTableView) {
        for column in tableView.tableColumns {
            let base: String
            switch column.identifier.rawValue {
            case "size": base = "Size"
            case "date": base = "Date Modified"
            default: base = "Name"
            }
            column.title = column.identifier.rawValue == sortKey
                ? base + (sortAscending ? "  ▲" : "  ▼")
                : base
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row), let column = tableColumn else { return nil }
        let url = entries[row]
        let isDir = entryIsDirectory[row]

        switch column.identifier.rawValue {
        case "name":
            let identifier = NSUserInterfaceItemIdentifier("fileCell")
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = identifier

                let imageView = NSImageView()
                imageView.translatesAutoresizingMaskIntoConstraints = false
                imageView.imageScaling = .scaleProportionallyUpOrDown
                cell.addSubview(imageView)
                cell.imageView = imageView

                let textField = NSTextField()
                textField.isBordered = false
                textField.isEditable = false
                textField.isSelectable = false
                textField.backgroundColor = .clear
                // One line, truncated in the middle: recursively-searched rows show
                // a relative path, which is far too long for the column. Wrapping
                // would push the second line outside the fixed 24pt row height and
                // clip it. The full path is available from the tooltip.
                textField.usesSingleLineMode = true
                textField.maximumNumberOfLines = 1
                textField.lineBreakMode = .byTruncatingMiddle
                textField.cell?.wraps = false
                textField.allowsExpansionToolTips = true
                textField.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(textField)
                cell.textField = textField

                NSLayoutConstraint.activate([
                    imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                    imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    imageView.widthAnchor.constraint(equalToConstant: 16),
                    imageView.heightAnchor.constraint(equalToConstant: 16),

                    textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                    textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                    textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }

            let color: NSColor
            if isDir {
                color = .labelColor
            } else if url.pathExtension.isEmpty {
                color = .secondaryLabelColor
            } else {
                color = .labelColor
            }
            cell.textField?.textColor = color
            let name = displayName(for: url)
            if let positions = matchPositions[url], !positions.isEmpty,
               let textField = cell.textField {
                textField.attributedStringValue = highlightedName(name, positions: positions, color: color, font: textField.font)
            } else {
                cell.textField?.stringValue = name
            }
            cell.textField?.toolTip = url.path
            if let thumbnail = thumbnail(for: url, isDir: isDir) {
                cell.imageView?.image = thumbnail
            } else {
                cell.imageView?.image = NSWorkspace.shared.icon(forFile: url.path)
            }
            return cell

        case "size":
            let identifier = NSUserInterfaceItemIdentifier("sizeCell")
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = identifier

                let textField = NSTextField()
                textField.isBordered = false
                textField.isEditable = false
                textField.isSelectable = false
                textField.backgroundColor = .clear
                textField.alignment = .right
                textField.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(textField)
                cell.textField = textField

                NSLayoutConstraint.activate([
                    textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                    textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }

            if isDir {
                cell.textField?.stringValue = "--"
            } else {
                let size = (attributes(for: url)[.size] as? Int) ?? 0
                cell.textField?.stringValue = ByteCountFormatter.string(
                    fromByteCount: Int64(size),
                    countStyle: .file
                )
            }
            return cell

        case "date":
            let identifier = NSUserInterfaceItemIdentifier("dateCell")
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = identifier

                let textField = NSTextField()
                textField.isBordered = false
                textField.isEditable = false
                textField.isSelectable = false
                textField.backgroundColor = .clear
                textField.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(textField)
                cell.textField = textField

                NSLayoutConstraint.activate([
                    textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                    textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }

            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            if let modDate = attributes(for: url)[.modificationDate] as? Date {
                cell.textField?.stringValue = formatter.string(from: modDate)
            } else {
                cell.textField?.stringValue = ""
            }
            return cell

        default:
            return nil
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        true
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        onSelectionChanged?()
    }

    // MARK: Drag & drop — source

    func tableView(_ tableView: NSTableView, writeRowsWith rowIndexes: IndexSet, to pboard: NSPasteboard) -> Bool {
        let urls = rowIndexes.compactMap { entries.indices.contains($0) ? entries[$0] : nil }
        guard !urls.isEmpty else { return false }
        pboard.clearContents()
        pboard.writeObjects(urls as [NSURL])
        return true
    }

    // MARK: Drag & drop — destination

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard let sourceURLs = droppedFileURLs(from: info) else { return [] }

        let dropOnFolder = row < entries.count && entryIsDirectory[row]
        let targetDir = dropOnFolder ? entries[row] : currentDirectory

        for source in sourceURLs {
            let srcPath = source.standardizedFileURL.path
            let dstPath = targetDir.standardizedFileURL.path
            if dstPath == srcPath { return [] }
            if dstPath.hasPrefix(srcPath + "/") { return [] }
        }

        let isMove = info.draggingSourceOperationMask.contains(.move)
        if isMove, sourceURLs.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == targetDir.standardizedFileURL }) {
            return []
        }

        if dropOnFolder {
            tableView.setDropRow(row, dropOperation: .on)
        } else {
            tableView.setDropRow(min(row, entries.count), dropOperation: .above)
        }

        return isMove ? .move : .copy
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let sourceURLs = droppedFileURLs(from: info) else { return false }

        let dropOnFolder = dropOperation == .on && row < entries.count && entryIsDirectory[row]
        let targetDir = dropOnFolder ? entries[row] : currentDirectory
        let isMove = info.draggingSourceOperationMask.contains(.move)
        let fm = FileManager.default

        var anySucceeded = false
        for source in sourceURLs {
            let sourceParent = source.deletingLastPathComponent().standardizedFileURL.path
            if isMove && sourceParent == targetDir.standardizedFileURL.path { continue }
            let destination = uniqueDestinationURL(in: targetDir, name: source.lastPathComponent)
            do {
                if isMove {
                    try fm.moveItem(at: source, to: destination)
                } else {
                    try fm.copyItem(at: source, to: destination)
                }
                anySucceeded = true
            } catch {
                NSLog("Drag & drop %@ -> %@ failed: %@",
                      source.path, destination.path, error.localizedDescription)
            }
        }

        if anySucceeded {
            loadDirectory(currentDirectory)
            onDirectoryChanged?()
        }
        return anySucceeded
    }

    private func droppedFileURLs(from info: NSDraggingInfo) -> [URL]? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) as? [URL], !urls.isEmpty else { return nil }
        return urls
    }
}
