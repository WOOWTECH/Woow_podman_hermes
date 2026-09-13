#!/usr/bin/env python3
"""Apply .env fingerprint patch to Hermes WebUI config.py.
Works with both K3s and Podman versions.

3 patches:
1. Add _get_env_file_path() helper function
2. Add env_file to _models_cache_source_fingerprint() dict
3. Add _delete_models_cache_on_disk() on fingerprint mismatch
"""
import re, os, sys

CFG = '/app/api/config.py'
if not os.path.exists(CFG):
    print("ERROR: config.py not found")
    sys.exit(1)

with open(CFG) as f:
    src = f.read()

if '_get_env_file_path' in src:
    print("Already patched")
    sys.exit(0)

patched = False

# Patch 1: Add _get_env_file_path() function
# Find a good insertion point — after _get_config_path or _get_auth_store_path
for anchor in ['def _get_auth_store_path', 'def _get_config_path']:
    idx = src.find(anchor)
    if idx < 0:
        continue
    # Find end of this function (next def/class at same indent)
    end = src.find('\ndef ', idx + len(anchor))
    if end < 0:
        end = src.find('\nclass ', idx + len(anchor))
    if end < 0:
        continue

    env_fn = '''

def _get_env_file_path():
    """Return path to .env file for fingerprint tracking."""
    env_path = STATE_DIR.parent / ".env"
    return env_path if env_path.exists() else None

'''
    src = src[:end] + env_fn + src[end:]
    print("  Patch 1: _get_env_file_path() added")
    patched = True
    break

if not patched:
    print("ERROR: No insertion point for _get_env_file_path()")
    sys.exit(1)

# Patch 2: Add env_file to fingerprint dict
fp_old = '"catalog": _models_cache_catalog_fingerprint(),'
fp_new = '"catalog": _models_cache_catalog_fingerprint(),\n        "env_file": os.path.getmtime(str(_get_env_file_path())) if _get_env_file_path() else 0,'

if fp_old in src:
    src = src.replace(fp_old, fp_new)
    print("  Patch 2: env_file added to fingerprint dict")
else:
    # Try without trailing comma
    fp_old2 = '"catalog": _models_cache_catalog_fingerprint()'
    if fp_old2 in src:
        fp_new2 = fp_old2 + ',\n        "env_file": os.path.getmtime(str(_get_env_file_path())) if _get_env_file_path() else 0'
        src = src.replace(fp_old2, fp_new2, 1)
        print("  Patch 2: env_file added to fingerprint dict")
    else:
        print("  WARNING: Patch 2 skipped — fingerprint dict pattern not found")

# Patch 3: Add _delete_models_cache_on_disk() call on fingerprint mismatch
# Look for "source_fingerprint" mismatch log + cache invalidation
mismatch_pattern = r'("models cache rejected: source_fingerprint.*?"[\s\S]*?)(return None)'
match = re.search(mismatch_pattern, src)
if match:
    # Check if _delete_models_cache_on_disk already called nearby
    if '_delete_models_cache_on_disk()' not in match.group(0):
        src = src[:match.start(2)] + '_delete_models_cache_on_disk()\n            ' + src[match.start(2):]
        print("  Patch 3: _delete_models_cache_on_disk() on mismatch")
    else:
        print("  Patch 3: already present")
else:
    print("  WARNING: Patch 3 skipped — mismatch pattern not found")

with open(CFG, 'w') as f:
    f.write(src)

print("All patches applied successfully")
