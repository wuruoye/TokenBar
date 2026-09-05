from __future__ import annotations

import hmac
import hashlib
import ipaddress
import json
import os
import signal
import socket
import sqlite3
import sys
import threading
import time
import uuid
from dataclasses import dataclass
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlsplit

from . import PROTOCOL_VERSION
from .common import (
    MAX_BODY_BYTES,
    MAX_INT64,
    PROTOCOL_V2,
    UUID_RE,
    ValidationError,
    apply_partition_delta,
    canonical_json,
    incremental_delta,
    json_loads_strict,
    partition_manifest,
    sanitize_snapshot,
    snapshot_partitions,
    validate_partition_manifest,
    validate_device,
    validate_envelope,
)


DEFAULT_BIND = "127.0.0.1:18765"
DEFAULT_DATABASE = "./tokenbar-sync.sqlite3"
MAX_FUTURE_CLOCK_SKEW_MS = 5 * 60 * 1000
MAX_WEEKLY_RESET_AGE_MS = 8 * 24 * 60 * 60 * 1000
DELTA_FULL_RATIO = 0.70
MIN_TOKEN_CHARACTERS = 32
MAX_TOKEN_CHARACTERS = 512
PLACEHOLDER_TOKENS = {
    "replace-with-a-long-random-shared-token",
    "use-the-same-long-random-shared-token",
}


class ConflictError(RuntimeError):
    def __init__(
        self,
        message: str,
        *,
        full_required: bool = False,
        revision: int | None = None,
    ):
        self.full_required = full_required
        self.revision = revision
        super().__init__(message)


@dataclass(frozen=True)
class UpsertResult:
    outcome: str
    received_at_ms: int
    revision: int


class SnapshotRepository:
    def __init__(self, database: str):
        self._uri = database == ":memory:"
        self.database = (
            f"file:tokenbar-sync-{uuid.uuid4()}?mode=memory&cache=shared"
            if self._uri
            else database
        )
        self._keeper = self._connect() if self._uri else None
        self._initialize()

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.database, timeout=10.0, uri=self._uri)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA busy_timeout = 10000")
        return connection

    def _initialize(self) -> None:
        database_path = Path(self.database)
        if not self._uri and database_path.parent != Path("."):
            database_path.parent.mkdir(parents=True, exist_ok=True)
        connection = self._connect()
        try:
            connection.execute("PRAGMA journal_mode = WAL")
            connection.execute("PRAGMA synchronous = FULL")
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS snapshots (
                    device_id TEXT PRIMARY KEY,
                    device_json TEXT NOT NULL,
                    generated_at_ms INTEGER NOT NULL,
                    received_at_ms INTEGER NOT NULL,
                    snapshot_json TEXT NOT NULL,
                    revision INTEGER NOT NULL DEFAULT 1,
                    last_request_hash TEXT
                ) WITHOUT ROWID
                """
            )
            columns = {
                row[1] for row in connection.execute("PRAGMA table_info(snapshots)")
            }
            if "revision" not in columns:
                connection.execute(
                    "ALTER TABLE snapshots ADD COLUMN revision INTEGER NOT NULL DEFAULT 1"
                )
            if "last_request_hash" not in columns:
                connection.execute(
                    "ALTER TABLE snapshots ADD COLUMN last_request_hash TEXT"
                )
            connection.commit()
        finally:
            connection.close()
        if not self._uri and database_path.exists():
            database_path.chmod(0o600)

    def health(self) -> None:
        connection = self._connect()
        try:
            connection.execute("SELECT 1").fetchone()
        finally:
            connection.close()

    def upsert(
        self,
        envelope: dict[str, Any],
        *,
        request_hash: str | None = None,
    ) -> UpsertResult:
        device_id = envelope["device"]["id"]
        device_json = canonical_json(envelope["device"])
        snapshot_json = canonical_json(envelope["snapshot"])
        generated_at_ms = envelope["generatedAtMs"]
        received_at_ms = time.time_ns() // 1_000_000

        connection = self._connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            existing = connection.execute(
                """
                SELECT device_id, device_json, generated_at_ms, received_at_ms,
                       snapshot_json, revision, last_request_hash
                FROM snapshots WHERE device_id = ?
                """,
                (device_id,),
            ).fetchone()
            if existing is not None:
                old_generated_at_ms = existing["generated_at_ms"]
                if generated_at_ms < old_generated_at_ms:
                    raise ConflictError("generatedAtMs is older than the stored snapshot")
                if generated_at_ms == old_generated_at_ms:
                    if (
                        device_json == existing["device_json"]
                        and snapshot_json == existing["snapshot_json"]
                    ):
                        connection.commit()
                        return UpsertResult(
                            "retry", existing["received_at_ms"], existing["revision"]
                        )
                    raise ConflictError(
                        "snapshot with the same generatedAtMs differs from the stored snapshot"
                    )
                connection.execute(
                    """
                    UPDATE snapshots
                    SET device_json = ?, generated_at_ms = ?, received_at_ms = ?,
                        snapshot_json = ?, revision = ?, last_request_hash = ?
                    WHERE device_id = ?
                    """,
                    (
                        device_json,
                        generated_at_ms,
                        received_at_ms,
                        snapshot_json,
                        existing["revision"] + 1,
                        request_hash,
                        device_id,
                    ),
                )
                connection.commit()
                return UpsertResult("updated", received_at_ms, existing["revision"] + 1)

            connection.execute(
                """
                INSERT INTO snapshots (
                    device_id, device_json, generated_at_ms,
                    received_at_ms, snapshot_json, revision, last_request_hash
                ) VALUES (?, ?, ?, ?, ?, 1, ?)
                """,
                (
                    device_id,
                    device_json,
                    generated_at_ms,
                    received_at_ms,
                    snapshot_json,
                    request_hash,
                ),
            )
            connection.commit()
            return UpsertResult("created", received_at_ms, 1)
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def upsert_delta(
        self,
        envelope: dict[str, Any],
        *,
        request_hash: str,
    ) -> UpsertResult:
        device_id = envelope["device"]["id"]
        generated_at_ms = envelope["generatedAtMs"]
        received_at_ms = time.time_ns() // 1_000_000
        connection = self._connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            existing = connection.execute(
                """
                SELECT device_id, device_json, generated_at_ms, received_at_ms,
                       snapshot_json, revision, last_request_hash
                FROM snapshots WHERE device_id = ?
                """,
                (device_id,),
            ).fetchone()
            if existing is None:
                raise ConflictError(
                    "a full snapshot is required before an incremental update",
                    full_required=True,
                )
            if hmac.compare_digest(existing["last_request_hash"] or "", request_hash):
                connection.commit()
                return UpsertResult(
                    "retry", existing["received_at_ms"], existing["revision"]
                )
            if envelope["baseRevision"] != existing["revision"]:
                raise ConflictError(
                    "baseRevision does not match the stored snapshot",
                    full_required=True,
                    revision=existing["revision"],
                )
            if generated_at_ms <= existing["generated_at_ms"]:
                raise ConflictError(
                    "generatedAtMs must be newer than the stored snapshot",
                    full_required=True,
                    revision=existing["revision"],
                )
            previous = json_loads_strict(existing["snapshot_json"])
            snapshot = apply_partition_delta(
                previous,
                envelope["upserts"],
                envelope["deletes"],
            )
            v1_envelope = {
                "protocolVersion": PROTOCOL_VERSION,
                "device": envelope["device"],
                "generatedAtMs": generated_at_ms,
                "snapshot": snapshot,
            }
            validate_envelope(v1_envelope, path_device_id=device_id)
            next_revision = existing["revision"] + 1
            connection.execute(
                """
                UPDATE snapshots
                SET device_json = ?, generated_at_ms = ?, received_at_ms = ?,
                    snapshot_json = ?, revision = ?, last_request_hash = ?
                WHERE device_id = ?
                """,
                (
                    canonical_json(envelope["device"]),
                    generated_at_ms,
                    received_at_ms,
                    canonical_json(snapshot),
                    next_revision,
                    request_hash,
                    device_id,
                ),
            )
            connection.commit()
            return UpsertResult("updated", received_at_ms, next_revision)
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def list_snapshots(self, *, include_revision: bool = False) -> list[dict[str, Any]]:
        connection = self._connect()
        try:
            rows = connection.execute(
                """
                SELECT device_id, device_json, generated_at_ms, received_at_ms,
                       snapshot_json, revision
                FROM snapshots ORDER BY device_id ASC
                """
            ).fetchall()
        finally:
            connection.close()
        snapshots = []
        try:
            for row in rows:
                device = json_loads_strict(row["device_json"])
                snapshot = sanitize_snapshot(json_loads_strict(row["snapshot_json"]))
                envelope = {
                    "protocolVersion": PROTOCOL_VERSION,
                    "device": device,
                    "generatedAtMs": row["generated_at_ms"],
                    "snapshot": snapshot,
                }
                validate_envelope(envelope, path_device_id=row["device_id"])
                if device.get("id") != row["device_id"]:
                    raise ValueError("stored device identity does not match its primary key")
                received_at_ms = row["received_at_ms"]
                if (
                    not isinstance(received_at_ms, int)
                    or isinstance(received_at_ms, bool)
                    or received_at_ms <= 0
                    or received_at_ms > time.time_ns() // 1_000_000 + MAX_FUTURE_CLOCK_SKEW_MS
                ):
                    raise ValueError("stored receivedAtMs is invalid")
                record = {
                    "device": device,
                    "generatedAtMs": row["generated_at_ms"],
                    "receivedAtMs": received_at_ms,
                    "snapshot": snapshot,
                }
                if include_revision:
                    revision = row["revision"]
                    if not isinstance(revision, int) or revision <= 0:
                        raise ValueError("stored revision is invalid")
                    record["revision"] = revision
                snapshots.append(record)
        except (AttributeError, TypeError, ValueError, RecursionError) as error:
            raise sqlite3.DatabaseError("stored snapshot is invalid") from error
        return snapshots


def _validate_v2_upload(
    envelope: Any,
    *,
    path_device_id: str,
) -> dict[str, Any]:
    if not isinstance(envelope, dict) or envelope.get("protocolVersion") != PROTOCOL_V2:
        raise ValidationError("protocolVersion must be 2")
    mode = envelope.get("mode")
    if mode == "full":
        if set(envelope) != {
            "protocolVersion",
            "mode",
            "device",
            "generatedAtMs",
            "snapshot",
        }:
            raise ValidationError("request body fields do not match protocol v2 full mode")
        validate_envelope(
            {
                "protocolVersion": PROTOCOL_VERSION,
                "device": envelope["device"],
                "generatedAtMs": envelope["generatedAtMs"],
                "snapshot": envelope["snapshot"],
            },
            path_device_id=path_device_id,
        )
    elif mode == "delta":
        if set(envelope) != {
            "protocolVersion",
            "mode",
            "device",
            "generatedAtMs",
            "baseRevision",
            "upserts",
            "deletes",
        }:
            raise ValidationError("request body fields do not match protocol v2 delta mode")
        device = validate_device(envelope.get("device"))
        if device["id"] != path_device_id:
            raise ValidationError("device.id must match the path deviceId")
        base_revision = envelope.get("baseRevision")
        if (
            not isinstance(base_revision, int)
            or isinstance(base_revision, bool)
            or base_revision <= 0
        ):
            raise ValidationError("baseRevision must be a positive integer")
        generated_at_ms = envelope.get("generatedAtMs")
        if (
            not isinstance(generated_at_ms, int)
            or isinstance(generated_at_ms, bool)
            or generated_at_ms <= 0
            or generated_at_ms > MAX_INT64
        ):
            raise ValidationError("generatedAtMs must be a positive signed 64-bit integer")
        if not isinstance(envelope.get("upserts"), dict):
            raise ValidationError("incremental upserts must be an object")
        if not isinstance(envelope.get("deletes"), list):
            raise ValidationError("incremental deletes must be an array")
    else:
        raise ValidationError("mode must be full or delta")
    return envelope


def _validate_incremental_query(value: Any) -> tuple[dict[str, dict[str, Any]], bool, str | None]:
    if not isinstance(value, dict) or set(value) - {
        "protocolVersion",
        "known",
        "forceFull",
        "excludeDeviceId",
    }:
        raise ValidationError("query body fields do not match protocol v2")
    if value.get("protocolVersion") != PROTOCOL_V2:
        raise ValidationError("protocolVersion must be 2")
    known = value.get("known")
    if not isinstance(known, list) or len(known) > 10_000:
        raise ValidationError("known must be an array")
    force_full = value.get("forceFull", False)
    if not isinstance(force_full, bool):
        raise ValidationError("forceFull must be a boolean")
    exclude_device_id = value.get("excludeDeviceId")
    if exclude_device_id is not None and (
        not isinstance(exclude_device_id, str)
        or UUID_RE.fullmatch(exclude_device_id) is None
        or str(uuid.UUID(exclude_device_id)) != exclude_device_id
    ):
        raise ValidationError("excludeDeviceId must be a canonical UUID string")

    result: dict[str, dict[str, Any]] = {}
    for item in known:
        if not isinstance(item, dict) or set(item) != {"deviceId", "revision", "manifest"}:
            raise ValidationError("known snapshot metadata is invalid")
        device_id = item.get("deviceId")
        revision = item.get("revision")
        if (
            not isinstance(device_id, str)
            or UUID_RE.fullmatch(device_id) is None
            or str(uuid.UUID(device_id)) != device_id
            or device_id in result
        ):
            raise ValidationError("known snapshot deviceId is invalid or duplicated")
        if not isinstance(revision, int) or isinstance(revision, bool) or revision <= 0:
            raise ValidationError("known snapshot revision must be a positive integer")
        manifest = validate_partition_manifest(item.get("manifest"))
        result[device_id] = {"revision": revision, "manifest": manifest}
    return result, force_full, exclude_device_id


def _incremental_query_response(
    records: list[dict[str, Any]],
    request: Any,
) -> dict[str, Any]:
    known, force_full, exclude_device_id = _validate_incremental_query(request)
    current_device_ids = {
        record["device"]["id"]
        for record in records
        if record["device"]["id"] != exclude_device_id
    }
    deleted_device_ids = sorted(
        device_id
        for device_id in set(known) - current_device_ids
        if device_id != exclude_device_id
    )
    changes: list[dict[str, Any]] = []
    for record in records:
        device_id = record["device"]["id"]
        if device_id == exclude_device_id:
            continue
        partitions = snapshot_partitions(record["snapshot"])
        manifest = partition_manifest(partitions)
        previous = known.get(device_id)
        common = {
            "device": record["device"],
            "generatedAtMs": record["generatedAtMs"],
            "receivedAtMs": record["receivedAtMs"],
            "revision": record["revision"],
            "manifest": manifest,
        }
        if (
            not force_full
            and previous is not None
            and previous["revision"] == record["revision"]
            and previous["manifest"] == manifest
        ):
            continue
        if force_full or previous is None:
            changes.append({"mode": "full", **common, "snapshot": record["snapshot"]})
            continue

        upserts, deletes, _manifest = incremental_delta(
            partitions,
            previous["manifest"],
        )
        delta = {"mode": "delta", **common, "upserts": upserts, "deletes": deletes}
        delta_bytes = len(canonical_json(delta).encode("utf-8"))
        full = {"mode": "full", **common, "snapshot": record["snapshot"]}
        full_bytes = len(canonical_json(full).encode("utf-8"))
        changes.append(full if delta_bytes >= full_bytes * DELTA_FULL_RATIO else delta)
    return {
        "protocolVersion": PROTOCOL_V2,
        "snapshots": changes,
        "deletedDeviceIds": deleted_device_ids,
    }


def _weekly_reset_metadata(records: list[dict[str, Any]]) -> dict[str, int]:
    now_ms = time.time_ns() // 1_000_000
    ordered = sorted(records, key=lambda item: item["receivedAtMs"], reverse=True)
    resets: dict[str, int] = {}

    def accept(value: Any, generated_at_ms: int) -> int | None:
        if (
            isinstance(value, int)
            and not isinstance(value, bool)
            and now_ms - MAX_WEEKLY_RESET_AGE_MS <= value <= generated_at_ms <= now_ms
        ):
            return value
        return None

    for record in ordered:
        snapshot = record["snapshot"]
        generated_at_ms = record["generatedAtMs"]
        for source in snapshot.get("sources") or []:
            platform = source.get("platform")
            if platform not in {"codex", "claude", "grok"} or platform in resets:
                continue
            weekly = source.get("weeklySinceReset")
            reset = accept(
                weekly.get("startedAtMs") if isinstance(weekly, dict) else None,
                generated_at_ms,
            )
            if reset is not None:
                resets[platform] = reset
    if "codex" not in resets:
        for record in ordered:
            weekly = record["snapshot"].get("weeklySinceReset")
            reset = accept(
                weekly.get("startedAtMs") if isinstance(weekly, dict) else None,
                record["generatedAtMs"],
            )
            if reset is not None:
                resets["codex"] = reset
                break
    return resets


class TokenBarHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(
        self,
        server_address: tuple[str, int],
        repository: SnapshotRepository,
        token: str = "",
        token_hashes: tuple[bytes, ...] = (),
    ):
        self.repository = repository
        configured_hashes = list(token_hashes)
        if token:
            validate_server_token(token)
            configured_hashes.append(hashlib.sha256(token.encode("ascii")).digest())
        if not configured_hashes:
            raise ValueError("at least one sync token or token hash is required")
        self.auth_token_hashes = tuple(dict.fromkeys(configured_hashes))
        if ":" in server_address[0]:
            self.address_family = socket.AF_INET6
        super().__init__(server_address, TokenBarRequestHandler)


class TokenBarRequestHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "TokenBarSync/2"
    sys_version = ""

    @property
    def app(self) -> TokenBarHTTPServer:
        return self.server  # type: ignore[return-value]

    def log_message(self, format: str, *args: object) -> None:
        # Request logging is intentionally disabled: never log auth headers,
        # device payloads, or identifiers through BaseHTTPRequestHandler.
        return

    def setup(self) -> None:
        super().setup()
        self.connection.settimeout(15)

    def handle_one_request(self) -> None:
        try:
            super().handle_one_request()
        except (TimeoutError, socket.timeout):
            self.close_connection = True

    def _send_json(
        self,
        status: int | HTTPStatus,
        value: dict[str, Any],
        *,
        extra_headers: dict[str, str] | None = None,
    ) -> None:
        body = canonical_json(value).encode("utf-8") + b"\n"
        self.send_response(int(status))
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        if extra_headers:
            for key, header_value in extra_headers.items():
                self.send_header(key, header_value)
        self.end_headers()
        self.wfile.write(body)

    def _error(self, status: int | HTTPStatus, message: str) -> None:
        self._send_json(status, {"error": message})

    def _authorized(self) -> bool:
        headers = self.headers.get_all("Authorization", [])
        if len(headers) != 1:
            return False
        header = headers[0]
        supplied = header[7:] if header.startswith("Bearer ") else ""
        supplied_bytes = supplied.encode("utf-8", errors="surrogatepass")
        supplied_hash = hashlib.sha256(supplied_bytes).digest()
        matched = False
        for expected_hash in self.app.auth_token_hashes:
            matched = hmac.compare_digest(supplied_hash, expected_hash) or matched
        return matched

    def _require_auth(self) -> bool:
        if self._authorized():
            return True
        self._send_json(
            HTTPStatus.UNAUTHORIZED,
            {"error": "unauthorized"},
            extra_headers={"WWW-Authenticate": "Bearer"},
        )
        return False

    def _read_json_body(self) -> tuple[Any, bytes] | None:
        if self.headers.get("Transfer-Encoding") is not None:
            self.close_connection = True
            self._error(HTTPStatus.BAD_REQUEST, "Transfer-Encoding is not supported")
            return None
        content_type = self.headers.get("Content-Type", "").split(";", 1)[0].strip().casefold()
        if content_type != "application/json":
            self.close_connection = True
            self._error(HTTPStatus.UNSUPPORTED_MEDIA_TYPE, "Content-Type must be application/json")
            return None
        content_length_headers = self.headers.get_all("Content-Length", [])
        if len(content_length_headers) > 1:
            self.close_connection = True
            self._error(HTTPStatus.BAD_REQUEST, "multiple Content-Length headers are not allowed")
            return None
        content_length_value = self.headers.get("Content-Length")
        if content_length_value is None:
            self.close_connection = True
            self._error(HTTPStatus.LENGTH_REQUIRED, "Content-Length is required")
            return None
        try:
            content_length = int(content_length_value, 10)
        except ValueError:
            self.close_connection = True
            self._error(HTTPStatus.BAD_REQUEST, "Content-Length is invalid")
            return None
        if content_length < 0:
            self.close_connection = True
            self._error(HTTPStatus.BAD_REQUEST, "Content-Length is invalid")
            return None
        if content_length > MAX_BODY_BYTES:
            self.close_connection = True
            self._error(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "request body exceeds 16 MiB")
            return None
        raw = self.rfile.read(content_length)
        if len(raw) != content_length:
            self.close_connection = True
            self._error(HTTPStatus.BAD_REQUEST, "request body is incomplete")
            return None
        try:
            return json_loads_strict(raw), raw
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError, RecursionError):
            self._error(HTTPStatus.BAD_REQUEST, "request body is invalid JSON")
            return None

    def do_GET(self) -> None:
        target = urlsplit(self.path)
        if target.path.startswith(("/v1/", "/v2/")) and not self._require_auth():
            return
        if target.query or target.fragment:
            self._error(HTTPStatus.NOT_FOUND, "not found")
            return
        if target.path == "/healthz":
            try:
                self.app.repository.health()
            except sqlite3.Error:
                self._error(HTTPStatus.SERVICE_UNAVAILABLE, "database unavailable")
                return
            self._send_json(
                HTTPStatus.OK,
                {"ok": True, "protocolVersion": PROTOCOL_VERSION},
            )
            return
        if target.path == "/v1/snapshots":
            try:
                snapshots = self.app.repository.list_snapshots()
            except sqlite3.Error:
                self._error(HTTPStatus.INTERNAL_SERVER_ERROR, "storage error")
                return
            self._send_json(
                HTTPStatus.OK,
                {"protocolVersion": PROTOCOL_VERSION, "snapshots": snapshots},
            )
            return
        if target.path == "/v2/reset-metadata":
            try:
                snapshots = self.app.repository.list_snapshots()
                resets = _weekly_reset_metadata(snapshots)
            except sqlite3.Error:
                self._error(HTTPStatus.INTERNAL_SERVER_ERROR, "storage error")
                return
            self._send_json(
                HTTPStatus.OK,
                {"protocolVersion": PROTOCOL_V2, "resets": resets},
            )
            return
        self._error(HTTPStatus.NOT_FOUND, "not found")

    def do_PUT(self) -> None:
        target = urlsplit(self.path)
        if not target.path.startswith(("/v1/", "/v2/")):
            self.close_connection = True
            self._error(HTTPStatus.NOT_FOUND, "not found")
            return
        if not self._require_auth():
            self.close_connection = True
            return
        if target.query or target.fragment:
            self.close_connection = True
            self._error(HTTPStatus.NOT_FOUND, "not found")
            return
        if target.path.startswith("/v1/snapshots/"):
            prefix = "/v1/snapshots/"
            protocol = PROTOCOL_VERSION
        elif target.path.startswith("/v2/snapshots/"):
            prefix = "/v2/snapshots/"
            protocol = PROTOCOL_V2
        else:
            self.close_connection = True
            self._error(HTTPStatus.NOT_FOUND, "not found")
            return
        path_device_id = unquote(target.path[len(prefix) :])
        if UUID_RE.fullmatch(path_device_id) is None:
            self.close_connection = True
            self._error(HTTPStatus.BAD_REQUEST, "path deviceId must be a UUID string")
            return
        decoded = self._read_json_body()
        if decoded is None:
            return
        envelope, raw = decoded
        try:
            if protocol == PROTOCOL_VERSION and isinstance(envelope, dict):
                _redact_legacy_workspace_labels(envelope.get("snapshot"))
            if protocol == PROTOCOL_VERSION:
                validate_envelope(envelope, path_device_id=path_device_id)
            else:
                _validate_v2_upload(envelope, path_device_id=path_device_id)
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError, RecursionError) as error:
            message = str(error) if isinstance(error, ValidationError) else "request body is invalid"
            self._error(HTTPStatus.BAD_REQUEST, message)
            return
        if envelope["generatedAtMs"] > (
            time.time_ns() // 1_000_000 + MAX_FUTURE_CLOCK_SKEW_MS
        ):
            self._error(HTTPStatus.BAD_REQUEST, "generatedAtMs is too far in the future")
            return
        try:
            if protocol == PROTOCOL_VERSION:
                result = self.app.repository.upsert(envelope)
            elif envelope["mode"] == "full":
                result = self.app.repository.upsert(
                    {
                        "protocolVersion": PROTOCOL_VERSION,
                        "device": envelope["device"],
                        "generatedAtMs": envelope["generatedAtMs"],
                        "snapshot": envelope["snapshot"],
                    },
                    request_hash=hashlib.sha256(canonical_json(envelope).encode("utf-8")).hexdigest(),
                )
            else:
                result = self.app.repository.upsert_delta(
                    envelope,
                    request_hash=hashlib.sha256(canonical_json(envelope).encode("utf-8")).hexdigest(),
                )
        except ConflictError as error:
            value: dict[str, Any] = {"error": str(error)}
            if protocol == PROTOCOL_V2:
                value["fullRequired"] = error.full_required
                if error.revision is not None:
                    value["revision"] = error.revision
            self._send_json(HTTPStatus.CONFLICT, value)
            return
        except ValidationError as error:
            self._error(HTTPStatus.BAD_REQUEST, str(error))
            return
        except (sqlite3.Error, ValueError, RecursionError):
            self._error(HTTPStatus.INTERNAL_SERVER_ERROR, "storage error")
            return
        status = HTTPStatus.CREATED if result.outcome == "created" else HTTPStatus.OK
        response = {"status": result.outcome, "receivedAtMs": result.received_at_ms}
        if protocol == PROTOCOL_V2:
            response["protocolVersion"] = PROTOCOL_V2
            response["revision"] = result.revision
        self._send_json(status, response)

    def do_POST(self) -> None:
        target = urlsplit(self.path)
        if not target.path.startswith("/v2/"):
            self.close_connection = True
            self._error(HTTPStatus.NOT_FOUND, "not found")
            return
        if not self._require_auth():
            self.close_connection = True
            return
        if target.query or target.fragment or target.path != "/v2/snapshots/query":
            self.close_connection = True
            self._error(HTTPStatus.NOT_FOUND, "not found")
            return
        decoded = self._read_json_body()
        if decoded is None:
            return
        request, _raw = decoded
        try:
            records = self.app.repository.list_snapshots(include_revision=True)
            response = _incremental_query_response(records, request)
        except ValidationError as error:
            self._error(HTTPStatus.BAD_REQUEST, str(error))
            return
        except sqlite3.Error:
            self._error(HTTPStatus.INTERNAL_SERVER_ERROR, "storage error")
            return
        self._send_json(HTTPStatus.OK, response)


def _redact_legacy_workspace_labels(value: Any, *, _depth: int = 0) -> None:
    """Allow rolling protocol-v1 upgrades without retaining old project labels."""
    if _depth > 100:
        raise ValidationError("snapshot nesting exceeds 100 levels")
    if isinstance(value, dict):
        for key, child in value.items():
            if key == "workspaceLabel":
                value[key] = None
            else:
                _redact_legacy_workspace_labels(child, _depth=_depth + 1)
    elif isinstance(value, list):
        for child in value:
            _redact_legacy_workspace_labels(child, _depth=_depth + 1)


def parse_bind(value: str) -> tuple[str, int]:
    if value.startswith("["):
        close = value.find("]")
        if close < 0 or close + 1 >= len(value) or value[close + 1] != ":":
            raise ValueError("TOKENBAR_SYNC_BIND must use [address]:port for IPv6")
        host, port_text = value[1:close], value[close + 2 :]
    else:
        if value.count(":") != 1:
            raise ValueError("TOKENBAR_SYNC_BIND must use address:port")
        host, port_text = value.rsplit(":", 1)
    if not host:
        raise ValueError("TOKENBAR_SYNC_BIND address must not be empty")
    try:
        port = int(port_text, 10)
    except ValueError as error:
        raise ValueError("TOKENBAR_SYNC_BIND port must be an integer") from error
    if not 1 <= port <= 65535:
        raise ValueError("TOKENBAR_SYNC_BIND port must be between 1 and 65535")
    return host, port


def validate_server_token(token: str) -> None:
    if (
        token in PLACEHOLDER_TOKENS
        or not MIN_TOKEN_CHARACTERS <= len(token) <= MAX_TOKEN_CHARACTERS
        or any(ord(character) < 33 or ord(character) > 126 for character in token)
    ):
        raise ValueError(
            "TOKENBAR_SYNC_TOKEN must be 32..512 non-whitespace ASCII characters "
            "and must not use an example placeholder"
        )


def parse_server_token_hashes(value: str) -> tuple[bytes, ...]:
    hashes: list[bytes] = []
    for item in value.split(","):
        candidate = item.strip().casefold()
        if not candidate:
            continue
        if len(candidate) != 64 or any(character not in "0123456789abcdef" for character in candidate):
            raise ValueError(
                "TOKENBAR_SYNC_TOKEN_SHA256 must contain comma-separated SHA-256 hex values"
            )
        hashes.append(bytes.fromhex(candidate))
    if len(set(hashes)) != len(hashes):
        raise ValueError("TOKENBAR_SYNC_TOKEN_SHA256 contains a duplicate hash")
    return tuple(hashes)


def is_loopback_bind(host: str) -> bool:
    if host.casefold() == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def build_server(
    bind: str,
    database: str,
    token: str,
    *,
    token_hashes: str = "",
    allow_public_bind: bool = False,
) -> TokenBarHTTPServer:
    parsed_hashes = parse_server_token_hashes(token_hashes)
    if token:
        validate_server_token(token)
    elif not parsed_hashes:
        raise ValueError("TOKENBAR_SYNC_TOKEN or TOKENBAR_SYNC_TOKEN_SHA256 is required")
    address = parse_bind(bind)
    if not allow_public_bind and not is_loopback_bind(address[0]):
        raise ValueError(
            "TOKENBAR_SYNC_BIND must be loopback unless "
            "TOKENBAR_SYNC_ALLOW_PUBLIC_BIND=1 is explicitly set"
        )
    return TokenBarHTTPServer(
        address,
        SnapshotRepository(database),
        token,
        parsed_hashes,
    )


def main() -> int:
    os.umask(0o077)
    bind = os.environ.get("TOKENBAR_SYNC_BIND", DEFAULT_BIND)
    database = os.environ.get("TOKENBAR_SYNC_DATABASE", DEFAULT_DATABASE)
    token = os.environ.get("TOKENBAR_SYNC_TOKEN", "")
    token_hashes = os.environ.get("TOKENBAR_SYNC_TOKEN_SHA256", "")
    allow_public_bind = os.environ.get("TOKENBAR_SYNC_ALLOW_PUBLIC_BIND") == "1"
    try:
        server = build_server(
            bind,
            database,
            token,
            token_hashes=token_hashes,
            allow_public_bind=allow_public_bind,
        )
    except (ValueError, OSError, sqlite3.Error) as error:
        print(f"tokenbar-sync-server: configuration/startup error: {error}", file=sys.stderr)
        return 2

    stopping = threading.Event()

    def stop(_signum: int, _frame: object) -> None:
        if not stopping.is_set():
            stopping.set()
            threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    actual_host, actual_port = server.server_address[:2]
    print(f"tokenbar-sync-server: listening on {actual_host}:{actual_port}", file=sys.stderr)
    try:
        server.serve_forever(poll_interval=0.25)
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
