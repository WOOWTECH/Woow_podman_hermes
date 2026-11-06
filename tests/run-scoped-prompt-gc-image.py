#!/usr/bin/env python3
"""Rerun GC regressions in a locally built image, with no network or host access.

    python3 tests/run-scoped-prompt-gc-image.py --image "$(podman image inspect --format '{{.Id}}' localhost/woow-hermes-agent:<tag>)"

--apply-build-patch copies only the relevant complete module to owned tmpfs and
applies the product build patch there. Omit it to check an already-built image.
--unpatched is the negative control: tests must fail on unrelated-orphan GC
(run it against the upstream base, whose session module is unpatched).
From the Home Assistant add-on (container/patches/PROVENANCE), with podman
instead of docker and no default image: this repo publishes none to pin.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import uuid

PAYLOAD = '''import logging, os, pathlib, runpy, shutil, sys
logging.disable(logging.CRITICAL)
sys.dont_write_bytecode = True
mode = sys.argv[1]
args = ["/repo/tests/test-scoped-prompt-gc.py", "--runtime-root", "/opt/hermes"]
if mode == "patch":
    root = pathlib.Path("/tmp/scoped-gc-overlay")
    root.mkdir()
    upstream = pathlib.Path("/opt/hermes")
    name = "hermes_state_sessions.py" if (upstream / "hermes_state_sessions.py").exists() else "hermes_state.py"
    shutil.copyfile(upstream / name, root / name)
    patcher = runpy.run_path("/repo/container/patches/scoped-prompt-gc.py")
    patcher["patch_directory"](root)
    patcher["patch_directory"](root, check=True)
    args += ["--overlay-root", str(root)]
elif mode == "unpatched":
    args += ["--unpatched"]
sys.argv = args
runpy.run_path(args[0], run_name="__main__")
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True, help="digest reference or sha256 image ID; tags are refused")
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--apply-build-patch", action="store_true")
    modes.add_argument("--unpatched", action="store_true")
    parser.add_argument("--describe", action="store_true", help="emit command metadata without invoking podman")
    args = parser.parse_args()
    if not re.fullmatch(r"(?:[a-zA-Z0-9./_:-]+@)?sha256:[0-9a-f]{64}", args.image):
        parser.error("use an immutable digest or image ID")
    mode = "patch" if args.apply_build_patch else "unpatched" if args.unpatched else "built"
    name = "hermes-p1-test-scoped-gc-" + uuid.uuid4().hex[:12]
    command = ["podman", "run", "--rm", "--pull", "never", "--name", name,
               "--network", "none", "--read-only", "--cap-drop", "ALL",
               "--security-opt", "no-new-privileges", "--user", "10000:10000",
               "--memory", "768m", "--cpus", "1", "--pids-limit", "96",
               "--tmpfs", "/tmp:rw,nosuid,nodev,size=128m,mode=1777",
               "-e", "PYTHONDONTWRITEBYTECODE=1", "-e", "HERMES_HOME=/tmp/hermes-test-home",
               "-v", str(Path(__file__).resolve().parents[1])+":/repo:ro",
               "--entrypoint", "/opt/hermes/.venv/bin/python", "-i", args.image, "-", mode]
    receipt = {"command": command, "mode": mode, "ha_access": False, "image_runtime_executed": False}
    if args.describe:
        print(json.dumps(receipt, sort_keys=True))
        return 0
    try:
        result = subprocess.run(command, input=PAYLOAD, capture_output=True, text=True, timeout=90)
    except FileNotFoundError:
        receipt["blocked"] = "podman-unavailable"
        print(json.dumps(receipt, sort_keys=True))
        return 2
    except subprocess.TimeoutExpired:
        subprocess.run(["podman", "rm", "-f", name], capture_output=True, timeout=15)
        receipt["blocked"] = "own-container-timeout"
        print(json.dumps(receipt, sort_keys=True))
        return 2
    receipt.update(image_runtime_executed=True, exit_code=result.returncode, stderr_bytes=len(result.stderr.encode()))
    try:
        receipt["tests"] = json.loads(result.stdout)
    except ValueError:
        receipt["blocked"] = "missing-test-receipt"
        print(json.dumps(receipt, sort_keys=True))
        return 2
    expected = 1 if args.unpatched else 0
    passed = (result.returncode == expected and not receipt["tests"]["errors"]
              and bool(receipt["tests"]["failures"]) == args.unpatched)
    receipt["expected_result"] = passed
    print(json.dumps(receipt, sort_keys=True))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
