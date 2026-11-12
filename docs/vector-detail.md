# Image-to-vector detail

Version 0.6 makes **Detailed** the default and adds an opt-in **Ultra** preset. Detail is controlled during tracing, before SVG export. The SVG exporter preserves the paths it receives; exporting a previously simplified document cannot restore missing shapes.

## Rebuild an existing image

1. Open **Draw with Codex** (Shift-Command-G).
2. Choose **Ultra** under **Vector detail**.
3. Click **Rebuild Last Image**, or **Rebuild These Vectors** when a result is already in the panel.
4. Compare **Editable vectors** and **Source image**.
5. Click **Export SVG…** to export the preview directly, or **Add to Canvas** to insert its editable paths.

Rebuild uses the most recent completed source image saved by Magdobe, across documents. To choose a different source, use **Vectorize an Existing Image…**. Rebuilding copies the original PNG unchanged and runs locally, without requesting another image from Codex. It does not require a Codex connection.

Each rebuild gets a separate job folder. Existing canvas objects and saved projects are untouched. Edits made on the canvas are not part of the source image and are not transferred to a new trace. Adding a result inserts new objects as one undoable action; it does not replace an earlier insertion. Direct preview export avoids loading tens of thousands of objects into the editing canvas.

## Presets and limits

| Preset | Intended use | Speckle filter | Color precision | Layer difference | Segment length | Path decimals |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Simple | Bold graphics, fewer objects | 32 | 5 | 40 | 6 | 2 |
| Balanced | Smaller files and easier editing | 16 | 6 | 24 | 4 | 2 |
| Detailed | Illustrated artwork; default | 8 | 7 | 16 | 3 | 2 |
| Ultra | Tiny accents and finer color transitions | 2 | 8 | 6 | 2.5 | 4 |

The original three tracing configurations are unchanged. All use the existing VTracer 0.6.15 stacked color/spline pipeline. Ultra keeps smaller regions and more color variation, and native conversion preserves the resulting coordinate precision. It is still an approximation of the source image: fine texture, translucent pixels, or tiny lettering may not reproduce exactly. It cannot invent details missing from the source.

Ultra can create tens of thousands of individually editable filled paths, large SVG/native files, and slower canvas editing. A trace is rejected above 80,000 paths or 750,000 anchors, with a message to lower the detail setting. Limits do not silently simplify the result. A failed rebuild keeps the previous preview; native result files are written atomically. **Show Files** includes `trace-info.json` with the settings, dimensions, object count, and anchor count.

## Validation

Local comparison used the same saved 1024 × 1536 source image for each setting:

| Setting | Independently editable objects |
| --- | ---: |
| Balanced (previous result) | 3,030 |
| Detailed | 12,091 |
| Ultra | 65,496 |

Ultra retained 690,306 anchors. VTracer tracing took about 7 seconds; tracing plus conversion into the native project took about 15 seconds on the development Mac. These timings are illustrative, not a guarantee for other images or computers. The production SVG exporter produced a roughly 67 MiB SVG with 65,496 path elements, zero image elements, and the original artboard dimensions. The native project was decoded, validated, rendered, and exported successfully. The source and rendered preview were inspected visually; no pixel-identical or Adobe Illustrator validation is claimed.

The original 2,199-object illustration was also traced at Ultra, yielding 63,785 paths at the VTracer stage. This second measurement is not a claim of an Illustrator round trip or a full native export test.

The native drawing panel was exercised in a separate test app: Detailed was the default, Ultra could be selected, Rebuild Last Image completed with 65,496 objects, and the preview's Export SVG opened the existing options and save panel. Saving produced a complete 65,496-path SVG that parsed successfully. UI inspection timed out after the save, so the final success label and return from that sheet were not visually verified.

Automated coverage uses a synthetic PNG with small highlights and subtle color differences, not private artwork. Four Python tests exercise the real pinned tracer, source preservation, greater retained detail, native path counts, four-decimal Bézier coordinates, explicit invalid settings, and complexity-limit failure. Two Swift tests check the Detailed default, latest completed source selection, and preservation of the current result when a rebuild fails.

Run the existing native suite and the tracer tests:

```sh
./script/test.sh
python3.11 -m venv .build/artwork-tests
.build/artwork-tests/bin/python -m pip install vtracer==0.6.15 svgpathtools==1.8.0
.build/artwork-tests/bin/python -m unittest discover -s Tests/Artwork -v
```

SVG export options, supported geometry, and interoperability limits remain documented in [SVG export](svg-export.md).
