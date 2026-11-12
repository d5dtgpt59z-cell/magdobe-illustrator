# Magdobe Illustrator

<img src="Resources/AppIcon/Magdobe-Icon.png" alt="Magdobe Illustrator app icon" width="112">

[![macOS tests](https://github.com/d5dtgpt59z-cell/magdobe-illustrator/actions/workflows/macos.yml/badge.svg)](https://github.com/d5dtgpt59z-cell/magdobe-illustrator/actions/workflows/macos.yml)

A native macOS vector editor, built from scratch with SwiftUI, AppKit, and Core Graphics. Version 0.4 combines real groups and nested layers, precise editable SVG export, and a signed-in Codex image-to-vector workflow. It uses original source code and no Adobe binaries or assets. Open source under the [MIT license](LICENSE).

## Open the app

The built application is `dist/Magdobe Illustrator.app`. On launch, choose **New Document** or open an existing `.mvector` project.

Requirements: macOS 14+, Xcode with a Swift 6 toolchain, and Python 3 with `venv`/`pip`. The first app build downloads the two pinned vector-conversion packages. Codex is optional for manual drawing and SVG export; generation requires an installed Codex CLI with an existing ChatGPT sign-in.

```sh
git clone https://github.com/d5dtgpt59z-cell/magdobe-illustrator.git
cd magdobe-illustrator
```

Build and launch from this directory:

```sh
./script/build_and_run.sh
```

The script stages a local `.app`, signs it for local use, and launches it. Pass `--build-only` to update the bundle without restarting an active document session. It uses installed Xcode when available without changing the system developer-tool selection. macOS 14 or later is required. The native editor has no third-party Swift package dependencies. The build script installs a local Python environment with VTracer 0.6.15 and svgpathtools 1.8.0 for vector conversion. The project-local Codex Run action calls this script.

## Draw with Codex

Click **Draw with Codex** in the toolbar, or press **Shift-Command-G**. Describe your artwork, choose the image style, composition, and vector detail, then click **Generate Editable Artwork**. Compare **Editable vectors** with **Source image**, then **Add to Canvas**. Insertion is one undoable action; a blank document adopts the generated image size, while an existing document fits the new artwork inside its artboard.

Generation uses the installed Codex CLI App Server and your existing ChatGPT sign-in. It does not require an API key. Codex must be installed and signed in, and image generation must be available for the account. The account's image generation limits apply. An optional reference image is sent with the prompt to Codex. **Check Connection** checks the existing login without exposing or copying credentials.

**Vectorize an Existing Image** converts a PNG, JPEG, or WebP locally. This does not require a Codex connection. Vectorization approximates shading with colored Bézier contours, simplifying fine texture and outlining text. Simple detail produces fewer paths; Detailed preserves more shading and can produce thousands of objects.

Source images, prompts, SVGs, vector previews, and native projects are retained in `~/Library/Application Support/Magdobe Illustrator/Artwork/`. Use **Show Files** to find a result. The Python runtime lives alongside that folder under `Runtime/`; the app bundle's `runtime.json` points to that runtime and the local Codex executable.

The cream paper texture is the editor workspace. The white artboard and exported artwork retain their existing behavior. Custom editor and generation controls have native hover tooltips. The generated app icon is included in `Resources/AppIcon/`.

## Editable SVG export

Use **File → Export → SVG…** or the existing Export toolbar menu. Options preserve named object groups, outline text, remove formatting whitespace, and keep the entire artboard or fit the drawing. Exports run in the background with progress, cancellation and atomic saving. All geometry retains full coordinate precision; hidden objects and stable IDs are kept. The 2,199-object sample and validation report are in `QA/SVG/` and [`docs/svg-export.md`](docs/svg-export.md). Illustrator is not installed here, so actual Illustrator compatibility has **not** been verified.

## Working features

- Rectangle, ellipse, pen, and text tools.
- Cubic Bézier pen: click corners, drag smooth handles, click the first anchor to close a path, or press Return to finish an open path.
- Compound paths preserve multiple contours and holes using nonzero winding. Inner contours support direct node editing and transform with their parent object.
- Direct selection: drag individual anchors and control handles. Convert rectangles and ellipses to editable paths through Object → Convert to Path.
- Selection, Shift multiselection, marquee selection, movement, corner resizing, and numeric position/size editing. Shift constrains shape proportions and movement.
- Fill and stroke colors, alpha, stroke weight, object opacity, and quick color swatches.
- Hierarchical groups and nested layers with names, disclosure controls, inherited visibility/locks, drag into containers, and Move to Layer context commands. Groups move/resize/align as units; double-click to edit inside and press Escape to exit. See [groups and layers](docs/groups-and-layers.md).
- Alignment to the artboard for one object, or to the selection bounds for multiple objects.
- Undo/redo, duplication, and native copy/cut/paste of vector objects between document windows. Copy also places SVG text on the clipboard. Standard text-field clipboard actions remain available.
- Native document windows with New/Open/Save/Save As and `.mvector` JSON project files.
- SVG, vector PDF, and transparent PNG export. Export clips artwork to the artboard.
- Scroll/hand pan, pinch zoom, fit, actual size, and a visual grid.

The canvas uses a white artboard as a viewing surface. Exports have no automatic white background; add a white rectangle if the artwork needs one. PNG exports at one pixel per document unit, capped at 64 million pixels. SVG keeps text editable; line wrapping and font metrics can vary in another viewer. PDF and PNG use the native canvas renderer.

## Keyboard

| Action | Key |
| --- | --- |
| Selection / direct selection | V / A |
| Pen / rectangle / ellipse / text / hand | P / M / L / T / H |
| Temporary hand | Hold Space on the canvas |
| Finish pen path / deselect | Return / Escape |
| Move selection | Arrow keys; Shift for 10 units |
| Copy / cut / paste | Command-C / X / V |
| Duplicate | Command-D |
| Group / ungroup | Command-G / Option-Command-G |
| New layer | Shift-Command-N |
| Exit group isolation | Escape |
| Undo / redo | Command-Z / Shift-Command-Z |
| Select all / deselect | Command-A / Shift-Command-A |
| Convert to path | Shift-Command-O |
| Fit / actual size | Command-0 / Command-1 |
| Zoom | Pinch, or Option/Command-scroll |
| Draw with Codex | Shift-Command-G |
| Save / new / open | Standard macOS File menu shortcuts |

Tool-letter shortcuts apply when the canvas has focus. Enter a numeric inspector value and press Return or leave the field to apply it.

## Verification

```sh
./script/test.sh
./script/build_and_run.sh --verify
```

The tests cover project round trips, curve conversion/resizing, hit testing, compound contours and holes, compatibility with earlier projects, SVG XML/escaping, PDF/transparent PNG output, document validation, undo/redo, locks, duplication, and discarded single-anchor pen paths, and generated-artwork insertion with artboard sizing, compound contours, ID remapping, and undo/redo. The test script selects installed Xcode because some Command Line Tools installations do not include XCTest.

A live Codex App Server check generated a sample illustration through the existing ChatGPT sign-in and converted it into 16 editable objects. The native drawing panel completed the user-entered Optimus Prime versus Garbage Pail Kids request and displayed a vector preview containing 2,199 editable objects with Add to Canvas enabled.

Native UI checks completed: drawing an ellipse; undo and redo; converting to a path; dragging an anchor; drawing a curved open pen path; inserting text; saving and reopening a three-object project; copying and pasting a vector object; undoing the paste; and exporting SVG. The drawing and exported SVG are in `QA/`.

Groups/layers tests also cover native outline selection, nested selection/isolation, group transforms, inherited visibility/locks, hierarchy validation, copy/paste, undo, and the actual 2,199-object illustration. The grouped illustration keeps every shape and renders identically to the flat original.

## Next development stages

1. Editing depth: rotate/reflect, node insertion/deletion, corner/smooth conversion, snapping, and rulers.
2. Vector operations: boolean operations, clipping masks, gradients, and richer stroke controls.
3. Interchange: SVG import with a deliberately supported feature set, placed images, and font controls/text outlines.
4. Professional documents: multiple artboards, color management/CMYK, print preparation, performance profiling, and broader interoperability testing.

Version 0.4 does not import SVG/AI files or offer Illustrator feature parity. Distribution signing, notarization, and an installer have not been set up.

## Source map

- `App/`: document scene, application activation, and commands.
- `Models/`: Codable vector geometry, color, validation, and native document format.
- `Stores/`: per-window tools, selection, appearance defaults, and undo transactions.
- `Canvas/`: small AppKit bridge for rendering and precise pointer/keyboard input.
- `Views/`: SwiftUI editor layout, tools, inspector, and layers.
- `Services/`: shared Core Graphics renderer and SVG/PDF/PNG serialization.

## Project status and assets

This is an early native editor, with source builds for local use. A notarized installer and general SVG import are not included. The application source is available under the [MIT license](LICENSE). Clone it, try it, break it, improve it. Make something.

The icon and illustration regression fixtures were generated during development; they are examples, not official brand or character artwork. Third-party names, characters and trademarks remain the property of their respective owners; the software license does not grant rights to those properties.
