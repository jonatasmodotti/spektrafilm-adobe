#!/usr/bin/env python3
"""Fetch the pinned public renderer and model data, and apply the reviewed Adobe port patch."""
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def git(*args, cwd=ROOT, check=True):
    return subprocess.run(["git", *args], cwd=cwd, check=check)


def applies(*args, cwd):
    """Quiet git apply --check; failing is an expected answer, not an error."""
    return subprocess.run(["git", "apply", "--check", *args], cwd=cwd, capture_output=True).returncode == 0


# Model data read from the reference spektrafilm checkout: profiles, neutral
# print filters and their license. Nothing else is checked out.
REFERENCE_PATHS = (
    "/src/spektrafilm/data/profiles/",
    "/src/spektrafilm/data/filters/neutral_print_filters.json",
    "/SPEKTRAFILM_LICENSE.txt",
)


def fetch_reference(reference):
    checkout = ROOT / "third_party" / "spektrafilm"
    if not checkout.exists():
        checkout.mkdir(parents=True)
        git("init", "--quiet", cwd=checkout)
        git("remote", "add", "origin", reference["url"], cwd=checkout)
        git("sparse-checkout", "set", "--no-cone", *REFERENCE_PATHS, cwd=checkout)
    actual = subprocess.run(
        ["git", "rev-parse", "--verify", "--quiet", "HEAD"], cwd=checkout, text=True, capture_output=True
    ).stdout.strip()
    if actual == reference["commit"]:
        print(f"Reference spektrafilm {actual}: model data present.")
        return
    if actual:
        raise SystemExit(f"Expected reference spektrafilm {reference['commit']}, found {actual} in {checkout}. "
                         "Remove that directory and run this script again.")
    git("fetch", "--quiet", "--depth", "1", "origin", reference["commit"], cwd=checkout)
    git("checkout", "--quiet", "--detach", "FETCH_HEAD", cwd=checkout)
    print(f"Reference spektrafilm {reference['commit']}: model data fetched.")


def main():
    lock = json.loads((ROOT / "upstream.lock.json").read_text())
    fetch_reference(lock["reference"])
    upstream = lock["ofx"]
    checkout = ROOT / "third_party" / "spektrafilm-ofx"
    checkout.parent.mkdir(exist_ok=True)
    if not checkout.exists():
        git("clone", "--no-checkout", upstream["url"], str(checkout))
        git("checkout", "--detach", upstream["commit"], cwd=checkout)
    actual = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=checkout, text=True
    ).strip()
    if actual != upstream["commit"]:
        raise SystemExit(f"Expected upstream {upstream['commit']}, found {actual}. No files changed.")
    patch = ROOT / "patches" / "adobe-port.patch"
    if applies("--reverse", str(patch), cwd=checkout):
        print(f"Upstream {actual}: port patch already applied.")
        return
    if not applies(str(patch), cwd=checkout):
        raise SystemExit(
            "The checkout has other local changes, such as an earlier port patch. Restore it with\n"
            f"  git -C {checkout} checkout -- .\n"
            "and run this script again."
        )
    git("apply", str(patch), cwd=checkout)
    print(f"Upstream {actual}: port patch applied.")


if __name__ == "__main__":
    main()
