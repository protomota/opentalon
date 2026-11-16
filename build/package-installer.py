"""Package a signed Mac app in the PulseCanvas Finder installer layout."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

from dmgbuild import build_dmg
from ds_store import DSStore
from mac_alias import Alias

ARTWORK = Path("Contents/Resources/installer-background.tiff")


def run(*command: str) -> None:
    subprocess.run(command, check=True)


def notarize(artifact: Path, staple_target: Path | None = None) -> None:
    """Use the same Apple credential options as electron-builder."""
    env = os.environ
    if env.get("APPLE_ID") and env.get("APPLE_APP_SPECIFIC_PASSWORD"):
        credentials = ["--apple-id", env["APPLE_ID"],
                       "--password", env["APPLE_APP_SPECIFIC_PASSWORD"],
                       "--team-id", env["APPLE_TEAM_ID"]]
    elif env.get("APPLE_API_KEY"):
        credentials = ["--key", env["APPLE_API_KEY"], "--key-id", env["APPLE_API_KEY_ID"],
                       "--issuer", env["APPLE_API_ISSUER"]]
    else:
        credentials = ["--keychain-profile", env["APPLE_KEYCHAIN_PROFILE"]]
        if env.get("APPLE_KEYCHAIN"):
            credentials += ["--keychain", env["APPLE_KEYCHAIN"]]
    result = subprocess.run(
        ["xcrun", "notarytool", "submit", str(artifact), *credentials, "--wait",
         "--output-format", "json"], capture_output=True, text=True,
    )
    if result.returncode:
        raise RuntimeError(f"Apple notarization command failed for {artifact.name}")
    receipt = json.loads(result.stdout)
    artifact.with_suffix(".notarization.json").write_text(json.dumps(receipt, indent=2) + "\n")
    if receipt.get("status") != "Accepted":
        raise RuntimeError(f"Apple did not accept {artifact.name}: {receipt.get('status')}")
    target = str(staple_target or artifact)
    run("xcrun", "stapler", "staple", target)
    run("xcrun", "stapler", "validate", target)


def package(app: Path, output: Path, title: str, background: Path | None = None) -> None:
    artwork = background or app / ARTWORK
    if not artwork.is_file() or output.exists():
        raise ValueError("Use existing installer artwork and a new output path")
    run("codesign", "--verify", "--deep", "--strict", str(app))
    mount: Path

    def remember_mount(mount_point: str, _options: dict) -> None:
        nonlocal mount
        mount = Path(mount_point)

    def write_background_alias(event: dict) -> None:
        if background is not None or event.get("type") != "operation::finished" or event.get("operation") != "dsstore::create":
            return
        with DSStore.open(str(mount / ".DS_Store"), "r+") as store:
            icons = store["."]["icvp"]
            icons["backgroundType"] = 2
            icons["backgroundImageAlias"] = Alias.for_file(str(mount / app.name / ARTWORK)).to_bytes()
            store["."]["icvp"] = icons

    build_dmg(str(output), title, settings={
        "format": "UDZO",
        "filesystem": "HFS+",
        "files": [str(app)],
        "symlinks": {"Applications": "/Applications"},
        "window_rect": ((160, 160), (720, 520)),
        "default_view": "icon-view",
        "show_toolbar": False,
        "show_sidebar": False,
        "show_status_bar": False,
        "show_pathbar": False,
        "show_tab_view": False,
        "arrange_by": None,
        "scroll_position": (0, 0),
        "icon_size": 104,
        "text_size": 15,
        "label_pos": "bottom",
        "icon_locations": {app.name: (195, 230), "Applications": (525, 230)},
        "create_hook": remember_mount,
        **({"background": str(background.resolve())} if background else {}),
    }, callback=write_background_alias)
    identity = os.environ.get("CSC_NAME") or "Developer ID Application: Protomota, LLC (22HV69L32T)"
    if not identity.startswith("Developer ID Application: "):
        identity = f"Developer ID Application: {identity}"
    keychain = os.environ.get("CSC_KEYCHAIN") or str(Path.home() / "Library/Keychains/login.keychain-db")
    run("codesign", "--timestamp", "--sign", identity, "--keychain", keychain, str(output))
    notarize(output)
    run("codesign", "--verify", "--strict", str(output))
    run("spctl", "--assess", "--type", "open", "--context", "context:primary-signature",
        "--verbose=2", str(output))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("title", nargs="?")
    parser.add_argument("--background", type=Path, help="Use external artwork without modifying the signed app.")
    parser.add_argument("--notarize-app", action="store_true")
    args = parser.parse_args()
    if args.notarize_app:
        with tempfile.TemporaryDirectory(prefix="notary-app-") as temporary:
            archive = Path(temporary) / f"{args.app.stem}.zip"
            run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(args.app), str(archive))
            notarize(archive, args.app)
    package(args.app, args.output, args.title or args.app.stem, args.background)


if __name__ == "__main__":
    main()
