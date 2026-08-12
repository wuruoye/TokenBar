# Multi-device snapshot sync

Protocol v2 transports privacy-redacted `ActivitySnapshot` values as revisioned replacement partitions, with protocol v1 retained for rolling compatibility. Snapshot `schemaVersion` remains independent from either network protocol version.

- The Rust crate in this directory is the headless Windows collector and client. Build and install it with the scripts in [`scripts/`](scripts/).
- The Python service, Linux client, packaging, systemd units, and deployment guide live in [`Linux/`](Linux/README.md).
- The macOS app configures the shared endpoint/token, uploads its local snapshot, downloads the latest snapshot for every device, and merges compatible calendars into the existing TokenBar dashboard.
- The current incremental contract is documented in [`docs/protocol-v2.md`](docs/protocol-v2.md); [`docs/protocol-v1.md`](docs/protocol-v1.md) documents the full-snapshot fallback.

Normal syncs replace only changed summary/day/source-day/session/memory-day partitions and send tombstones for removals. A full snapshot is forced after 24 hours plus up to one hour of deterministic device jitter, whenever revision/schema/timezone/window metadata is unusable, or whenever a delta would be at least 70% of the full request. The Linux server keeps only the latest materialized full snapshot and revision per device; it does not retain a delta history.

The sync client invokes the repository's Rust `tokenbar-helper` with an explicit statistics timezone. Sync defaults to UTC so its calendar windows, `today`, weekly-reset scan boundary, per-message dates, and emitted `snapshot.timezone` match the macOS sync merger. `local` remains an explicit opt-in for deployments where every merging client uses the same local-statistics convention.

Bearer-authenticated clients require HTTPS for every non-loopback server URL, bypass ambient forward proxies, and do not follow redirects. Current clients exclude prompt/output previews, session titles, workspace labels, absolute paths, provider credentials, raw session files, local databases, and payload retry state from synchronized snapshots and repository artifacts. Incremental upload state contains only revisions, calibration metadata, and partition hashes. The Mac also keeps a separate local integrity digest for its sanitized remote cache; server manifests remain opaque server-issued revision metadata. The server removes a legacy protocol-v1 `workspaceLabel` before validation and storage during rolling upgrades.

## Windows

Windows requires Rust's MSVC target and the Visual C++ build tools:

```powershell
.\Sync\scripts\Build-TokenBarSync.ps1
```

The installer accepts this Windows installation's bearer token only from the current PowerShell process, protects it with DPAPI CurrentUser, and never writes it to `config.json` or the Scheduled Task command line. Each upload decrypts it only for the child process lifetime and clears that environment entry afterward. A one-shot upload collects a fresh, sanitized snapshot in memory. A v2 base-revision conflict immediately retries that same fresh collection as a full snapshot; other HTTP 409 responses discard it so the next invocation can collect a newer timestamp.

Build first, set a 32–512 character random token only in the current PowerShell process, and install the fixed per-user Scheduled Task:

```powershell
$env:TOKENBAR_SYNC_TOKEN = Read-Host 'Device access token'
.\Sync\scripts\Install-TokenBarSync.ps1 -Endpoint 'https://sync.example.com'
Remove-Item Env:TOKENBAR_SYNC_TOKEN
.\Sync\scripts\Get-TokenBarSyncStatus.ps1
```

The installer owns only `%LOCALAPPDATA%\TokenBarSync` and the `TokenBarSync` task, verifies both before upgrades/removal, and never recursively deletes an arbitrary directory. It writes the two binaries, license files, non-secret configuration, a DPAPI-protected token, stable device UUID, and non-payload last-run status there.

## macOS

Open TokenBar Settings, enable **Multi-device sync**, then enter the HTTPS server origin, this Mac's access token, and a device name. The token is stored in the macOS Keychain; the URL, stable UUID, enabled state, and display name use TokenBar preferences. Mac uploads local changes, queries only changed remote partitions, caches only privacy-sanitized remote snapshots in a mode-0600 Application Support file, then recomputes the aggregate from current per-device snapshots. Changing or disabling sync cancels the in-flight activity refresh and refreshes the dashboard from local data. Remote sessions are labeled with their device and remain read-only because prompt/output text and source paths are never uploaded.

## Verification

```sh
cargo test --manifest-path Helper/Cargo.toml --locked
cargo test --manifest-path Sync/Cargo.toml --locked
cd Sync/Linux && PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
```
