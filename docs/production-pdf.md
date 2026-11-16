# Printer-profile production PDF export

Open **File → Export → Production PDF / PDF/X…** or **File → Production Export / Check…**. This is a separate delivery-copy workflow. Ordinary SVG/PDF/PNG exports retain their existing behavior; the editable project remains the master.

## Use your printer's specification

1. Enter actual trim width/height, bleed, safe inset, source reference and applicable limits. Review **Fit within trim** versus **Fill through bleed**; both preserve aspect ratio, and fill can crop the delivery copy.
2. Enable **Production PDF** and choose **CMYK PDF** or **PDF/X-4**. Other PDF/X variants, including PDF/X-1a, are unsupported and are not silently substituted.
3. Choose **Import Printer ICC…** and select the printer's CMYK output profile. The importer requires a valid printer/output-class ICC v2 or v4 profile, four CMYK channels, a valid tag structure and a maximum size of 16 MiB. RGB/display/DeviceLink/damaged profiles are rejected. No default printer profile is selected.
4. Enter the output condition identifier supplied for the job and, where available, its description and registry reference. The registry is metadata; it is never fetched. Select the rendering intent and black point compensation requested by the printer. Black generation follows the profile; K-only overrides are not implemented.
5. Export the production PDF and review its report. Only an output that passes the supported file checks replaces the destination. Failures preserve an existing destination and retain working copies and an actionable report.

The setup thumbnail is an RGB placement preview. It is not a calibrated CMYK soft proof or a contract proof.

## What gets exported

The native app uses its existing geometry and text layout to prepare a physically sized RGB vector PDF. Text becomes real glyph outlines; a glyph without a vector outline produces an error rather than an image fallback. The original editable text stays in the project.

Only visible objects with no assigned production role, **Artwork**, or **Barcode** roles enter the process-color PDF. Cut, crease, glue, reference/legend and finish roles are omitted. A technical-only drawing cannot become a successful blank production PDF. The retained object manifest identifies included and omitted native objects. Separate tooling and finishing deliverables require their own workflow.

The bundled Ghostscript 10.08.0 engine performs ICC conversion once using the imported profile, selected rendering intent and black point compensation. The PDF embeds the exact output ICC bytes. Trim and bleed boxes use the job's physical dimensions, with points calculated as `72 / 25.4` per millimeter. MediaBox and BleedBox cover trim plus the configured bleed; no crop marks or additional press/gripper space are invented.

PDF/X-4 output uses PDF 1.6 and retains live transparency where present. The converter reconstructs PDF paint operations and can combine or clip them. PDF paint counts are not native object identities or layer counts. The editable project and SVG preserve their own objects and hierarchy; no source artwork is rewritten.

## File checks and approval

A separate pikepdf/qpdf audit inspects the source and written result. Supported checks cover page boxes and physical size, exact embedded ICC identity, CMYK/gray process paints, supported transparency spaces, PDF/X identification/XMP where requested, outlined vectors, and absence of raster artwork, fonts, active actions, attachments and unsupported constructs. Parsing has explicit file, decoded-stream, token, depth and time limits. This is a native-generated-vector workflow, not a general PDF repair service.

The report records source/output hashes, ICC hash, job settings, measured paint operations, rule findings, tool versions and limitations. `pass_supported_checks` means those checks passed. It is **not** independent full ISO PDF/X certification, a contract color proof or manufacturing approval. Barcode print quality, total ink limits, gamut warnings, spot/white/foil separations, overprint, trapping, material behavior and physical fit remain unverified.

Working copies and reports are retained under `~/Library/Application Support/Magdobe Illustrator/Production PDFs/`. The app can reveal the saved PDF, open its full local report or show the retained artifact folder. ICC/profile data and local reports are not uploaded during export.

## Profiles, projects and AI

The active ICC profile is a bounded portable project asset, separate from `ProductionSpec`. Its name and SHA-256 live in job metadata; its bytes do not enter AI requests or SVG metadata. A private hash-indexed local library lets saved printer presets resolve their profiles. A missing or mismatched asset requires reimporting the actual file.

The existing provider assistant may propose PDF target, output-condition fields, rendering intent and BPC from explicit supplied instructions. Changes need exact source evidence and review. Negated/ambiguous instructions are rejected, and AI cannot replace a selected profile, change its name/hash, insert profile bytes or choose a local path. If the setup, profile, model, provider or brief changes while a proposal is pending, the stale proposal cannot be applied. Supplier confirmation is cleared for proposals and reused profiles.

## Validation and reproducible builds

Native tests cover physical vector drafts, text outlines, role exclusions, ICC validation/library/portable assets, undo, stale proposals, client integrity, cancellation and atomic commit. Backend tests use a pinned real Ghostscript engine plus independent qpdf reads, including 2,199-path fixtures, transparency and tampered outputs. The real illustration is also rendered for composition review. Automated fixture profiles are clearly marked **test only**; no supplier-approved printing condition or physical press test is implied.

`script/build_ghostscript.py` builds the pinned official source with bundled libraries and ROM resources, matching the build Mac's architecture and targeting macOS 14. `script/stage_ghostscript.py` places the separate executable in the checker helper's `Contents/MacOS`, and exact source/licenses/build material under `Contents/Resources/Ghostscript`. The app includes its checker/runtime/converter, so recipients do not install Python, Node, Ghostscript or Xcode. Source, dependency and binary checksums accompany the build material. Only the ARM64 artifact has been built/tested here; native Intel build support is not an Intel validation claim.

See [Ghostscript's released source](https://github.com/ArtifexSoftware/ghostpdl-downloads/releases/tag/gs10080), its [PDF writer documentation](https://ghostscript.readthedocs.io/en/gs10.08.0/VectorDevices.html), and [Mac signing/distribution](macos-distribution.md). A PDF/X metadata claim alone is never treated as proof of full conformance.

The Built by Magnus project page is a final release step after the suite is complete and the signed download is verified. It must describe shipped features and tested limits; this export addition does not publish or redesign the website.
