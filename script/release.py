#!/usr/bin/env python3
"""Inspect, sign, notarize, and package a portable Magdobe macOS release.

This command never chooses signing credentials and never publishes a release.
`verify` is read-only. Other subcommands require explicit user-supplied arguments.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile

DEFAULT_APP = Path('dist/release/Magdobe Illustrator.app')
HELPER = Path('Contents/Helpers/MagdobeArtworkWorker.app/Contents/MacOS/MagdobeArtworkWorker')
MACH_MAGICS = {b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}
SYSTEM_ROOTS = ('/System/Library/', '/usr/lib/')
TEXT_SUFFIXES = {'.json', '.plist', '.txt', '.py', '.sh', '.md', '.toml', '.ini', '.cfg'}
PRIVATE_CONTENT = [re.compile(rb'/Users/[^/\s<>]+/'), re.compile(rb'/home/[^/\s<>]+/'),
                   re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
                   re.compile(rb'\bsk-[A-Za-z0-9_-]{24,}\b'), re.compile(rb'\bgh[pousr]_[A-Za-z0-9]{25,}\b')]
FORBIDDEN_NAMES = {'auth.json', 'request.json', 'generation-info.json', 'trace-info.json', 'source.png', 'artwork.svg', 'vector-preview.png', '.DS_Store'}


class ReleaseError(RuntimeError):
    pass


def run(args, *, check=True):
    result = subprocess.run([str(x) for x in args], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if check and result.returncode:
        detail = (result.stderr or result.stdout).strip()[-3000:]
        raise ReleaseError(Path(str(args[0])).name + ' failed: ' + detail)
    return result


def inside(path, root):
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


def is_macho(path):
    try:
        with path.open('rb') as stream:
            return stream.read(4) in MACH_MAGICS
    except OSError:
        return False


def bundle_files(app):
    """Do not follow directory symlinks; check targets before inspecting files."""
    files = []
    for path in app.rglob('*'):
        relative = path.relative_to(app)
        if path.is_symlink():
            target = os.readlink(path)
            if os.path.isabs(target) or not inside(path, app) or not path.exists():
                raise ReleaseError('Nonportable or broken symlink: ' + str(relative))
        if path.name in FORBIDDEN_NAMES or path.name.startswith('.env') or path.suffix.lower() in {'.mvector', '.p12', '.pfx', '.key'}:
            raise ReleaseError('Private, development, or artwork file in app: ' + str(relative))
        if path.is_file():
            files.append(path)
            if path.suffix.lower() in TEXT_SUFFIXES and path.stat().st_size <= 2_000_000:
                data = path.read_bytes()
                if any(pattern.search(data) for pattern in PRIVATE_CONTENT):
                    raise ReleaseError('Private path or credential-shaped content in metadata: ' + str(relative))
    return files


def inspect_layout(app):
    app = Path(app).resolve()
    if not app.is_dir() or app.suffix != '.app':
        raise ReleaseError('Choose the portable release .app bundle, not a source-build directory.')
    try:
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        raise ReleaseError('The app Info.plist is missing or invalid.') from error
    for key in ['CFBundleExecutable', 'CFBundleIdentifier', 'CFBundleVersion', 'CFBundleShortVersionString', 'LSMinimumSystemVersion']:
        if not str(info.get(key, '')).strip():
            raise ReleaseError('Info.plist is missing ' + key)
    executable = info['CFBundleExecutable']
    if Path(executable).name != executable:
        raise ReleaseError('CFBundleExecutable must be a filename inside Contents/MacOS.')
    main = app / 'Contents/MacOS' / executable
    if not main.is_file() or not os.access(main, os.X_OK) or not is_macho(main):
        raise ReleaseError('The main app executable is missing, not executable, or not Mach-O.')
    helper = app / HELPER
    if not helper.is_file() or not os.access(helper, os.X_OK) or not is_macho(helper):
        raise ReleaseError('The bundled artwork worker is missing. Run script/build_release.sh first.')
    notices = app / 'Contents/Resources/ThirdPartyNotices'
    if not all((notices / name).is_file() for name in ['manifest.json', 'Magdobe-LICENSE.txt', 'Python-LICENSE.txt']):
        raise ReleaseError('The bundled app license or third-party license manifest is missing.')
    try:
        if not json.loads((notices / 'manifest.json').read_text()):
            raise ValueError('empty manifest')
    except (ValueError, UnicodeDecodeError) as error:
        raise ReleaseError('The third-party license manifest is invalid or empty.') from error
    files = bundle_files(app)
    machos = sorted({p.resolve() for p in files if is_macho(p)}, key=str)
    # Swift assertions and DWARF can retain the builder's source paths even in release builds.
    # Scan the whole main executable; it is larger than the text-metadata scan bound.
    if any(pattern.search(main.read_bytes()) for pattern in PRIVATE_CONTENT):
        raise ReleaseError('Private path or credential-shaped content in main app executable. Strip symbols and remap Swift source/debug prefixes before signing.')
    build_home = str(Path.home()).encode('utf-8')
    if build_home not in (b'/', b'/var/empty'):
        for binary in machos:
            if build_home + b'/' in binary.read_bytes():
                raise ReleaseError('Current build-user home path in native code: ' + str(binary.relative_to(app)))
    return app, info, main, helper, machos


def load_commands(path):
    text = run(['/usr/bin/otool', '-l', path]).stdout
    rpaths = re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset \d+\)', text)
    versions = re.findall(r'\bminos ([\d.]+)', text) + re.findall(r'cmd LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version ([\d.]+)', text)
    return rpaths, versions


def executable_dir(path, app):
    for parent in path.parents:
        if parent.suffix == '.app' and inside(parent, app):
            return parent / 'Contents/MacOS'
    return app / 'Contents/MacOS'


def expand_local(value, path, app):
    if value == '@loader_path' or value.startswith('@loader_path/'):
        return path.parent / value[len('@loader_path'):].lstrip('/')
    if value == '@executable_path' or value.startswith('@executable_path/'):
        return executable_dir(path, app) / value[len('@executable_path'):].lstrip('/')
    return Path(value)


def version_tuple(value):
    values = tuple(int(x) for x in value.split('.'))
    return values + (0,) * (3 - len(values))


def verify_dependencies(app, info, main, helper, machos, arch):
    main_archs = set(run(['/usr/bin/lipo', '-archs', main]).stdout.split())
    required = {arch} if arch else main_archs
    if not required or not required.issubset(main_archs):
        raise ReleaseError('The main executable does not contain the requested architecture.')
    commands = {path: load_commands(path) for path in machos}
    root_rpaths = []
    for executable in [main.resolve(), helper.resolve()]:
        for value in commands[executable][0]:
            root_rpaths.append(expand_local(value, executable, app))
    for path in machos:
        relative = str(path.relative_to(app))
        archs = set(run(['/usr/bin/lipo', '-archs', path]).stdout.split())
        if not required.issubset(archs):
            raise ReleaseError('Architecture mismatch: ' + relative)
        rpaths, versions = commands[path]
        for version in versions:
            if version_tuple(version) > version_tuple(info['LSMinimumSystemVersion']):
                raise ReleaseError('A native dependency requires newer macOS than Info.plist declares: ' + relative)
        local_rpaths = []
        for value in rpaths:
            expanded = expand_local(value, path, app)
            if value.startswith(SYSTEM_ROOTS):
                local_rpaths.append(expanded)
                continue
            if value.startswith('@rpath') or not inside(expanded, app):
                raise ReleaseError('Nonportable library search path in ' + relative)
            local_rpaths.append(expanded)
        lines = run(['/usr/bin/otool', '-L', path]).stdout.splitlines()[1:]
        for line in lines:
            value = line.strip().split(' (', 1)[0]
            if not value or value.endswith(':') or value.startswith(SYSTEM_ROOTS):
                continue
            # LC_ID_DYLIB names may refer to the library itself; resolve them like dependencies.
            if value.startswith('@rpath/'):
                candidates = [root / value[len('@rpath/'):] for root in local_rpaths + root_rpaths]
            elif value.startswith(('@loader_path', '@executable_path')):
                candidates = [expand_local(value, path, app)]
            else:
                raise ReleaseError('External absolute or relative library dependency in ' + relative + ': ' + value)
            if not any((candidate.exists() and inside(candidate, app)) or str(candidate).startswith(SYSTEM_ROOTS) for candidate in candidates):
                raise ReleaseError('Unresolved bundled library dependency in ' + relative + ': ' + value)
    return sorted(main_archs)


def signing_targets(app, machos):
    targets = set(machos)
    for path in app.rglob('*'):
        if (path.is_dir() and not path.is_symlink() and path.suffix in {'.app', '.framework', '.xpc', '.bundle'}
                and any(inside(binary, path) for binary in machos)):
            targets.add(path)
    targets.add(app)
    return sorted(targets, key=lambda p: (-len(p.parts), str(p)))


def signature_details(target):
    result = run(['/usr/bin/codesign', '-d', '--verbose=4', target], check=False)
    if result.returncode:
        raise ReleaseError('Unsigned code: ' + target.name)
    return result.stdout + result.stderr


def verify_signatures(app, machos, mode):
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', '--verbose=2', app])
    main_details = signature_details(app)
    team = re.search(r'^TeamIdentifier=(.+)$', main_details, re.MULTILINE)
    if not team or team.group(1) == 'not set':
        raise ReleaseError('Distribution requires a Developer ID Application signature. This app is unsigned or ad-hoc signed.')
    for target in signing_targets(app, machos):
        text = signature_details(target)
        if 'Authority=Developer ID Application:' not in text or 'TeamIdentifier=' + team.group(1) not in text:
            raise ReleaseError('Nested code has a different or non-Developer-ID identity: ' + str(target.relative_to(app)))
        if '(runtime)' not in text or not re.search(r'^Timestamp=.+$', text, re.MULTILINE):
            raise ReleaseError('Hardened runtime and a secure timestamp are required: ' + str(target.relative_to(app)))
    if mode == 'ready':
        run(['/usr/bin/xcrun', 'stapler', 'validate', app])
        run(['/usr/sbin/spctl', '--assess', '--type', 'execute', '--verbose=2', app])


def verify(app, mode='preview', arch=None):
    app, info, main, helper, machos = inspect_layout(app)
    architectures = verify_dependencies(app, info, main, helper, machos, arch)
    if mode != 'preview':
        verify_signatures(app, machos, mode)
    return {'app': str(app), 'mode': mode, 'version': info['CFBundleShortVersionString'], 'build': str(info['CFBundleVersion']),
            'architectures': architectures, 'nativeCodeFiles': len(machos), 'portableLayout': True,
            'distributionReady': mode == 'ready'}


def developer_identity(identity):
    """Resolve only the explicit name/fingerprint supplied by the release owner."""
    identity = (identity or '').strip()
    if not identity or identity == '-':
        raise ReleaseError('Supply your Developer ID Application identity explicitly; ad-hoc signing is preview-only.')
    listing = run(['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning']).stdout
    candidates = re.findall(r'^\s*\d+\)\s+([A-Fa-f0-9]{40})\s+"(Developer ID Application: [^"\n]+)"', listing, re.MULTILINE)
    matches = [(fingerprint, name) for fingerprint, name in candidates
               if identity == name or identity.upper() == fingerprint.upper()]
    if len(matches) != 1:
        raise ReleaseError('The supplied identity does not uniquely match a valid Developer ID Application certificate with its private key. Use its exact displayed name or SHA-1 fingerprint; no files were signed.')
    return matches[0][0]


def sign(app, identity):
    identity = developer_identity(identity)
    verify(app)
    app, _, _, _, machos = inspect_layout(app)
    for target in signing_targets(app, machos):
        print('Signing ' + str(target.relative_to(app) if target != app else app.name), flush=True, file=sys.stderr)
        run(['/usr/bin/codesign', '--force', '--options', 'runtime', '--timestamp', '--sign', identity, target])
    return verify(app, 'signed')


def notarize_archive(archive, profile, diagnostic_directory=None):
    result = run(['/usr/bin/xcrun', 'notarytool', 'submit', archive, '--keychain-profile', profile, '--wait', '--output-format', 'json'])
    try:
        receipt = json.loads(result.stdout)
    except ValueError as error:
        raise ReleaseError('notarytool did not return a JSON receipt; inspect its status before retrying.') from error
    directory = Path(diagnostic_directory) if diagnostic_directory else archive.parent
    receipt_path = directory / (archive.stem + '-notarization.json')
    receipt_path.write_text(json.dumps(receipt, indent=2))
    log = directory / (archive.stem + '-notary-log.json')
    if receipt.get('id'):
        run(['/usr/bin/xcrun', 'notarytool', 'log', receipt['id'], '--keychain-profile', profile, log])
    if receipt.get('status') != 'Accepted':
        raise ReleaseError('Notarization was not accepted. Submission ' + str(receipt.get('id', 'unknown')) + ': ' + str(receipt.get('status', 'unknown')) + '. Review ' + str(log))
    return receipt


def notarize(app, profile):
    if not profile.strip():
        raise ReleaseError('Supply the name of an existing notarytool Keychain profile.')
    verify(app, 'signed')
    app = Path(app).resolve()
    with tempfile.TemporaryDirectory(prefix='magdobe-notary-') as directory:
        archive = Path(directory) / 'Magdobe-Notarization.zip'
        run(['/usr/bin/ditto', '-c', '-k', '--keepParent', app, archive])
        receipt = notarize_archive(archive, profile, app.parent)
        run(['/usr/bin/xcrun', 'stapler', 'staple', app])
    report = verify(app, 'ready')
    report['notarizationSubmission'] = receipt.get('id')
    return report


def checksum(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def package(app, output, preview=False, identity=None, profile=None):
    if preview and (identity or profile):
        raise ReleaseError('Preview packaging does not sign or notarize; omit identity and profile.')
    if not preview and (not identity or identity.strip() == '-' or not profile):
        raise ReleaseError('Publish-ready packaging requires your Developer ID --identity and existing notary --profile. Use --preview for an untrusted local preview.')
    if not preview:
        identity = developer_identity(identity)
    report = verify(app, 'preview' if preview else 'ready')
    app, output = Path(app).resolve(), Path(output).resolve()
    sidecar = output.with_suffix(output.suffix + '.sha256')
    if output.suffix.lower() != '.dmg' or output.exists() or sidecar.exists():
        raise ReleaseError('Choose a new .dmg output filename; existing artifacts are never replaced.')
    if preview and 'PREVIEW' not in output.name.upper():
        raise ReleaseError('A preview disk image must include PREVIEW in its filename.')
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='magdobe-package-') as directory:
        root = Path(directory); stage = root / 'stage'; stage.mkdir()
        run(['/usr/bin/ditto', app, stage / app.name])
        (stage / 'Applications').symlink_to('/Applications', target_is_directory=True)
        if preview:
            (stage / 'PREVIEW.txt').write_text('Local preview build. This download has not passed Developer ID signing and Apple notarization.\n')
        run(['/usr/bin/hdiutil', 'create', '-volname', 'Magdobe Illustrator', '-srcfolder', stage, '-format', 'UDZO', output])
        run(['/usr/bin/hdiutil', 'verify', output])
        mount = root / 'mounted'; mount.mkdir()
        run(['/usr/bin/hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', mount, output])
        try:
            if not (mount / 'Applications').is_symlink() or os.readlink(mount / 'Applications') != '/Applications':
                raise ReleaseError('Packaged disk image is missing its Applications shortcut.')
            verify(mount / app.name, 'preview' if preview else 'ready')
        finally:
            run(['/usr/bin/hdiutil', 'detach', mount])
    if not preview:
        run(['/usr/bin/codesign', '--force', '--timestamp', '--sign', identity, output])
        receipt = notarize_archive(output, profile)
        run(['/usr/bin/xcrun', 'stapler', 'staple', output])
        run(['/usr/bin/xcrun', 'stapler', 'validate', output])
        run(['/usr/sbin/spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', '--verbose=2', output])
        (output.parent / (output.stem + '-notarization.json')).write_text(json.dumps(receipt, indent=2))
    run(['/usr/bin/hdiutil', 'verify', output])
    digest = checksum(output)
    sidecar.write_text(digest + '  ' + output.name + '\n')
    report.update({'diskImage': str(output), 'sha256': digest, 'preview': preview})
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    for name in ['verify', 'sign', 'notarize', 'package']:
        command = sub.add_parser(name)
        command.add_argument('--app', type=Path, default=DEFAULT_APP)
        command.add_argument('--json', action='store_true', help='Print a machine-readable result')
        if name == 'verify':
            command.add_argument('--mode', choices=['preview', 'signed', 'ready'], default='preview')
            command.add_argument('--arch', choices=['arm64', 'x86_64'])
        elif name == 'sign': command.add_argument('--identity', required=True)
        elif name == 'notarize': command.add_argument('--profile', required=True)
        else:
            command.add_argument('--output', type=Path, required=True)
            command.add_argument('--preview', action='store_true')
            command.add_argument('--identity', help='Explicit Developer ID Application identity for the final DMG')
            command.add_argument('--profile', help='Existing notarytool Keychain profile for the final DMG')
    args = parser.parse_args()
    try:
        if args.command == 'verify': report = verify(args.app, args.mode, args.arch)
        elif args.command == 'sign': report = sign(args.app, args.identity)
        elif args.command == 'notarize': report = notarize(args.app, args.profile)
        else: report = package(args.app, args.output, args.preview, args.identity, args.profile)
        print(json.dumps(report, indent=2) if args.json else '\n'.join(str(k) + ': ' + str(v) for k, v in report.items()))
    except (ReleaseError, OSError, ValueError) as error:
        if args.json: print(json.dumps({'ok': False, 'error': str(error)}))
        else: print('Release check failed: ' + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
