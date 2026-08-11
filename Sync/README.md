# Multi-device snapshot sync

Protocol v1 transports privacy-redacted `ActivitySnapshot` values independently of the snapshot's own positive `schemaVersion`. Linux service, client, packaging, systemd, protocol, and deployment documentation live in [`Linux/`](Linux/README.md).

The sync client invokes the repository's Rust `tokenbar-helper` with an explicit statistics timezone. Sync defaults to UTC so its calendar windows, `today`, weekly-reset scan boundary, per-message dates, and emitted `snapshot.timezone` match the macOS sync merger. `local` remains an explicit opt-in for deployments where every merging client uses the same local-statistics convention.
