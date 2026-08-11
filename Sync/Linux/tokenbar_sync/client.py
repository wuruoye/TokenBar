from __future__ import annotations

import argparse
import json
import os
import platform
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from typing import Any

from . import PACKAGE_VERSION, PROTOCOL_VERSION
from .common import (
    MAX_BODY_BYTES,
    ValidationError,
    canonical_json,
    json_loads_strict,
    sanitize_snapshot,
    validate_envelope,
)


DEFAULT_URL = "http://127.0.0.1:18765"
DEFAULT_DEVICE_ID_FILE = "~/.config/tokenbar-sync/device-id"
DEFAULT_STATE_DIR = "~/.local/state/tokenbar-sync"
DEFAULT_HELPER = "tokenbar-helper"
MAX_RESPONSE_BYTES = 64 * 1024 * 1024
WEEKLY_RESET_FLAGS = {
    "codex": "--weekly-reset-ms",
    "claude": "--claude-weekly-reset-ms",
    "grok": "--grok-weekly-reset-ms",
}


def _expand(path: str) -> Path:
    return Path(os.path.expandvars(os.path.expanduser(path)))


def _atomic_private_write(path: Path, text: str) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        path.parent.chmod(0o700)
    except OSError:
        pass
    temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    descriptor = os.open(temporary, flags, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        path.chmod(0o600)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def load_or_create_device_id(explicit: str | None, id_file: Path) -> str:
    if explicit:
        value = explicit
    elif id_file.exists():
        value = id_file.read_text(encoding="utf-8").strip()
    else:
        value = str(uuid.uuid4())
        _atomic_private_write(id_file, value + "\n")
    try:
        parsed = uuid.UUID(value)
    except ValueError as error:
        raise ValidationError("device id must be a UUID string") from error
    if str(parsed) != value.casefold():
        raise ValidationError("device id must use the standard hyphenated UUID form")
    return value


def decode_snapshot(raw: bytes) -> dict[str, Any]:
    if len(raw) > MAX_BODY_BYTES:
        raise ValidationError("activity snapshot exceeds 16 MiB before envelope encoding")
    try:
        value = json_loads_strict(raw)
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError, RecursionError) as error:
        raise ValidationError("activity snapshot file is not valid JSON") from error
    if not isinstance(value, dict):
        raise ValidationError("activity snapshot must be a JSON object")
    schema_version = value.get("schemaVersion")
    if not isinstance(schema_version, int) or isinstance(schema_version, bool) or schema_version <= 0:
        raise ValidationError("activity snapshot must contain a positive integer schemaVersion")
    generated_at_ms = value.get("generatedAtMs")
    if (
        not isinstance(generated_at_ms, int)
        or isinstance(generated_at_ms, bool)
        or generated_at_ms <= 0
    ):
        raise ValidationError("activity snapshot must contain a positive generatedAtMs")
    if not isinstance(value.get("timezone"), str):
        raise ValidationError("activity snapshot must contain a timezone string")
    if not isinstance(value.get("today"), dict):
        raise ValidationError("activity snapshot must contain a today object")
    if not isinstance(value.get("sessions"), list):
        raise ValidationError("activity snapshot must contain a sessions array")
    if not isinstance(value.get("days"), list):
        raise ValidationError("activity snapshot must contain a days array")
    return sanitize_snapshot(value)


def load_snapshot(path: Path) -> dict[str, Any]:
    try:
        raw = path.read_bytes()
    except OSError as error:
        raise RuntimeError("activity snapshot file is unavailable") from error
    return decode_snapshot(raw)


def collect_helper_snapshot(
    helper: str,
    days: int,
    statistics_timezone: str,
    weekly_resets: dict[str, int] | None = None,
) -> dict[str, Any]:
    if days <= 0:
        raise ValidationError("helper days must be positive")
    if statistics_timezone not in {"utc", "local"}:
        raise ValidationError("statistics timezone must be utc or local")
    helper_args = [
        helper,
        "--days",
        str(days),
        "--statistics-timezone",
        statistics_timezone,
    ]
    for platform in ("codex", "claude", "grok"):
        reset = (weekly_resets or {}).get(platform)
        if reset is not None:
            helper_args.extend([WEEKLY_RESET_FLAGS[platform], str(reset)])
    try:
        result = subprocess.run(
            helper_args,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=120,
        )
    except FileNotFoundError as error:
        raise RuntimeError(
            "tokenbar-helper is unavailable; install it or provide --snapshot-file"
        ) from error
    except subprocess.TimeoutExpired as error:
        raise RuntimeError("tokenbar-helper timed out") from error
    if result.returncode != 0:
        raise RuntimeError("tokenbar-helper failed")
    snapshot = decode_snapshot(result.stdout)
    _validate_statistics_timezone(snapshot, statistics_timezone)
    return snapshot


def _validate_statistics_timezone(
    snapshot: dict[str, Any],
    statistics_timezone: str,
) -> None:
    if statistics_timezone == "utc" and snapshot["timezone"] != "UTC":
        raise ValidationError("UTC collection requires snapshot.timezone to be UTC")


def collect_snapshot(
    snapshot_file: str | None,
    helper: str,
    helper_days: int,
    statistics_timezone: str,
    weekly_resets: dict[str, int] | None = None,
) -> dict[str, Any]:
    if snapshot_file:
        snapshot = load_snapshot(_expand(snapshot_file))
        _validate_statistics_timezone(snapshot, statistics_timezone)
        return snapshot
    return collect_helper_snapshot(
        helper,
        helper_days,
        statistics_timezone,
        weekly_resets,
    )


def build_envelope(
    snapshot: dict[str, Any],
    *,
    device_id: str,
    device_name: str,
    generated_at_ms: int | None = None,
    client_version: str | None = None,
) -> dict[str, Any]:
    device: dict[str, Any] = {
        "id": device_id,
        "name": device_name,
        "os": "linux",
    }
    if client_version:
        device["clientVersion"] = client_version
    envelope = {
        "protocolVersion": PROTOCOL_VERSION,
        "device": device,
        "generatedAtMs": (
            generated_at_ms
            if generated_at_ms is not None
            else snapshot.get("generatedAtMs", time.time_ns() // 1_000_000)
        ),
        "snapshot": sanitize_snapshot(snapshot),
    }
    validate_envelope(envelope, path_device_id=device_id)
    return envelope


def _read_token(token_file: str | None) -> str:
    token = os.environ.get("TOKENBAR_SYNC_TOKEN", "")
    if token_file:
        try:
            token = _expand(token_file).read_text(encoding="utf-8").strip()
        except OSError as error:
            raise RuntimeError("token file is unavailable") from error
    if not token:
        raise RuntimeError("TOKENBAR_SYNC_TOKEN or --token-file is required")
    return token


def _base_url(value: str) -> str:
    parsed = urllib.parse.urlsplit(value)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ValidationError("sync URL must be an http or https URL")
    if parsed.username is not None or parsed.password is not None:
        raise ValidationError("sync URL must not contain credentials")
    if parsed.query or parsed.fragment:
        raise ValidationError("sync URL must not contain a query or fragment")
    return value.rstrip("/")


def _request_json(
    method: str,
    url: str,
    token: str,
    body: dict[str, Any] | None = None,
    *,
    timeout: float = 15.0,
    response_limit: int = MAX_BODY_BYTES,
) -> tuple[int, dict[str, Any]]:
    encoded = None if body is None else canonical_json(body).encode("utf-8")
    if encoded is not None and len(encoded) > MAX_BODY_BYTES:
        raise ValidationError("encoded upload exceeds the 16 MiB request limit")
    request = urllib.request.Request(
        url,
        data=encoded,
        method=method,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
            **({"Content-Type": "application/json"} if encoded is not None else {}),
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            response_body = response.read(response_limit + 1)
            status = response.status
    except urllib.error.HTTPError as error:
        response_body = error.read(64 * 1024)
        detail = ""
        try:
            parsed_error = json_loads_strict(response_body)
            if isinstance(parsed_error, dict) and isinstance(parsed_error.get("error"), str):
                detail = f": {parsed_error['error']}"
        except (ValueError, json.JSONDecodeError, UnicodeDecodeError):
            pass
        raise RuntimeError(f"sync server returned HTTP {error.code}{detail}") from error
    except urllib.error.URLError as error:
        raise RuntimeError("sync server is unreachable") from error
    if len(response_body) > response_limit:
        raise RuntimeError("sync server response exceeds the client limit")
    try:
        response_value = json_loads_strict(response_body)
    except (ValueError, json.JSONDecodeError, UnicodeDecodeError) as error:
        raise RuntimeError("sync server returned invalid JSON") from error
    if not isinstance(response_value, dict):
        raise RuntimeError("sync server returned an invalid response object")
    return status, response_value


def upload_envelope(base_url: str, token: str, envelope: dict[str, Any]) -> tuple[int, dict[str, Any]]:
    validate_envelope(envelope, path_device_id=envelope.get("device", {}).get("id"))
    device_id = urllib.parse.quote(envelope["device"]["id"], safe="")
    return _request_json(
        "PUT",
        f"{_base_url(base_url)}/v1/snapshots/{device_id}",
        token,
        envelope,
    )


def download_snapshots(base_url: str, token: str) -> dict[str, Any]:
    _status, value = _request_json(
        "GET",
        f"{_base_url(base_url)}/v1/snapshots",
        token,
        response_limit=MAX_RESPONSE_BYTES,
    )
    return value


def extract_weekly_resets(
    response: Any,
    *,
    now_ms: int | None = None,
) -> dict[str, int]:
    if not isinstance(response, dict) or response.get("protocolVersion") != PROTOCOL_VERSION:
        return {}
    snapshots = response.get("snapshots")
    if not isinstance(snapshots, list):
        return {}
    current_ms = now_ms if now_ms is not None else time.time_ns() // 1_000_000

    def valid_positive_ms(value: Any) -> int | None:
        if (
            isinstance(value, int)
            and not isinstance(value, bool)
            and 0 < value <= current_ms
        ):
            return value
        return None

    ordered: list[tuple[int, dict[str, Any]]] = []
    for entry in snapshots:
        if not isinstance(entry, dict) or not isinstance(entry.get("snapshot"), dict):
            continue
        received_at_ms = entry.get("receivedAtMs")
        generated_at_ms = entry.get("generatedAtMs")
        if (
            not isinstance(received_at_ms, int)
            or isinstance(received_at_ms, bool)
            or received_at_ms <= 0
            or not isinstance(generated_at_ms, int)
            or isinstance(generated_at_ms, bool)
            or generated_at_ms <= 0
        ):
            continue
        ordered.append((received_at_ms, entry["snapshot"]))
    ordered.sort(key=lambda item: item[0], reverse=True)

    resets: dict[str, int] = {}
    for _received_at_ms, snapshot in ordered:
        sources = snapshot.get("sources")
        if isinstance(sources, list):
            for source in sources:
                if not isinstance(source, dict):
                    continue
                platform = source.get("platform")
                if platform not in WEEKLY_RESET_FLAGS or platform in resets:
                    continue
                weekly = source.get("weeklySinceReset")
                if not isinstance(weekly, dict):
                    continue
                reset = valid_positive_ms(weekly.get("startedAtMs"))
                if reset is not None:
                    resets[platform] = reset
        if "codex" not in resets:
            weekly = snapshot.get("weeklySinceReset")
            if isinstance(weekly, dict):
                reset = valid_positive_ms(weekly.get("startedAtMs"))
                if reset is not None:
                    resets["codex"] = reset
        if len(resets) == len(WEEKLY_RESET_FLAGS):
            break
    return resets


def fetch_weekly_resets(base_url: str, token: str) -> dict[str, int]:
    try:
        response = download_snapshots(base_url, token)
    except (RuntimeError, ValidationError):
        return {}
    return extract_weekly_resets(response)


def _common_values(
    args: argparse.Namespace,
    weekly_resets: dict[str, int] | None = None,
) -> tuple[str, str, dict[str, Any]]:
    device_id = load_or_create_device_id(
        args.device_id,
        _expand(args.device_id_file),
    )
    device_name = args.device_name or platform.node() or "Linux device"
    snapshot = collect_snapshot(
        args.snapshot_file,
        args.helper,
        args.helper_days,
        args.statistics_timezone,
        weekly_resets,
    )
    return device_id, device_name, snapshot


def command_collect(args: argparse.Namespace) -> int:
    token = _read_token(args.token_file)
    weekly_resets = fetch_weekly_resets(args.url, token)
    device_id, device_name, snapshot = _common_values(args, weekly_resets)
    envelope = build_envelope(
        snapshot,
        device_id=device_id,
        device_name=device_name,
        client_version=args.client_version,
    )
    print(canonical_json(envelope))
    return 0


def command_upload(args: argparse.Namespace) -> int:
    token = _read_token(args.token_file)
    state_dir = _expand(args.state_dir)
    pending_path = state_dir / "pending-upload.json"
    if pending_path.exists():
        try:
            pending = json_loads_strict(pending_path.read_bytes())
            validate_envelope(pending)
        except (OSError, ValueError, json.JSONDecodeError, UnicodeDecodeError) as error:
            raise RuntimeError("pending upload is invalid; move it aside before retrying") from error
        envelope = pending
    else:
        weekly_resets = fetch_weekly_resets(args.url, token)
        device_id, device_name, snapshot = _common_values(args, weekly_resets)
        envelope = build_envelope(
            snapshot,
            device_id=device_id,
            device_name=device_name,
            client_version=args.client_version,
        )
        _atomic_private_write(pending_path, canonical_json(envelope) + "\n")

    status, response = upload_envelope(args.url, token, envelope)
    pending_path.unlink(missing_ok=True)
    print(
        "uploaded "
        f"device={envelope['device']['id']} "
        f"generatedAtMs={envelope['generatedAtMs']} "
        f"http={status} status={response.get('status', 'ok')}"
    )
    return 0


def command_download(args: argparse.Namespace) -> int:
    token = _read_token(args.token_file)
    print(canonical_json(download_snapshots(args.url, token)))
    return 0


def _add_source_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--snapshot-file",
        default=os.environ.get("TOKENBAR_ACTIVITY_SNAPSHOT"),
        help="existing TokenBar ActivitySnapshot JSON (otherwise run tokenbar-helper)",
    )
    parser.add_argument(
        "--helper",
        default=os.environ.get("TOKENBAR_HELPER", DEFAULT_HELPER),
        help="TokenBar helper executable",
    )
    parser.add_argument(
        "--helper-days",
        type=int,
        default=int(os.environ.get("TOKENBAR_HELPER_DAYS", "30")),
        help="number of local activity days requested from tokenbar-helper",
    )
    parser.add_argument(
        "--statistics-timezone",
        choices=("utc", "local"),
        default=os.environ.get("TOKENBAR_STATISTICS_TIMEZONE", "utc"),
        help="statistics timezone passed to tokenbar-helper (default: utc)",
    )
    parser.add_argument(
        "--device-id",
        default=os.environ.get("TOKENBAR_SYNC_DEVICE_ID"),
        help="stable device UUID (otherwise loaded/generated from --device-id-file)",
    )
    parser.add_argument(
        "--device-id-file",
        default=os.environ.get("TOKENBAR_SYNC_DEVICE_ID_FILE", DEFAULT_DEVICE_ID_FILE),
    )
    parser.add_argument(
        "--device-name",
        default=os.environ.get("TOKENBAR_SYNC_DEVICE_NAME"),
    )
    parser.add_argument(
        "--client-version",
        default=os.environ.get("TOKENBAR_SYNC_CLIENT_VERSION", f"linux/{PACKAGE_VERSION}"),
    )


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="tokenbar-sync-client",
        description="Sanitize and sync a TokenBar ActivitySnapshot from headless Linux",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    collect = subparsers.add_parser("collect", help="emit a sanitized protocol-v1 envelope")
    _add_source_arguments(collect)
    collect.add_argument("--url", default=os.environ.get("TOKENBAR_SYNC_URL", DEFAULT_URL))
    collect.add_argument("--token-file")
    collect.set_defaults(handler=command_collect)

    upload = subparsers.add_parser("upload", help="sanitize, spool, and upload a snapshot")
    _add_source_arguments(upload)
    upload.add_argument("--url", default=os.environ.get("TOKENBAR_SYNC_URL", DEFAULT_URL))
    upload.add_argument("--token-file")
    upload.add_argument(
        "--state-dir",
        default=os.environ.get("TOKENBAR_SYNC_STATE_DIR", DEFAULT_STATE_DIR),
    )
    upload.set_defaults(handler=command_upload)

    download = subparsers.add_parser("download", help="download the latest device snapshots")
    download.add_argument("--url", default=os.environ.get("TOKENBAR_SYNC_URL", DEFAULT_URL))
    download.add_argument("--token-file")
    download.set_defaults(handler=command_download)
    return parser


def main(argv: list[str] | None = None) -> int:
    os.umask(0o077)
    parser = build_argument_parser()
    args = parser.parse_args(argv)
    try:
        return args.handler(args)
    except (RuntimeError, ValidationError, OSError) as error:
        print(f"tokenbar-sync-client: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
