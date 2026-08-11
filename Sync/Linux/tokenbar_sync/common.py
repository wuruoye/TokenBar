from __future__ import annotations

import json
import re
import unicodedata
from typing import Any

from . import PROTOCOL_VERSION


MAX_BODY_BYTES = 16 * 1024 * 1024
OS_VALUES = {"macos", "windows", "linux"}
UUID_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)

# These ActivitySnapshot fields may exist structurally, but their values must
# never leave the device. The sanitizer operates recursively.
PRIVACY_NULL_FIELDS = {
    "promptPreview",
    "outputPreview",
    "sessionPath",
    "title",
    "workspacePath",
    "promptText",
    "outputText",
    "rawPrompt",
    "rawOutput",
    "messages",
    "conversation",
    "rawSession",
    "rawSessionFile",
    "sessionFile",
    "sessionContents",
    "cwd",
}

# Credential-bearing properties are omitted, rather than transmitted as null.
CREDENTIAL_KEYS = {
    "credential",
    "credentials",
    "password",
    "secret",
    "apikey",
    "accesstoken",
    "refreshtoken",
    "authorization",
    "bearertoken",
    "token",
    "authtoken",
    "idtoken",
    "oauthtoken",
    "sessiontoken",
    "providertoken",
    "providercredential",
    "providercredentials",
    "clientsecret",
    "privatekey",
    "cookie",
    "cookies",
}


class ValidationError(ValueError):
    pass


def json_loads_strict(raw: bytes | str) -> Any:
    def reject_constant(value: str) -> None:
        raise ValueError(f"invalid JSON number: {value}")

    return json.loads(raw, parse_constant=reject_constant)


def canonical_json(value: Any) -> str:
    return json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        separators=(",", ":"),
    )


def _normalized_key(key: str) -> str:
    return re.sub(r"[^a-z0-9]", "", key.casefold())


def _looks_like_absolute_local_path(value: str) -> bool:
    return (
        value.startswith("/")
        or value.startswith("\\\\")
        or re.match(r"^[A-Za-z]:[\\/]", value) is not None
        or value.casefold().startswith("file://")
    )


def sanitize_snapshot(value: Any, *, _depth: int = 0) -> Any:
    """Return a JSON-compatible privacy-sanitized deep copy.

    Explicit preview/session metadata fields are retained as null so clients can
    decode their established schema. Credential properties are removed. Any
    absolute local path that appears in an otherwise unknown field is nulled as
    defense in depth.
    """
    if _depth > 100:
        raise ValidationError("snapshot nesting exceeds 100 levels")
    if isinstance(value, dict):
        clean: dict[str, Any] = {}
        for key, child in value.items():
            if not isinstance(key, str):
                raise ValidationError("snapshot object keys must be strings")
            if _normalized_key(key) in CREDENTIAL_KEYS:
                continue
            if key in PRIVACY_NULL_FIELDS:
                clean[key] = None
            else:
                clean[key] = sanitize_snapshot(child, _depth=_depth + 1)
        return clean
    if isinstance(value, list):
        return [sanitize_snapshot(item, _depth=_depth + 1) for item in value]
    if isinstance(value, str) and _looks_like_absolute_local_path(value):
        return None
    if value is None or isinstance(value, (str, int, float, bool)):
        if isinstance(value, float) and (value != value or value in (float("inf"), float("-inf"))):
            raise ValidationError("snapshot contains a non-finite number")
        return value
    raise ValidationError(f"snapshot contains unsupported JSON value {type(value).__name__}")


def _validate_device(device: Any) -> dict[str, Any]:
    if not isinstance(device, dict):
        raise ValidationError("device must be an object")
    required = {"id", "name", "os"}
    allowed = required | {"clientVersion"}
    if set(device) - allowed:
        raise ValidationError("device contains unsupported fields")
    if required - set(device):
        raise ValidationError("device is missing required fields")

    device_id = device["id"]
    if not isinstance(device_id, str) or UUID_RE.fullmatch(device_id) is None:
        raise ValidationError("device.id must be a UUID string")

    name = device["name"]
    if not isinstance(name, str) or not 1 <= len(name) <= 80 or not name.strip():
        raise ValidationError("device.name must contain 1..80 display characters")
    if any(unicodedata.category(ch) in {"Cc", "Cs"} for ch in name):
        raise ValidationError("device.name must contain 1..80 display characters")

    os_name = device["os"]
    if os_name not in OS_VALUES:
        raise ValidationError("device.os must be macos, windows, or linux")

    if "clientVersion" in device and not isinstance(device["clientVersion"], str):
        raise ValidationError("device.clientVersion must be a string")
    return device


def validate_envelope(
    envelope: Any,
    *,
    path_device_id: str | None = None,
    enforce_privacy: bool = True,
) -> dict[str, Any]:
    if not isinstance(envelope, dict):
        raise ValidationError("request body must be an object")
    required = {"protocolVersion", "device", "generatedAtMs", "snapshot"}
    if set(envelope) != required:
        raise ValidationError("request body fields do not match protocol v1")
    if envelope["protocolVersion"] != PROTOCOL_VERSION or isinstance(
        envelope["protocolVersion"], bool
    ):
        raise ValidationError("protocolVersion must be 1")

    device = _validate_device(envelope["device"])
    if path_device_id is not None and device["id"] != path_device_id:
        raise ValidationError("device.id must match the path deviceId")

    generated_at_ms = envelope["generatedAtMs"]
    if (
        not isinstance(generated_at_ms, int)
        or isinstance(generated_at_ms, bool)
        or generated_at_ms <= 0
    ):
        raise ValidationError("generatedAtMs must be a positive integer")

    snapshot = envelope["snapshot"]
    if not isinstance(snapshot, dict):
        raise ValidationError("snapshot must be an object")
    sanitized = sanitize_snapshot(snapshot)
    if enforce_privacy and sanitized != snapshot:
        raise ValidationError("snapshot is not privacy-sanitized")
    canonical_json(envelope)
    return envelope
