# hawkBit update server — RAUC bundle distribution (dev)

Local [Eclipse hawkBit](https://eclipse.dev/hawkbit/) server to roll out RAUC
bundles to A/B update devices, driven by `hawkbit.sh` — server lifecycle plus
a thin wrapper around the hawkBit Management REST API (register a target,
upload a bundle, assign it, confirm the rollout).

Which bundle: `fus-fw-bundle` carries the firmware, `fus-app-bundle` the
application. In `FUS_UPDATE_APP_MODE=container` these are **two separate
rollouts**, and a combined firmware+app bundle is refused at build time — the
updater activates an application image only from its own bundle, so a combined
one would install the application without ever activating it.

## Stack

Monolith + PostgreSQL, based verbatim on the upstream
`docker/postgres/docker-compose-monolith-with-ui-postgres` chain (kept in
`upstream/` for reference). One change vs upstream: a persistent **`pgdata`**
volume — upstream persists only artifacts, so targets/distribution sets would
be lost on `compose down`.

| Service | Image | Port (host) | Purpose |
|---|---|---|---|
| hawkbit | hawkbit-update-server | **8080** | Management REST **+ DDI API** (devices) |
| hawkbit-ui | hawkbit-ui | **8088** | Web UI (login `admin` / `admin`) |
| postgres | postgres:16.5 | — | metadata (volume `pgdata`) |
| rabbitmq | rabbitmq:4-mgmt | 15672 | DMF (UI `guest`/`guest`) |
| hawkbit-db-init | hawkbit-repository-jpa-init | — | one-shot schema migration |

Persistence: `pgdata` (targets, distribution sets) + `artifactrepo`
(uploaded bundles). `docker compose down` keeps both; `down -v` wipes them.

Prerequisites: `docker compose`, `curl`, `jq` — `hawkbit.sh` checks for all
three at startup and fails with an install hint if one's missing.

## Quick start

```bash
./hawkbit.sh up                     # pull + start (first run pulls ~images)
./hawkbit.sh wait                   # block until the REST API actually responds
# UI:   http://<host>:8088   (admin/admin)
# REST: http://<host>:8080/rest/v1     Swagger: http://<host>:8080/swagger-ui/index.html
```

`wait` polls the Management REST API itself rather than `docker compose`'s
own health state — the `hawkbit` service has no healthcheck of its own (only
`postgres`/`hawkbit-db-init` do), and a successful authenticated REST call is
a strictly stronger readiness signal anyway (proves migration finished, the
app is serving, and `HB_URL`/`HB_AUTH` are correct).

## Roll out a bundle

```bash
# 1) register the device as a target (idempotent — reruns reuse the
#    existing target's stored token instead of minting an unused one)
./hawkbit.sh target fsimx8mp-01

# 2) upload the bundle + assign it to the target (forced) in one step
./hawkbit.sh deploy \
  <build>/tmp/deploy/images/fsimx8mp/fus-fw-bundle-fsimx8mp.raucb \
  fsimx8mp-01

# 3) confirm the device actually installed it (pure REST, no SSH needed)
./hawkbit.sh verify fsimx8mp-01
```

`push` (upload only, prints the distribution-set id) and `assign <ds> <id>`
are also available separately.

**Firmware and application are two rollouts, in that order.** Assign the
firmware bundle first and let it finish its whole lifecycle on the device,
including the explicit `fus-update-confirm commit` — nothing auto-confirms —
then assign `fus-app-bundle-fsimx8mp.raucb` the same way. The updater takes
one update at a time: a second assignment arriving while the first is still
pending-and-unconfirmed fails with a retriable update-in-progress error, so an
early assignment does no damage, it just cannot proceed yet.

`push`/`deploy` are idempotent by `name`+`version`: a rerun with the same
bundle basename and version reuses the existing software module and
distribution set instead of creating duplicates. Pass an explicit version
for reruns you want deduplicated (`push <bundle> 1.2.3`); the default
timestamp-based version stays non-idempotent, for interactive one-offs.

## Subcommand reference

| Subcommand | Effect | Output / exit code |
|---|---|---|
| `up` | `docker compose up -d` | prints the UI/REST URLs |
| `down` | `docker compose down` (volumes kept) | — |
| `status` | `docker compose ps` | container table |
| `logs [svc] [--once]` | tail (default) or one-shot dump (`--once`) of a service's log, default `svc=hawkbit` | streamed/dumped log lines |
| `wait [timeout-s]` | poll the REST API until it responds (default 120s) | `OK hawkbit=ready (Ns)` / `FAIL hawkbit=not-ready after Ns` (exit 0/1) |
| `target <id> [token]` | register a target, or reuse it if it already exists | echoes the token (the *stored* one on reuse) on stdout |
| `push <bundle> [ver]` | upload as a software module + distribution set, idempotent by name+version | echoes the distribution-set id on stdout |
| `assign <ds-id> <id>` | force-assign a distribution set to a target | — (exit non-zero if the assignment had zero effect, e.g. an unknown target) |
| `deploy <bundle> <id> [ver]` | `push` + `assign` in one call | same as `push` + `assign`; on an `assign` failure, points at the uploaded distribution-set id and the exact retry command |
| `verify <id> [timeout-s]` | poll the target's latest rollout action to a terminal state (default 600s) | `OK action=N status=finished` / `FAIL action=N status=... [(timeout)]` (exit 0/1) |

An unrecognized subcommand, or a bare invocation with no arguments, prints
usage and exits **2** (distinct from a normal failure); `help`/`-h`/`--help`
print the same usage and exit **0**. Every subcommand's exit code is meant
to be the gate — see "CI / pipeline usage" below.

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `HB_URL` | `http://localhost:8080` | Management + DDI base URL |
| `HB_AUTH` | `admin:admin` | Management REST basic-auth credentials (`user:pass`) |
| `SM_TYPE` | `os` | software module type key |
| `DS_TYPE` | `os` | distribution set type key |

## Device side

`rauc-hawkbit-updater` (already in meta-rauc) polls hawkBit, downloads the
assigned `.raucb`, and installs it (`rauc install` over D-Bus by default; in
`FUS_UPDATE_APP_MODE=container` or any `FUS_UPDATE_INSTALL_DOOR=fsupdater`
image, the installer backend is swapped to shell out to `fs-updater
--install_update` instead — see `docs/rauc-ab/STATUS.md` in the meta-fus
layer). This end-to-end path — hawkBit assignment through to a confirmed
device install — is validated: `./hawkbit.sh verify <id>` closes the loop
by polling the same rollout-action status the device itself reports back.

Image-side config (`config.conf`, templated from `FUS_UPDATE_HAWKBIT_*` —
see `config.conf.example` for the raw device-side format):

- `hawkbit_server = <this-host-LAN-IP>:8080` (not 127.0.0.1 — that is the board)
- `tenant_id = DEFAULT`, `target_name = fsimx8mp-01`
- `auth_token = <token from ./hawkbit.sh target ...>`

Target-token DDI auth is already enabled in `compose.yaml`
(`HAWKBIT_SERVER_DDI_SECURITY_AUTHENTICATION_TARGETTOKEN_ENABLED=true`).

## Known gotchas

- **`assign` can silently do nothing.** hawkBit's `assignedTargets`
  endpoint accepts an unknown `controllerId` with HTTP 200 and
  `{"assigned":0,"alreadyAssigned":0}` rather than an error — a typo'd
  target id looks like success unless the counts are checked.
  `hawkbit.sh`'s `assign`/`deploy` already treat that specific
  zero/zero combination as a failure; keep that in mind if you extend the
  script with more assignment calls of your own.
- **jq's `//` operator treats a JSON `false` as falsy too**, not just
  `null`/absent. `jq -r '.someBool // default'` silently discards a real
  `false` value. Never use `// default` on a field that can legitimately
  be `false` — extract it plainly instead (an absent/null field then just
  prints the literal string `"null"`, which callers can check for).

## CI / pipeline usage

Every subcommand's exit code is the gate — no output parsing needed by the
CI layer (see the subcommand reference above for exact codes). `wait`/
`verify` additionally print a final `OK <label>=<value>` (stdout, exit 0) or
`FAIL <label>=<value>` (stderr, exit non-zero) verdict line.

### Gitea Actions

```yaml
# .gitea/workflows/hawkbit-rollout.yaml (illustrative)
jobs:
  rollout:
    runs-on: [self-hosted, dev-lan]      # needs docker + curl + jq
    steps:
      - uses: actions/checkout@v4
      - name: start server
        run: ./hawkbit/hawkbit.sh up && ./hawkbit/hawkbit.sh wait 180
      - name: register target (idempotent)
        run: ./hawkbit/hawkbit.sh target fsimx8mp-ci-01 "$HB_TARGET_TOKEN"
      - name: deploy bundle
        run: ./hawkbit/hawkbit.sh deploy "$BUNDLE" fsimx8mp-ci-01 "$CI_VERSION"
      - name: gate on install outcome
        run: ./hawkbit/hawkbit.sh verify fsimx8mp-ci-01 600
      # optional teardown for ephemeral runners:
      # - if: always()
      #   run: ./hawkbit/hawkbit.sh down
```

### Jenkins (declarative pipeline)

```groovy
// Jenkinsfile (illustrative)
pipeline {
    agent { label 'dev-lan' }          // needs docker + curl + jq
    environment {
        HB_TARGET_TOKEN = credentials('hawkbit-target-token')
        CI_VERSION       = "${env.GIT_COMMIT}"
    }
    stages {
        stage('start server') {
            steps {
                sh './hawkbit/hawkbit.sh up'
                sh './hawkbit/hawkbit.sh wait 180'
            }
        }
        stage('register target') {
            steps { sh './hawkbit/hawkbit.sh target fsimx8mp-ci-01 "$HB_TARGET_TOKEN"' }
        }
        stage('deploy bundle') {
            steps { sh './hawkbit/hawkbit.sh deploy "$BUNDLE" fsimx8mp-ci-01 "$CI_VERSION"' }
        }
        stage('gate on install outcome') {
            steps { sh './hawkbit/hawkbit.sh verify fsimx8mp-ci-01 600' }
        }
    }
    post {
        // optional teardown for ephemeral agents:
        // always { sh './hawkbit/hawkbit.sh down' }
        failure { echo 'rollout failed or was not confirmed within the verify timeout' }
    }
}
```

Both examples follow the same shape: `up` → `wait` → `target` (idempotent)
→ `deploy` → `verify`, with `$CI_VERSION` explicit (git SHA, build number,
...) so `deploy` reruns dedupe correctly, and the target's security token
pinned via a CI secret/credential so the device-side `config.conf` never
drifts. Self-test: `./hawkbit.test.sh` (stubs `curl`/`docker`, no server
needed, mirrors `docker-bb.test.sh`'s pattern) — run it after any change to
`hawkbit.sh` before wiring it into a real pipeline.

## Notes

- **Signing material.** The device verifies every bundle against
  `/etc/rauc/ca.cert.pem` — the keyring the image ships — so a bundle rolled
  out from here must be signed by that same CA. The layer generates the dev
  material with `meta-fus-sdk/scripts/fus-update-gen-certs.sh`, a build-host
  helper that runs outside bitbake; the recipes only read what it leaves
  behind.

  ```bash
  # through the build-container wrapper (uses the configured CERT_DIR):
  ./docker-bb.sh certs                 # variant "dev"
  ./docker-bb.sh certs dev --force     # rotate existing material

  # or directly:
  FUS_UPDATE_CERT_DIR=<dir> sh meta-fus-sdk/scripts/fus-update-gen-certs.sh \
      [--variant dev] [--dir <dir>] [--force]
  ```

  It writes `<dir>/<variant>/`: `ca.cert.pem` (goes into the device keyring),
  `ca.key.pem` (stays on the build host, never shipped), plus `sign.cert.pem`
  and `sign.key.pem` (used to sign the bundles). Re-running without `--force`
  changes nothing, so it is safe in a pipeline. The script **refuses
  `--variant prod`**: production keys are provisioned out of band, not
  generated here — with `FUS_UPDATE_CERT_VARIANT = "prod"` the recipes expect
  the material to be in place already.
- Credentials here are upstream demo defaults (`admin/admin`, postgres
  `admin`) — fine for a dev LAN, change for anything exposed.
