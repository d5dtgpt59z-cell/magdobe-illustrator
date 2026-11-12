# SVG export in Magdobe Illustrator 0.3

## Result and usage

Use **File → Export → SVG…** or the existing toolbar Export menu. The native sheet offers Preserve editable layers (on), Convert text to outlines (off), Optimize SVG (off), and Export entire artboard (on). A native save panel selects the destination. Serialization and writing run on a worker task with object-count progress, cancellation, errors, and a success message.

The document is captured as a value snapshot. Export does not finish an active pen path, change selection, mutate artwork, or add undo entries. Files stream one object at a time into a temporary file beside the destination and replace the destination atomically after successful completion. Failure or cancellation before commit keeps the previous file intact. No extra Swift or native libraries were introduced.

## Audit and supported data

The existing document has one artboard and a flat, ordered array of rectangles, ellipses, cubic Bézier paths (including compound contours), and text. The Layers panel displays that array in reverse visual order; drawing and SVG serialization use its original back-to-front order. Position and scale are already applied to stored geometry. Colors are sRGB. Stroke caps and joins are fixed to round in the existing renderer.

The previous SVG code used four decimal places, omitted hidden objects, had no stable IDs, and exported synchronously. `VectorExporter` now delegates SVG to `SVGExporter`; PDF/PNG rendering remains unchanged. Native copy still puts editable SVG on the clipboard through the same serializer.

The exporter preserves:

- Native `rect`, `ellipse`, `path`, and editable `text` / `tspan` elements.
- All contours, cubic handles, nonzero winding, coordinates and stacking order, without curve simplification or quantization.
- Full-precision numeric values and RGB percentages instead of truncating colors to 8-bit hex.
- Fills, strokes, widths, color alpha, object opacity, round caps and round joins.
- Hidden geometry using `display="none"`; stable UUID-based object/group IDs; Unicode names in `title` and `data-name`.
- Artboard clipping with an explicit `clipPathUnits="userSpaceOnUse"` rectangle. Text has a separate rectangular clipping path for its native text box.
- Named object groups when Preserve editable layers is enabled. Disabling it removes only optional wrappers; objects, names and geometry remain.

SVG dimensions use explicit `pt` units with an unchanged document-coordinate `viewBox`, matching the editor's Core Graphics/PDF point dimensions. A browser using 96 CSS pixels per inch may report a different intrinsic pixel width; the viewBox coordinates are unchanged. When Export entire artboard is off, the viewport fits visible drawing bounds, including stroke extents and off-artboard geometry, while leaving object coordinates intact. Empty drawings report an error in this mode.

Optimize SVG only removes XML formatting whitespace. It never changes numerical precision, IDs, names, order, groups or path geometry.

## Compatibility limits and fallbacks

**Adobe Illustrator is not installed in this development environment. No actual Illustrator open/edit test has been performed.** This implementation emits standards-based SVG 1.1, and has been validated structurally, by geometry round-trip, and by an independent browser renderer. Those checks are not a substitute for opening the sample in Illustrator.

SVG has groups rather than a portable native layer model. The safest portable representation of Magdobe's current Layers rows is named `g` elements. Illustrator may import those as groups inside a layer, and may choose IDs rather than title/data-name values as its displayed labels. Native Illustrator layer metadata or proprietary Adobe editing payloads are not generated. Lock state has a Magdobe attribute for bookkeeping, but SVG has no interoperable editing lock, so Illustrator need not enforce it.

Magdobe does not currently model gradients, nested groups/layers, arbitrary object clips/masks, rotation matrices, non-round stroke styles, dash patterns, blend modes, placed bitmaps, or multiple artboards. These are existing editor limitations, not features silently dropped from a supported document. No new document schema or drawing tools were introduced for this export change. Existing move/resize operations remain baked into the exported geometry.

Core Graphics applies object alpha separately to fill and stroke paint operations. SVG element opacity normally composites those operations together. For an object with both fill and stroke and opacity below 1, the exporter keeps a named object group containing separate native fill and stroke geometry, each with the original object opacity. This preserves their overlap appearance. It can produce two editable geometry elements for one Magdobe object; unrelated objects are never merged. The actual 2,199-object illustration is fill-only and exports as exactly 2,199 path elements.

Editable text uses explicit line baselines from the native TextKit layout, the system font family with portable fallbacks, and complete text contents even when clipped by the text box. Another application may substitute the private macOS system font or shape text differently. Use Convert text to outlines for appearance-sensitive delivery. Outlining uses the actual Core Text fallback fonts and glyph paths and keeps each text object as an editable compound vector path. Font hinting and antialiasing can differ between native glyph rendering and path rendering. Color/bitmap-only glyphs such as emoji fail with a clear error rather than silently becoming raster artwork. Text strokes are not rendered by the existing editor and are not added by export.

Invalid XML control characters cause an actionable export error instead of creating malformed XML or silently deleting names/text. The original document remains unchanged.

## Validation

Run from the project directory:

```sh
MAGDOBE_SVG_QA_DIR="$PWD/QA/SVG" ./script/test.sh
./script/build_and_run.sh --build-only
```

The checked-in fixture `Tests/MagnusVectorTests/Fixtures/Complex-2199.mvector` is the actual generated Optimus Prime/Garbage Pail Kids illustration: **2,199 objects and 125,093 anchors**. Tests verify the exact object/anchor counts, full coordinate and control-point fidelity, names, IDs, paint values, transparency, nonzero compound contours, hidden objects, stacking/group order, artboard dimensions, valid XML and no image/foreignObject/use/script payloads. The independent test importer reads the emitted geometry and paint attributes; it does not recover geometry from embedded native JSON. It supports only the exporter’s emitted subset and is not a general SVG import feature in the app.

The native File → Export → SVG menu, all four options, native destination picker, live progress (observed at 1,504/2,199), and saved-file confirmation were exercised in a separate QA instance of the built executable. The user’s active unsaved document was left open. `QA/SVG/UI-export-2199.svg` is the UI-generated output and is byte-for-byte identical to the automated sample (SHA-256 `2973c65f0de85dce59ee03839fc172db541ff9ae1bb9daad7d41293dd9396b00`).

Additional tests cover editable/outlined text, explicit stroke semantics, fit-to-drawing bounds, optional wrappers, whitespace-only optimization, atomic overwrites, failed writes, cancellation, and preservation of a live pen transaction. All **23 tests** passed, including the existing 13 editor tests.

Sample: `QA/SVG/Optimus-and-GPK-2199-editable.svg` (6,628,023 bytes). The measured debug-build serialization time was about 0.41 seconds, and streaming atomic file export about 0.50 seconds on this Mac. These are observed measurements, not performance guarantees.

`QA/SVG/compare.html` compares browser-rendered SVG against native PNG references at the same viewport size. For the complex illustration, mean absolute RGB channel error was **0.2428 / 255**, and **0.1633%** of pixels differed by more than 16 levels in any channel. The transparency fixture had mean error **0.0283 / 255**. Outlined text was visually aligned, with renderer/antialiasing differences; editable text showed the expected font substitution difference. The harness and references are retained for reproduction. Serve the QA/SVG directory locally and open compare.html to rerun the visual comparison.

## References

- [SVG 1.1 coordinate systems and units](https://www.w3.org/TR/SVG11/coords.html)
- [SVG 1.1 paint, opacity, joins and caps](https://www.w3.org/TR/SVG11/painting.html)
- [Apple Core Text glyph outline API](https://developer.apple.com/documentation/coretext/ctfontcreatepathforglyph(_:_:_:))
- [Adobe Illustrator supported formats](https://helpx.adobe.com/illustrator/desktop/get-started/learn-the-basics/supported-file-formats-in-illustrator.html)
