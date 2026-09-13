# Rehearsal of `scripts/migrate-legacy.sh` on toypark1234, 2026-09-14

Evidence for the P6 migration script. Nothing in this file is a plan: every line below is output
from a real run. `woowtechopenclaw` was **not** touched — it was read, read-only, for the facts the
script depends on (image ids, restart policies, published ports, volume mounts, writable-layer
sizes).

## What was stood up

The compose deployment of this repository's own `compose-final` tag, checked out so that the compose
file sits in a directory literally named `podman` — which is how podman-compose derives the project
name `podman`, and with it the `podman_*` volume names and the `podman_default` network that
`woowtechopenclaw` has. Isolated high ports on `127.0.0.1`.

```
=== podman-compose up (project name comes from this directory: podman) ===
hermes-agent|Up 36 seconds (starting)|docker.io/nousresearch/hermes-agent:latest
hermes-postgresql|Up 34 seconds (healthy)|docker.io/library/postgres:15
hermes-redis|Up 31 seconds (healthy)|docker.io/library/redis:7-alpine
hermes-agent policy=always project=podman net=podman_default
hermes-postgresql policy=always project=podman net=podman_default
hermes-redis policy=always project=podman net=podman_default
podman_hermes-data
podman_postgres-data
podman_redis-data
gateway HTTP 200 after 20s
```

| | openclaw | rehearsal |
|---|---|---|
| gateway / dashboard / webhook | 18642 / 19119 / 18644 on `0.0.0.0` | 41864 / 41911 / 41865 on `127.0.0.1` |
| containers | `hermes-agent`, `hermes-postgresql`, `hermes-redis` | the same (toypark had none of those names) |
| compose project / network | `podman` / `podman_default` | the same |
| volumes | `podman_hermes-data`, `podman_postgres-data`, `podman_redis-data` | the same |
| `hermes-postgresql` `.SizeRw` | 1 087 119 B | 1 087 123 B |
| `hermes-redis` `.SizeRw` | 11 376 B | 11 378 B |
| restart policy | `unless-stopped` | **`always`** (deliberate — see below) |

**One deliberate divergence.** On openclaw all three containers are `unless-stopped`, which
`podman-restart.service`'s filter does not match, so that host takes the *rename* path. To rehearse
the capture path at all, the rehearsal added an overlay setting `restart: always`. Both paths are
covered: the rename answer was demonstrated by a dry-run on the host as it really is, and the
capture path was then run for real.

The two PostgreSQL and Redis writable-layer sizes coming out within a handful of bytes of the live
openclaw values on a completely independent host is worth noting on its own: the 1.04 MiB that pushes
`hermes-postgresql` over the commit threshold is inherent to `postgres:15`, not an openclaw artefact.

## How the `capture` path was reached without touching `podman-restart.service`

toypark's `podman-restart.service` is **disabled** and was left that way. `ql_podman_restart_enabled`
is the single place the library asks that question, so the decision boundary was shimmed: a wrapper
first on `PATH` that answers exactly

```sh
[ "$1" = --user ] && [ "$2" = is-enabled ] && [ "$3" = podman-restart.service ] && { echo enabled; exit 0; }
exec /usr/bin/systemctl "$@"
```

and passes every other `systemctl` call through to the real binary. Everything else was real.

Without the shim, on the host as it is:

```
migrate-legacy.sh: podman-restart.service is not enabled for this user, so renaming and leaving the
legacy container(s) stopped is safe
... The cutover would stop the three containers, rename them to *-legacy-20260914 and then install
```

With it:

```
WARNING: podman-restart.service is enabled for this user: at boot it runs 'podman start --all
--filter restart-policy=always', which would revive hermes-agent(always) hermes-postgresql(always)
hermes-redis(always) next to the new Quadlet container(s)
... The cutover would stop the three containers, capture them into the backup directory
(hermes-agent with --commit) and remove them
```

Both dry-runs derived the same settings from the running containers — including the volume names
that make the adoption possible, the memory and CPU limits read off `HostConfig`, and `--no-llm`
because the legacy `MINIMAX_API_KEY` is empty (as it is on openclaw):

```
    WOOW_HERMES_DATA_VOLUME=podman_hermes-data
    WOOW_HERMES_POSTGRES_VOLUME=podman_postgres-data
    WOOW_HERMES_REDIS_VOLUME=podman_redis-data
    WOOW_HERMES_PORT_GATEWAY=41864
    WOOW_HERMES_PORT_DASHBOARD=41911
    WOOW_HERMES_PORT_WEBHOOK=41865
    WOOW_HERMES_BIND=127.0.0.1
    WOOW_HERMES_MEMORY=6144m
    WOOW_HERMES_CPUS=3
adopted in place: podman_hermes-data   (.../volumes/podman_hermes-data/_data|2026-09-14 03:16:17.853724505 +0800 CST|1049243)
adopted in place: podman_redis-data    (.../volumes/podman_redis-data/_data|2026-09-14 03:19:23.384050653 +0800 CST|1090676)
adopted in place: podman_postgres-data (.../volumes/podman_postgres-data/_data|2026-09-14 03:19:20.891402384 +0800 CST|1048805)
the compose network podman_default belongs to this stack and is left untouched; the Quadlet units
create 'hermes' instead
```

## `--prepare-only`: the expensive half, with the stack still serving

Before the rehearsal, `hermes-agent` was given a writable layer of its own — an 8 MiB random blob
plus a symlink into `/usr/local/bin`, standing in for what the compose-era `deploy.sh` wrote there
with `podman exec`. That is what `--commit` has to preserve.

```
hermes-agent: committing the writable layer at capture time (this stack writes into its own container)
committed hermes-agent -> localhost/woow-legacy/hermes-agent:20260914-032913 (its writable layer survives the removal)
captured container hermes-agent -> .../legacy-container/hermes-agent (policy=always, image=docker.io/nousresearch/hermes-agent:latest, recreatable=1)
hermes-postgresql: writable layer is 1087123 bytes (over 1048576); committing it at capture time
committed hermes-postgresql -> localhost/woow-legacy/hermes-postgresql:20260914-032915
captured container hermes-postgresql -> ... (policy=always, image=docker.io/library/postgres:15, recreatable=1)
hermes-redis: writable layer is 11378 bytes; nothing worth committing
captured container hermes-redis -> ... (policy=always, image=docker.io/library/redis:7-alpine, recreatable=1)
```

The full commit decision matrix, exercised live, exactly as designed:

| container | `.SizeRw` | decision | `COMMIT_IMAGE` recorded |
|---|---|---|---|
| `hermes-agent` | 8 429 585 | commit — declared in `LEGACY_COMMIT_ALWAYS` | `localhost/woow-legacy/hermes-agent:20260914-032913` |
| `hermes-postgresql` | 1 087 123 | commit — measurement alone, over 1 MiB | `localhost/woow-legacy/hermes-postgresql:20260914-032915` |
| `hermes-redis` | 11 378 | no commit | *(empty)* |

The backup, taken while the gateway still answered 200 and all three containers were healthy:

```
-rw------- hermes-pg.dump                       (pg_dump -Fc)
-rw------- roles.sql                            (pg_dumpall --roles-only)
-rw------- inspect.json           63366 bytes, mode 0600 (it carries the provider keys and both passwords)
-rw-r--r-- podman_hermes-data-....tar        71 036 416
-rw-r--r-- podman_postgres-data-....tar      48 640 000
-rw-r--r-- podman_redis-data-....tar              4 096
-rw------- SHA256SUMS
           legacy-podman-compose.yml, legacy-.env (0600), legacy-deploy.sh
drwx------ legacy-container/{hermes-agent,hermes-postgresql,hermes-redis}
--- still serving during prepare ---
gateway /health 200
hermes-agent|Up 9 minutes (healthy)
```

The agent image (`localhost/woow-hermes-agent:v2026.8.31-woow1`, 3.21 GB) was built here too — in
the prepare phase, before any downtime, which is the point of putting it there.

## `--rollback` on the capture path: the committed writable layer comes back

```
stopping and removing the Quadlet units (the three volumes, podman_default and the secrets are kept)
hermes: units stopped and 8 installed file(s) removed
hermes: kept volumes (podman_redis-data podman_postgres-data podman_hermes-data), networks (hermes), secrets, images and data
recreating hermes-agent from localhost/woow-legacy/hermes-agent:20260914-032913 (the image committed at capture time: its writable layer comes back)
recreated container hermes-agent ... (restart policy always, stopped)
recreating hermes-postgresql from localhost/woow-legacy/hermes-postgresql:20260914-032915 ...
recreated container hermes-redis ... (restart policy always, stopped)
http://127.0.0.1:41864/health -> 200
rolled back: the legacy Hermes stack runs again.
rollback wall time: 61s

hermes-agent|Up 47 seconds (starting)|localhost/woow-legacy/hermes-agent:20260914-032913
hermes-postgresql|Up 49 seconds (healthy)|localhost/woow-legacy/hermes-postgresql:20260914-032915
hermes-redis|Up 48 seconds (healthy)|docker.io/library/redis:7-alpine
hermes-agent policy=always   hermes-postgresql policy=always   hermes-redis policy=always
legacy gateway /health 200

--- THE POINT OF --commit ---
before: c5b0a89d31a0fe22c2f44433a15f37ebec54aab70f3959aac746145df95d27e6  /opt/woow-rehearsal/blob
after:  c5b0a89d31a0fe22c2f44433a15f37ebec54aab70f3959aac746145df95d27e6  /opt/woow-rehearsal/blob
COMMIT-VERDICT: MATCH - the 8 MB blob written into the container before the migration is
byte-identical after the rollback
lrwxrwxrwx 1 root root 24 /usr/local/bin/woow-rehearsal-marker -> /opt/woow-rehearsal/blob
```

`hermes-redis`, which was captured **without** `--commit`, came back from the plain upstream image —
correct, because it had nothing in its writable layer worth keeping. `restart policy always` was
restored on all three: podman 4.9.3 cannot set a policy after create, so `ql_recreate_container` has
to put it back into the replayed `podman create`, and a container that came back as `no` would not
be the container that was removed.

## `podman diff` is not the measurement

The brief offered `podman diff` or the library's own measurement. On the live openclaw
`hermes-agent`, `podman diff` prints **nothing** — `{}` with exit 0 — while
`podman inspect --size` reports **42 672 686 bytes**; the container's overlay upper dir holds **844
files**, exactly `/root/.cache/uv`, `/root/.officecli`, `/usr/bin`, `/usr/local`, `/opt/hermes` and
the apt lists that `deploy.sh` created. The same disagreement reproduced on toypark, on a different
host and a different container:

```
--- podman diff vs .SizeRw on the restored container ---
diff lines: 0
SizeRw=37670
```

`app_legacy_rw_bytes` therefore uses `podman inspect --size`. Note that this repository's own
`tests/smoke.sh` check A8 ("nothing was written into the image layer") counts `podman diff` lines —
on a host where `podman diff` returns nothing for this image, that check passes vacuously. Left
as-is here and flagged rather than changed: it is a smoke-test question, not a migration one.

## Four pre-existing bugs the rehearsal found

1. **`ql_lock`'s file descriptor leaks into the containers the scripts start.** It is opened with
   `exec {fd}>lock`, which bash does not mark close-on-exec, so conmon and rootlessport inherit it
   and hold the flock for as long as the container runs; the next install, upgrade or
   **`--rollback`** dies with "another install/upgrade/uninstall is running". Two of toypark's
   twelve app locks were held that way (`emqx` and `odoo18`), so this is not specific to this repo.
   The vendored library is not edited (D8); everything here that can start a container goes through
   `app_unlocked`. **The real fix belongs in quadlet-lib.**

2. **`scripts/build-image.sh` called `ql_env_load` with no argument** and died with its usage error.
   It only fires on a host that already has `~/.config/hermes/hermes.env` — every host after the
   first install — so it went unnoticed until this rehearsal built the image from a prepared env
   file. The build aborted *before any downtime* and the legacy stack was untouched, which is what
   the ordering is for. `tests/lint-repo.sh` now has a rule for the bare call.

3. **`container/fix-model-routes.py` failed the whole provisioning unit on an ordinary config,
   twice over.** It is the last command of `woow-provision`, which runs under `set -euo pipefail`,
   so its exit code decides whether `hermes-provision.service` — and through it `install.sh` and
   this migration — succeeds. The cutover got as far as three healthy containers and a gateway
   answering 200, then failed on:

   ```
   ERROR: No model_routes section found in config
   ```

   Nothing to add is not a failure; the compose-era `deploy.sh` said so with
   `|| echo "(model routes: no model_routes section yet)"`. With that fixed the *next* cutover
   failed on the other branch:

   ```
   ERROR: model_routes exists but has no api_key: line to insert after
   ```

   because the generated `config.yaml` documents this very feature in a comment block containing
   both `model_routes:` and `# api_key:`, and the scan did not skip comments. Both are now exit 0
   with a message that says which case it is, and `tests/provisioning-test.sh` pins all four shapes
   plus idempotence.

   Finding the second bug only because the first was fixed is the argument for running the rehearsal
   to the end rather than stopping at "the containers came up".

4. **`tests/smoke.sh` A5 tested a dashboard auth surface this build does not have.** It asserted
   HTTP basic auth on `GET /` — 401 without credentials, 200 with the generated password, 401 for
   `admin/admin`. Measured against the live stack:

   ```
   /            no creds -> 302 /login?next=%2F, and that login page is 200
   /chat /config /dashboard   the same
   /api/config   no creds 401, correct password 401, admin/admin 401
   /api/sessions, /api/memory, /api/v1/status   the same 401
   ```

   The dashboard **is** gated — nothing is served to an unauthenticated caller — but through a login
   form plus 401s, not basic auth, so `curl -u admin:<generated>` proves nothing about the secret
   and all three assertions failed. A5 now checks what is real and load-bearing (the API answers 401
   without credentials, `admin/admin` opens nothing, `/` does not serve content unauthenticated) and
   *warns* that the secret is not verified end to end rather than implying that it is.

   No security posture was changed: `HERMES_DASHBOARD_INSECURE=1` and the basic-auth environment
   come from the units on `main` and were left alone. Whether that variable should stay is a
   question for a human, not for a migration branch.
