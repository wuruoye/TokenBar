# TokenBar Sync protocol v1

Protocol v1 versions the network envelope independently from TokenBar's `ActivitySnapshot.schemaVersion`. A client must preserve the positive schema version produced by its bundled helper; it must not rewrite that value to match another device.

## Upload

```http
PUT /v1/snapshots/{deviceId}
Authorization: Bearer <shared token>
Content-Type: application/json
```

```json
{
  "protocolVersion": 1,
  "device": {
    "id": "<UUID matching deviceId in the path>",
    "name": "<1 to 80 display characters>",
    "os": "macos|windows|linux",
    "clientVersion": "<optional string>"
  },
  "generatedAtMs": 123,
  "snapshot": {
    "schemaVersion": "<positive helper-produced version>"
  }
}
```

Before network serialization, recursively set these fields to JSON `null` wherever they occur in the snapshot:

- `promptPreview`
- `outputPreview`
- `sessionPath`
- session `title`
- `workspacePath`
- `workspaceLabel`

Never transmit credentials or raw session files. During a rolling protocol-v1 upgrade, the server accepts a legacy non-null `workspaceLabel` only to replace it with `null` before validation and storage; other unredacted content remains invalid. The request body limit is 16 MiB.

Credential-bearing properties are omitted, known content/path properties are `null`, and unknown absolute POSIX, Windows, UNC, or `file://` paths are also `null`. The server validates protocol version, the device/path ID match, canonical lowercase UUID, OS enum, device/client-version display bounds, positive timestamps, signed 64-bit and nonnegative aggregate ranges, and the complete ActivitySnapshot structure required by the Mac decoder. It rejects a `generatedAtMs` more than five minutes ahead of server time. `PUT` is an idempotent latest-snapshot upsert. An older `generatedAtMs` for the same device returns HTTP 409; an exact retry with identical device/snapshot content succeeds without changing `receivedAtMs`; conflicting content at the same timestamp returns 409.

The headless client has no persistent payload spool. A 409 drops the rejected in-memory envelope; the next scheduled invocation performs a fresh collection. Only non-payload last-run metadata is retained.

## Download

```http
GET /v1/snapshots
Authorization: Bearer <shared token>
```

```json
{
  "protocolVersion": 1,
  "snapshots": [
    {
      "device": {
        "id": "<UUID>",
        "name": "<display name>",
        "os": "windows"
      },
      "generatedAtMs": 123,
      "receivedAtMs": 456,
      "snapshot": {}
    }
  ]
}
```

The server returns one latest row per device in stable device-ID order. The client validates positive timestamps and unique device IDs, normalizes the order, and applies the same recursive sanitization again before saving downloaded JSON.

Before collection, the headless client also uses this GET response as reset metadata. It sorts valid rows by descending `receivedAtMs` and, for each of `codex`, `claude`, and `grok`, selects the newest positive `sources[].weeklySinceReset.startedAtMs` that is no more than eight days old and no later than its snapshot's `generatedAtMs`. Top-level `weeklySinceReset.startedAtMs` is accepted only as a legacy Codex fallback. The values map to `--weekly-reset-ms`, `--claude-weekly-reset-ms`, and `--grok-weekly-reset-ms` respectively. A failed GET or missing/stale reset value never blocks Today/30-day collection and upload.

The health endpoint is unauthenticated. Every client uses a 32–512 character non-whitespace ASCII bearer token. The server can accept one plaintext token for local testing or a comma-separated set of SHA-256 token hashes so each deployed device can generate and retain its own secret. Non-loopback client endpoints require HTTPS; HTTP is accepted only for loopback development/deployment. The client rejects all redirects, bypasses ambient forward proxies, and removes `TOKENBAR_SYNC_TOKEN` from the helper child process environment. No client or server component may log an access token or snapshot payload. Mac bounds the streamed response before buffering more than 64 MiB; Windows and Linux also enforce the 64 MiB download limit while reading.

## Statistics timezone

Windows and Linux Sync clients default to UTC. `local` is an explicit compatibility option. The selected statistics timezone controls all of the following together:

- each activity record's derived calendar date;
- the scan and visible day windows;
- `today`;
- weekly-reset timestamp-to-date conversion;
- the final `snapshot.timezone` identifier.

Changing only the timezone string without re-deriving dates is invalid because the macOS merger rejects incompatible snapshot calendars.
