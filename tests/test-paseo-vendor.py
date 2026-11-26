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
import subprocess
import tempfile

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

# Every documented Podman install runs as the service identity, never root.
for readme_name in ('README.md', 'README_zh-TW.md'):
    readme = (root / readme_name).read_text()
    assert 'podman exec hermes-agent hermes plugins install' not in readme
    assert readme.count('podman exec --user hermes --env HOME=/opt/data') >= 4

# Exercise the documented update primitive against a real Git checkout: a clean fast-forward moves
# the same directory, preserves untracked plugin identity, and does not rewrite .git/config (the
# Omnigent plugin fingerprints that file to distinguish an update from a replacement install).
with tempfile.TemporaryDirectory() as td:
    work = Path(td)
    source, remote, checkout = work/'source', work/'remote.git', work/'checkout'
    subprocess.run(['git', 'init', '-q', str(source)], check=True)
    subprocess.run(['git', '-C', str(source), 'config', 'user.name', 'test'], check=True)
    subprocess.run(['git', '-C', str(source), 'config', 'user.email', 'test@example.invalid'], check=True)
    (source/'plugin.yaml').write_text('version: old\n')
    subprocess.run(['git', '-C', str(source), 'add', 'plugin.yaml'], check=True)
    subprocess.run(['git', '-C', str(source), 'commit', '-qm', 'old'], check=True)
    subprocess.run(['git', 'init', '--bare', '-q', str(remote)], check=True)
    subprocess.run(['git', '-C', str(source), 'remote', 'add', 'origin', str(remote)], check=True)
    subprocess.run(['git', '-C', str(source), 'push', '-q', '-u', 'origin', 'HEAD:main'], check=True)
    subprocess.run(['git', 'clone', '-q', '--branch', 'main', str(remote), str(checkout)], check=True)
    marker = checkout/'.omnigent-installation.json'
    marker.write_text('{"id":"preserved"}\n')
    config = checkout/'.git/config'
    config_before, config_mtime = config.read_bytes(), config.stat().st_mtime_ns
    checkout_inode = checkout.stat().st_ino
    (source/'plugin.yaml').write_text('version: new\n')
    subprocess.run(['git', '-C', str(source), 'commit', '-qam', 'new'], check=True)
    new_sha = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    subprocess.run(['git', '-C', str(source), 'push', '-q', 'origin', 'HEAD:main'], check=True)
    tracked = subprocess.check_output(
        ['git', '-C', str(checkout), 'status', '--porcelain', '--untracked-files=no'], text=True)
    assert tracked == ''
    subprocess.run(['git', '-C', str(checkout), 'fetch', '-q', 'origin', new_sha], check=True)
    subprocess.run(['git', '-C', str(checkout), 'merge', '-q', '--ff-only', 'FETCH_HEAD'], check=True)
    assert subprocess.check_output(['git', '-C', str(checkout), 'rev-parse', 'HEAD'], text=True).strip() == new_sha
    assert checkout.stat().st_ino == checkout_inode
    assert marker.read_text() == '{"id":"preserved"}\n'
    assert config.read_bytes() == config_before and config.stat().st_mtime_ns == config_mtime
print('Paseo host provenance and packaging: ok')
