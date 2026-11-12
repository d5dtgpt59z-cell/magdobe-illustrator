# Save and export

Version 0.7.1 makes project saving and exporting visible in both the editing workspace and the generated-artwork preview.

## Canvas

- **Save Project**, **File → Save**, and **Command-S** use the same save coordinator. A new project opens an active, app-modal native destination dialog. The owning `NSDocument` performs the write and retains ownership of the file URL, dirty state, coordinated saving, and subsequent saves. **File → Save As…** uses the same working dialog; Duplicate Document retains Shift-Command-S.
- **Export → SVG / PDF / PNG** opens a shared format panel. The File menu offers the same choices.
- Opening an export panel does not finish an active pen path, alter selection, or add an undo step.

## Generated artwork

- **Save Project…** saves the preview as an editable `.mvector` file, directly from the preview. The canvas does not need to receive the objects first.
- **Export** offers SVG, PDF, and PNG. The shared preview save panel also allows switching to Editable Project.
- **Add to Canvas** remains a separate action. Saving the preview does not save or replace the current canvas document, or include edits made there.

| Format | What it saves | Open action |
| --- | --- | --- |
| Editable Project (`.mvector`) | All native geometry, IDs, groups, layers, names, visibility, locks, text, and appearance properties | Magdobe |
| SVG | Editable vector geometry with the existing layer/text/artboard options | Safari for viewing |
| PDF | Vector output of the artboard | Preview |
| PNG | Flat image at one pixel per document unit, with alpha supported | Preview |

SVG options still preserve editable layers, convert text to outlines, remove formatting whitespace, and export the entire artboard or fit the drawing. PDF and PNG retain the existing artboard clipping and renderer. PNG keeps the existing 64-million-pixel limit. SVG and PDF output do not constitute print-production certification or verified Adobe Illustrator interoperability.

## Saving and viewing

The native destination picker is activated and runs its own modal event loop, avoiding the disabled actions observed with the previous sheet presentation. Export remembers the last chosen folder. The picker supplies the filename, location, correct extension, and replacement confirmation. A successful save shows the actual filename, **Open in Magdobe/Safari/Preview**, and **Show in Finder**. Viewer-launch failures report that the file was saved but could not be opened.

Preview project saving and exports use a value snapshot in a background task. SVG retains its streaming writer and object progress. PDF/PNG use the existing renderer, with an activity indicator. The native preview project is compact JSON in the existing document format, retaining full coordinate precision.

Destination writes are atomic. Cancellation detected before writing, invalid documents, and write failures preserve any existing destination file. PDF/PNG rendering and native JSON encoding finish their current operation before cancellation is checked; a cancellation may therefore take a moment on dense artwork. Once the final write has begun, it completes atomically. Normal canvas project saving continues to use the existing document system.

## Validation

`ArtworkSaveTests` writes all four formats from the real 2,199-object fixture with an added named group and layer. It checks native-project equality after reopen, SVG path count and absence of raster images, PDF page dimensions, PNG dimensions, and that saving never changes the source project. Separate tests cover failed and cancelled saves preserving existing files, plus asynchronous success/error reporting. The export-presentation regression now checks SVG, PDF, and PNG without changing an active pen path.

The local native suite passed 62 tests, plus four Python artwork tests. In an isolated copy of the actual application, native UI testing completed:

- A new editable project saved through **Save Project**; an object rename persisted after **Command-S**.
- A 65,496-object document saved through **File → Save As…**. Decoding the saved 125 MB native file produced a project identical to the source, with all 65,496 objects.
- The same document exported through the app as SVG, PDF, and PNG. SVG XML parsing found 65,496 paths, zero raster images, and the expected 1024 × 1536 viewBox. PNG dimensions are 1024 × 1536. PDF and PNG opened successfully through **Open in Preview**.

The original working app was left running during the build. Reopen it to load this version. Actual Adobe Illustrator interoperability remains unverified.

## Dense-document navigation

The document caches hierarchy lookups until an edit, including edits restored by undo. The native Layers outline rebuilds its rows only when the document changes. Cached Core Graphics paths retain every original curve; viewport culling skips off-screen shapes.

For 2,000+ visible objects, navigation uses an in-memory artboard preview (at most roughly eight million pixels), while a cancellable background task renders a sharp image of the current viewport at screen resolution (bounded to roughly sixteen million pixels). A 150 ms idle interval coalesces navigation updates. Every result is tied to the document revision and viewport; edits invalidate both caches. These are display caches only: project saving and exports read the original vectors. No paths are simplified or replaced in the document. The canvas is clipped to its view so the artboard cannot paint over the toolbar or inspector during zooming.

A local optimized rendering benchmark on the actual 65,496-object illustration measured about 699 ms for a full original redraw, 447 ms for cached vector rendering, and 2.2 ms for drawing the navigation preview. These measure rendering operations, not end-to-end UI frame rate. Native UI testing exercised repeated zooms and hand-tool panning. Automated tests compare cached/cropped rendering against the original renderer pixel-for-pixel and verify cache invalidation on edit/undo. The normal build script now produces an optimized release app; `--debug` retains a debug build.
