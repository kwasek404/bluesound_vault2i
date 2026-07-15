# bluesound_vault2i

Automated mover that makes a TrueNAS the authoritative home for CDs ripped on
a Bluesound Vault 2i, keeping the Vault's internal drive as a transient rip
buffer only.

## Why

BlueOS on the Vault 2i cannot rip directly to a network share: ripping always
targets the Vault's internal drive (`rips/` as a transient working directory,
then `Music/` as the finished FLAC library). There is no setting to redirect
rip output to a NAS. Since rip-time redirection is impossible, the only
viable mechanism is a post-rip move: copy finished rips off the Vault onto
the TrueNAS, verify the copy, then delete the local copy - turning the
TrueNAS into the source of truth while the Vault stays a disposable buffer.

## Architecture / data flow

```
1. RIP (native, unavoidable):
   CD -> Vault internal drive   //192.168.0.20/shared/Music   (FLAC)

2. MOVE (this project, automated):
   //192.168.0.20/shared/Music
     --copy + verify + delete-source-->
   //192.168.0.200/shared/Music

3. PLAYBACK (manual reconfiguration):
   Vault mounts //192.168.0.200/shared as a network library and plays from it.
```

- Source: Bluesound Vault 2i, `192.168.0.20`, SMB share `shared`, guest /
  anonymous access, `Music/` folder (FLAC). Read + delete-after-verified-move
  only. The transient `rips/` working directory is never touched.
- Destination: TrueNAS, `192.168.0.200`, SMB share `shared`, SMB user `smb`,
  `Music/` folder. Read-write, additive only (nothing is ever deleted on the
  destination).

The job runs ON the TrueNAS (25.10.4, Linux-based, native Docker) as a
Custom App (Docker Compose), with Host Path bind mounts to a pool dataset for
`/state` and `/log` so they survive OS upgrades. Both ends are single
spinning HDDs, so transfers are single-stream/sequential to avoid head
thrashing.

## How the mover works

One pass runs every `POLL_INTERVAL` seconds, single-instance enforced via
`flock`:

1. **Rip-completion gate**: `GET http://<vault>:2000/ripencstat?noheader=1`.
   The Vault is considered idle only if the body contains both
   `No CD inserted.` and `No tracks to encode.`. Any other content, or a
   fetch failure, is treated as busy and the pass waits. `IDLE_CONFIRMATIONS`
   consecutive idle polls are required before acting (fail-safe).
2. **Stage 1 - copy**: `rclone copy` (no deletion).
3. **Stage 2 - verify**: `rclone check --download --one-way`, a
   byte-for-byte verification. This is required because the SMB backend
   exposes no hashes, so size/modtime alone is not sufficient. Produces
   matched/differ/missing/errors lists.
4. **Gate**: proceed only if differ/missing/errors are all empty.
5. **Stage 3 - delete source**: `rclone delete --files-from matched.txt` on
   the Vault (deletes only byte-verified files), followed by `rmdir` of any
   emptied album directories.
6. **Reindex**: once per drain (when the Vault is idle, its `Music/` folder
   is empty, and something was deleted this batch), `POST
   http://<vault>:11000/Reindex` with body `reindex=1` to refresh the BlueOS
   library.

## Safety & self-heal

- No source file is ever deleted without a byte-verified match.
- `rclone check` differences are not fatal - they are simply retried on the
  next pass.
- The destination is additive; nothing is deleted there.
- Every stage is idempotent/convergent. After a power loss or crash, the
  next pass resumes from actual state; a half-copied file never appears in
  `matched.txt`, so it is never deleted from the source.

## Status UI

A stdlib Python HTTP server on port `WEB_PORT` (default `8080`), UI in
Polish. Shows a large verdict banner:

- **"BEZPIECZNY DO WYLACZENIA"** (green) - safe to power off: Vault idle,
  nothing pending, no errors, no pending reindex.
- **"NIE WYLACZAJ - trwa praca"** (red) - work in progress.

It also shows current device status, pending counts, last-run stats, and a
live reverse-tailed log (newest first).

Endpoints: `/api/status`, `/api/log`.

## Configuration

Environment variables, with defaults:

| Variable | Default | Notes |
|---|---|---|
| `TRUENAS_SMB_PASSWORD` | (required) | Secret; set in the TrueNAS app config, never commit |
| `VAULT_HOST` | `192.168.0.20` | |
| `VAULT_STATUS_PORT` | `2000` | Rip-status endpoint |
| `VAULT_API_PORT` | `11000` | Reindex endpoint |
| `TRUENAS_HOST` | `192.168.0.200` | |
| `TRUENAS_SMB_USER` | `smb` | |
| `SMB_SHARE` | `shared` | Same share name on both ends |
| `SRC_SUBPATH` | `Music` | Path under the Vault share |
| `DST_SUBPATH` | `Music` | Path under the TrueNAS share |
| `POLL_INTERVAL` | `60` | Seconds between passes |
| `IDLE_CONFIRMATIONS` | `2` | Consecutive idle polls required before acting |
| `WEB_PORT` | `8080` | Status UI port |
| `LOG_TAIL_LINES` | `200` | Lines shown in the status UI log tail |
| `STATE_DIR` | `/state` | Persistent state (bind-mounted) |
| `LOG_DIR` | `/log` | Logs (bind-mounted) |
| `RCLONE_CONFIG` | `/state/rclone.conf` | Generated at container startup |

## Deployment on TrueNAS

1. Create a dataset for state/logs.
2. Use `docker-compose.yml`, replacing the `/mnt/YOURPOOL/...` host paths
   with the real dataset paths.
3. Set `TRUENAS_SMB_PASSWORD` in the app environment.
4. Deploy as a TrueNAS Custom App (Docker Compose).
5. Open the status UI on port `8080`.

## Vault playback reconfiguration

One-time, manual: in the BluOS Controller app, go to Settings -> Music
Library -> Network Shares and add `//192.168.0.200/shared` as a network
share. The Vault then plays from the TrueNAS, which becomes the source of
truth instead of its local library.

## Building / image

The container is Debian-slim based and bundles `rclone` (installed from the
official Debian package, pinned to v1.74.4 and verified against the
upstream SHA256SUMS), `jq`, `flock` (util-linux), `curl`, and `python3`. The
entrypoint generates `/state/rclone.conf` at startup from the
environment, obscuring the SMB password via `rclone obscure` - the plaintext
password lives only in the app environment, the obscured form only on the
dataset, never in git. It then starts the status web server and runs the
mover loop.

Published to `ghcr.io/kwasek404/bluesound_vault2i` via GitHub Actions
(`.github/workflows/build.yml`), `linux/amd64`.

## Repo layout

```
bin/lib.sh                       shared shell helpers
bin/mover.sh                     the mover (rip-gate, copy, verify, delete, reindex)
web/server.py                    status UI HTTP server
web/index.html                   status UI page
web/static/app.js                status UI client logic
web/static/style.css             status UI styling
Dockerfile                       container image
entrypoint.sh                    generates rclone.conf, starts web server + mover loop
docker-compose.yml               TrueNAS Custom App compose file
.github/workflows/build.yml      CI image build/publish
AGENTS.md                        project constraints and design notes
```
