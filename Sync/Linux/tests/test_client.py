import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from tokenbar_sync.client import (
    MAX_WEEKLY_RESET_AGE_MS,
    SyncHTTPError,
    _base_url,
    build_envelope,
    command_upload,
    collect_helper_snapshot,
    download_snapshots,
    extract_weekly_resets,
    fetch_weekly_resets,
    load_or_create_device_id,
    load_snapshot,
)
from tokenbar_sync.common import ValidationError
def zero_tokens():
    return {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "reasoning": 0}


def zero_totals():
    return {
        "tokens": zero_tokens(),
        "costUsd": 0,
        "requestCount": 0,
        "sessionCount": 0,
    }


def minimal_snapshot(generated=123, timezone="UTC"):
    return {
        "schemaVersion": 9,
        "generatedAtMs": generated,
        "timezone": timezone,
        "today": zero_totals(),
        "sessions": [],
        "days": [],
    }


class ClientTests(unittest.TestCase):
    def test_device_id_is_created_once_with_private_mode(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config" / "device-id"
            first = load_or_create_device_id(None, path)
            second = load_or_create_device_id(None, path)
            self.assertEqual(first, second)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_snapshot_load_and_envelope_are_sanitized(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "activity.json"
            path.write_text(
                json.dumps(
                    {
                        **minimal_snapshot(),
                        "schemaVersion": 8,
                        "sessions": [{
                            "id": "session",
                            "title": "private",
                            "workspacePath": "/private/project",
                            "workspaceLabel": "project",
                            "startedAtMs": 1,
                            "endedAtMs": 2,
                            "tokens": zero_tokens(),
                            "costUsd": 0,
                            "models": ["gpt-test"],
                            "requests": [{
                                "id": "request",
                                "sessionId": "session",
                                "physicalSessionId": "session",
                                "isSubagent": False,
                                "model": "gpt-test",
                                "provider": "openai",
                                "startedAtMs": 1,
                                "endedAtMs": 2,
                                "durationMs": 1,
                                "tokens": zero_tokens(),
                                "costUsd": 0,
                                "costSource": "estimated",
                                "promptPreview": "private prompt",
                                "outputPreview": "private output",
                                "sessionPath": "/private/session.jsonl",
                            }],
                        }],
                        "credentials": {"token": "private"},
                    }
                ),
                encoding="utf-8",
            )
            snapshot = load_snapshot(path)
            self.assertEqual(snapshot["schemaVersion"], 8)
            session = snapshot["sessions"][0]
            self.assertIsNone(session["title"])
            self.assertIsNone(session["workspacePath"])
            self.assertEqual(session["workspaceLabel"], "project")
            self.assertIsNone(session["requests"][0]["promptPreview"])
            self.assertIsNone(session["requests"][0]["outputPreview"])
            self.assertIsNone(session["requests"][0]["sessionPath"])
            self.assertNotIn("credentials", snapshot)

            value = build_envelope(
                snapshot,
                device_id="11111111-1111-4111-8111-111111111111",
                device_name="Linux",
                generated_at_ms=123,
                client_version="test/1",
            )
            self.assertEqual(value["generatedAtMs"], 123)
            self.assertEqual(value["device"]["os"], "linux")
            self.assertEqual(value["snapshot"]["schemaVersion"], 8)

    @patch("tokenbar_sync.client.subprocess.run")
    def test_helper_uses_explicit_utc_and_preserves_helper_schema(self, run):
        run.return_value = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=json.dumps(
                minimal_snapshot(generated=456)
            ).encode(),
            stderr=b"",
        )

        snapshot = collect_helper_snapshot("tokenbar-helper", 30, "utc")

        self.assertEqual(snapshot["schemaVersion"], 9)
        run.assert_called_once()
        self.assertEqual(
            run.call_args.args[0],
            [
                "tokenbar-helper",
                "--days",
                "30",
                "--statistics-timezone",
                "utc",
            ],
        )
        self.assertNotIn("TOKENBAR_SYNC_TOKEN", run.call_args.kwargs["env"])

    def test_plain_http_is_restricted_to_loopback(self):
        self.assertEqual(_base_url("http://127.0.0.1:18765"), "http://127.0.0.1:18765")
        self.assertEqual(_base_url("http://[::1]:18765"), "http://[::1]:18765")
        with self.assertRaisesRegex(ValidationError, "must use HTTPS"):
            _base_url("http://sync.example.com")

    @patch("tokenbar_sync.client._common_values")
    @patch("tokenbar_sync.client.fetch_weekly_resets", return_value={})
    @patch("tokenbar_sync.client.upload_envelope")
    def test_conflict_collects_fresh_again_on_the_next_invocation(
        self, upload, _fetch_resets, common_values
    ):
        common_values.return_value = (
            "11111111-1111-4111-8111-111111111111",
            "Linux",
            minimal_snapshot(generated=789),
        )
        upload.side_effect = SyncHTTPError(409)
        with patch.dict(os.environ, {"TOKENBAR_SYNC_TOKEN": "test-token"}):
            args = SimpleNamespace(
                token_file=None,
                url="https://sync.example.com",
                client_version="test/1",
            )

            for _ in range(2):
                with self.assertRaisesRegex(RuntimeError, "collect a fresh snapshot"):
                    command_upload(args)

            self.assertEqual(common_values.call_count, 2)

    @patch("tokenbar_sync.client.subprocess.run")
    def test_helper_maps_all_three_platform_weekly_resets(self, run):
        run.return_value = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=json.dumps(
                minimal_snapshot(generated=456)
            ).encode(),
            stderr=b"",
        )

        collect_helper_snapshot(
            "tokenbar-helper",
            30,
            "utc",
            {"codex": 101, "claude": 202, "grok": 303},
        )

        self.assertEqual(
            run.call_args.args[0],
            [
                "tokenbar-helper",
                "--days",
                "30",
                "--statistics-timezone",
                "utc",
                "--weekly-reset-ms",
                "101",
                "--claude-weekly-reset-ms",
                "202",
                "--grok-weekly-reset-ms",
                "303",
            ],
        )

    def test_extracts_each_platform_from_latest_valid_received_snapshot(self):
        response = {
            "protocolVersion": 1,
            "snapshots": [
                {
                    "generatedAtMs": 300,
                    "receivedAtMs": 300,
                    "snapshot": {
                        "generatedAtMs": 300,
                        "weeklySinceReset": {"startedAtMs": 50},
                        "sources": [
                            {
                                "platform": "codex",
                                "weeklySinceReset": {"startedAtMs": 100},
                            },
                            {
                                "platform": "claude",
                                "weeklySinceReset": {"startedAtMs": 2_000},
                            },
                        ],
                    },
                },
                {
                    "generatedAtMs": 200,
                    "receivedAtMs": 200,
                    "snapshot": {
                        "generatedAtMs": 200,
                        "sources": [
                            {
                                "platform": "claude",
                                "weeklySinceReset": {"startedAtMs": 200},
                            },
                            {
                                "platform": "grok",
                                "weeklySinceReset": {"startedAtMs": 180},
                            },
                        ]
                    },
                },
            ],
        }
        self.assertEqual(
            extract_weekly_resets(response, now_ms=1_000),
            {"codex": 100, "claude": 200, "grok": 180},
        )

    def test_invalid_and_future_weekly_resets_are_ignored(self):
        response = {
            "protocolVersion": 1,
            "snapshots": [
                {
                    "generatedAtMs": 10,
                    "receivedAtMs": 10,
                    "snapshot": {
                        "generatedAtMs": 10,
                        "weeklySinceReset": {"startedAtMs": 0},
                        "sources": [
                            {"platform": "codex", "weeklySinceReset": {"startedAtMs": True}},
                            {"platform": "claude", "weeklySinceReset": {"startedAtMs": -1}},
                            {"platform": "grok", "weeklySinceReset": {"startedAtMs": 1_001}},
                        ],
                    },
                }
            ],
        }
        self.assertEqual(extract_weekly_resets(response, now_ms=1_000), {})

    def test_source_codex_reset_wins_before_legacy_top_level_fallback(self):
        response = {
            "protocolVersion": 1,
            "snapshots": [
                {
                    "generatedAtMs": 300,
                    "receivedAtMs": 300,
                    "snapshot": {
                        "generatedAtMs": 300,
                        "weeklySinceReset": {"startedAtMs": 50},
                        "sources": [],
                    },
                },
                {
                    "generatedAtMs": 200,
                    "receivedAtMs": 200,
                    "snapshot": {
                        "generatedAtMs": 200,
                        "sources": [
                            {
                                "platform": "codex",
                                "weeklySinceReset": {"startedAtMs": 100},
                            }
                        ]
                    },
                },
            ],
        }

        self.assertEqual(
            extract_weekly_resets(response, now_ms=1_000),
            {"codex": 100},
        )

    def test_stale_latest_reset_does_not_hide_an_older_current_reset(self):
        now_ms = 1_000_000_000
        response = {
            "protocolVersion": 1,
            "snapshots": [
                {
                    "generatedAtMs": now_ms - 1,
                    "receivedAtMs": 300,
                    "snapshot": {
                        "generatedAtMs": now_ms - 1,
                        "sources": [{
                            "platform": "codex",
                            "weeklySinceReset": {
                                "startedAtMs": now_ms - MAX_WEEKLY_RESET_AGE_MS - 1,
                            },
                        }],
                    },
                },
                {
                    "generatedAtMs": now_ms - 2,
                    "receivedAtMs": 200,
                    "snapshot": {
                        "generatedAtMs": now_ms - 2,
                        "sources": [{
                            "platform": "codex",
                            "weeklySinceReset": {"startedAtMs": now_ms - 1_000},
                        }],
                    },
                },
            ],
        }

        self.assertEqual(
            extract_weekly_resets(response, now_ms=now_ms),
            {"codex": now_ms - 1_000},
        )

    def test_no_remote_snapshot_data_degrades_to_no_reset_flags(self):
        self.assertEqual(
            extract_weekly_resets({"protocolVersion": 1, "snapshots": []}),
            {},
        )

    @patch("tokenbar_sync.client._request_json")
    def test_snapshot_download_uses_64_mib_response_limit(self, request_json):
        request_json.return_value = (200, {"protocolVersion": 1, "snapshots": []})
        download_snapshots("https://sync.invalid", "test-token")
        self.assertEqual(request_json.call_args.kwargs["response_limit"], 64 * 1024 * 1024)

    @patch("tokenbar_sync.client.download_snapshots")
    def test_weekly_preflight_failure_degrades_to_no_reset_flags(self, download):
        download.side_effect = RuntimeError("unavailable")
        self.assertEqual(fetch_weekly_resets("https://sync.invalid", "test-token"), {})

    def test_envelope_defaults_to_helper_generated_timestamp(self):
        snapshot = minimal_snapshot(generated=789)
        value = build_envelope(
            snapshot,
            device_id="11111111-1111-4111-8111-111111111111",
            device_name="Linux",
        )
        self.assertEqual(value["generatedAtMs"], 789)

    @patch("tokenbar_sync.client.subprocess.run")
    def test_utc_collection_rejects_mislabeled_helper_snapshot(self, run):
        run.return_value = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=json.dumps(
                minimal_snapshot(generated=456, timezone="Europe/Paris")
            ).encode(),
            stderr=b"",
        )
        with self.assertRaisesRegex(ValidationError, "snapshot.timezone"):
            collect_helper_snapshot("tokenbar-helper", 30, "utc")


if __name__ == "__main__":
    unittest.main()
