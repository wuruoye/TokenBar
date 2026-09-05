from __future__ import annotations

import json
import hashlib
import math
import re
import unicodedata
import uuid
from typing import Any

from . import PROTOCOL_VERSION


MAX_BODY_BYTES = 16 * 1024 * 1024
PROTOCOL_V2 = 2
MAX_PARTITIONS = 100_000
MIN_INT64 = -(2**63)
MAX_INT64 = 2**63 - 1
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
    "workspacePath",
    "workspaceLabel",
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

    def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        value: dict[str, Any] = {}
        for key, child in pairs:
            if key in value:
                raise ValueError(f"duplicate JSON object key: {key}")
            value[key] = child
        return value

    return json.loads(
        raw,
        parse_constant=reject_constant,
        object_pairs_hook=reject_duplicate_keys,
    )


def canonical_json(value: Any) -> str:
    return json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        separators=(",", ":"),
    )


def _partition_key(kind: str, *identity: str) -> str:
    material = "\0".join((kind, *identity)).encode("utf-8")
    return f"{kind}:{hashlib.sha256(material).hexdigest()}"


def snapshot_partitions(snapshot: Any) -> dict[str, Any]:
    """Split a sanitized ActivitySnapshot into stable replacement partitions."""
    clean = sanitize_snapshot(snapshot)
    validate_activity_snapshot(clean)

    root = {
        key: value
        for key, value in clean.items()
        if key not in {"sessions", "days", "sources", "memoryUsage"}
    }
    sources = clean.get("sources")
    source_summaries: list[dict[str, Any]] | None = None
    if sources is not None:
        source_summaries = []
        for source in sources:
            source_summaries.append(
                {key: value for key, value in source.items() if key != "days"}
            )

    memory = clean.get("memoryUsage")
    memory_summary = (
        None
        if memory is None
        else {key: value for key, value in memory.items() if key != "days"}
    )
    partitions: dict[str, Any] = {
        "summary": {
            "snapshot": root,
            "sources": source_summaries,
            "memoryUsage": memory_summary,
        }
    }

    for day in clean.get("days", []):
        key = _partition_key("day", day["date"])
        if key in partitions:
            raise ValidationError("snapshot days contain a duplicate partition")
        partitions[key] = day
    for source in sources or []:
        for day in source["days"]:
            key = _partition_key("source-day", source["platform"], day["date"])
            if key in partitions:
                raise ValidationError("snapshot source days contain a duplicate partition")
            partitions[key] = {"platform": source["platform"], "day": day}
    for session in clean.get("sessions", []):
        platform = session.get("platform") or ""
        key = _partition_key("session", platform, session["id"])
        if key in partitions:
            raise ValidationError("snapshot sessions contain a duplicate identity")
        partitions[key] = session
    for day in (memory or {}).get("days", []):
        key = _partition_key("memory-day", day["date"])
        if key in partitions:
            raise ValidationError("snapshot memory days contain a duplicate partition")
        partitions[key] = day

    if len(partitions) > MAX_PARTITIONS:
        raise ValidationError("snapshot contains too many incremental partitions")
    return partitions


def partition_manifest(partitions: dict[str, Any]) -> dict[str, str]:
    if not isinstance(partitions, dict) or len(partitions) > MAX_PARTITIONS:
        raise ValidationError("incremental partitions are invalid")
    return {
        key: hashlib.sha256(canonical_json(value).encode("utf-8")).hexdigest()
        for key, value in partitions.items()
    }


def validate_partition_manifest(value: Any) -> dict[str, str]:
    if not isinstance(value, dict) or len(value) > MAX_PARTITIONS:
        raise ValidationError("incremental manifest must be an object")
    manifest: dict[str, str] = {}
    for key, digest in value.items():
        if not isinstance(key, str) or not key or len(key) > 256:
            raise ValidationError("incremental manifest contains an invalid key")
        if (
            not isinstance(digest, str)
            or len(digest) != 64
            or any(character not in "0123456789abcdef" for character in digest)
        ):
            raise ValidationError("incremental manifest contains an invalid SHA-256 value")
        manifest[key] = digest
    return manifest


def incremental_delta(
    current: dict[str, Any],
    previous_manifest: Any,
) -> tuple[dict[str, Any], list[str], dict[str, str]]:
    manifest = validate_partition_manifest(previous_manifest)
    current_manifest = partition_manifest(current)
    upserts = {
        key: value
        for key, value in current.items()
        if manifest.get(key) != current_manifest[key]
    }
    deletes = sorted(set(manifest) - set(current_manifest))
    return upserts, deletes, current_manifest


def materialize_snapshot(partitions: Any) -> dict[str, Any]:
    """Rebuild and deeply validate a full ActivitySnapshot from partitions."""
    if not isinstance(partitions, dict) or not 1 <= len(partitions) <= MAX_PARTITIONS:
        raise ValidationError("incremental partitions must be a non-empty object")
    summary = partitions.get("summary")
    if not isinstance(summary, dict) or set(summary) != {
        "snapshot",
        "sources",
        "memoryUsage",
    }:
        raise ValidationError("incremental summary partition is invalid")
    root = summary["snapshot"]
    if not isinstance(root, dict):
        raise ValidationError("incremental summary snapshot must be an object")
    if any(key in root for key in ("sessions", "days", "sources", "memoryUsage")):
        raise ValidationError("incremental summary contains partitioned fields")

    source_summaries = summary["sources"]
    if source_summaries is not None and not isinstance(source_summaries, list):
        raise ValidationError("incremental source summaries must be an array or null")
    memory_summary = summary["memoryUsage"]
    if memory_summary is not None and not isinstance(memory_summary, dict):
        raise ValidationError("incremental memory summary must be an object or null")

    days: list[dict[str, Any]] = []
    sessions: list[dict[str, Any]] = []
    source_days: dict[str, list[dict[str, Any]]] = {}
    memory_days: list[dict[str, Any]] = []
    for key, value in partitions.items():
        if key == "summary":
            continue
        if key.startswith("day:"):
            if not isinstance(value, dict) or key != _partition_key("day", value.get("date", "")):
                raise ValidationError("incremental day partition identity is invalid")
            days.append(value)
        elif key.startswith("source-day:"):
            if not isinstance(value, dict) or set(value) != {"platform", "day"}:
                raise ValidationError("incremental source-day partition is invalid")
            platform = value["platform"]
            day = value["day"]
            if not isinstance(platform, str) or not isinstance(day, dict):
                raise ValidationError("incremental source-day partition is invalid")
            if key != _partition_key("source-day", platform, day.get("date", "")):
                raise ValidationError("incremental source-day identity is invalid")
            source_days.setdefault(platform, []).append(day)
        elif key.startswith("session:"):
            if not isinstance(value, dict):
                raise ValidationError("incremental session partition is invalid")
            platform = value.get("platform") or ""
            if key != _partition_key("session", platform, value.get("id", "")):
                raise ValidationError("incremental session identity is invalid")
            sessions.append(value)
        elif key.startswith("memory-day:"):
            if not isinstance(value, dict) or key != _partition_key(
                "memory-day", value.get("date", "")
            ):
                raise ValidationError("incremental memory-day identity is invalid")
            memory_days.append(value)
        else:
            raise ValidationError("incremental partition kind is unsupported")

    snapshot = dict(root)
    snapshot["days"] = sorted(days, key=lambda item: item["date"], reverse=True)
    snapshot["sessions"] = sorted(
        sessions,
        key=lambda item: (
            item.get("endedAtMs", 0),
            item.get("startedAtMs", 0),
            item.get("platform") or "",
            item.get("id") or "",
        ),
        reverse=True,
    )
    if source_summaries is not None:
        rebuilt_sources: list[dict[str, Any]] = []
        source_platforms: set[str] = set()
        for source_summary in source_summaries:
            if not isinstance(source_summary, dict) or "days" in source_summary:
                raise ValidationError("incremental source summary is invalid")
            platform = source_summary.get("platform")
            if not isinstance(platform, str) or not platform or platform in source_platforms:
                raise ValidationError("incremental source summary platform is invalid")
            source_platforms.add(platform)
            source = dict(source_summary)
            source["days"] = sorted(
                source_days.pop(platform, []),
                key=lambda item: item["date"],
                reverse=True,
            )
            rebuilt_sources.append(source)
        if source_days:
            raise ValidationError("incremental source-day has no source summary")
        snapshot["sources"] = sorted(
            rebuilt_sources, key=lambda item: item["platform"]
        )
    elif source_days:
        raise ValidationError("incremental source-day has no source summary")

    if memory_summary is not None:
        memory = dict(memory_summary)
        memory["days"] = sorted(
            memory_days, key=lambda item: item["date"], reverse=True
        )
        snapshot["memoryUsage"] = memory
    elif memory_days:
        raise ValidationError("incremental memory-day has no memory summary")

    clean = sanitize_snapshot(snapshot)
    validate_activity_snapshot(clean)
    return clean


def apply_partition_delta(
    snapshot: Any,
    upserts: Any,
    deletes: Any,
) -> dict[str, Any]:
    if not isinstance(upserts, dict) or len(upserts) > MAX_PARTITIONS:
        raise ValidationError("incremental upserts must be an object")
    if not isinstance(deletes, list) or len(deletes) > MAX_PARTITIONS:
        raise ValidationError("incremental deletes must be an array")
    if any(not isinstance(key, str) or not key or len(key) > 256 for key in upserts):
        raise ValidationError("incremental upserts contain an invalid key")
    if any(not isinstance(key, str) or not key or len(key) > 256 for key in deletes):
        raise ValidationError("incremental deletes contain an invalid key")
    if len(set(deletes)) != len(deletes) or set(upserts).intersection(deletes):
        raise ValidationError("incremental changes contain duplicate keys")
    clean_upserts = sanitize_snapshot(upserts)
    if clean_upserts != upserts:
        raise ValidationError("incremental upserts are not privacy-sanitized")
    partitions = snapshot_partitions(snapshot)
    for key in deletes:
        partitions.pop(key, None)
    partitions.update(clean_upserts)
    return materialize_snapshot(partitions)


def _normalized_key(key: str) -> str:
    return re.sub(r"[^a-z0-9]", "", key.casefold())


def _looks_like_absolute_local_path(value: str) -> bool:
    return (
        value.startswith("/")
        or value.startswith("\\\\")
        or re.match(r"^[A-Za-z]:[\\/]", value) is not None
        or value.casefold().startswith("file://")
    )


def _is_activity_session(value: dict[str, Any]) -> bool:
    return all(
        key in value
        for key in ("id", "startedAtMs", "endedAtMs", "tokens", "models", "requests")
    )


def _valid_session_title(value: Any) -> bool:
    return (
        isinstance(value, str)
        and bool(value)
        and len(value.encode("utf-8")) <= 512
        and not any(ord(character) < 0x20 or ord(character) == 0x7F for character in value)
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
        is_session = _is_activity_session(value)
        for key, child in value.items():
            if not isinstance(key, str):
                raise ValidationError("snapshot object keys must be strings")
            if _normalized_key(key) in CREDENTIAL_KEYS:
                continue
            if key == "title" and is_session:
                clean[key] = child if _valid_session_title(child) else None
            elif key == "title" or key in PRIVACY_NULL_FIELDS:
                clean[key] = None
            else:
                clean[key] = sanitize_snapshot(child, _depth=_depth + 1)
        return clean
    if isinstance(value, list):
        return [sanitize_snapshot(item, _depth=_depth + 1) for item in value]
    if isinstance(value, str) and _looks_like_absolute_local_path(value):
        return None
    if isinstance(value, int) and not isinstance(value, bool):
        if not MIN_INT64 <= value <= MAX_INT64:
            raise ValidationError("snapshot contains an integer outside the signed 64-bit range")
        return value
    if value is None or isinstance(value, (str, float, bool)):
        if isinstance(value, float) and (value != value or value in (float("inf"), float("-inf"))):
            raise ValidationError("snapshot contains a non-finite number")
        return value
    raise ValidationError(f"snapshot contains unsupported JSON value {type(value).__name__}")


def _require_object(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValidationError(f"{label} must be an object")
    return value


def _require_array(value: Any, label: str) -> list[Any]:
    if not isinstance(value, list):
        raise ValidationError(f"{label} must be an array")
    return value


def _require_string(value: Any, label: str, *, allow_empty: bool = False) -> str:
    if not isinstance(value, str) or (not allow_empty and not value):
        raise ValidationError(f"{label} must be a string")
    return value


def _require_int64(value: Any, label: str, *, positive: bool = False) -> int:
    if (
        not isinstance(value, int)
        or isinstance(value, bool)
        or not MIN_INT64 <= value <= MAX_INT64
        or (positive and value <= 0)
    ):
        qualifier = "positive " if positive else ""
        raise ValidationError(f"{label} must be a {qualifier}signed 64-bit integer")
    return value


def _require_nonnegative_int(value: Any, label: str) -> int:
    result = _require_int64(value, label)
    if result < 0:
        raise ValidationError(f"{label} must be nonnegative")
    return result


def _require_nonnegative_number(value: Any, label: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValidationError(f"{label} must be a nonnegative finite number")
    number = float(value)
    if not math.isfinite(number) or number < 0:
        raise ValidationError(f"{label} must be a nonnegative finite number")
    return number


def _validate_tokens(value: Any, label: str) -> None:
    tokens = _require_object(value, label)
    for key in ("input", "output", "cacheRead", "cacheWrite", "reasoning"):
        _require_nonnegative_int(tokens.get(key), f"{label}.{key}")


def _validate_token_costs(value: Any, label: str) -> None:
    costs = _require_object(value, label)
    for key in ("input", "output", "cacheRead", "cacheWrite", "reasoning"):
        _require_nonnegative_number(costs.get(key), f"{label}.{key}")


def _validate_totals(value: Any, label: str) -> None:
    totals = _require_object(value, label)
    _validate_tokens(totals.get("tokens"), f"{label}.tokens")
    _require_nonnegative_number(totals.get("costUsd"), f"{label}.costUsd")
    _require_nonnegative_int(totals.get("requestCount"), f"{label}.requestCount")
    _require_nonnegative_int(totals.get("sessionCount"), f"{label}.sessionCount")
    token_costs = totals.get("tokenCosts")
    if token_costs is not None:
        _validate_token_costs(token_costs, f"{label}.tokenCosts")
    speed = totals.get("averageGenerationTokensPerSecond")
    if speed is not None:
        _require_nonnegative_number(speed, f"{label}.averageGenerationTokensPerSecond")
    first_token = totals.get("averageTimeToFirstTokenMs")
    sample_count = totals.get("firstTokenSampleCount")
    if first_token is not None:
        _require_nonnegative_number(first_token, f"{label}.averageTimeToFirstTokenMs")
    if sample_count is not None:
        _require_nonnegative_int(sample_count, f"{label}.firstTokenSampleCount")
    if (first_token is None) != (sample_count in (None, 0)):
        raise ValidationError(f"{label} has inconsistent first-token metrics")


def _validate_range(value: Any, label: str, *, generated_at_ms: int) -> None:
    summary = _require_object(value, label)
    started_at_ms = _require_int64(
        summary.get("startedAtMs"), f"{label}.startedAtMs", positive=True
    )
    if started_at_ms > generated_at_ms:
        raise ValidationError(f"{label}.startedAtMs must not follow snapshot.generatedAtMs")
    _validate_totals(summary.get("totals"), f"{label}.totals")


def _validate_daily_model(value: Any, label: str) -> None:
    model = _require_object(value, label)
    platform = model.get("platform")
    if platform is not None:
        _require_string(platform, f"{label}.platform")
    _require_string(model.get("model"), f"{label}.model", allow_empty=True)
    _require_string(model.get("provider"), f"{label}.provider", allow_empty=True)
    _validate_tokens(model.get("tokens"), f"{label}.tokens")
    _require_nonnegative_number(model.get("costUsd"), f"{label}.costUsd")
    _require_nonnegative_int(model.get("requestCount"), f"{label}.requestCount")
    _require_nonnegative_int(model.get("sessionCount"), f"{label}.sessionCount")


def _validate_day(value: Any, label: str) -> str:
    day = _require_object(value, label)
    date = _require_string(day.get("date"), f"{label}.date")
    _validate_tokens(day.get("tokens"), f"{label}.tokens")
    _require_nonnegative_number(day.get("costUsd"), f"{label}.costUsd")
    _require_nonnegative_int(day.get("requestCount"), f"{label}.requestCount")
    _require_nonnegative_int(day.get("sessionCount"), f"{label}.sessionCount")
    first_token = day.get("averageTimeToFirstTokenMs")
    sample_count = day.get("firstTokenSampleCount")
    if first_token is not None:
        _require_nonnegative_number(first_token, f"{label}.averageTimeToFirstTokenMs")
    if sample_count is not None:
        _require_nonnegative_int(sample_count, f"{label}.firstTokenSampleCount")
    if (first_token is None) != (sample_count in (None, 0)):
        raise ValidationError(f"{label} has inconsistent first-token metrics")
    models = _require_array(day.get("models", []), f"{label}.models")
    for index, model in enumerate(models):
        _validate_daily_model(model, f"{label}.models[{index}]")
    return date


def _validate_request(value: Any, label: str, *, depth: int = 0) -> None:
    if depth > 100:
        raise ValidationError("request contribution nesting exceeds 100 levels")
    request = _require_object(value, label)
    for key in ("id", "sessionId", "physicalSessionId"):
        _require_string(request.get(key), f"{label}.{key}")
    for key in ("model", "provider"):
        _require_string(request.get(key), f"{label}.{key}", allow_empty=True)
    agent = request.get("agent")
    if agent is not None:
        _require_string(agent, f"{label}.agent", allow_empty=True)
    if not isinstance(request.get("isSubagent"), bool):
        raise ValidationError(f"{label}.isSubagent must be a boolean")
    started = _require_int64(request.get("startedAtMs"), f"{label}.startedAtMs", positive=True)
    ended = _require_int64(request.get("endedAtMs"), f"{label}.endedAtMs", positive=True)
    if ended < started:
        raise ValidationError(f"{label}.endedAtMs must not precede startedAtMs")
    for key in ("durationMs", "modelDurationMs", "timeToFirstTokenMs"):
        duration = request.get(key)
        if duration is not None:
            _require_nonnegative_int(duration, f"{label}.{key}")
    _validate_tokens(request.get("tokens"), f"{label}.tokens")
    _require_nonnegative_number(request.get("costUsd"), f"{label}.costUsd")
    if request.get("costSource") not in {"unknown", "providerReported", "estimated"}:
        raise ValidationError(f"{label}.costSource is invalid")
    service_tier = request.get("serviceTier")
    if service_tier is not None and service_tier not in {"unknown", "standard", "fast", "mixed"}:
        raise ValidationError(f"{label}.serviceTier is invalid")
    platform = request.get("platform")
    if platform is not None:
        _require_string(platform, f"{label}.platform")
    contributions = request.get("contributions")
    if contributions is not None:
        for index, child in enumerate(_require_array(contributions, f"{label}.contributions")):
            _validate_request(child, f"{label}.contributions[{index}]", depth=depth + 1)


def _validate_session(value: Any, label: str) -> None:
    session = _require_object(value, label)
    _require_string(session.get("id"), f"{label}.id")
    title = session.get("title")
    if title is not None and not _valid_session_title(title):
        raise ValidationError(f"{label}.title must be a valid session name")
    started = _require_int64(session.get("startedAtMs"), f"{label}.startedAtMs", positive=True)
    ended = _require_int64(session.get("endedAtMs"), f"{label}.endedAtMs", positive=True)
    if ended < started:
        raise ValidationError(f"{label}.endedAtMs must not precede startedAtMs")
    _validate_tokens(session.get("tokens"), f"{label}.tokens")
    _require_nonnegative_number(session.get("costUsd"), f"{label}.costUsd")
    for index, model in enumerate(_require_array(session.get("models"), f"{label}.models")):
        _require_string(model, f"{label}.models[{index}]", allow_empty=True)
    for index, request in enumerate(_require_array(session.get("requests"), f"{label}.requests")):
        _validate_request(request, f"{label}.requests[{index}]")
    platform = session.get("platform")
    if platform is not None:
        _require_string(platform, f"{label}.platform")


def _validate_source(value: Any, label: str, *, generated_at_ms: int) -> str:
    source = _require_object(value, label)
    platform = _require_string(source.get("platform"), f"{label}.platform")
    _validate_totals(source.get("today"), f"{label}.today")
    if source.get("weeklySinceReset") is not None:
        _validate_range(
            source["weeklySinceReset"],
            f"{label}.weeklySinceReset",
            generated_at_ms=generated_at_ms,
        )
    if source.get("rangeTotals") is not None:
        _validate_totals(source["rangeTotals"], f"{label}.rangeTotals")
    dates: set[str] = set()
    for index, day in enumerate(_require_array(source.get("days"), f"{label}.days")):
        date = _validate_day(day, f"{label}.days[{index}]")
        if date in dates:
            raise ValidationError(f"{label}.days contains a duplicate date")
        dates.add(date)
    return platform


def _validate_memory_phase(value: Any, label: str) -> None:
    phase = _require_object(value, label)
    for key in ("total", "input", "cachedInput", "cacheWriteInput", "output", "reasoningOutput"):
        _require_nonnegative_int(phase.get(key), f"{label}.{key}")


def _validate_memory_usage(value: Any, label: str) -> None:
    memory = _require_object(value, label)
    _require_int64(memory.get("collectedFromMs"), f"{label}.collectedFromMs", positive=True)
    for key in ("lastReceivedAtMs", "lastMemoryReceivedAtMs"):
        timestamp = memory.get(key)
        if timestamp is not None:
            _require_int64(timestamp, f"{label}.{key}", positive=True)
    _require_nonnegative_int(memory.get("observationCount"), f"{label}.observationCount")
    for totals_key in ("today", "rangeTotals"):
        totals = _require_object(memory.get(totals_key), f"{label}.{totals_key}")
        _validate_memory_phase(totals.get("phase1"), f"{label}.{totals_key}.phase1")
        _validate_memory_phase(totals.get("phase2"), f"{label}.{totals_key}.phase2")
    dates: set[str] = set()
    for index, day_value in enumerate(_require_array(memory.get("days"), f"{label}.days")):
        day = _require_object(day_value, f"{label}.days[{index}]")
        date = _require_string(day.get("date"), f"{label}.days[{index}].date")
        if date in dates:
            raise ValidationError(f"{label}.days contains a duplicate date")
        dates.add(date)
        _validate_memory_phase(day.get("phase1"), f"{label}.days[{index}].phase1")
        _validate_memory_phase(day.get("phase2"), f"{label}.days[{index}].phase2")


def validate_activity_snapshot(snapshot: Any) -> dict[str, Any]:
    value = _require_object(snapshot, "snapshot")
    generated_at_ms = _require_int64(
        value.get("generatedAtMs"), "snapshot.generatedAtMs", positive=True
    )
    _validate_totals(value.get("today"), "snapshot.today")
    if value.get("rangeTotals") is not None:
        _validate_totals(value["rangeTotals"], "snapshot.rangeTotals")
    if value.get("weeklySinceReset") is not None:
        _validate_range(
            value["weeklySinceReset"],
            "snapshot.weeklySinceReset",
            generated_at_ms=generated_at_ms,
        )
    session_identities: set[tuple[str, str]] = set()
    for index, session in enumerate(_require_array(value.get("sessions"), "snapshot.sessions")):
        _validate_session(session, f"snapshot.sessions[{index}]")
        identity = (session.get("platform") or "", session["id"])
        if identity in session_identities:
            raise ValidationError("snapshot.sessions contains a duplicate identity")
        session_identities.add(identity)
    dates: set[str] = set()
    for index, day in enumerate(_require_array(value.get("days"), "snapshot.days")):
        date = _validate_day(day, f"snapshot.days[{index}]")
        if date in dates:
            raise ValidationError("snapshot.days contains a duplicate date")
        dates.add(date)
    platforms: set[str] = set()
    sources = value.get("sources")
    if sources is not None:
        for index, source in enumerate(_require_array(sources, "snapshot.sources")):
            platform = _validate_source(
                source,
                f"snapshot.sources[{index}]",
                generated_at_ms=generated_at_ms,
            )
            if platform in platforms:
                raise ValidationError("snapshot.sources contains a duplicate platform")
            platforms.add(platform)
    if value.get("memoryUsage") is not None:
        _validate_memory_usage(value["memoryUsage"], "snapshot.memoryUsage")
    return value


def validate_device(device: Any) -> dict[str, Any]:
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
    try:
        parsed_device_id = uuid.UUID(device_id)
    except ValueError as error:
        raise ValidationError("device.id must be a UUID string") from error
    if str(parsed_device_id) != device_id:
        raise ValidationError("device.id must use canonical lowercase UUID form")

    name = device["name"]
    if not isinstance(name, str) or not 1 <= len(name) <= 80 or not name.strip():
        raise ValidationError("device.name must contain 1..80 display characters")
    if any(unicodedata.category(ch) in {"Cc", "Cs"} for ch in name):
        raise ValidationError("device.name must contain 1..80 display characters")

    os_name = device["os"]
    if os_name not in OS_VALUES:
        raise ValidationError("device.os must be macos, windows, or linux")

    if "clientVersion" in device:
        client_version = device["clientVersion"]
        if (
            not isinstance(client_version, str)
            or len(client_version) > 80
            or any(unicodedata.category(ch) in {"Cc", "Cs"} for ch in client_version)
        ):
            raise ValidationError("device.clientVersion must be at most 80 display characters")
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

    device = validate_device(envelope["device"])
    if path_device_id is not None and device["id"] != path_device_id:
        raise ValidationError("device.id must match the path deviceId")

    generated_at_ms = envelope["generatedAtMs"]
    if (
        not isinstance(generated_at_ms, int)
        or isinstance(generated_at_ms, bool)
        or generated_at_ms <= 0
        or generated_at_ms > MAX_INT64
    ):
        raise ValidationError("generatedAtMs must be a positive integer")

    snapshot = envelope["snapshot"]
    if not isinstance(snapshot, dict):
        raise ValidationError("snapshot must be an object")
    try:
        _require_int64(snapshot.get("schemaVersion"), "snapshot.schemaVersion", positive=True)
    except ValidationError:
        raise ValidationError("snapshot.schemaVersion must be a positive integer")
    if snapshot.get("generatedAtMs") != generated_at_ms:
        raise ValidationError("snapshot.generatedAtMs must match generatedAtMs")
    timezone = snapshot.get("timezone")
    if (
        not isinstance(timezone, str)
        or not timezone.strip()
        or len(timezone) > 128
        or any(unicodedata.category(ch) in {"Cc", "Cs"} for ch in timezone)
    ):
        raise ValidationError("snapshot.timezone must be a non-empty string")
    if not isinstance(snapshot.get("today"), dict):
        raise ValidationError("snapshot.today must be an object")
    if not isinstance(snapshot.get("sessions"), list):
        raise ValidationError("snapshot.sessions must be an array")
    if not isinstance(snapshot.get("days"), list):
        raise ValidationError("snapshot.days must be an array")
    validate_activity_snapshot(snapshot)
    sanitized = sanitize_snapshot(snapshot)
    if enforce_privacy and sanitized != snapshot:
        raise ValidationError("snapshot is not privacy-sanitized")
    canonical_json(envelope)
    return envelope
