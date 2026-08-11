# TokenBar Sync client

`Sync` contains the headless ActivitySnapshot collector and protocol-v1 client used on Windows and Linux. It reuses the repository's Rust `Helper` crate, keeps the helper-produced positive `schemaVersion` unchanged, and versions the network envelope independently with `protocolVersion: 1`.

The client never uploads raw JSONL rows, credentials, prompt/output previews, session titles, or absolute session/workspace paths. It recursively sets `promptPreview`, `outputPreview`, `sessionPath`, `title`, and `workspacePath` to JSON `null` before serialization. `workspaceLabel` may remain.

## Build

Windows requires Rust's MSVC target plus the Visual C++ build tools:

```powershell
.\Sync\scripts\Build-TokenBarSync.ps1
```

The script runs locked release builds for both `tokenbar-helper` and `tokenbar-sync`, places both executables together under `Sync/target/release`, and prints their paths, sizes, and SHA-256 digests. Build output remains ignored by Git.

On another supported Rust host:

```sh
cargo build --manifest-path Helper/Cargo.toml --release --locked
cargo build --manifest-path Sync/Cargo.toml --release --locked
```

Place the resulting `tokenbar-helper` executable beside `tokenbar-sync`, or pass its absolute path with `--helper-path`. The two crates intentionally build into separate `target/release` directories unless a shared Cargo target directory is configured.

## Configuration

The Bearer token is accepted only through `TOKENBAR_SYNC_TOKEN`; it is never accepted as a command-line or JSON-config value, and the client removes it from the environment inherited by `tokenbar-helper`. A generic config file looks like this:

```json
{
  "endpoint": "https://sync.example.com",
  "deviceName": "Workstation",
  "days": 30,
  "codexHome": "<absolute Codex data root ending in .codex>",
  "helperPath": "<absolute tokenbar-helper executable path>",
  "statisticsTimezone": "utc",
  "stateDir": "<absolute TokenBar Sync state directory>"
}
```

`statisticsTimezone` supports `utc` and `local`. Sync clients default to `utc`, matching TokenBar's macOS default statistics calendar. Choosing `local` changes record-day derivation, the visible date window, weekly-reset day conversion, `today`, and `snapshot.timezone`; it is not a display-only label.

The stable UUID lives in `device.json` inside the state directory. Do not copy one device's state directory onto another device unless both installations are intentionally meant to represent the same device.

## One-shot commands

```powershell
$env:TOKENBAR_SYNC_TOKEN = '<shared token>'
.\Sync\target\release\tokenbar-sync.exe --config .\sync-config.json collect
.\Sync\target\release\tokenbar-sync.exe --config .\sync-config.json upload
.\Sync\target\release\tokenbar-sync.exe --config .\sync-config.json download
.\Sync\target\release\tokenbar-sync.exe --config .\sync-config.json status
```

Before collection, `collect` and `upload` attempt an authenticated `GET` when endpoint/auth configuration is available. They use the newest valid per-platform weekly reset metadata and pass it to `tokenbar-helper`; a failed preflight or missing reset metadata degrades to normal Today/30-day collection. `collect` then writes a sanitized envelope, `upload` sends one `PUT`, and `download` sends one authenticated `GET` and sanitizes every returned snapshot again before saving it. Non-loopback endpoints must be HTTPS origins without embedded credentials, paths, query strings, or fragments; plain HTTP is accepted only for loopback hosts. HTTP redirects are never followed, so a Bearer token cannot cross origins through redirection.

`upload` has no persistent pending-payload spool: it collects a fresh snapshot for each invocation and keeps the envelope only in memory. HTTP 409 discards that rejected in-memory envelope, records non-payload status metadata, and the next scheduled invocation collects again instead of retrying a permanently blocked payload.

## Periodic Windows installation

The Windows installer uses a per-user Scheduled Task. This is appropriate for non-admin installations and prevents overlapping runs. It does not create a Windows service and does not place the token in the task action or config file.

First set the shared token in the user environment using your organization's secret-handling procedure. The following value is only a placeholder:

```powershell
[Environment]::SetEnvironmentVariable('TOKENBAR_SYNC_TOKEN', '<shared token>', 'User')
```

Then build and install:

```powershell
.\Sync\scripts\Build-TokenBarSync.ps1
.\Sync\scripts\Install-TokenBarSync.ps1 -Endpoint 'https://sync.example.com' -IntervalMinutes 15
```

Inspect non-secret status:

```powershell
.\Sync\scripts\Get-TokenBarSyncStatus.ps1
```

Remove the scheduled task, binary, config, and local device/status state:

```powershell
.\Sync\scripts\Uninstall-TokenBarSync.ps1
```

Uninstall deliberately preserves the `TOKENBAR_SYNC_TOKEN` environment variable because it may be shared with another approved client. The uninstall script refuses to recursively remove an unmarked or broad directory.

## Protocol and safety

See [docs/protocol-v1.md](docs/protocol-v1.md) for the exact wire contract. Upload serialization is rejected above 16 MiB. The client never logs the token, request body, response body, or raw session rows. Stored `last-run.json` contains only timestamp, success state, HTTP status/category, and schema version.

Run verification with:

```sh
cargo fmt --manifest-path Helper/Cargo.toml -- --check
cargo test --manifest-path Helper/Cargo.toml --locked
cargo fmt --manifest-path Sync/Cargo.toml -- --check
cargo test --manifest-path Sync/Cargo.toml --locked
```
