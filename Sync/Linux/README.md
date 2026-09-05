# TokenBar Sync protocol v1 MVP

Python 3 service and headless Linux collector/uploader for latest-per-device TokenBar activity snapshots. The service itself has no third-party Python dependency. The collector invokes this repository's Rust `tokenbar-helper`, sanitizes its JSON in memory, and only then constructs a network envelope. The service defaults to loopback, authenticates all `/v1/*` routes with bearer tokens, stores durable SQLite state, and never logs tokens or payloads.

## Fixed protocol

- `GET /healthz` is unauthenticated.
- `PUT /v1/snapshots/{deviceId}` requires `Authorization: Bearer …` and `Content-Type: application/json`.
- `GET /v1/snapshots` requires the same authorization and returns one latest snapshot per device, ordered by device id.
- Request bodies are limited to 16 MiB.
- `protocolVersion` must be `1`; ids must use canonical lowercase UUID form and the path/body ids must match; OS must be `macos`, `windows`, or `linux`; `generatedAtMs` must be a positive integer. The snapshot must have a positive `schemaVersion`, the same `generatedAtMs`, a non-empty timezone, and the core ActivitySnapshot objects/arrays.
- Newer snapshots replace older ones. An exact retry at the same timestamp returns success and retains the original `receivedAtMs`. Older writes, and different content at the same timestamp, return HTTP 409.

Example download response:

```json
{
  "protocolVersion": 1,
  "snapshots": [
    {
      "device": {"id": "11111111-1111-4111-8111-111111111111", "name": "Linux", "os": "linux"},
      "generatedAtMs": 123,
      "receivedAtMs": 456,
      "snapshot": {
        "schemaVersion": 9,
        "generatedAtMs": 123,
        "timezone": "UTC",
        "today": {
          "tokens": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "reasoning": 0},
          "costUsd": 0,
          "requestCount": 0,
          "sessionCount": 0
        },
        "sessions": [],
        "days": []
      }
    }
  ]
}
```

## Privacy boundary

The client sanitizes immediately before envelope creation and again before upload. At every nesting level it sets `promptPreview`, `outputPreview`, `sessionPath`, session `title`, `workspacePath`, and `workspaceLabel` to `null`. It also nulls raw prompt/session-content fields and absolute POSIX, Windows, UNC, or `file://` paths, and removes credential-bearing properties.

The server rejects a snapshot that still contains any other protected value, or whose required totals/session/day/source fields cannot be decoded by the Mac client. For rolling protocol-v1 upgrades it clears a legacy `workspaceLabel` before validation and storage. It never reads raw Codex session files and never logs authorization headers or request/response payloads. Headless clients keep the upload envelope only in memory and never persist a payload retry spool.

## Local run

Run the service from the authoritative repository clone:

```bash
cd TokenBar/Sync/Linux
read -r -s -p 'Shared token: ' TOKENBAR_SYNC_TOKEN
export TOKENBAR_SYNC_TOKEN
./bin/tokenbar-sync-server
```

The default server configuration is:

```text
TOKENBAR_SYNC_BIND=127.0.0.1:18765
TOKENBAR_SYNC_DATABASE=./tokenbar-sync.sqlite3
TOKENBAR_SYNC_TOKEN=(plaintext local-testing option)
TOKENBAR_SYNC_TOKEN_SHA256=(comma-separated production device-token hashes)
```

Build the repository helper once on a Linux build host with Rust installed:

```sh
cd TokenBar
cargo build --locked --release --manifest-path Helper/Cargo.toml
export TOKENBAR_HELPER=$PWD/Helper/target/release/tokenbar-helper
```

In another shell, export the same token and helper path, then run:

```sh
./bin/tokenbar-sync-client collect
./bin/tokenbar-sync-client upload
./bin/tokenbar-sync-client download
```

ActivitySnapshot versioning is independent of envelope `protocolVersion`. The collector requires a structurally decodable ActivitySnapshot with a positive integer `schemaVersion` and preserves it exactly; it does not hardcode v8, v9, or v10. This allows, for example, a Windows helper producing v8 and the current Mac helper producing v9 to share protocol-v1 transport.

By default the client runs `tokenbar-helper --days 30 --statistics-timezone utc`. The explicit helper option changes the actual statistics calculation: message dates are normalized in the selected zone, the visible day window and `today` use that zone, weekly-reset timestamps are converted to scan dates in that zone, and `snapshot.timezone` is emitted consistently. Linux and Windows sync should use UTC. `--statistics-timezone local` (or `TOKENBAR_STATISTICS_TIMEZONE=local`) is available only for a deployment where all merging clients intentionally use local statistics.

Immediately before every fresh collection, the client performs an authenticated `GET /v1/snapshots` with a 64 MiB response cap. For each of `codex`, `claude`, and `grok`, it walks valid snapshots from newest to oldest `receivedAtMs` and takes the first reset no more than eight days old and no later than its source snapshot's `generatedAtMs`. A top-level `weeklySinceReset.startedAtMs` is accepted only as a legacy Codex fallback. The selected values are passed to the helper as `--weekly-reset-ms`, `--claude-weekly-reset-ms`, and `--grok-weekly-reset-ms`. A failed download, malformed response, absent platform, or invalid/stale/future timestamp quietly yields no flag for that platform, so Today and the normal 30-day snapshot still collect and upload. Download payloads are never logged.

For testing or an external helper runner, `TOKENBAR_ACTIVITY_SNAPSHOT` or `--snapshot-file` can point to an already-produced ActivitySnapshot. A UTC upload rejects a file whose `snapshot.timezone` is not exactly `UTC`; choose `local` explicitly for a local-zone file. The unrelated `tokscale` TUI cache is not an ActivitySnapshot source and is not accepted. A stable UUID is generated once at `~/.config/tokenbar-sync/device-id`. Failed uploads do not persist snapshot payloads; the next invocation collects a fresh snapshot.

Non-loopback endpoints must use HTTPS, and the client bypasses ambient forward proxies and refuses HTTP redirects so the bearer token cannot be forwarded to a different URL. The sync token is removed from the environment inherited by `tokenbar-helper`. Every timer run collects a fresh in-memory envelope. A network/authentication failure or HTTP 409 exits without retaining payload state; the next run collects again.

Client configuration variables are `TOKENBAR_SYNC_URL`, `TOKENBAR_SYNC_TOKEN`, `TOKENBAR_ACTIVITY_SNAPSHOT`, `TOKENBAR_HELPER`, `TOKENBAR_HELPER_DAYS`, `TOKENBAR_STATISTICS_TIMEZONE`, `TOKENBAR_SYNC_DEVICE_ID`, `TOKENBAR_SYNC_DEVICE_ID_FILE`, `TOKENBAR_SYNC_DEVICE_NAME`, and `TOKENBAR_SYNC_CLIENT_VERSION`.

## Tests

```sh
cd TokenBar/Sync/Linux
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
```

The Python suite exercises authentication, Mac-decodable structure validation, recursive sanitization, helper argument/timezone behavior, schema-version preservation, request limits, fresh collection after 409, reset freshness, create/update/exact-retry/older-conflict behavior, durable and in-memory repositories, future-clock rejection, and stable device ordering. The helper's Rust tests cover CLI timezone parsing and UTC date normalization.

## systemd installation

The repository contains a hardened server unit and a per-user upload timer. Build `tokenbar-helper` first, or point `TOKENBAR_HELPER_BINARY` at a packaged Linux helper. Both installers deploy files from this repository and reload unit metadata, but intentionally do not enable or start anything:

```sh
sudo ./scripts/install-server.sh
./scripts/install-user-client.sh
```

After installation, generate an independent random 32–512 character ASCII token on each client and keep its plaintext only in that client's protected store. Put the comma-separated SHA-256 hashes in `TOKENBAR_SYNC_TOKEN_SHA256` inside `/etc/tokenbar-sync/server.env`; the Linux client's own plaintext goes only in the XDG config file `${XDG_CONFIG_HOME:-~/.config}/tokenbar-sync/client.env`. `TOKENBAR_SYNC_TOKEN` remains available as a single-token local-testing option. The server refuses malformed or placeholder credentials and non-loopback binds unless `TOKENBAR_SYNC_ALLOW_PUBLIC_BIND=1` is explicitly set. Test manually, and only then enable the units using the commands printed by the installers. Avoid placing a literal token on a command line or in a Codex message.

## Deployment recommendation

Keep `TOKENBAR_SYNC_BIND=127.0.0.1:18765`; do not expose the Python listener directly. When public multi-device access is authorized, add a narrowly scoped route to the host's existing Caddy production configuration, terminate HTTPS there, preserve the Authorization header, cap request bodies to 16 MiB, and rate-limit the route. Prefer private VPN access or mTLS in addition to the bearer token. Back up the SQLite database with a SQLite-aware snapshot/backup procedure.

No Caddy, firewall, DNS, or persistent service change is part of this artifact.

## Linux deployment artifact from the Mac repository

The source of truth is already this TokenBar repository under `Sync/Linux`. On a Linux-capable Rust build host, create a self-contained service/client/helper archive and checksum:

```sh
cd /path/to/TokenBar
./Sync/Linux/scripts/package-linux.sh
scp .build/TokenBar-sync-linux.tar.gz .build/TokenBar-sync-linux.tar.gz.sha256 SERVER:incoming/
```

Verify with `sha256sum -c` on the server before unpacking. Do not package or transfer any local database, env file, generated device id, pending upload, token, Codex data, raw session, or cache snapshot.
