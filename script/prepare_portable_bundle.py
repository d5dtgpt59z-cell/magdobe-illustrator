#!/usr/bin/env python3
"""Remove upstream build search paths, then seal an ad-hoc local preview."""
import argparse
from pathlib import Path
from release import SYSTEM_ROOTS, expand_local, inside, inspect_layout, load_commands, run, signing_targets


def prepare(app):
    app, _, _, _, binaries = inspect_layout(app)
    for binary in binaries:
        for value in load_commands(binary)[0]:
            expanded = expand_local(value, binary, app)
            if not value.startswith(SYSTEM_ROOTS) and not inside(expanded, app):
                # Dependencies still have to resolve in the separate strict verifier.
                print("Removing build search path from " + str(binary.relative_to(app)))
                run(["/usr/bin/install_name_tool", "-delete_rpath", value, binary])
    for target in signing_targets(app, binaries):
        run(["/usr/bin/codesign", "--force", "--sign", "-", target])
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    args = parser.parse_args()
    prepare(args.app)
