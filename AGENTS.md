# AGENTS.md - bluesound_vault2i

> Preliminary. Records the confirmed constraints, the target architecture,
> and the decisions still open. No implementation exists yet.

## Purpose / target architecture

Make the **TrueNAS the authoritative home** for CDs ripped on a
**Bluesound Vault 2i**. The Vault's internal drive must be only a **transient
rip buffer**: a CD is ripped locally (unavoidable), then an automated job
**moves** the finished rip to the TrueNAS and **removes the local copy** once
the transfer is verified. The Vault is then reconfigured to play from the
TrueNAS (NAS mounted as a network library), so the TrueNAS becomes the source
of truth.

Goal restated: rips should END UP on the TrueNAS, not live on the Vault. Local
storage is acceptable only momentarily, during and just after ripping.

## Hard constraint (researched, high confidence)

BlueOS / the Vault 2i **cannot rip to a network share**. There is no setting to
redirect the rip destination; ripping ALWAYS targets the internal drive
(`rips/` = transient WAV working dir -> `Music/` = FLAC library; a separate
`MP3/` folder only if both output formats are enabled). BlueOS can *read*
network shares (mount a NAS as a playback source) but cannot *write* rips to
one. Rip-time redirection is therefore impossible; the only viable mechanism is
a post-rip move from the Vault's SMB share to the TrueNAS.

## Data flow

```
1. RIP (native, unavoidable):
   CD -> Vault internal drive   //192.168.0.20/shared/Music   (FLAC)

2. MOVE (automated job - this project):
   //192.168.0.20/shared/Music  --copy + verify + delete-source-->  //192.168.0.200/shared/...
   (read source, delete local only AFTER verified transfer; never delete on destination)

3. PLAYBACK (reconfiguration):
   Vault mounts //192.168.0.200/shared as a network library and plays from it.
```

Transfer scope: `Music/` (FLAC) only for now. The transient `rips/` working dir
is NEVER touched (a rip may be in progress). Junk metadata excluded.

## Resources

### Bluesound Vault 2i - rip buffer (source)
- Host: `192.168.0.20` (BlueOS; device model "Bluesound V510"). SMB1 disabled.
- SMB share: `shared` (comment "BlueOS Share"), **guest / anonymous** (no creds).
- Layout: `rips/` (transient WAV - DO NOT TOUCH), `Music/` (FLAC library - the
  transfer source), optional `MP3/` (only if dual-format ripping is enabled).
- Capacity: ~1.93 TB volume, ~1.83 TB free (recon 2026-07-14).
- Access for this project: READ finished `Music/` entries; DELETE them locally
  only AFTER a verified transfer. Never modify `rips/`; never write new content
  to the Vault.

### TrueNAS - authoritative library (destination)
- Host: `192.168.0.200` (web UI `http://192.168.0.200/`). SMB1 disabled.
- Version: TrueNAS 25.10.4 (Community Edition, Linux-based; native Docker app
  stack). CORE/FreeBSD is EOL and not in play. Hardware: Intel i3-6100T,
  ~31 GiB RAM.
- SMB share: `shared` (comment "pula wspoldzielona").
- SMB auth: username `smb` + password from `pass` (see Credentials). The web-UI
  admin `truenas_admin` is a different user that shares the same password.
- Capacity: ~16.88 TB, essentially empty (recon 2026-07-14).
- Existing top-level: `youtube/`, `Music/`, `test.txt` (15 B scratch file).
- Access: **READ-WRITE** (destination). Never delete on the destination
  (additive) unless a mirror policy is explicitly approved later.

## Credentials

Never hardcode secrets. All TrueNAS credentials come from `pass`.

- Entry `Internet/truenas-bronek/dane` (multiline):
  - line 1: web URL (`http://192.168.0.200/`)
  - line 2: `Login: truenas_admin`  (web UI only)
  - line 3: `Passwd: <secret>`       (shared by web UI and SMB user `smb`)
- SMB username: `smb`.
- SMB password extraction (exact):
  ```
  pass Internet/truenas-bronek/dane | grep Passwd | awk -F ': ' '{print $NF}'
  ```
- The Bluesound Vault requires no credentials (guest).

Do not log, print, or commit the password. Do not embed it in scripts or in any
credentials file tracked by git.

## Safety rules

- The move is COPY -> VERIFY -> DELETE-source. NEVER delete a local rip before
  the destination copy is verified (size + checksum).
- Never touch the Vault's `rips/` working dir (a rip may be in progress). Only
  operate on completed `Music/` entries.
- A rip must be detected as COMPLETE and stable before it is moved (BlueOS emits
  no "rip finished" event - completion detection is an open design point below).
- Never delete anything on the TrueNAS (additive destination) unless a mirror
  policy is explicitly chosen and approved.
- Exclude junk metadata: `.DS_Store`, `._*`, `.prmscan`, `.Trashes`,
  `.Spotlight-*`.

## Environment / tooling

- Dev host has `smbclient`, `mount.cifs`, `nmblookup`. Both hosts on the LAN
  (Vault ~10 ms, TrueNAS ~2 ms). Use SMB2/SMB3 (`vers=3.0` / `vers=2.1`).
- IMPORTANT: the current working machine is a DEVELOPMENT box, NOT the runtime
  host for the job. The runtime host is the TrueNAS (see Hosting decision).

## Hosting decision

The transfer job runs ON the TrueNAS (confirmed 25.10.4, Linux-based, native
Docker) as a **Custom App (Docker Compose)**, with a **Host Path bind mount to a
dataset in the pool** for scripts, state, and logs. Rationale: the app config
lives in the TrueNAS config DB and survives OS upgrades, while anything on the
boot-pool/OS filesystem is wiped on upgrade - persistent files MUST live on a
pool dataset. Running on the Vault is ruled out (locked BlueOS appliance); the
current dev box is development only.

SMB access from the container: either the native SMB/CIFS volume type or a
custom image bundling rclone/smbclient (base images usually lack smbclient).

## Open questions / decisions pending

- Trigger model: scheduled poll (cron / systemd timer) vs an event/trigger.
  BlueOS provides no "rip finished" event, so completion must be inferred.
- Rip-completion detection: how to know a CD's rip is finished and stable before
  moving (e.g. file mtime stable for N minutes, no active rip in progress).
- Transfer-status indicator: a mechanism to know when all rips are finished AND
  safely transferred + verified to the TrueNAS, so the operator knows it is safe
  to power the equipment off. This is an explicit project requirement.
- Playback reconfiguration: add the TrueNAS SMB share as a BlueOS network
  library source and stop relying on the Vault's local library.
- Transfer tool: rclone (SMB backend) vs rsync over mounted cifs vs `smbclient`
  scripting.
- Destination layout on the TrueNAS (into `shared/Music`, a dedicated
  `shared/bluesound/` folder, etc.).

## Repo status

Fresh, empty repository (branch `main`, no commits). No implementation yet.

## Conventions

Repo content in English. Commits only on explicit approval (see global
AGENTS.md).
