PyMuPDF / MuPDF renderer notices and source provenance
====================================================

The standalone PressCheck worker uses PyMuPDF to render passive SVG previews.
The pinned build environment reports PyMuPDF 2.1 and MuPDF 1.28.6. Upstream's
PyMuPDF 2.1 release notes and setup.py identify the same MuPDF version:

https://github.com/pymupdf/PyMuPDF/releases/tag/2.1
https://github.com/pymupdf/PyMuPDF/blob/2.1/setup.py
https://github.com/ArtifexSoftware/mupdf/releases/tag/1.28.6

The original wheel COPYING declaration is retained alongside AGPL-3.0.txt.
The latter is the complete GNU AGPL version 3 text, verified byte-for-byte
against https://www.gnu.org/licenses/agpl-3.0.txt on 2026-11-16:
SHA-256 0d96a4ff68ad6d4b6f1f30f713b18d5184912ba8dd389f86aa7710db079abcb0

Official PyMuPDF source distribution, published through the project's PyPI page:
https://files.pythonhosted.org/packages/13/d9/5ae3cce31a4a62de4f6979331b4d8d5b86a8f2520f06754cf5e69065c887/pymupdf-2.1.tar.gz
Published SHA-256 9ac95f98016e83eafb8f1d786396f9c60e400d559590596e5b2df9eb6384948b
https://pypi.org/project/PyMuPDF/2.1/

The MuPDF source URL used by that setup.py:
https://mupdf.com/downloads/archive/mupdf-1.28.6-source.tar.gz

The release's ThirdPartySources directory and its provenance manifest record
the source archives supplied with the app. Source archives, dependency license
texts and source-version records are evidence of what was supplied; this notice
does not claim a legal audit, printer certification or release-owner signing.
Third-party component notices and build material are retained with those sources.

Optional layout-analysis modules, trained layout models and ONNX are excluded
from the PressCheck helper build. They are not needed for SVG rendering.
