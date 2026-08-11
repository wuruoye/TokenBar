from __future__ import annotations

import hmac
import json
import os
import signal
import socket
import sqlite3
import sys
import threading
import time
from dataclasses import dataclass
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlsplit

from . import PROTOCOL_VERSION
from .common import (
    MAX_BODY_BYTES,
    UUID_RE,
    ValidationError,
    canonical_json,
    json_loads_strict,
    validate_envelope,
)


DEFAULT_BIND = "127.0.0.1:18765"
DEFAULT_DATABASE = "./tokenbar-sync.sqlite3"


class ConflictError(RuntimeError):
    pass


@dataclass(frozen=True)
class UpsertResult:
    outcome: str
    received_at_ms: int


class SnapshotRepository:
    def __init__(self, database: str):
        self.database = database
        self._initialize()

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.database, timeout=10.0)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA busy_timeout = 10000")
        return connection

    def _initialize(self) -> None:
        database_path = Path(self.database)
        if self.database != ":memory:" and database_path.parent != Path("."):
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
                    snapshot_json TEXT NOT NULL
                ) WITHOUT ROWID
                """
            )
            connection.commit()
        finally:
            connection.close()
        if self.database != ":memory:" and database_path.exists():
            database_path.chmod(0o600)

    def health(self) -> None:
        connection = self._connect()
        try:
            connection.execute("SELECT 1").fetchone()
        finally:
            connection.close()

    def upsert(self, envelope: dict[str, Any]) -> UpsertResult:
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
                SELECT device_json, generated_at_ms, received_at_ms, snapshot_json
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
                        return UpsertResult("retry", existing["received_at_ms"])
                    raise ConflictError(
                        "snapshot with the same generatedAtMs differs from the stored snapshot"
                    )
                connection.execute(
                    """
                    UPDATE snapshots
                    SET device_json = ?, generated_at_ms = ?, received_at_ms = ?,
                        snapshot_json = ?
                    WHERE device_id = ?
                    """,
                    (
                        device_json,
                        generated_at_ms,
                        received_at_ms,
                        snapshot_json,
                        device_id,
                    ),
                )
                connection.commit()
                return UpsertResult("updated", received_at_ms)

            connection.execute(
                """
                INSERT INTO snapshots (
                    device_id, device_json, generated_at_ms,
                    received_at_ms, snapshot_json
                ) VALUES (?, ?, ?, ?, ?)
                """,
                (
                    device_id,
                    device_json,
                    generated_at_ms,
                    received_at_ms,
                    snapshot_json,
                ),
            )
            connection.commit()
            return UpsertResult("created", received_at_ms)
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def list_snapshots(self) -> list[dict[str, Any]]:
        connection = self._connect()
        try:
            rows = connection.execute(
                """
                SELECT device_json, generated_at_ms, received_at_ms, snapshot_json
                FROM snapshots ORDER BY device_id ASC
                """
            ).fetchall()
        finally:
            connection.close()
        return [
            {
                "device": json.loads(row["device_json"]),
                "generatedAtMs": row["generated_at_ms"],
                "receivedAtMs": row["received_at_ms"],
                "snapshot": json.loads(row["snapshot_json"]),
            }
            for row in rows
        ]


class TokenBarHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(
        self,
        server_address: tuple[str, int],
        repository: SnapshotRepository,
        token: str,
    ):
        self.repository = repository
        self.auth_token = token.encode("utf-8")
        if ":" in server_address[0]:
            self.address_family = socket.AF_INET6
        super().__init__(server_address, TokenBarRequestHandler)


class TokenBarRequestHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "TokenBarSync/1"
    sys_version = ""

    @property
    def app(self) -> TokenBarHTTPServer:
        return self.server  # type: ignore[return-value]

    def log_message(self, format: str, *args: object) -> None:
        # Request logging is intentionally disabled: never log auth headers,
        # device payloads, or identifiers through BaseHTTPRequestHandler.
        return

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
        if extra_headers:
            for key, header_value in extra_headers.items():
                self.send_header(key, header_value)
        self.end_headers()
        self.wfile.write(body)

    def _error(self, status: int | HTTPStatus, message: str) -> None:
        self._send_json(status, {"error": message})

    def _authorized(self) -> bool:
        header = self.headers.get("Authorization", "")
        supplied = header[7:] if header.startswith("Bearer ") else ""
        supplied_bytes = supplied.encode("utf-8", errors="surrogatepass")
        return hmac.compare_digest(supplied_bytes, self.app.auth_token)

    def _require_auth(self) -> bool:
        if self._authorized():
            return True
        self._send_json(
            HTTPStatus.UNAUTHORIZED,
            {"error": "unauthorized"},
            extra_headers={"WWW-Authenticate": "Bearer"},
        )
        return False

    def do_GET(self) -> None:
        target = urlsplit(self.path)
        if target.path.startswith("/v1/") and not self._require_auth():
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
        self._error(HTTPStatus.NOT_FOUND, "not found")

    def do_PUT(self) -> None:
        target = urlsplit(self.path)
        if not target.path.startswith("/v1/"):
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
        prefix = "/v1/snapshots/"
        if not target.path.startswith(prefix):
            self.close_connection = True
            self._error(HTTPStatus.NOT_FOUND, "not found")
            return
        path_device_id = unquote(target.path[len(prefix) :])
        if UUID_RE.fullmatch(path_device_id) is None:
            self.close_connection = True
            self._error(HTTPStatus.BAD_REQUEST, "path deviceId must be a UUID string")
            return
        if self.headers.get("Transfer-Encoding") is not None:
            self.close_connection = True
            self._error(HTTPStatus.BAD_REQUEST, "Transfer-Encoding is not supported")
            return
        content_type = self.headers.get("Content-Type", "").split(";", 1)[0].strip().casefold()
        if content_type != "application/json":
            self.close_connection = True
            self._error(HTTPStatus.UNSUPPORTED_MEDIA_TYPE, "Content-Type must be application/json")
            return
        content_length_headers = self.headers.get_all("Content-Length", [])
        if len(content_length_headers) > 1:
            self.close_connection = True
            self._error(HTTPStatus.BAD_REQUEST, "multiple Content-Length headers are not allowed")
            return
        content_length_value = self.headers.get("Content-Length")
        if content_length_value is None:
            self._error(HTTPStatus.LENGTH_REQUIRED, "Content-Length is required")
            return
        try:
            content_length = int(content_length_value, 10)
        except ValueError:
            self._error(HTTPStatus.BAD_REQUEST, "Content-Length is invalid")
            return
        if content_length < 0:
            self._error(HTTPStatus.BAD_REQUEST, "Content-Length is invalid")
            return
        if content_length > MAX_BODY_BYTES:
            self.close_connection = True
            self._error(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "request body exceeds 16 MiB")
            return
        raw = self.rfile.read(content_length)
        if len(raw) != content_length:
            self.close_connection = True
            self._error(HTTPStatus.BAD_REQUEST, "request body is incomplete")
            return
        try:
            envelope = json_loads_strict(raw)
            validate_envelope(envelope, path_device_id=path_device_id)
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError, RecursionError) as error:
            message = str(error) if isinstance(error, ValidationError) else "request body is invalid JSON"
            self._error(HTTPStatus.BAD_REQUEST, message)
            return
        try:
            result = self.app.repository.upsert(envelope)
        except ConflictError as error:
            self._error(HTTPStatus.CONFLICT, str(error))
            return
        except sqlite3.Error:
            self._error(HTTPStatus.INTERNAL_SERVER_ERROR, "storage error")
            return
        status = HTTPStatus.CREATED if result.outcome == "created" else HTTPStatus.OK
        self._send_json(
            status,
            {
                "status": result.outcome,
                "receivedAtMs": result.received_at_ms,
            },
        )


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


def build_server(bind: str, database: str, token: str) -> TokenBarHTTPServer:
    if not token:
        raise ValueError("TOKENBAR_SYNC_TOKEN must be set and non-empty")
    return TokenBarHTTPServer(parse_bind(bind), SnapshotRepository(database), token)


def main() -> int:
    os.umask(0o077)
    bind = os.environ.get("TOKENBAR_SYNC_BIND", DEFAULT_BIND)
    database = os.environ.get("TOKENBAR_SYNC_DATABASE", DEFAULT_DATABASE)
    token = os.environ.get("TOKENBAR_SYNC_TOKEN", "")
    try:
        server = build_server(bind, database, token)
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
