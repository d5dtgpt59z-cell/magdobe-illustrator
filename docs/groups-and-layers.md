# Groups and layers (0.4)

## Editing

- **Object → Group (Command-G)** wraps selected siblings in a group. Nested groups are supported. Select at least two objects/groups with the same parent; layers are organization containers and cannot be grouped inside a group.
- **Object → Ungroup (Option-Command-G)** dissolves selected groups, leaving their children in place. Shift-Command-G continues to open Draw with Codex.
- **Object → New Layer (Shift-Command-N)** or the Layers header button creates a layer. Right-click a layer for **New Sublayer**.
- Select a row to rename it in Properties. Use disclosure triangles to expand/collapse containers. Standard Shift/Command multiselection and outline keyboard navigation are supported.
- Drag rows onto a group/layer, or right-click and choose **Move to Layer**. Moving to a container places the selection at its front. Use Bring to Front/Send to Back to reorder within the current parent. A container cannot move into itself or a descendant; layers cannot go inside groups.
- The last layer selected in the panel is the drawing destination. When editing inside a group, new shapes and generated artwork go into that group. Hidden/locked destinations report an error instead of placing new artwork elsewhere.
- Clicking a group on the canvas selects it as a unit. Double-click a group on the canvas or in the panel to edit inside. Use **Back**, **Escape**, or **Object → Exit Group** to leave one level. Direct Selection can still target individual paths.
- Move, resize, numeric transforms, and alignment treat groups as units. Appearance edits apply to their individual shapes. This release does not add composited group opacity or new transform types.
- Visibility and locking inherit through all ancestors. Showing/unlocking a parent preserves each child's own flags. A selected container with a locked descendant cannot be transformed, deleted, duplicated, grouped, or reordered as a partial unit; unlock the descendant or edit the unlocked children directly.
- Duplicate, native copy/paste between windows, deletion, undo/redo, and SVG clipboard output retain hierarchy. Copies receive fresh object/container/anchor IDs. Geometry and stacking inside each copied container stay intact.

Grouping nonadjacent siblings places the group at the frontmost selected sibling's position, maintaining the selected children's relative order. Unselected objects between the selected siblings can therefore move behind the group, as is usual when making one contiguous group. Undo restores the exact prior arrangement.

## Document architecture and compatibility

`VectorProject.shapes` remains the single geometry store. An optional ordered tree contains object references and named group/layer containers. Structural edits keep the shape array's back-to-front order identical to the tree's leaf order. Rendering, hit testing, SVG/PDF/PNG export, and selection use the same hierarchy-derived visibility and locking information. There are no new dependencies.

Original v1 `.mvector` documents load unchanged with a virtual flat hierarchy. The first structural edit upgrades the document to v2. V2 validates unique container IDs, exactly one reference per shape, matching paint order, legal layer placement, and a maximum depth of 64. Older Magdobe builds reject v2 instead of silently flattening it. Keep the original file or use Save As if an older build must still open it.

Selection, expansion, isolation, and the active drawing layer belong to the editor session; names, child order, visibility, and locks are saved. Undo restores document hierarchy plus selection and isolation context. Each document action has an explicit undo group.

The Layers list is a narrow `NSOutlineView` bridge inside the existing SwiftUI inspector. AppKit owns row interaction, disclosure, drag/drop, context menus, and clipboard responder routing; `EditorSession` remains the source of truth. Geometry-only changes do not reload row data. The cream surface and the existing inspector/tool layout are retained.

## SVG

With Preserve editable layers on, actual layers/groups become nested named `<g>` elements with stable IDs, original child order, and inherited visibility. With the option off, their wrappers are removed and effective visibility/locking is recorded on each object. Paths, fills, strokes, and coordinates remain unchanged. Empty containers are retained when preserving the hierarchy.

SVG has no portable native layer or editing-lock semantics. Illustrator may show the containers as groups within a layer and may ignore the lock metadata. Actual Illustrator open/edit testing remains unverified because Illustrator is unavailable here. See [SVG export](svg-export.md).

## Validation and reproduction

```sh
./script/test.sh
MAGDOBE_HIERARCHY_QA_DIR="$PWD/Artwork/Hierarchy QA" ./script/test.sh --filter HierarchyTests.test2199ObjectHierarchyRoundTripExportAndRenderingPreserveArtwork
./script/build_and_run.sh --build-only
```

All 41 tests passed locally. The complex test uses the existing 2,199-object / 125,093-anchor illustration. It wraps two contiguous batches in nested groups and a layer, saves/reopens the document, exports SVG, checks every object ID/order and geometry, rejects raster elements, and compares native PNG output byte-for-byte against the flat original. Grouping does not semantically recognize characters or body parts; the batch split is a regression fixture.

The optional QA directory receives `2199-grouped.mvector` and `2199-grouped.svg`. `Artwork/` is ignored by Git so generated local documents are not accidentally published.

Other tests cover inherited locks/visibility, nested isolation and selection, group transforms and Bézier handles, copy/paste, unique IDs, native outline synchronization, undo/redo, insertion/deletion in groups, reordering, migration, empty layers, malformed hierarchy references, cycles, and excessive depth.

Native UI checks exercised grouping by Command-G, renaming, double-click isolation, the Back breadcrumb, ungrouping by Option-Command-G, hierarchy undo, creating layers, the Move to Layer context menu, and saving the resulting nested hierarchy. The production build also opened the grouped 2,199-object document, expanded its nested containers, entered group isolation, and exited with Escape. Automated native dragging did not complete a pointer drop: diagnostic callbacks reported the source-row location rather than the requested destination. The drag adapter is implemented, but that gesture requires a manual check; Move to Layer is the verified alternative. Temporary diagnostic logs were removed from the build.
