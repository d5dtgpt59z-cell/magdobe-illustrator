#!/usr/bin/env python3
"""Offline Ghostscript PDF/X-4 smoke test, not an ISO conformance validator.

Creates a tiny real PDF containing vectors, embedded transparency state and a
standard font. Uses the engine's bundled CMYK profile ONLY as a test fixture,
never as a recommended or supplier-approved output condition.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import zlib


def sample_pdf():
    stream = b"0.1 0.4 0.9 rg 15 20 145 145 re f\nq /GS1 gs 1 0.2 0 rg 70 70 105 105 re f Q\nBT /F1 12 Tf 15 180 Td (Vector and transparency) Tj ET\n"
    objects = [b"<< /Type /Catalog /Pages 2 0 R >>", b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /TrimBox [10 10 190 190] /BleedBox [5 5 195 195] /Contents 4 0 R /Resources << /ExtGState << /GS1 5 0 R >> /Font << /F1 6 0 R >> >> >>",
        b"<< /Length " + str(len(stream)).encode() + b" >>\nstream\n" + stream + b"endstream",
        b"<< /Type /ExtGState /ca 0.5 /CA 0.5 >>", b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
    content = b"%PDF-1.6\n%\xe2\xe3\xcf\xd3\n"; offsets = [0]
    for index, value in enumerate(objects, 1):
        offsets.append(len(content)); content += str(index).encode() + b" 0 obj\n" + value + b"\nendobj\n"
    start = len(content)
    content += b"xref\n0 7\n0000000000 65535 f \n" + b"".join(f"{offset:010d} 00000 n \n".encode() for offset in offsets[1:])
    content += f"trailer\n<< /Size 7 /Root 1 0 R >>\nstartxref\n{start}\n%%EOF\n".encode()
    return content


def definition():
    return b"""%!
[ /Title (Magdobe Ghostscript PDFX4 smoke fixture) /GTS_PDFXVersion (PDF/X-4) /Trapped /False /DOCINFO pdfmark
[/_objdef {icc_PDFX} /type /stream /OBJ pdfmark
[{icc_PDFX} << /N 4 >> /PUT pdfmark
[{icc_PDFX} (%rom%iccprofiles/default_cmyk.icc) (r) file /PUT pdfmark
[/_objdef {OutputIntent_PDFX} /type /dict /OBJ pdfmark
[{OutputIntent_PDFX} << /Type /OutputIntent /S /GTS_PDFX
 /OutputCondition (ENGINE TEST FIXTURE - NOT A PRINTING CONDITION)
 /OutputConditionIdentifier (Magdobe-test-only) /Info (Bundled default CMYK - test only)
 /RegistryName (http://www.color.org) /DestOutputProfile {icc_PDFX} >> /PUT pdfmark
[{Catalog} << /OutputIntents [{OutputIntent_PDFX}] >> /PUT pdfmark
"""


def inspect(data):
    # Disable object streams in the fixture output so basic structural probes need
    # no PDF library. This does not substitute for a PDF/X conformance validator.
    streams = []
    for match in re.finditer(rb"<<(.*?)>>\s*stream\r?\n(.*?)\r?\nendstream", data, re.S):
        dictionary, content = match.groups()
        if b"/FlateDecode" in dictionary:
            try: content = zlib.decompress(content)
            except zlib.error: continue
        streams.append(content)
    combined = data + b"\n" + b"\n".join(streams)
    checks = {
        "pdf_1_6": data.startswith(b"%PDF-1.6"),
        "pdfx4_metadata": b"PDF/X-4" in combined and b"pdfxid:GTS_PDFXVersion" in combined,
        "output_intent": b"/OutputIntents" in data and b"/DestOutputProfile" in data and b"/GTS_PDFX" in data,
        "cmyk_profile_embedded": any(len(value) > 128 and value[36:40] == b"acsp" and value[16:20] == b"CMYK" for value in streams),
        "transparent_graphics_state": bool(re.search(rb"/ca\s+0?\.5\b", data)),
        "vector_rectangle_operator": any(re.search(rb"\bre\b", value) for value in streams),
        "cmyk_paint_operator": any(re.search(rb"\bk\b", value) for value in streams),
        "no_image_objects": b"/Subtype/Image" not in data and b"/Subtype /Image" not in data,
        "font_program_embedded": b"/FontFile" in data,
        "trim_box": b"/TrimBox" in data,
        "bleed_box": b"/BleedBox" in data,
    }
    return checks


def smoke(executable, output):
    if output.exists(): raise ValueError("Choose a new smoke-test output directory")
    output.mkdir(parents=True)
    source, prefix, result = output / "input.pdf", output / "definition.ps", output / "output-pdfx4.pdf"
    source.write_bytes(sample_pdf()); prefix.write_bytes(definition())
    environment = {"PATH": "/usr/bin:/bin", "HOME": "/var/empty", "LANG": "C", "TMPDIR": str(output)}
    command = [str(executable.resolve()), "-q", "-dSAFER", "-dBATCH", "-dNOPAUSE", "-dPDFSTOPONERROR", "-sDEVICE=pdfwrite", "-dPDFX=4",
               "-dPDFACompatibilityPolicy=2", "-sColorConversionStrategy=CMYK", "-sBlendConversionStrategy=Simple", "-sDefaultRGBProfile=%rom%iccprofiles/default_rgb.icc", "-sOutputICCProfile=%rom%iccprofiles/default_cmyk.icc",
               "-dWriteObjStms=false", "-dWriteXRefStm=false", "-sOutputFile=" + str(result.resolve()), str(prefix.resolve()), str(source.resolve())]
    run = subprocess.run(command, cwd=output, env=environment, capture_output=True, text=True, timeout=90)
    (output / "conversion.log").write_text(run.stdout + run.stderr)
    if run.returncode != 0: raise RuntimeError("PDF/X-4 conversion failed: " + run.stdout + run.stderr)
    checks = inspect(result.read_bytes())
    receipt = {"engine": subprocess.check_output([str(executable), "--version"], text=True).strip(), "checks": checks,
               "sha256": hashlib.sha256(result.read_bytes()).hexdigest(),
               "scope": "Engine smoke test only; not independent ISO PDF/X conformance or supplier approval.",
               "profile": "Embedded Ghostscript default CMYK, test only; not a production printing condition"}
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    if not all(checks.values()): raise RuntimeError("Failed smoke checks: " + json.dumps(checks))
    print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gs", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    smoke(args.gs, args.output.resolve())
