"""Verify the reviewed Paseo host adapter is complete, pinned, untampered and packaged as reviewed.

Ported from the Home Assistant add-on's hermes/test/test-paseo-vendor.py (container/patches/
PROVENANCE): the same pins against container/vendor/paseo, plus the Podman packaging (the venv entry
point is replaced, upstream's privilege-drop shim is not). Needs python3 only.

    python3 tests/test-paseo-vendor.py
"""
import ast
import hashlib
import json
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
vendor = root / 'container/vendor/paseo'
pin = json.loads((vendor / 'PROVENANCE.json').read_text())
assert pin['repository'] == 'https://github.com/WOOWTECH/hermes-paseo-plugin'
assert pin['commit'] == '7b9c88d032672f688c88df222e384ce3bc1af2f2'
assert pin['version'] == '0.1.5-rc.3'
assert set(pin['sha256']) == {'dashboard_control.py', 'profile_lifecycle.py', 'resource_limits.py', 'hermes'}
for name, digest in pin['sha256'].items():
    data = (vendor / name).read_bytes()
    assert hashlib.sha256(data).hexdigest() == digest, name + ' differs from reviewed source'
    if name.endswith('.py'):
        ast.parse(data)
assert 'MIT License' in (vendor / 'LICENSE').read_text()
assert 'HERMES_PASEO_INGRESS_ORIGIN' in (vendor / 'dashboard_control.py').read_text()

# The HA add-on commit the files were taken from, and the plugin release they belong to.
provenance = (root / 'container/patches/PROVENANCE').read_text()
assert pin['commit'] in provenance and pin['version'] in provenance, 'PROVENANCE does not name the adapter source'
digest = hashlib.sha256((vendor / 'PROVENANCE.json').read_bytes()).hexdigest()
assert f'{digest}  hermes/vendor/paseo/PROVENANCE.json' in provenance, 'PROVENANCE.json differs from the HA copy'

containerfile = (root / 'container/Containerfile').read_text()
assert ('COPY --chmod=0555 vendor/paseo/dashboard_control.py vendor/paseo/profile_lifecycle.py '
        'vendor/paseo/resource_limits.py /opt/hermes-paseo-dashboard-control/') in containerfile
assert 'COPY --chmod=0555 vendor/paseo/hermes /opt/woow/paseo-hermes-entrypoint' in containerfile
# The venv entry point is replaced; the shim that drops `podman exec ... hermes` to the hermes user
# and upstream's libexec launcher are proven unchanged, and nothing writes over /opt/hermes/bin.
assert 'install -o root -g root -m 0555 /opt/woow/paseo-hermes-entrypoint /opt/hermes/.venv/bin/hermes' in containerfile
assert 'cmp /opt/hermes/bin/hermes /opt/hermes/docker/hermes-exec-shim.sh' in containerfile
assert "grep -qx 'REAL=/opt/hermes/.venv/bin/hermes' /opt/hermes/bin/hermes" in containerfile
assert "grep -q 'Bundled interpreter missing' /opt/hermes/libexec/hermes" in containerfile
assert not re.search(r'^(COPY|ADD)\b.*\s/opt/hermes/bin/', containerfile, re.M), 'the privilege-drop shim is overwritten'
assert not re.search(r'^(COPY|ADD)\b.*\s/opt/hermes/\.venv/bin/hermes\s*$', containerfile, re.M), \
    'COPY onto the venv symlink is builder-dependent; install the wrapper explicitly'
# The wrapper refuses to start the dashboard as root, and the build proves it.
assert 'Start Dashboard as the Hermes service account.' in (vendor / 'hermes').read_text()
assert "'Start Dashboard as the Hermes service account.'" in containerfile
# Paseo needs Node.js 22.19+ at runtime (plugin package.json engines); the build checks the image's.
assert 'a>22||(a===22&&b>=19)' in containerfile
# The extra origin is converted at boot, never set by the unit.
assert 'HERMES_PASEO' not in (root / 'quadlet/hermes-agent.container').read_text()
assert (root / 'container/rootfs/etc/cont-init.d/04-woow-paseo-origin').exists()

# The separately managed plugins are optional and reproducibly pinned. A normal install/update does
# not force a reinstall, which would invalidate user-held login/consent state.
for readme_name in ('README.md', 'README_zh-TW.md'):
    readme = (root / readme_name).read_text()
    assert '7b9c88d032672f688c88df222e384ce3bc1af2f2 --enable' in readme
    assert '84e0c41ce91594908a53c91fcff09123ca92f626 --enable' in readme
    assert '0.11.2-r3-523d451cc096' in readme
    for command in re.findall(r'hermes plugins install WOOWTECH/hermes-(?:paseo|omnigent)-plugin[^\n`]*', readme):
        assert '--force' not in command
print('Paseo host provenance and packaging: ok')
