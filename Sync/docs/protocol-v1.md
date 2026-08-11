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

`workspaceLabel` may remain. Never transmit credentials or raw session files. The request body limit is 16 MiB.

The server validates protocol version, the device/path ID match, canonical lowercase UUID, OS enum, device-name length, positive timestamps, and an object-valued snapshot. The client additionally validates positive `snapshot.schemaVersion` and `snapshot.generatedAtMs`, a nonempty `snapshot.timezone`, object-valued `snapshot.today`, and array-valued `snapshot.sessions` and `snapshot.days`. `PUT` is an idempotent latest-snapshot upsert. An older `generatedAtMs` for the same device returns HTTP 409; an exact retry succeeds.

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

Before collection, the headless client also uses this GET response as reset metadata. It sorts valid rows by descending `receivedAtMs` and, for each of `codex`, `claude`, and `grok`, selects the newest positive `sources[].weeklySinceReset.startedAtMs` that is not in the future. Top-level `weeklySinceReset.startedAtMs` is accepted only as a legacy Codex fallback. The values map to `--weekly-reset-ms`, `--claude-weekly-reset-ms`, and `--grok-weekly-reset-ms` respectively. A failed GET or missing reset value never blocks Today/30-day collection and upload.

The health endpoint is unauthenticated. Non-loopback client endpoints require HTTPS; HTTP is accepted only for loopback development/deployment. The client rejects all redirects and removes `TOKENBAR_SYNC_TOKEN` from the helper child process environment. No client or server component may log the shared token or snapshot payload.

## Statistics timezone

Windows and Linux Sync clients default to UTC. `local` is an explicit compatibility option. The selected statistics timezone controls all of the following together:

- each activity record's derived calendar date;
- the scan and visible day windows;
- `today`;
- weekly-reset timestamp-to-date conversion;
- the final `snapshot.timezone` identifier.

Changing only the timezone string without re-deriving dates is invalid because the macOS merger rejects incompatible snapshot calendars.
