import XCTest
import AppKit
@testable import MagnusVector

final class HierarchyTests: XCTestCase {
    private func session(_ count: Int = 3) -> EditorSession {
        let shapes = (0..<count).map { VectorShape(name: "Shape \($0)", kind: .rectangle, x: Double($0 * 30), y: 10, width: 20, height: 20, stroke: nil) }
        return EditorSession(document: VectorDocument(project: VectorProject(width: 200, height: 120, shapes: shapes)))
    }
    private func checkpoint(_ s: EditorSession) { if s.history.groupingLevel > 0 { s.history.endUndoGrouping() } }
    private func group(_ s: EditorSession, ids: [UUID]) throws -> UUID {
        s.selection = Set(ids); XCTAssertTrue(s.canGroup); s.groupSelection(); checkpoint(s)
        return try XCTUnwrap(s.selectedNode?.id)
    }
    func testLegacyFlatDocumentRemainsUnchangedUntilStructuralEdit() throws {
        let s = session(), original = s.document.project
        let decoded = try JSONDecoder().decode(VectorProject.self, from: JSONEncoder().encode(original)).validated()
        XCTAssertNil(decoded.hierarchy); XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.rootNodes.map(\.id), original.shapes.map(\.id))
        s.newLayer()
        XCTAssertEqual(s.document.project.version, 2)
        XCTAssertEqual(s.document.project.shapes, original.shapes)
        XCTAssertNoThrow(try s.document.project.validated())
    }
    func testGroupUngroupPreservesGeometryAndStackingAndUndoSelection() throws {
        let s = session(), original = s.document.project
        let ids = original.shapes.map(\.id)
        let id = try group(s, ids: [ids[0], ids[1]])
        XCTAssertEqual(s.document.project.shapes, original.shapes)
        XCTAssertEqual(s.selectedNode?.children.map(\.id), Array(ids.prefix(2)))
        XCTAssertEqual(s.selectedShapes.count, 2)
        XCTAssertNil(s.selectedShape)
        s.undo()
        XCTAssertEqual(s.document.project, original); XCTAssertEqual(s.selection, Set(ids.prefix(2)))
        s.redo(); XCTAssertEqual(s.selection, [id])
        s.ungroupSelection(); checkpoint(s)
        XCTAssertEqual(s.document.project.rootNodes.map(\.id), ids)
        XCTAssertEqual(s.document.project.shapes, original.shapes)
        XCTAssertEqual(s.selection, Set(ids.prefix(2)))
        s.undo(); XCTAssertEqual(s.selection, [id]); XCTAssertEqual(s.selectedNode?.kind, .group)
    }
    func testNonAdjacentGroupingUsesFrontmostSelectedSlot() throws {
        let s = session(4), ids = s.document.project.shapes.map(\.id)
        let groupID = try group(s, ids: [ids[0], ids[2]])
        XCTAssertEqual(s.document.project.rootNodes.map(\.id), [ids[1], groupID, ids[3]])
        XCTAssertEqual(s.document.project.shapes.map(\.id), [ids[1], ids[0], ids[2], ids[3]])
        s.ungroupSelection()
        XCTAssertEqual(s.document.project.rootNodes.map(\.id), [ids[1], ids[0], ids[2], ids[3]])
        XCTAssertNoThrow(try s.document.project.validated())
    }
    func testNestedGroupsSelectAsUnitsAndIsolationScopesSelection() throws {
        let s = session(), ids = s.document.project.shapes.map(\.id)
        let inner = try group(s, ids: Array(ids.prefix(2)))
        let outer = try group(s, ids: [inner, ids[2]])
        let index = s.document.project.hierarchyIndex
        XCTAssertEqual(index.canvasTarget(for: ids[0], inside: nil), outer)
        s.enterGroup(outer); s.selectAll()
        XCTAssertEqual(s.selection, [inner, ids[2]])
        XCTAssertEqual(index.canvasTarget(for: ids[0], inside: outer), inner)
        s.enterGroup(inner); s.selectAll()
        XCTAssertEqual(s.selection, Set(ids.prefix(2)))
        XCTAssertEqual(index.canvasTarget(for: ids[0], inside: inner), ids[0])
        XCTAssertNil(index.canvasTarget(for: ids[2], inside: inner))
        s.exitGroup(); XCTAssertEqual(s.isolatedGroupID, outer); XCTAssertEqual(s.selection, [inner])
        s.exitGroup(); XCTAssertNil(s.isolatedGroupID); XCTAssertEqual(s.selection, [outer])
    }
    func testGroupMoveResizeAndAlignKeepRelativePositionsAndBezierHandles() throws {
        let s = session()
        for i in s.document.project.shapes.indices { s.document.project.shapes[i].convertToPath() }
        let originals = s.document.project.shapes, ids = originals.map(\.id)
        _ = try group(s, ids: Array(ids.prefix(2)))
        s.moveSelection(CGSize(width: 7, height: 9))
        XCTAssertEqual(s.document.project.shapes[0].bounds.origin, CGPoint(x: 7, y: 19))
        XCTAssertEqual(s.document.project.shapes[1].bounds.origin, CGPoint(x: 37, y: 19))
        XCTAssertEqual(s.document.project.shapes[2], originals[2])
        s.setGeometry("width", value: 100)
        XCTAssertEqual(s.document.project.shapes[0].bounds.width, 40)
        XCTAssertEqual(s.document.project.shapes[1].bounds.minX, 67)
        s.align("right")
        XCTAssertEqual(s.selectionBounds?.maxX, 200)
        XCTAssertEqual(s.document.project.shapes[1].bounds.minX - s.document.project.shapes[0].bounds.minX, 60)
        XCTAssertEqual(s.document.project.shapes[2], originals[2])
        XCTAssertNoThrow(try s.document.project.validated())
    }
    func testAncestorSelectionDoesNotTransformChildrenTwice() throws {
        let s = session(), ids = s.document.project.shapes.map(\.id)
        let id = try group(s, ids: Array(ids.prefix(2)))
        s.selection = [id, ids[0]]
        s.moveSelection(CGSize(width: 5, height: 0))
        XCTAssertEqual(s.document.project.shapes[0].x, 5)
        XCTAssertEqual(s.document.project.shapes[1].x, 35)
        s.deleteSelection()
        XCTAssertEqual(s.document.project.shapes.map(\.id), [ids[2]])
        XCTAssertNoThrow(try s.document.project.validated())
    }
    func testNestedLayersDrawingDestinationMovesAndCycleProtection() throws {
        let s = session(), ids = s.document.project.shapes.map(\.id)
        let groupID = try group(s, ids: Array(ids.prefix(2)))
        s.newLayer(); let layer = try XCTUnwrap(s.activeLayerID)
        s.newLayer(inside: layer); let sublayer = try XCTUnwrap(s.activeLayerID)
        s.moveNodes([groupID], to: sublayer)
        let index = s.document.project.hierarchyIndex
        XCTAssertEqual(index.parents[groupID], sublayer)
        XCTAssertEqual(index.parents[sublayer], layer)
        XCTAssertFalse(s.canMove([layer], to: sublayer))
        XCTAssertFalse(s.canMove([groupID], to: groupID))
        XCTAssertFalse(s.canMove([layer], to: groupID))
        let before = s.document.project
        s.moveNodes([layer], to: sublayer); XCTAssertEqual(s.document.project, before)
        let destination = try XCTUnwrap(s.insertionDestination())
        XCTAssertEqual(destination.parent, sublayer)
        let drawn = VectorShape(name: "Drawn on sublayer", kind: .ellipse)
        s.document.project.appendShapes([drawn], to: destination.parent)
        XCTAssertEqual(s.document.project.hierarchyIndex.parents[drawn.id], sublayer)
        s.enterGroup(groupID)
        XCTAssertEqual(s.insertionDestination()?.parent, groupID)
        s.selection = [ids[0], ids[2]]; XCTAssertFalse(s.canGroup)
        XCTAssertNoThrow(try s.document.project.validated())
    }
    func testLayerAndGroupLocksProtectDescendantsAndDoNotPartiallyTransform() throws {
        let s = session(), ids = s.document.project.shapes.map(\.id)
        let groupID = try group(s, ids: Array(ids.prefix(2)))
        s.toggleNode(ids[0], visibility: false)
        let locked = s.document.project
        s.selection = [groupID]; s.moveSelection(CGSize(width: 20, height: 20)); s.deleteSelection(); s.duplicate()
        XCTAssertEqual(s.document.project, locked)
        s.toggleNode(ids[0], visibility: false)
        s.newLayer(); let layerID = try XCTUnwrap(s.activeLayerID)
        s.moveNodes([groupID], to: layerID)
        s.toggleNode(layerID, visibility: false)
        s.selection = [ids[0]]; s.moveSelection(CGSize(width: 10, height: 0))
        XCTAssertEqual(s.document.project.shapes.first { $0.id == ids[0] }?.x, 0)
        XCTAssertNil(s.insertionDestination())
        XCTAssertTrue(s.document.project.hierarchyIndex.locked.contains(ids[1]))
        XCTAssertNil(s.document.project.hierarchyIndex.canvasTarget(for: ids[1], inside: nil))
        s.toggleNode(layerID, visibility: false)
        XCTAssertFalse(s.document.project.hierarchyIndex.locked.contains(ids[1]))
    }
    func testHidingParentPreservesChildFlagsAndAffectsNativeAndSVGExports() throws {
        let s = session(), ids = s.document.project.shapes.map(\.id)
        let groupID = try group(s, ids: Array(ids.prefix(2)))
        s.toggleNode(ids[0], visibility: true)
        s.toggleNode(groupID, visibility: true)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: VectorExporter.data(s.document.project, format: .png)))
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 35, y: 15)).alphaComponent, 0)
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 65, y: 15)).alphaComponent, 0.9)
        let svg = try XMLDocument(data: SVGExporter.data(s.document.project), options: [])
        let node = try XCTUnwrap(svg.nodes(forXPath: "//*[@id='group_\(groupID.uuidString.lowercased())']").first as? XMLElement)
        XCTAssertEqual(node.attribute(forName: "display")?.stringValue, "none")
        XCTAssertEqual(try node.nodes(forXPath: ".//*[starts-with(@id,'object_')]").count, 2)
        let flat = try XMLDocument(data: SVGExporter.data(s.document.project, options: .init(preserveEditableLayers: false)), options: [])
        XCTAssertEqual(try flat.nodes(forXPath: "//*[starts-with(@id,'object_') and @display='none']").count, 2)
        XCTAssertEqual(try flat.nodes(forXPath: "//*[@data-magdobe-kind]").count, 0)
        s.toggleNode(groupID, visibility: true)
        XCTAssertFalse(s.document.project.shapes.first { $0.id == ids[0] }!.visible)
        XCTAssertTrue(s.document.project.shapes.first { $0.id == ids[1] }!.visible)
        let fit = try XMLDocument(data: SVGExporter.data(s.document.project, options: .init(entireArtboard: false)), options: [])
        XCTAssertEqual(fit.rootElement()?.attribute(forName: "viewBox")?.stringValue, "30.0 10.0 50.0 20.0")
    }
    func testDuplicateAndClipboardPreserveNestedStructureWithFreshIDs() throws {
        let s = session(), ids = s.document.project.shapes.map(\.id)
        let inner = try group(s, ids: Array(ids.prefix(2)))
        let outer = try group(s, ids: [inner, ids[2]])
        let original = s.document.project
        s.duplicate(); checkpoint(s)
        XCTAssertEqual(s.document.project.shapes.count, 6)
        let copy = try XCTUnwrap(s.selectedNode)
        XCTAssertNotEqual(copy.id, outer); XCTAssertEqual(copy.children[0].kind, .group)
        XCTAssertEqual(copy.name, "Group copy")
        XCTAssertTrue(Set(original.hierarchyIndex.order).isDisjoint(with: Set([copy.id] + copy.objectIDs)))
        let clipboard = try XCTUnwrap(s.selectionProject())
        let encoded = try JSONEncoder().encode(clipboard)
        let decoded = try JSONDecoder().decode(VectorProject.self, from: encoded).validated()
        let target = session(0); target.pasteProject(decoded)
        XCTAssertEqual(target.document.project.shapes.count, 3)
        XCTAssertEqual(target.selectedNode?.children[0].kind, .group)
        XCTAssertEqual(target.document.project.shapes[0].x, 40)
        XCTAssertNoThrow(try target.document.project.validated())
        s.undo(); XCTAssertEqual(s.document.project, original); XCTAssertEqual(s.selection, [outer])
        s.redo(); XCTAssertEqual(s.document.project.shapes.count, 6)
    }
    func testReorderingStaysInsideParentAndMovesWholeGroups() throws {
        let s = session(4), ids = s.document.project.shapes.map(\.id)
        let groupID = try group(s, ids: Array(ids.prefix(2)))
        s.selection = [ids[0]]; s.reorder(true)
        XCTAssertEqual(s.document.project.shapes.map(\.id), [ids[1], ids[0], ids[2], ids[3]])
        XCTAssertEqual(s.document.project.hierarchyIndex.parents[ids[0]], groupID)
        s.selection = [groupID]; s.reorder(true)
        XCTAssertEqual(s.document.project.shapes.map(\.id), [ids[2], ids[3], ids[1], ids[0]])
        s.reorder(false)
        XCTAssertEqual(s.document.project.shapes.map(\.id), [ids[1], ids[0], ids[2], ids[3]])
        XCTAssertNoThrow(try s.document.project.validated())
    }
    func testEmptyLayersPersistAndDeletingIsolatedGroupExitsSafely() throws {
        let s = session(), ids = s.document.project.shapes.map(\.id)
        let groupID = try group(s, ids: Array(ids.prefix(2)))
        s.newLayer(); let layerID = try XCTUnwrap(s.activeLayerID)
        s.renameSelection("Foreground & <details>")
        s.enterGroup(groupID)
        s.selection = [groupID]; s.deleteSelection(); checkpoint(s)
        XCTAssertNil(s.isolatedGroupID)
        XCTAssertNotNil(s.document.project.hierarchyIndex.nodes[layerID])
        let restored = try JSONDecoder().decode(VectorProject.self, from: JSONEncoder().encode(s.document.project)).validated()
        XCTAssertEqual(restored, s.document.project)
        let xml = try XMLDocument(data: SVGExporter.data(restored), options: [])
        let exportedLayer = try XCTUnwrap(xml.nodes(forXPath: "//*[@data-magdobe-kind='layer']").first as? XMLElement)
        XCTAssertEqual(exportedLayer.attribute(forName: "data-name")?.stringValue, "Foreground & <details>")
        s.undo(); XCTAssertEqual(s.isolatedGroupID, groupID)
    }
    func testRejectsMissingDuplicateOrMisorderedReferencesAndExcessiveDepth() {
        let s = session(1), p = s.document.project, shape = p.shapes[0]
        XCTAssertThrowsError(try VectorProject(version: 2, shapes: p.shapes).validated())
        XCTAssertThrowsError(try VectorProject(version: 2, shapes: p.shapes, hierarchy: []).validated())
        XCTAssertThrowsError(try VectorProject(version: 2, shapes: p.shapes, hierarchy: [.object(shape.id), .object(shape.id)]).validated())
        XCTAssertThrowsError(try VectorProject(version: 2, shapes: p.shapes, hierarchy: [.object(UUID())]).validated())
        let invalid = VectorNode(id: shape.id, kind: .group, children: [.object(shape.id)])
        XCTAssertThrowsError(try VectorProject(version: 2, shapes: p.shapes, hierarchy: [invalid]).validated())
        let layer = VectorNode(kind: .layer, name: "Invalid nested layer")
        XCTAssertThrowsError(try VectorProject(version: 2, hierarchy: [VectorNode(kind: .group, children: [layer])]).validated())
        var nested = VectorNode.object(shape.id)
        for _ in 0..<66 { nested = VectorNode(kind: .group, children: [nested]) }
        XCTAssertThrowsError(try VectorProject(version: 2, shapes: p.shapes, hierarchy: [nested]).validated())
        let two = session(2).document.project
        XCTAssertThrowsError(try VectorProject(version: 2, shapes: two.shapes, hierarchy: two.rootNodes.reversed()).validated())
    }
    func testCopyHiddenGroupKeepsItsChildVisibilityFlags() throws {
        let s = session(), ids = s.document.project.shapes.map(\.id)
        let groupID = try group(s, ids: Array(ids.prefix(2)))
        s.toggleNode(ids[0], visibility: true)
        s.toggleNode(groupID, visibility: true)
        s.selection = [groupID]
        let fragment = try XCTUnwrap(s.selectionProject())
        XCTAssertFalse(fragment.rootNodes[0].visible)
        XCTAssertFalse(fragment.shapes[0].visible)
        XCTAssertTrue(fragment.shapes[1].visible)
        let target = session(0); target.pasteProject(fragment)
        let pasted = try XCTUnwrap(target.selection.first)
        target.toggleNode(pasted, visibility: true)
        let index = target.document.project.hierarchyIndex
        XCTAssertTrue(index.hidden.contains(target.document.project.shapes[0].id))
        XCTAssertFalse(index.hidden.contains(target.document.project.shapes[1].id))
    }
    func testGroupResizeMapsBezierHandlesAndCompoundContours() throws {
        let s = session(2)
        s.document.project.shapes[0].kind = .ellipse
        s.document.project.shapes[0].convertToPath()
        let original = s.document.project.shapes[0]
        s.document.project.shapes[0].subpaths = [original.anchors]
        let ids = s.document.project.shapes.map(\.id)
        _ = try group(s, ids: ids)
        let old = try XCTUnwrap(s.selectionBounds)
        s.setGeometry("width", value: old.width * 2)
        let actual = s.document.project.shapes[0]
        for (before, after) in zip(original.anchors, actual.anchors) {
            XCTAssertEqual(after.point.x, old.minX + (before.point.x - old.minX) * 2)
            XCTAssertEqual(after.incoming?.x, before.incoming.map { old.minX + ($0.x - old.minX) * 2 })
            XCTAssertEqual(after.outgoing?.y, before.outgoing?.y)
        }
        XCTAssertEqual(actual.anchors, actual.subpaths?[0])
    }
    func testInsertionAndDeletionWithinGroupKeepHierarchyValid() throws {
        let s = session(), ids = s.document.project.shapes.map(\.id)
        let groupID = try group(s, ids: Array(ids.prefix(2)))
        s.enterGroup(groupID)
        s.insertArtwork(VectorProject(width: 100, height: 100, shapes: [VectorShape(name: "Generated", kind: .ellipse)]))
        let index = s.document.project.hierarchyIndex
        let generated = try XCTUnwrap(s.document.project.shapes.first { $0.name == "Generated" })
        XCTAssertEqual(index.parents[generated.id], groupID)
        XCTAssertNoThrow(try s.document.project.validated())
        s.selection = [ids[0]]; s.deleteSelection()
        XCTAssertNil(s.document.project.hierarchyIndex.nodes[ids[0]])
        XCTAssertEqual(s.isolatedGroupID, groupID)
        XCTAssertNoThrow(try s.document.project.validated())
    }
    func testNativeOutlineSelectionExpansionAndModelRefreshStayInSync() throws {
        let s = session(), ids = s.document.project.shapes.map(\.id)
        let coordinator = NativeLayerOutline.Coordinator(s)
        let outline = NSOutlineView(frame: CGRect(x: 0, y: 0, width: 272, height: 250))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("test-layers"))
        outline.addTableColumn(column); outline.outlineTableColumn = column
        outline.allowsMultipleSelection = true
        outline.dataSource = coordinator; outline.delegate = coordinator; coordinator.outline = outline
        coordinator.update()
        outline.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        XCTAssertEqual(s.selection, Set(ids.suffix(2)))
        s.groupSelection()
        let groupID = try XCTUnwrap(s.selection.first)
        coordinator.update()
        XCTAssertEqual(s.selection, [groupID])
        XCTAssertEqual(outline.numberOfRows, 4)
        let item = try XCTUnwrap(coordinator.items[groupID])
        outline.collapseItem(item)
        XCTAssertFalse(s.expandedNodes.contains(groupID))
        outline.expandItem(item)
        XCTAssertTrue(s.expandedNodes.contains(groupID))
        s.moveSelection(CGSize(width: 10, height: 10))
        coordinator.update()
        XCTAssertTrue(coordinator.items[groupID] === item)
        XCTAssertEqual(s.selection, [groupID])
        outline.dataSource = nil; outline.delegate = nil
    }
    func test2199ObjectHierarchyRoundTripExportAndRenderingPreserveArtwork() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Complex-2199", withExtension: "mvector", subdirectory: "Fixtures"))
        let original = try JSONDecoder().decode(VectorProject.self, from: Data(contentsOf: url)).validated()
        let s = EditorSession(document: VectorDocument(project: original))
        let ids = original.shapes.map(\.id)
        let start = Date()
        let first = try group(s, ids: Array(ids.prefix(1000)))
        let second = try group(s, ids: Array(ids.dropFirst(1000)))
        let outer = try group(s, ids: [first, second])
        s.newLayer(); let layer = try XCTUnwrap(s.activeLayerID)
        s.moveNodes([outer], to: layer)
        s.selection = [layer]; s.renameSelection("Artwork")
        s.selection = [outer]; s.renameSelection("Full illustration")
        s.selection = [first]; s.renameSelection("Back paths (1,000)")
        s.selection = [second]; s.renameSelection("Front paths (1,199)")
        let grouped = s.document.project
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
        XCTAssertEqual(grouped.shapes, original.shapes)
        XCTAssertEqual(grouped.hierarchyIndex.nodes[first]?.objectIDs.count, 1000)
        XCTAssertEqual(grouped.hierarchyIndex.nodes[second]?.objectIDs.count, 1199)
        let reopened = try JSONDecoder().decode(VectorProject.self, from: JSONEncoder().encode(grouped)).validated()
        XCTAssertEqual(reopened, grouped)
        let data = try SVGExporter.data(reopened)
        let xml = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        XCTAssertEqual(try xml.nodes(forXPath: "//*[starts-with(@id,'object_')]").count, 2199)
        XCTAssertEqual(try xml.nodes(forXPath: "//*[@data-magdobe-kind='group']").count, 3)
        XCTAssertEqual(try xml.nodes(forXPath: "//*[@data-magdobe-kind='layer']").count, 1)
        XCTAssertEqual(try xml.nodes(forXPath: "//*[local-name()='image' or local-name()='foreignObject']").count, 0)
        let exportedIDs = try xml.nodes(forXPath: "//*[starts-with(@id,'object_')]").compactMap { ($0 as? XMLElement)?.attribute(forName: "id")?.stringValue }
        XCTAssertEqual(exportedIDs, ids.map { "object_" + $0.uuidString.lowercased() })
        let restoredGeometry = try SVGTestImporter.read(xml)
        for (before, after) in zip(original.shapes, restoredGeometry.shapes) { XCTAssertEqual(before.bounds, after.bounds) }
        XCTAssertEqual(try VectorExporter.data(original, format: .png), try VectorExporter.data(reopened, format: .png))
        if let path = ProcessInfo.processInfo.environment["MAGDOBE_HIERARCHY_QA_DIR"] {
            let dir = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appendingPathComponent("2199-grouped.svg"))
            try JSONEncoder().encode(reopened).write(to: dir.appendingPathComponent("2199-grouped.mvector"))
        }
    }
}
