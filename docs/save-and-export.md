# Save and export

Version 0.7 makes project saving and exporting visible in both the editing workspace and the generated-artwork preview.

## Canvas

- **Save Project** in the toolbar invokes the same native document save action as **File → Save** and **Command-S**. The normal save location, subsequent saves, document state, Save As, and reopen behavior remain owned by macOS/SwiftUI's existing document system.
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

The native destination picker supplies the filename, location, correct extension, and replacement confirmation. A successful save shows the actual filename, **Open in Magdobe/Safari/Preview**, and **Show in Finder**. Viewer-launch failures report that the file was saved but could not be opened.

Preview project saving and exports use a value snapshot in a background task. SVG retains its streaming writer and object progress. PDF/PNG use the existing renderer, with an activity indicator. The native preview project is compact JSON in the existing document format, retaining full coordinate precision.

Destination writes are atomic. Cancellation detected before writing, invalid documents, and write failures preserve any existing destination file. PDF/PNG rendering and native JSON encoding finish their current operation before cancellation is checked; a cancellation may therefore take a moment on dense artwork. Once the final write has begun, it completes atomically. Normal canvas project saving continues to use the existing document system.

## Validation

`ArtworkSaveTests` writes all four formats from the real 2,199-object fixture with an added named group and layer. It checks native-project equality after reopen, SVG path count and absence of raster images, PDF page dimensions, PNG dimensions, and that saving never changes the source project. Separate tests cover failed and cancelled saves preserving existing files, plus asynchronous success/error reporting. The export-presentation regression now checks SVG, PDF, and PNG without changing an active pen path.

The local native suite passed 59 tests. Native UI inspection verified the canvas Save Project/Export controls, the preview's direct Save Project/Export controls with a 12,091-object result, format switching, SVG options, and destination-picker presentation. In the isolated test app, macOS left the final Save/Export action disabled even in the unchanged File → Save flow; computer-use coordinate interaction also reported no available window. The cause was not established, so completing the native picker and the post-save Open/Show in Finder actions were not verified in this session. The underlying file writes and success/error state were verified by automated tests. The user's working application was left open.
