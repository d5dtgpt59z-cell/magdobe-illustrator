# Freehand Pencil and vector brushes — 0.5.0

## Drawing

- **N / Pencil**: freehand centerline with a uniform stroke width and editable Bézier anchors.
- **B / Brush**: Round, Tapered Ink, or Calligraphy. Each gesture creates a single independently editable filled path, including compound contours when needed.
- **[ / ]**: size down/up, bounded to 1–300 artboard points. These shortcuts are scoped to the canvas so typing in fields is unaffected.
- **Escape**: discard the current preview without changing the document or undo history.
- The inspector controls the next stroke. Color, size, smoothing and opacity are shared across presets; pencil remembers its own size. Calligraphy exposes angle and nib roundness. A live preview shows the current brush treatment.
- A mouse or trackpad uses full width. An AppKit tablet-point event can supply normalized pressure; mouse-up pressure is deliberately not used to collapse the stroke endpoint. Pencil has constant width. Tilt, rotation and Force Touch pressure are not implemented.
- Select a completed brush with **A / Direct Selection** to edit outline anchors and handles. Select **V** to move or resize it, and use Appearance to recolor or change object opacity. Pencil retains normal stroke-weight editing. Filled brush outlines are resized as geometry.

## Data and rendering

`FreehandStroke` lives only in the canvas gesture state until mouse-up. It captures the chosen style and insertion container, and does not dirty the document during preview. Commit appends one existing `VectorShape` through the current transaction and hierarchy APIs. This requires no schema migration or exporter changes. Existing version 1 and 2 documents still open.

Input filtering rejects non-finite/out-of-range coordinates and duplicate samples. The gesture buffer is capped at 4,096 samples, keeping both endpoints when thinning a long gesture. Smoothing fits a reduced centerline while retaining pressure changes. Curves use bounded tangent handles. Uniform round/calligraphic strokes use Core Graphics vector outlines; pressure and taper use overlapping nib contours with consistent winding. Core Graphics normalizes those outlines on commit for direct node editing. One fill operation preserves opacity across self-overlaps. Variable-width curve sampling is bounded to about 8,192 points.

SVG contains ordinary native paths and paint attributes. PDF/PNG use the same existing renderer. No brush texture bitmap is embedded; unrelated artwork is never simplified. The sampled freehand gesture is the only geometry affected by its smoothing control.

## Verification

- `./script/test.sh`: **53 tests pass**, including the existing 2,199-object / 125,093-anchor illustration fixture.
- Twelve new brush tests cover actual `CanvasView` NSEvent handling, commit-on-release, Escape and focus-loss cancellation, pressure variation, taper, calligraphy angle, round caps, dots, degenerate input, closed-loop pencil endpoints, overlap alpha, preview/committed containment, layer insertion/locks, undo/redo, native serialization and SVG round trips with no image elements.
- A 20,000-input-sample gesture stays bounded. A 4,096-sample pressure gesture completed geometry validation in approximately 0.46 seconds in the local debug build; the automated test allows headroom for CI. This is not a general performance guarantee.
- `./script/build_and_run.sh --build-only`: builds and signs the local app. Version is 0.5.0.
- Native UI inspection verified the Pencil/Brush tools, the three preset choices, calligraphy-specific controls, live preview, and opening the four-object sample. Direct Selection visibly exposes the brush outline’s Bézier anchors.
- Native drag automation failed with the computer-control provider's `noWindowsAvailable` error. Field typing also did not reliably commit through that provider. Mouse event handling is tested directly by the automated canvas test; do not describe this as a completed physical mouse/tablet session. A physical-tablet pressure check remains outstanding.

Reproduce the sample:

```sh
MAGDOBE_BRUSH_QA_DIR="$PWD/QA/Brushes" ./script/test.sh --filter BrushTests
```

`QA/Brushes/brush-sampler.mvector` contains Round, Tapered Ink, pressure-varying Calligraphy and Pencil objects, in that order from top to bottom. Matching SVG and PNG files are included. The calligraphy pressure data is synthetic test input.

## Scope

This addition does not implement Adobe brush presets, imported art/scatter/pattern/bristle brushes, a vector eraser, automatic merging between separate strokes, persistent custom preset libraries, or nondestructive restyling of a completed brush stroke. Completed strokes are directly editable vector geometry. Illustrator open/edit compatibility remains unverified. Download packaging, notarization and PRESSCHECK integration remain outside this change.
