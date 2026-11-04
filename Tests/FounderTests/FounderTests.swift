import XCTest
@testable import Founder

final class FuzzyQueryTests: XCTestCase {
    func testEmptyQueryMatchesEverything() {
        let query = FuzzyQuery("   ")
        XCTAssertTrue(query.isEmpty)
        XCTAssertNotNil(query.match("anything at all"))
    }

    func testFuzzySubsequence() {
        let query = FuzzyQuery("rfp")
        XCTAssertNotNil(query.match("ReserveForPlan.pdf"))
        XCTAssertNil(query.match("invoice.pdf"))
    }

    func testAllTermsMustMatch() {
        let query = FuzzyQuery("pr rfp")
        XCTAssertNotNil(query.match("PurchaseRequestForPlan.pdf"))
        XCTAssertNil(query.match("PurchaseRequest.pdf"))
    }

    func testExactSubstring() {
        let query = FuzzyQuery("'plan")
        XCTAssertNotNil(query.match("ReserveForPlan.pdf"))
        XCTAssertNil(query.match("ReserveF-o-r-P-l-a-n.pdf"))
    }

    func testPrefixAndSuffix() {
        XCTAssertNotNil(FuzzyQuery("^Reserve").match("ReserveForPlan.pdf"))
        XCTAssertNil(FuzzyQuery("^Reserve").match("MyReserveForPlan.pdf"))
        XCTAssertNotNil(FuzzyQuery(".pdf$").match("ReserveForPlan.pdf"))
        XCTAssertNil(FuzzyQuery(".pdf$").match("ReserveForPlan.pdf.bak"))
        XCTAssertNotNil(FuzzyQuery("^ReserveForPlan.pdf$").match("ReserveForPlan.pdf"))
        XCTAssertNil(FuzzyQuery("^Reserve$").match("ReserveForPlan.pdf"))
    }

    func testNegation() {
        let query = FuzzyQuery("rfp !archive")
        XCTAssertNotNil(query.match("ReserveForPlan.pdf"))
        XCTAssertNil(query.match("ReserveForPlan.archive.pdf"))
    }

    func testSmartCase() {
        XCTAssertNotNil(FuzzyQuery("rfp").match("reserveforplan.pdf"))
        XCTAssertNil(FuzzyQuery("RFP").match("reserveforplan.pdf"))
        XCTAssertNotNil(FuzzyQuery("RFP").match("ReserveForPlan.pdf"))
    }

    func testCaseInsensitiveAnchors() {
        XCTAssertNotNil(FuzzyQuery("'plan").match("ReserveForPlan.PDF"))
        XCTAssertNotNil(FuzzyQuery(".pdf$").match("ReserveForPlan.PDF"))
    }

    func testWordBoundaryBeatsMidWord() {
        let query = FuzzyQuery("plan")
        let boundary = query.match("ReserveForPlan.pdf")
        let midword = query.match("reserveXplanX.pdf")
        XCTAssertNotNil(boundary)
        XCTAssertNotNil(midword)
        XCTAssertGreaterThan(boundary!.score, midword!.score)
    }

    func testConsecutiveRunBeatsScattered() {
        let query = FuzzyQuery("abc")
        let consecutive = query.match("abc.txt")
        let scattered = query.match("a-b-c.txt")
        XCTAssertNotNil(consecutive)
        XCTAssertNotNil(scattered)
        XCTAssertGreaterThan(consecutive!.score, scattered!.score)
    }

    func testPositionsPointAtMatchedCharacters() {
        let query = FuzzyQuery("rfp")
        guard let match = query.match("ReserveForPlan.pdf") else {
            return XCTFail("expected a match")
        }
        let characters = Array("ReserveForPlan.pdf")
        let matched = match.positions.map { characters[$0] }.map(String.init)
        XCTAssertEqual(matched, ["R", "F", "P"])
    }

    func testPositionsForAnchoredMatch() {
        guard let match = FuzzyQuery(".pdf$").match("ReserveForPlan.pdf") else {
            return XCTFail("expected a match")
        }
        XCTAssertEqual(match.positions, [14, 15, 16, 17])
    }
}

final class SearchStatusTests: XCTestCase {
    func testDurationFormatting() {
        XCTAssertEqual(FounderAppDelegate.formattedDuration(0.05), "50 ms")
        XCTAssertEqual(FounderAppDelegate.formattedDuration(0.406), "406 ms")
        XCTAssertEqual(FounderAppDelegate.formattedDuration(1.24), "1.2 s")
    }

    func testCountFormatting() {
        XCTAssertEqual(FounderAppDelegate.formattedCount(0), "0")
        XCTAssertFalse(FounderAppDelegate.formattedCount(5401).isEmpty)
    }
}

final class NameColumnTests: XCTestCase {
    func testHighlightedNameTruncatesInsteadOfWrapping() {
        let dataSource = FileTreeDataSource()
        let attributed = dataSource.highlightedName(
            "Documents/Sync/Projects/Nested/deep/file.swift",
            positions: [0, 10],
            color: .labelColor,
            font: nil
        )
        let paragraph = attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(paragraph?.lineBreakMode, .byTruncatingMiddle)
        XCTAssertEqual(attributed.string, "Documents/Sync/Projects/Nested/deep/file.swift")
    }
}

final class RelativeNameTests: XCTestCase {
    func testRelativeToVolumeRoot() {
        let base = URL(fileURLWithPath: "/").standardizedFileURL.path
        XCTAssertEqual(
            FileTreeDataSource.relativeName(for: URL(fileURLWithPath: "/usr/lib/python3.14/os.py"), base: base),
            "usr/lib/python3.14/os.py"
        )
    }

    func testRelativeToHome() {
        let base = URL(fileURLWithPath: "/Users/someone").standardizedFileURL.path
        XCTAssertEqual(
            FileTreeDataSource.relativeName(for: URL(fileURLWithPath: "/Users/someone/Documents/a/b.txt"), base: base),
            "Documents/a/b.txt"
        )
        XCTAssertEqual(
            FileTreeDataSource.relativeName(for: URL(fileURLWithPath: "/Users/other/x.txt"), base: base),
            "x.txt"
        )
    }
}

/// Minimal `NSDraggingInfo` so the drop handlers can be exercised without a
/// real drag session (multi-file drags are hard to drive from a test).
final class FakeDraggingInfo: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation
    var draggingLocation: NSPoint = .zero
    var draggingPasteboard: NSPasteboard
    var draggingSource: Any?
    var draggingSequenceNumber: Int = 1
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight = .none
    var draggingFormation: NSDraggingFormation = .none
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }

    init(urls: [URL], operation: NSDragOperation) {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("FounderTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        draggingPasteboard = pasteboard
        draggingSourceOperationMask = operation
        super.init()
    }

    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}

    func resetSpringLoading() {}

    func slideDraggedImage(to screenPoint: NSPoint) {}

    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
}

final class DragAndDropTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FounderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Target"), withIntermediateDirectories: true)
        for name in ["a.txt", "b.txt", "c.txt"] {
            try Data("x".utf8).write(to: root.appendingPathComponent(name))
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func targetRow(in dataSource: FileTreeDataSource) -> Int {
        dataSource.entries.firstIndex { $0.lastPathComponent == "Target" }!
    }

    private func fileURLs() -> [URL] {
        ["a.txt", "b.txt", "c.txt"].map { root.appendingPathComponent($0) }
    }

    func testDroppingSeveralFilesOntoAFolderMovesAllOfThem() {
        let dataSource = FileTreeDataSource()
        dataSource.loadDirectory(root)
        let row = targetRow(in: dataSource)
        let table = NSTableView()
        let info = FakeDraggingInfo(urls: fileURLs(), operation: .move)

        XCTAssertEqual(
            dataSource.tableView(table, validateDrop: info, proposedRow: row, proposedDropOperation: .on),
            .move
        )
        XCTAssertTrue(dataSource.tableView(table, acceptDrop: info, row: row, dropOperation: .on))

        let target = root.appendingPathComponent("Target")
        for name in ["a.txt", "b.txt", "c.txt"] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: target.appendingPathComponent(name).path),
                "\(name) should have been moved into Target"
            )
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path),
                "\(name) should no longer be in the source folder"
            )
        }
    }

    /// After moving files out of the listing, the selection must not slide down
    /// to whatever rows now occupy those numbers (Finder leaves nothing selected).
    func testMovingFilesClearsTheSelectionInsteadOfSlidingIt() {
        let dataSource = FileTreeDataSource()
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: .init("name")))
        table.dataSource = dataSource
        dataSource.owningTableView = table
        dataSource.loadDirectory(root)
        table.reloadData()

        let rows = IndexSet(["a.txt", "b.txt", "c.txt"].compactMap { name in
            dataSource.entries.firstIndex { $0.lastPathComponent == name }
        })
        table.selectRowIndexes(rows, byExtendingSelection: false)
        XCTAssertEqual(table.selectedRowIndexes.count, 3)

        let row = targetRow(in: dataSource)
        let info = FakeDraggingInfo(urls: fileURLs(), operation: .move)
        XCTAssertTrue(dataSource.tableView(table, acceptDrop: info, row: row, dropOperation: .on))

        XCTAssertTrue(
            table.selectedRowIndexes.isEmpty,
            "the moved rows should not leave the rows below them selected"
        )
    }

    func testCopyingSeveralFilesKeepsTheOriginals() {
        let dataSource = FileTreeDataSource()
        dataSource.loadDirectory(root)
        let row = targetRow(in: dataSource)
        let table = NSTableView()
        let info = FakeDraggingInfo(urls: fileURLs(), operation: .copy)

        XCTAssertEqual(
            dataSource.tableView(table, validateDrop: info, proposedRow: row, proposedDropOperation: .on),
            .copy
        )
        XCTAssertTrue(dataSource.tableView(table, acceptDrop: info, row: row, dropOperation: .on))

        let target = root.appendingPathComponent("Target")
        for name in ["a.txt", "b.txt", "c.txt"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent(name).path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path))
        }
    }

    func testDroppingSeveralFilesOntoAFavoriteFolderHandsThemAllOver() {
        let favorites = FavoritesDataSource()
        let target = root.appendingPathComponent("Target")
        favorites.favorites = [FavoriteEntry(path: target.path, depth: 0)]

        var dropped: (URL, [URL], Bool)?
        favorites.onFilesDropped = { dropped = ($0, $1, $2) }
        let table = NSTableView()
        let info = FakeDraggingInfo(urls: fileURLs(), operation: .move)

        XCTAssertEqual(
            favorites.tableView(table, validateDrop: info, proposedRow: 0, proposedDropOperation: .on),
            .move
        )
        XCTAssertTrue(favorites.tableView(table, acceptDrop: info, row: 0, dropOperation: .on))
        XCTAssertEqual(dropped?.0, target)
        XCTAssertEqual(dropped?.1.count, 3)
        XCTAssertEqual(dropped?.2, true)
    }

    func testDroppingAFolderIntoItselfIsRejected() {
        let dataSource = FileTreeDataSource()
        dataSource.loadDirectory(root)
        let row = targetRow(in: dataSource)
        let table = NSTableView()
        let target = root.appendingPathComponent("Target")
        let info = FakeDraggingInfo(urls: [target], operation: .move)

        XCTAssertEqual(
            dataSource.tableView(table, validateDrop: info, proposedRow: row, proposedDropOperation: .on),
            []
        )
    }
}

final class SplitViewTests: XCTestCase {
    /// Builds the real window so the divider lands where it does in the app.
    private func makeSplitView() throws -> GrabbySplitView {
        let delegate = FounderAppDelegate()
        delegate.setupMainWindow()
        let window = try XCTUnwrap(delegate.window)
        // Building the real window must not overwrite the size the app saved in
        // `NSWindow Frame FounderWindow`.
        window.setFrameAutosaveName("")
        window.setContentSize(NSSize(width: 900, height: 620))
        let split = try XCTUnwrap(delegate.splitView as? GrabbySplitView)
        split.layoutSubtreeIfNeeded()
        return split
    }

    /// AppKit only hit-tests the 1 pt divider (so grabs a few points off went to
    /// the favorites table, which starts a row drag instead of resizing).
    func testDividerIsGrabbableBeyondTheDividerLine() throws {
        let split = try makeSplitView()
        let divider = split.subviews[0].frame.maxX
        let superview = try XCTUnwrap(split.superview)

        for offset in [-3.0, -1.0, 1.0, 3.0] {
            let point = split.convert(NSPoint(x: divider + offset, y: 100), to: superview)
            XCTAssertTrue(
                split.hitTest(point) === split,
                "\(offset) points from the divider should still grab it"
            )
        }

        // Well inside the pane the table keeps its clicks, so selecting and
        // dragging favorites still works.
        let away = split.convert(NSPoint(x: divider - 12, y: 100), to: superview)
        XCTAssertFalse(split.hitTest(away) === split)
    }

    /// The first drag on an inactive window used to be spent activating the app,
    /// so the divider looked like it would not move at all.
    func testDividerAcceptsTheClickThatActivatesTheWindow() throws {
        let split = try makeSplitView()
        XCTAssertTrue(split.acceptsFirstMouse(for: nil))
    }
}

final class PathBarTests: XCTestCase {
    private let deepPath = URL(fileURLWithPath:
        "/Users/faucherd/Documents/Sync/MBP-Personal/1273 Washington Street Gloucester/AirBnB/Business Card/Claude/v1.1")

    /// The app window, at a size where the sidebar has room to grow.
    private func makeApp() throws -> FounderAppDelegate {
        let delegate = FounderAppDelegate()
        delegate.setupMainWindow()
        let window = try XCTUnwrap(delegate.window)
        // See SplitViewTests: keep the app's autosaved window size intact.
        window.setFrameAutosaveName("")
        window.setContentSize(NSSize(width: 900, height: 620))
        return delegate
    }

    func testDeepPathIsShortenedToItsLastFolders() throws {
        let delegate = try makeApp()
        delegate.updatePathBar(to: deepPath)
        XCTAssertEqual(delegate.pathControl.url?.path, "/…/Claude/v1.1")
        XCTAssertEqual(delegate.pathControl.toolTip, deepPath.path)
    }

    func testShortPathIsShownWhole() throws {
        let delegate = try makeApp()
        let home = URL(fileURLWithPath: "/Users/faucherd")
        delegate.updatePathBar(to: home)
        XCTAssertEqual(delegate.pathControl.url?.path, "/Users/faucherd")
    }

    func testShownComponentMapsBackToTheRealFolder() throws {
        let delegate = try makeApp()
        delegate.updatePathBar(to: deepPath)
        let clicked = URL(fileURLWithPath: "/…/Claude")
        XCTAssertEqual(
            delegate.realURL(forPathBarURL: clicked).path,
            "/Users/faucherd/Documents/Sync/MBP-Personal/1273 Washington Street Gloucester/AirBnB/Business Card/Claude"
        )
    }

    func testEllipsisMapsToTheFolderHoldingTheFirstShownComponent() throws {
        let delegate = try makeApp()
        delegate.updatePathBar(to: deepPath)
        let clicked = URL(fileURLWithPath: "/…")
        XCTAssertEqual(
            delegate.realURL(forPathBarURL: clicked).path,
            "/Users/faucherd/Documents/Sync/MBP-Personal/1273 Washington Street Gloucester/AirBnB/Business Card"
        )
    }

    /// The bug: a deep path made the file pane demand ~975 pt, so the sidebar
    /// divider could not be dragged right at all.
    func testDeepPathDoesNotPinTheSidebar() throws {
        let delegate = try makeApp()
        let window = try XCTUnwrap(delegate.window)
        let split = try XCTUnwrap(delegate.splitView)

        delegate.updatePathBar(to: deepPath)
        split.layoutSubtreeIfNeeded()
        XCTAssertEqual(window.frame.width, 900, accuracy: 1, "a deep path must not stretch the window")

        split.setPosition(420, ofDividerAt: 0)
        split.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            split.subviews[0].frame.width, 420, accuracy: 1,
            "the sidebar must be able to grow past the old 279 pt limit"
        )
    }

    /// Even a single huge component (which shortening cannot help with) must not
    /// put a floor under the file pane's width.
    func testVeryLongFolderNameDoesNotPinTheSidebar() throws {
        let delegate = try makeApp()
        let split = try XCTUnwrap(delegate.splitView)
        let longName = String(repeating: "very-long-folder-name-", count: 8)
        delegate.updatePathBar(to: URL(fileURLWithPath: "/tmp/" + longName))
        split.layoutSubtreeIfNeeded()

        split.setPosition(420, ofDividerAt: 0)
        split.layoutSubtreeIfNeeded()
        XCTAssertEqual(split.subviews[0].frame.width, 420, accuracy: 1)
    }
}

final class MetadataRefreshTests: XCTestCase {
    /// `refreshMetadata` reloads the table, and `NSTableView.reloadData()` drops
    /// the selection — so the two-second refresh used to deselect whatever had
    /// just been clicked.
    func testMetadataRefreshKeepsTheSelection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FounderRefresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["a.txt", "b.txt", "c.txt"] {
            try Data("x".utf8).write(to: root.appendingPathComponent(name))
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let delegate = FounderAppDelegate()
        delegate.setupMainWindow()
        delegate.window.setFrameAutosaveName("")
        let table = try XCTUnwrap(delegate.fileTreeTableView)
        delegate.fileTreeDataSource.loadDirectory(root)
        table.reloadData()

        let expected = delegate.fileTreeDataSource.entries[1]
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 1))

        delegate.refreshMetadata()

        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 1))
        XCTAssertEqual(delegate.selectedFileURLs, [expected])
    }
}
