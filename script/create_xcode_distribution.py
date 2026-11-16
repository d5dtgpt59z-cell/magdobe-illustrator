#!/usr/bin/env python3
"""Generate a genuine macOS application target; never build, sign, or upload it.

The explicit portable input must already pass release.py's signed gates. Only
public certificate/identity metadata is inspected; no key material is read.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import sys
import tempfile
from xml.sax.saxutils import quoteattr

ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location('magdobe_distribution_release', ROOT / 'script/release.py')
release = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(release)


def certificate_fingerprint(app):
    """Hash the public leaf certificate, not any private signing-key material."""
    with tempfile.TemporaryDirectory(prefix='magdobe-public-certificate-') as directory:
        prefix = Path(directory) / 'certificate'
        release.run(['/usr/bin/codesign', '--display', '--extract-certificates=' + str(prefix), app])
        leaf = Path(str(prefix) + '0')
        if not leaf.is_file() or not 0 < leaf.stat().st_size <= 128 * 1024:
            raise release.ReleaseError('Cannot read the signed app public certificate.')
        return hashlib.sha1(leaf.read_bytes()).hexdigest().upper()


def _checked_path(path):
    path = Path(path).absolute()
    if any(character in str(path) for character in '\n\r\\'):
        raise release.ReleaseError('Build paths must not contain newlines or backslashes.')
    return path


def _project(app, root, output, info, architectures, fingerprint, team, sources):
    """Use only an application target; aggregate/external targets cannot notarize."""
    objects = []
    uid = lambda label: hashlib.sha256(label.encode()).hexdigest()[:24].upper()
    quote = lambda value: json.dumps(str(value), ensure_ascii=False)

    def add(label, body):
        objects.append(f'\t\t{uid(label)} = {{ {body} }};')
        return uid(label)

    references, builds = [], []
    source_root = root / 'Sources/MagnusVector'
    for path in sources:
        name = str(path.relative_to(source_root))
        references.append(add('ref:' + name, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quote(name)}; sourceTree = "<group>";'))
        builds.append(add('build:' + name, f'isa = PBXBuildFile; fileRef = {uid("ref:" + name)};'))
    product_name = app.stem
    add('source-group', f'isa = PBXGroup; children = ({", ".join(references)}); name = Sources; path = {quote(source_root)}; sourceTree = "<absolute>";')
    add('product', f'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {quote(app.name)}; sourceTree = BUILT_PRODUCTS_DIR;')
    add('products', f'isa = PBXGroup; children = ({uid("product")}); name = Products; sourceTree = "<group>";')
    add('group', f'isa = PBXGroup; children = ({uid("source-group")}, {uid("products")}); sourceTree = "<group>";')
    add('sources-phase', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({", ".join(builds)}); runOnlyForDeploymentPostprocessing = 0;')
    add('frameworks-phase', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
    script = '''set -eu
SOURCE_APP="${MAGDOBE_PORTABLE_APP}"
# These are read-only operations. A changed tested input requires regeneration.
/usr/bin/shasum -a 256 -c "$SRCROOT/InputHashes.sha256" >/dev/null
/usr/bin/codesign --verify --deep --strict "$SOURCE_APP"
/usr/bin/ditto "$SOURCE_APP/Contents/Helpers" "$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
/usr/bin/ditto "$SOURCE_APP/Contents/Resources" "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
'''
    add('copy-phase', f'isa = PBXShellScriptBuildPhase; alwaysOutOfDate = 1; buildActionMask = 2147483647; files = (); inputPaths = (); name = "Verify and copy tested helpers and resources"; outputPaths = (); runOnlyForDeploymentPostprocessing = 0; shellPath = /bin/sh; shellScript = {quote(script)};')
    settings = {
        'ARCHS': ' '.join(architectures), 'CLANG_ENABLE_MODULES': 'YES',
        'CODE_SIGN_STYLE': 'Manual', 'CODE_SIGN_IDENTITY': fingerprint,
        'CODE_SIGN_INJECT_BASE_ENTITLEMENTS': 'NO', 'COPY_PHASE_STRIP': 'YES',
        'CURRENT_PROJECT_VERSION': info['CFBundleVersion'], 'DEBUG_INFORMATION_FORMAT': 'dwarf',
        'DEVELOPMENT_TEAM': team, 'ENABLE_APP_SANDBOX': 'NO',
        'ENABLE_HARDENED_RUNTIME': 'YES', 'ENABLE_USER_SCRIPT_SANDBOXING': 'NO',
        'EXECUTABLE_NAME': 'MagnusVector', 'GCC_GENERATE_DEBUGGING_SYMBOLS': 'NO',
        'GENERATE_INFOPLIST_FILE': 'NO', 'INFOPLIST_FILE': str(output / 'Distribution-Info.plist'),
        'INSTALL_PATH': '/Applications',
        'MACOSX_DEPLOYMENT_TARGET': info['LSMinimumSystemVersion'],
        'MAGDOBE_PORTABLE_APP': str(app), 'MARKETING_VERSION': info['CFBundleShortVersionString'],
        'ONLY_ACTIVE_ARCH': 'NO', 'OTHER_CODE_SIGN_FLAGS': '--timestamp',
        'PRODUCT_BUNDLE_IDENTIFIER': info['CFBundleIdentifier'], 'PRODUCT_NAME': product_name,
        'PRODUCT_MODULE_NAME': 'MagnusVector', 'SDKROOT': 'macosx', 'SKIP_INSTALL': 'NO',
        'STRIP_INSTALLED_PRODUCT': 'YES', 'STRIP_STYLE': 'non-global', 'STRIP_SWIFT_SYMBOLS': 'YES',
        'SUPPORTED_PLATFORMS': 'macosx', 'SWIFT_COMPILATION_MODE': 'wholemodule',
        'SWIFT_OPTIMIZATION_LEVEL': '-O', 'SWIFT_SERIALIZE_DEBUGGING_OPTIONS': 'NO',
        'SWIFT_STRICT_CONCURRENCY': 'minimal', 'SWIFT_VERSION': '5.0',
    }
    flags = ['-debug-prefix-map', f'{root}=.', '-file-prefix-map', f'{root}=.']
    body = ' '.join(f'{key} = {quote(value)};' for key, value in settings.items())
    body += ' OTHER_SWIFT_FLAGS = (' + ', '.join(quote(flag) for flag in flags) + ');'
    add('release', f'isa = XCBuildConfiguration; buildSettings = {{ {body} }}; name = Release;')
    add('target-configs', f'isa = XCConfigurationList; buildConfigurations = ({uid("release")}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
    add('project-release', 'isa = XCBuildConfiguration; buildSettings = {}; name = Release;')
    add('project-configs', f'isa = XCConfigurationList; buildConfigurations = ({uid("project-release")}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
    add('target', f'isa = PBXNativeTarget; buildConfigurationList = {uid("target-configs")}; buildPhases = ({uid("sources-phase")}, {uid("frameworks-phase")}, {uid("copy-phase")}); buildRules = (); dependencies = (); name = MagdobeDistribution; productName = {quote(product_name)}; productReference = {uid("product")}; productType = "com.apple.product-type.application";')
    add('project', f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 2600; TargetAttributes = {{ {uid("target")} = {{ CreatedOnToolsVersion = 26.0; DevelopmentTeam = {quote(team)}; ProvisioningStyle = Manual; }}; }}; }}; buildConfigurationList = {uid("project-configs")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = {uid("group")}; productRefGroup = {uid("products")}; projectDirPath = ""; projectRoot = ""; targets = ({uid("target")});')
    project = '// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + '\n'.join(objects) + f'\n\t}}; rootObject = {uid("project")};\n}}\n'
    scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
    <BuildActionEntries><BuildActionEntry buildForTesting="NO" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid('target')}" BuildableName={quoteattr(app.name)} BlueprintName="MagdobeDistribution" ReferencedContainer="container:MagdobeDistribution.xcodeproj"/></BuildActionEntry></BuildActionEntries>
  </BuildAction>
  <LaunchAction buildConfiguration="Release" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
    <BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid('target')}" BuildableName={quoteattr(app.name)} BlueprintName="MagdobeDistribution" ReferencedContainer="container:MagdobeDistribution.xcodeproj"/></BuildableProductRunnable>
  </LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/>
  <AnalyzeAction buildConfiguration="Release"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
    return project, scheme


def generate(app, identity, output, *, root=ROOT):
    output = _checked_path(output)
    if os.path.lexists(output):
        raise release.ReleaseError('Choose a new output directory; existing artifacts are never replaced.')
    output, app, root = output.resolve(), _checked_path(app).resolve(), _checked_path(root).resolve()
    if release.inside(output, app) or release.inside(output, root / 'Sources'):
        raise release.ReleaseError('The generated project must be outside the input app and source tree.')
    validation = release.verify(app, mode='signed')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleExecutable') != 'MagnusVector' or info.get('CFBundlePackageType') != 'APPL':
        raise release.ReleaseError('This generator requires the Magdobe MagnusVector application bundle.')
    if (not isinstance(info['CFBundleIdentifier'], str) or
            not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.-]+', info['CFBundleIdentifier'])):
        raise release.ReleaseError('The application bundle identifier is invalid.')
    for key in ['CFBundleVersion', 'CFBundleShortVersionString', 'LSMinimumSystemVersion']:
        if not isinstance(info[key], str) or not re.fullmatch(r'\d+(?:\.\d+){0,2}', info[key]):
            raise release.ReleaseError('Unsupported numeric app metadata: ' + key)
    architectures = validation['architectures']
    if not architectures or not set(architectures) <= {'arm64', 'x86_64'}:
        raise release.ReleaseError('Only verified arm64/x86_64 release architectures are supported.')
    fingerprint = release.developer_identity(identity).upper()
    if certificate_fingerprint(app) != fingerprint:
        raise release.ReleaseError('The explicit identity must match the portable app public signing certificate exactly.')
    team_match = re.search(r'^TeamIdentifier=([A-Z0-9]{10})$', release.signature_details(app), re.MULTILINE)
    if not team_match:
        raise release.ReleaseError('The signed input is missing a valid Developer ID team identifier.')
    team = team_match.group(1)
    source_root = root / 'Sources/MagnusVector'
    sources = sorted(source_root.rglob('*.swift'))
    if not sources or any(not release.inside(path, source_root) for path in sources):
        raise release.ReleaseError('The checked-out Magdobe Swift sources are missing or escape the source tree.')
    inputs = sources + [app / 'Contents' / path for path in ['Info.plist', 'MacOS/MagnusVector', '_CodeSignature/CodeResources']]
    hashes = [(release.file_sha256(_checked_path(path)), str(path)) for path in inputs]
    project_text, scheme = _project(app, root, output, info, architectures, fingerprint, team, sources)
    project = output / 'MagdobeDistribution.xcodeproj'
    archive = output / 'MagdobeDistribution.xcarchive'
    command = ['/usr/bin/xcodebuild', 'archive', '-project', str(project), '-scheme', 'MagdobeDistribution',
               '-configuration', 'Release', '-destination', 'generic/platform=macOS',
               '-derivedDataPath', str(output / 'DerivedData'), '-archivePath', str(archive)]
    receipt = {'schema_version': 1, 'app': str(app), 'project': str(project), 'archive': str(archive),
               'version': info['CFBundleShortVersionString'], 'build': str(info['CFBundleVersion']),
               'architectures': architectures, 'minimum_macos': info['LSMinimumSystemVersion'],
               'team': team, 'identity_sha1': fingerprint, 'swift_source_files': len(sources),
               'archive_command': command, 'built': False, 'notarized': False}
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    scheme_path = project / 'xcshareddata/xcschemes/MagdobeDistribution.xcscheme'
    scheme_path.parent.mkdir(parents=True)
    files = {project / 'project.pbxproj': project_text, scheme_path: scheme,
             output / 'InputHashes.sha256': ''.join(f'{digest}  {path}\n' for digest, path in hashes),
             output / 'generation.json': json.dumps(receipt, indent=2) + '\n'}
    for path, content in files.items():
        with path.open('x') as stream:
            stream.write(content)
    with (output / 'Distribution-Info.plist').open('xb') as stream:
        plistlib.dump(info, stream)
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path, help='Existing Developer-ID-signed portable Magdobe app')
    parser.add_argument('--identity', required=True, help='Exact Developer ID Application name or SHA-1 fingerprint')
    parser.add_argument('--output', required=True, type=Path, help='New local directory; never replaced')
    args = parser.parse_args()
    try:
        receipt = generate(args.app, args.identity, args.output)
    except (release.ReleaseError, OSError, ValueError) as error:
        parser.exit(1, 'Xcode project generation failed: ' + str(error) + '\n')
    print(json.dumps(receipt, indent=2))
    print('\nTo build and sign explicitly, run:\n' + shlex.join(receipt['archive_command']), file=sys.stderr)


if __name__ == '__main__':
    main()
