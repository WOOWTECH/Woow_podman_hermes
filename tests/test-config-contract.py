"""Static contract checks for the image build, the agent unit and the in-image provisioning.

Ported from the Home Assistant add-on's hermes/test/test-config-contract.py (container/patches/
PROVENANCE): the checks that apply to this stack, against its own files. Needs python3 only.

    python3 tests/test-config-contract.py
"""
import hashlib
import pathlib
import re

REPO = pathlib.Path(__file__).resolve().parent.parent
containerfile = (REPO / "container/Containerfile").read_text()
unit = (REPO / "quadlet/hermes-agent.container").read_text()
common = (REPO / "scripts/common.sh").read_text()
install = (REPO / "scripts/install.sh").read_text()
rootfs = REPO / "container/rootfs"


def code(path):
    """The file without comment lines, so a comment that names a removed thing does not count."""
    return "\n".join(line for line in path.read_text().splitlines() if not line.lstrip().startswith("#"))


# The image tag is derived from the upstream base: <upstream tag>-woow<N>.
base = re.search(r"^HERMES_BASE=docker\.io/nousresearch/hermes-agent:(v[0-9.]+)@sha256:[0-9a-f]{64}$", common, re.M)
tag = re.search(r"^HERMES_IMAGE_TAG=(\S+)$", common, re.M)
assert base and tag, "HERMES_BASE / HERMES_IMAGE_TAG missing from scripts/common.sh"
assert re.fullmatch(re.escape(base.group(1)) + r"-woow[0-9]+", tag.group(1)), (tag.group(1), base.group(1))

# v0.22.5 supplies the RFC 9207 issuer and the unattended approval gate natively. The old patches
# must not come back, and the contracts that replaced them are proven during the build.
for gone in ("iss-callback.py", "iss-permissive.py", "approval-unattended.py"):
    assert gone not in code(REPO / "container/Containerfile"), f"Containerfile applies {gone} again"
    assert not (REPO / "container/patches" / gone).exists(), gone
for step in ("upstream-contract.py", "scoped-prompt-gc.py --check", "iss: Optional\\[str\\] = None"):
    assert step in containerfile, f"no build step/proof for {step!r}"
provenance = (REPO / "container/patches/PROVENANCE").read_text()
for patch in (REPO / "container/patches").glob("*.py"):
    assert patch.name in provenance, f"{patch.name} has no PROVENANCE entry"
    # The patches are vendored unchanged: a local edit must update PROVENANCE (and say why).
    digest = hashlib.sha256(patch.read_bytes()).hexdigest()
    assert f"{digest}  hermes/patches/{patch.name}" in provenance, f"{patch.name} differs from its PROVENANCE hash"

# The browser tool is baked in from upstream's package manager into a build-only HERMES_HOME.
assert "export HERMES_HOME=/opt/woow/browser-home" in containerfile
assert "command -v tmux officecli agent-browser" in containerfile

# The TUI runs from the root-owned image tree: no chown of it, no copy into /opt/data.
assert "chown -R hermes:hermes /opt/hermes/ui-tui" not in code(REPO / "container/Containerfile")
assert not (rootfs / "etc/cont-init.d/016-fix-tui-perms").exists()
assert "HERMES_TUI_DIR" not in unit

# Upstream no longer reads these; the image's PATH and browser path must not be overridden (the old
# PATH hid the /opt/hermes/bin privilege-drop shim).
for key in ("HERMES_DASHBOARD_INSECURE", "HERMES_DASHBOARD_TUI", "PATH", "PLAYWRIGHT_BROWSERS_PATH"):
    assert not re.search(rf"^Environment={key}=", unit, re.M), f"the unit still sets {key}"
for env in ("HERMES_WRITE_SAFE_ROOT=/opt/data", "HERMES_DASHBOARD_PORT=9119", "S6_BEHAVIOUR_IF_STAGE2_FAILS=2",
            "S6_SERVICES_GRACETIME=25000", "S6_KILL_GRACETIME=25000", "NODE_OPTIONS=--max-old-space-size=4096"):
    assert env in containerfile, f"the image ENV lacks {env}"

# HERMES_UID=1000 stays: compose-era volumes are owned by 1000 and v0.22.5's targeted chown would
# leave most of such a volume unreadable to its default 10000 (tests/image-test.sh B6).
assert re.search(r"^Environment=HERMES_UID=1000$", unit, re.M) and re.search(r"^Environment=HERMES_GID=1000$", unit, re.M)

# Every generated secret the agent reads is a podman secret, created by install.sh.
secrets = dict(re.findall(r"^Secret=([a-z0-9-]+),type=env,target=([A-Z_]+)$", unit, re.M))
assert secrets == {
    "hermes-api-server-key": "API_SERVER_KEY",
    "hermes-webhook-secret": "WEBHOOK_SECRET",
    "hermes-dashboard-password": "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD",
    "hermes-dashboard-session-secret": "HERMES_DASHBOARD_BASIC_AUTH_SECRET",
}, secrets
for name in secrets:
    assert install.count(f"ql_secret_ensure {name} ") == 2, f"install.sh does not create and rotate {name}"

# The agent runs with upstream's approval defaults (decision 2026-09-25 in the add-on): the sed
# policy never matched the v2026.8.31 config and must not come back looking as if it did.
provision = code(rootfs / "usr/local/bin/woow-provision")
for text in ("cron_mode: yolo", "mode: off", "hooks_auto_accept: true", "sed -i"):
    assert text not in provision, f"woow-provision still carries the approval policy: {text!r}"
# v0.22.5 removed these core toolsets; enabling them fails provisioning under set -e.
for toolset in ("moa", "homeassistant"):
    assert not re.search(rf"tools enable.*\b{toolset}\b|\bfor t in [^;]*\b{toolset}\b", provision), toolset

# Defaults written while the keys are empty.
for default in ("set_default web.search_backend ddgs", "set_default web.extract_backend parallel",
                "set_default browser.backend off", "set_default platforms.webhook.enabled true"):
    assert default in provision, default

# .env is merged, not rewritten, and never carries a secret the unit manages.
dotenv = code(rootfs / "etc/cont-init.d/03-woow-dotenv")
assert "sha256sum" in dotenv and "API_SERVER_KEY|WEBHOOK_SECRET|HERMES_DASHBOARD_BASIC_AUTH_" in dotenv
assert ".env" not in code(rootfs / "etc/cont-init.d/020-woow-provision"), "020 must leave .env to 03-woow-dotenv"
assert "03-woow-dotenv" in containerfile
# ... nor a copy of the origins hermes.env declares (it would override them for OAuth and Paseo).
assert "HERMES_DASHBOARD_PUBLIC_URL|HERMES_BASE_URL|HERMES_PASEO_[A-Z_]*" in dotenv

# Paseo (tests/test-paseo-vendor.py checks the adapter itself): the extra origin is converted by the
# boot hook through the reviewed validator, and install.sh validates it before that.
paseo_hook = code(rootfs / "etc/cont-init.d/04-woow-paseo-origin")
assert "HERMES_PASEO_EXTRA_ORIGIN" in paseo_hook and "/opt/woow/paseo_origin.py" in paseo_hook
assert "rm -f \"$ENVDIR/HERMES_PASEO_INGRESS_ORIGIN\"" in paseo_hook
assert "04-woow-paseo-origin" in containerfile
assert "hermes_check_origins" in (REPO / "scripts/render-args.sh").read_text()
assert re.search(r"^HERMES_PASEO_EXTRA_ORIGIN=$", (REPO / "config/hermes.env.example").read_text(), re.M)
# A network or volume removed behind systemd's back is recreated (tests/resource-recreate.sh).
assert 'hermes_ensure_resources "$WORK/out"' in install

print("config contract: ok")
