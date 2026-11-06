"""The extra Paseo origin cannot widen the plugin's trusted browser origins.

Ported from the Home Assistant add-on's hermes/test/test-paseo-origin.py (container/patches/
PROVENANCE), with HA's paseo_ingress_url cases unchanged. The same cases also run through
scripts/render-args.sh's hermes_origin, which install.sh uses to refuse a bad HERMES_PASEO_EXTRA_ORIGIN
before the boot hook would: the two implementations must agree. Needs python3 and bash.

    python3 tests/test-paseo-origin.py
"""
import importlib.util
from pathlib import Path
import subprocess
import sys
import unittest

REPO = Path(__file__).resolve().parents[1]
FILE = REPO / 'container/rootfs/opt/woow/paseo_origin.py'
spec = importlib.util.spec_from_file_location('paseo_origin', FILE)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

VALID = ('https://ha.example', 'http://homeassistant.local:8123', 'http://[::1]:8123',
         'https://hermes-openclaw.woowtech.io', 'http://127.0.0.1:19119', 'http://localhost:19119')
INVALID = ('', '*', 'https://*.example', 'https://user:secret@ha.example',
           'https://ha.example/api/hassio_ingress/token', 'https://ha.example/?a=b',
           'https://ha.example/#x', 'javascript:alert(1)', '//ha.example',
           ' https://ha.example', 'https://ha.example\n', 'https://ha.example:bad',
           'https://ha.example:99999', 'https://ha.example\\evil',
           'https://ha.example?', 'https://ha.example#', 'https://ha.example:',
           'https://ha.example:0', 'https://bad..example', 'https://ha%2eexample',
           'ftp://ha.example', 'https://ha.example//', 'https://ha.example/hermes')


def shell_origin(value):
    """scripts/render-args.sh hermes_origin <value>: (exit code, output)."""
    script = 'set -u; ql_die() { exit 9; }; ql_warn() { :; }; . "$1"; hermes_origin "$2"'
    result = subprocess.run(['bash', '-c', script, 'bash', str(REPO / 'scripts/render-args.sh'), value],
                            text=True, capture_output=True)
    return result.returncode, result.stdout


class OriginTests(unittest.TestCase):
    def test_accepts_exact_http_https_and_ipv6_origins(self):
        for value in VALID:
            self.assertEqual(module.canonical_origin(value), value)
            self.assertEqual(module.canonical_origin(value + '/'), value)

    def test_rejects_credentials_paths_wildcards_and_ambiguous_urls(self):
        for value in INVALID:
            with self.subTest(value=value), self.assertRaises(ValueError):
                module.canonical_origin(value)

    def test_install_sh_agrees_with_the_boot_hook(self):
        for value in VALID:
            for variant in (value, value + '/'):
                with self.subTest(value=variant):
                    self.assertEqual(shell_origin(variant), (0, value))
        for value in INVALID:
            with self.subTest(value=value):
                self.assertNotEqual(shell_origin(value)[0], 0)

    def test_invalid_input_is_not_echoed(self):
        secret = 'https://user:unique-test-secret@ha.example'
        result = subprocess.run([sys.executable, str(FILE)], input=secret, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('unique-test-secret', result.stdout + result.stderr)
        self.assertIn('HERMES_PASEO_EXTRA_ORIGIN', result.stderr)


if __name__ == '__main__':
    unittest.main()
