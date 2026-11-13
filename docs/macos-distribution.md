# macOS download and distribution

Magdobe has two separate builds. `script/build_and_run.sh` creates a developer app that uses the local tracing runtime. `script/build_release.sh` creates the self-contained application intended for packaging. Distribute the latter. The release app includes its own artwork worker, Python runtime, tracing dependencies, and license notices.

The current release target is macOS 14 or later. Build Apple Silicon and Intel artifacts separately on matching machines and Python runtimes; the verifier checks that every native dependency supports the advertised architecture. An Apple Silicon build is not an Intel or universal build.

The steps below prepare a local preview, then let the release owner sign and notarize it using their own Apple Developer account. The scripts never choose an identity, read a password, create signing credentials, or publish a download. A successful build alone does not establish Apple trust or a public release.

## Build a portable preview

On the build Mac, install Xcode with its command-line tools and a Swift 6 toolchain. The default release build fetches a pinned, checksum-verified, relocatable Python 3.11 runtime from the official Astral `python-build-standalone` release, then downloads the packages pinned in `script/release-requirements.txt` and freezes the helper with PyInstaller. A separate global Python 3.11/Homebrew installation is not required. These build tools are needed by the developer, not by people installing the release app. See the checked-in Python release lock for the exact version, platform asset, and SHA-256.

```sh
./script/test.sh
./script/build_release.sh
python3 -m unittest discover -s Tests/Release -v
python3 script/release.py verify \
  --app "dist/release/Magdobe Illustrator.app" \
  --mode preview --arch arm64 --json
```

`MAGDOBE_RELEASE_ARCH` accepts `arm64` or `x86_64`; use the architecture of the build machine and bundled runtime. If you deliberately override the portable Python source through the build script, the dependency and minimum-OS verifier still applies: a Homebrew interpreter built for a newer macOS cannot be relabeled as supporting macOS 14. Set a new `MAGDOBE_BUILD_NUMBER` for each distributed build. Keep the existing prepared/signed app in a separate versioned folder before rebuilding; the release script refuses to overwrite it.

The result is `dist/release/Magdobe Illustrator.app`. The helper lives at `Contents/Helpers/MagdobeArtworkWorker.app/Contents/MacOS/MagdobeArtworkWorker`. Runtime configuration must not contain the build machine's home directory, Python installation, or Codex installation. Codex and Claude Code remain optional external tools; the app discovers their installed, signed-in CLIs. API providers and local vectorization use the bundled worker.

To make a clearly labeled local testing disk image without Apple signing or notarization:

```sh
python3 script/release.py package \
  --app "dist/release/Magdobe Illustrator.app" \
  --output "dist/Magdobe-0.8.1-arm64-PREVIEW.dmg" --preview
```

The preview image includes an Applications shortcut and a preview notice. It is not a trusted public installer; Gatekeeper can reject it. The `PREVIEW` filename is required. Preview mode does not sign with Developer ID, contact Apple, weaken Gatekeeper, or claim distribution readiness.

## Sign with your Apple Developer account

The release owner performs these steps. Use a **Developer ID Application** certificate whose private key is available in your macOS Keychain. An Apple Development or Developer ID Installer certificate is not a substitute for this app/DMG workflow. Apple documents certificate setup under [Signing Mac Software with Developer ID](https://developer.apple.com/developer-id/).

List the local code-signing identities and supply the exact identity you intend to use:

```sh
security find-identity -v -p codesigning
export MAGDOBE_SIGN_IDENTITY="Developer ID Application: Your Name (YOURTEAMID)"
python3 script/release.py sign \
  --app "dist/release/Magdobe Illustrator.app" \
  --identity "$MAGDOBE_SIGN_IDENTITY"
python3 script/release.py verify \
  --app "dist/release/Magdobe Illustrator.app" --mode signed --arch arm64
```

Before changing any signature, the signing and strict packaging commands require the explicit identity name or SHA-1 fingerprint to uniquely match a valid Developer ID Application identity. They reject Apple Development, ad-hoc, unavailable, and ambiguous names without signing files. Signing works from the deepest Mach-O files and frameworks outward through the helper app, then signs the outer app last. It uses hardened runtime and secure timestamps with the supplied identity. It does not use `codesign --deep` for signing or add blanket entitlements. The verifier checks nested signatures and matching Developer ID team identities. Apple describes the signing order in [Using the latest code signature format](https://developer.apple.com/documentation/xcode/using-the-latest-code-signature-format) and the protection under [Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime).

If a signed helper needs an entitlement, diagnose the exact failing operation before adding one. Re-signing or changing any sealed resource after notarization requires repeating the relevant validation and notarization steps. Keep private keys and exported certificates outside the repository and app bundle.

## Notarize and staple the app

Configure a `notarytool` credential profile locally if you do not already have one. The interactive command below stores the credentials in Keychain; do not paste Apple passwords or API private keys into chat, source files, or command-line arguments.

```sh
xcrun notarytool store-credentials "magdobe-notary"
export MAGDOBE_NOTARY_PROFILE="magdobe-notary"
python3 script/release.py notarize \
  --app "dist/release/Magdobe Illustrator.app" \
  --profile "$MAGDOBE_NOTARY_PROFILE"
python3 script/release.py verify \
  --app "dist/release/Magdobe Illustrator.app" --mode ready --arch arm64
```

The command uploads a ZIP of the already signed app through `notarytool`, waits for an **Accepted** result, records the service receipt/log beside the release app, staples the ticket to the app, and validates the stapled ticket and Gatekeeper assessment. Review the notary log even when Apple accepts a submission. A pending, invalid, rejected, or failed submission is not a notarized release. See Apple's [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

## Produce the final download

Once the app passes `--mode ready`, build the final signed and notarized disk image:

```sh
python3 script/release.py package \
  --app "dist/release/Magdobe Illustrator.app" \
  --output "dist/Magdobe-0.8.1-arm64.dmg" \
  --identity "$MAGDOBE_SIGN_IDENTITY" \
  --profile "$MAGDOBE_NOTARY_PROFILE"
(cd dist && shasum -a 256 -c "Magdobe-0.8.1-arm64.dmg.sha256")
```

The final packaging command validates the ready app, copies it with an Applications shortcut, creates a read-only compressed DMG, verifies and mounts that image for another bundle check, signs the DMG with Developer ID, notarizes/staples the DMG, and assesses the final container. The SHA-256 sidecar is written only after these steps. Existing DMGs/checksum files are never replaced. If a later stage fails, treat the output as incomplete and use a new output filename after resolving the reported failure.

The checksum line contains the DMG's filename. Run the checksum check from the DMG's folder, or use:

```sh
(cd dist && shasum -a 256 -c "Magdobe-0.8.1-arm64.dmg.sha256")
```

Publishing is a separate action. Upload only the final verified DMG and its matching checksum to the intended GitHub release or download host, then test the actual public download. No script in this workflow uploads to GitHub or modifies the website.

## Validated candidate

The local candidate is **Magdobe 0.8.1, build 3**, for **Apple Silicon (arm64)**. Portable-bundle verification covers 115 Mach-O code files, their deployment targets and dependencies, private-path scanning, notice inventory, and nested code-signature integrity. It remains an **ad-hoc preview**: Developer ID signing and Apple notarization were not run.

A QA clone of the actual bundled application completed a live Codex image request through the existing sign-in, converted the image into **8,783 editable objects**, and saved an editable project of approximately **34 MB**. The relocated-worker tests use a temporary home and a minimal system PATH with local image/TLS fixtures; this demonstrates independence from the developer’s Python environment on the development Mac. It does not establish behavior on another physical Mac, actual macOS 14, or a quarantined browser download.

Automated validation comprises **77 native tests, 47 artwork/provider Python tests, and 17 release tests**. The release suite includes 14 offline validator tests and three integration tests against the actual portable bundle. CI runs the offline validation gates; without a built portable app, the three bundle tests explicitly skip. CI never signs with Developer ID, submits to Apple, or publishes a binary.

## Validation before publishing

The automated verifier checks:

- Required app metadata, executable permissions, embedded artwork worker, and license manifest.
- Architecture consistency and minimum macOS versions across native code.
- Library dependencies and search paths that resolve inside the app or to macOS system libraries.
- Broken, absolute, or escaping bundle symlinks; developer-home paths in runtime/text metadata and the main Swift executable; the current builder’s home path in native dependencies; credential-shaped data; and accidental source requests or artwork.
- Developer ID signatures, matching team identities, hardened runtime, and secure timestamps in signed mode.
- Stapled notarization tickets and Gatekeeper assessment in ready mode.
- DMG integrity, its Applications shortcut, the copied app, and final container trust before writing a strict download checksum.

The offline validator tests use fake bundles and mocked Apple commands. They exercise the gates without selecting a certificate, accessing signing credentials, signing code, or submitting anything to Apple. The frozen-bundle integration tests copy the actual release app to a relocated folder and run its worker with a temporary home and minimal system PATH, using local API/TLS fixtures and test credentials. These are clean-environment tests on the development Mac; they do not establish installation behavior on a separate Mac or actual macOS 14 runtime compatibility.

Perform an installation check on a fresh Mac/user account where Magdobe, Xcode, Homebrew, the project's Python environment, and its source checkout are absent. Download the final artifact through a browser so normal quarantine/Gatekeeper behavior applies, drag the app to Applications, eject the DMG, then launch the installed copy. Validate manual drawing; save/reopen; SVG/PDF/PNG export; local image vectorization; provider settings/Keychain storage; and cancellation. If possible, repeat offline to verify local editing/vectorization and stapled trust. Test Codex and Claude Code separately when their external CLIs are installed. Claims about Intel support require the matching Intel artifact and an Intel test.

The dependency notices include Python/PSF and each bundled distribution's full license text. NumPy/SciPy notices include their bundled numerical-library notices; preserving only the top-level MIT file is insufficient. Inspect the license manifest after dependency upgrades. These checks do not certify Adobe Illustrator interoperability or print-production readiness.
