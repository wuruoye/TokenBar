# TokenBar activity sync protocol v2

Protocol v2 adds revisioned replacement partitions while retaining protocol v1 for rolling upgrades. It never sends arithmetic counter deltas. A changed day, source day, session, or memory day replaces the previous partition; a removed item is sent as a tombstone. This allows local history corrections and deletions to converge without cumulative rounding or counting drift.

## Partitions

Every privacy-sanitized `ActivitySnapshot` is deterministically split into:

- `summary`: top-level totals and metadata, source summaries without their `days`, and the memory summary without its `days`;
- `day`: one partition per top-level date;
- `source-day`: one partition per platform and date;
- `session`: one partition per platform and stable session ID;
- `memory-day`: one partition per memory-usage date.

Partition identity is `kind:sha256(kind + NUL + identity...)`. A manifest maps each identity to the SHA-256 of its canonical JSON value. Manifests contain identifiers and hashes only; they contain no prompt, output, path, or snapshot body.

## Upload

```text
PUT /v2/snapshots/{deviceId}
Authorization: Bearer ...
Content-Type: application/json
```

A full upload uses `protocolVersion: 2`, `mode: "full"`, the device descriptor, `generatedAtMs`, and the complete sanitized snapshot. A delta upload uses `mode: "delta"`, `baseRevision`, changed `upserts`, and removed partition keys in `deletes`.

The server applies a delta inside one SQLite transaction, reconstructs a complete snapshot, and runs the same deep schema, numeric, identity, privacy, and path validation used by protocol v1. A stale or missing base returns HTTP 409 with `fullRequired: true`; the client immediately retries the freshly collected snapshot in full mode. Exact request retries are idempotent.

After a successful upload, a client persists only the server revision, last full-calibration time, schema/timezone/window metadata, and the local partition manifest. It does not persist the upload body or a retry spool. A missing, corrupt, incompatible, or stale manifest forces a full upload.

Normal clients force a full calibration after 24 hours plus deterministic per-device jitter of up to one hour. They also choose full mode when a delta would be at least 70% of the full encoded request.

## Incremental download

```text
POST /v2/snapshots/query
Authorization: Bearer ...
Content-Type: application/json
```

The Mac client sends the server-issued revision and manifest for each cached remote device. Unchanged devices are omitted. A changed device is returned as a full snapshot when it has no usable base, a full calibration was requested, or the delta would be at least 70% of the full response; otherwise only its changed partitions and tombstones are returned. `deletedDeviceIds` removes server-side rows from the client cache.

The Mac stores only privacy-sanitized materialized remote snapshots and their server manifests in a mode-0600 Application Support file. After applying and validating changes, it recomputes the combined display from the current local snapshot and every current remote snapshot. Aggregate counters are not incrementally added to a previously merged result.

## Weekly reset metadata

```text
GET /v2/reset-metadata
Authorization: Bearer ...
```

This returns only the newest valid `codex`, `claude`, and `grok` weekly reset timestamps. Windows and Linux use it before local collection instead of downloading every device snapshot.

## Compatibility and limits

- Clients try v2 first and fall back to protocol-v1 full upload/download when v2 returns HTTP 404.
- The request-body limit remains 16 MiB and the download limit remains 64 MiB.
- Redirects and forward proxies are disabled for sync traffic; non-loopback endpoints require HTTPS.
- Both full and incremental data use the protocol-v1 privacy boundary: prompt/output text, titles, workspace/session paths, raw session content, credentials, cookies, and bearer tokens are never accepted or stored.
- The server stores only one current, fully materialized snapshot plus revision metadata per device. It does not retain a delta event history.
