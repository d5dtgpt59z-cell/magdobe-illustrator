# Production setup and local checks

Use **File → Production Export / Check…**, **File → Export → Production PDF / PDF/X…**, or the toolbar’s production export entry. Existing SVG, PDF, PNG and editable-project save commands retain their behavior.

Production Setup records a separate job specification in the `.mvector` document. Enter the printer's actual trim dimensions, bleed, safe inset, color requirement and any specified minimum text size, stroke width or raster resolution. Dimensions can be displayed in inches or millimeters; millimeters are stored. The initial values are an unconfirmed example, not a supplier-approved template. Custom named profiles, printer notes and specification references can be saved locally and reused. Loading a profile or changing confirmed requirements clears supplier confirmation.

**Fit within trim** uniformly scales and centers the original artboard inside trim. A differing aspect ratio leaves margins. **Fill through bleed** uniformly scales and centers it to cover the bleed rectangle; some content can be cropped in the delivery copy. The thumbnail uses the same placement matrix as export. Bleed, trim and safe guides appear only in the preview, never as printable guide artwork. No placement mode stretches geometry independently along two axes or changes the original document coordinates.

**Export Production SVG…** writes a separate editable SVG with explicit physical `mm` dimensions and a point-coordinate `viewBox`, including the specified bleed area. A uniform wrapper transform places the existing artboard; its geometry, Bézier handles, paint, IDs, names, groups and stacking order are serialized by the existing SVG exporter. A nested viewport uses unitless document coordinates to avoid the CSS pixel/point conversion. The embedded job metadata describes the requirements. Export streams to an atomic replacement file and supports cancellation.

**Check Locally** sends no artwork or provider credentials to an external service. It writes a snapshot SVG and job JSON under Application Support → Magdobe Illustrator → Print Checks, then invokes the bundled PressCheck worker. A successful invocation returns the actual report findings and limitations, with an option to open its local HTML report. The checker needs no user-installed Python, Node or web server in the distributed application. Source builds without the bundled helper give a meaningful missing-worker error; development can select an existing executable using `MAGDOBE_PRESSCHECK_WORKER`.

Each check verifies the submitted SVG's SHA-256 and confines report files to that check's output directory. Failed or cancelled checks keep the original project and saved artwork. The optional HTTP client is restricted to literal loopback destinations, rejects redirects and forwards no ambient cookies, authorization or provider keys; the installed application uses the bundled worker by default.

## AI assistance

Paste printer specifications or instructions in the optional assistant section. Select your own provider and, for API providers, an explicit text-capable model. Magdobe uses the existing provider endpoint and Keychain key; the image-generation model is kept separate. Codex and Claude Code can use their existing account sign-in. Only the entered instructions and current job settings are sent, not the complete artwork.

AI returns a proposal with explanations, source evidence and unconfirmed information. Review the before/after settings and choose **Keep Current** or **Use Proposed Setup**. Nothing is applied automatically. The latter changes the setup draft; **Save Setup** persists it in the project with undo support. Supplier confirmation is always cleared for AI proposals. Manual fields remain available when no AI provider is connected.

## Production roles

The inspector can assign artwork, cut, crease, perforation, glue, foil, emboss, deboss, varnish, white ink, registration, barcode or legend roles to selected objects, groups or layers. Children inherit the nearest assigned role and can override it. These roles persist in the native hierarchy and export as `data-production-role` attributes even when SVG group wrappers are disabled.

Role metadata does not create a spot-color ink separation, a tooling file or a manufacturing approval. An RGB layer named Foil is not a foil production plate.

## Bundled production workspace

**File → Open Production Workspace…** starts the included independent PressCheck worker and opens its static production console in the browser. It binds only to `127.0.0.1` on an available port. An ephemeral token authenticates every API request; the browser removes the initial token from the address bar. No public service, Node installation or user-installed Python is required. The owned process stops when Magdobe quits. Desktop printer profiles persist in the workspace's Application Support directory across port/session changes; profile JSON import/export is also available. Native setup profiles are separate from workspace profiles.

The **Card Preflight** workspace preserves an uploaded SVG and measures its supported geometry against the entered job. Reports distinguish failed checks, missing specifications, unsupported measurements and review items. Original downloads remain attachments; previews use a bounded, passive PNG rendering subset.

The **Structure** workspace generates a straight-tuck carton study from nominal panel width/depth/height, board caliper and glue-flap size. It returns a closed cut path, separate crease paths, glue guide and reference annotations. Download a native `.mvector` project to edit the 25 objects in five named layers inside Magdobe, or download SVG and a handoff JSON manifest. Its annotated drawing canvas uses one document unit per millimeter; it is distinct from the finished carton dimensions. Native crease strokes are solid because the editor has no dash-pattern property.

This structure is a starting study. Internal capacity, material grain, bend allowance, closure strength, glue compatibility, press compensation and physical fit are unverified. The caliper-driven flap relief is explicitly experimental. A converter's approved CAD/dieline and physical sample are still required.

## Explicit limits

- Production SVG remains RGB. Selecting “CMYK required” records its requirement. The separate [Production PDF workflow](production-pdf.md) now converts once using the imported ICC profile and writes an output intent, with CMYK PDF and PDF/X-4 targets. Its supported-subset checks do not establish independent full ISO certification.
- The ordinary PDF exporter remains general-purpose, with its existing artboard sizing/clipping. Use Production SVG or Production PDF for the physical setup; the ordinary PDF command does not apply production dimensions or the printer ICC.
- A validator cannot invent missing artwork, determine a printer's unprovided tolerances, certify physical color or replace a supplier proof. Unknown requirements must remain unconfirmed.
- Native SVG does not embed raster artwork. Vector paths have no intrinsic raster PPI. Editable text can still require font substitution; the existing standard SVG export has a separate optional outline mode.
- Structural dielines, card front/back/deck assembly, substrate/caliper, wrapper sealing and physical manufacturing approval require their own workflows and supplier specifications.
- Actual Illustrator open/edit, commercial-press color and physical manufacturing compatibility are not certified by these structural tests.

## Tests

Run `./script/test.sh`. New tests cover backward-compatible document loading, production job/profile persistence, validation, uniform fit/fill mathematics, inherited roles, undo, atomic writes, cancellation, worker relocation and report integrity, plus offline HTTP protocol behavior. The real 2,199-object fixture retains the same native object XML, geometry, paint and order inside the production wrapper, with no image or script payloads. Set `MAGDOBE_PRODUCTION_QA_DIR` to write a physical-size SVG/job sample while running the production workflow tests.

`Tests/MagnusVectorTests/Fixtures/PressCheck-Carton.mvector` is a generated, unverified PressCheck carton study used as a native interchange fixture. Tests preserve its 25 independent objects, five named layers, operation roles, identifiers and one-document-unit-to-one-millimeter production mapping. Its reference legends remain explicitly separate from cut/crease/glue operations; this is not a supplier-approved tooling template.
