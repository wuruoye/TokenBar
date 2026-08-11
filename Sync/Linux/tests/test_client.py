import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from tokenbar_sync.client import (
    build_envelope,
    collect_helper_snapshot,
    download_snapshots,
    extract_weekly_resets,
    fetch_weekly_resets,
    load_or_create_device_id,
    load_snapshot,
)
from tokenbar_sync.common import ValidationError


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
                        "schemaVersion": 8,
                        "generatedAtMs": 123,
                        "timezone": "UTC",
                        "today": {},
                        "sessions": [
                            {
                                "title": "private",
                                "workspacePath": "/private/project",
                                "workspaceLabel": "project",
                                "request": {
                                    "promptPreview": "private prompt",
                                    "outputPreview": "private output",
                                    "sessionPath": "/private/session.jsonl",
                                },
                            }
                        ],
                        "days": [],
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
            self.assertIsNone(session["request"]["promptPreview"])
            self.assertIsNone(session["request"]["outputPreview"])
            self.assertIsNone(session["request"]["sessionPath"])
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
                {
                    "schemaVersion": 9,
                    "generatedAtMs": 456,
                    "timezone": "UTC",
                    "today": {},
                    "sessions": [],
                    "days": [],
                }
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

    @patch("tokenbar_sync.client.subprocess.run")
    def test_helper_maps_all_three_platform_weekly_resets(self, run):
        run.return_value = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=json.dumps(
                {
                    "schemaVersion": 9,
                    "generatedAtMs": 456,
                    "timezone": "UTC",
                    "today": {},
                    "sessions": [],
                    "days": [],
                }
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
                        "sources": [
                            {
                                "platform": "claude",
                                "weeklySinceReset": {"startedAtMs": 200},
                            },
                            {
                                "platform": "grok",
                                "weeklySinceReset": {"startedAtMs": 300},
                            },
                        ]
                    },
                },
            ],
        }
        self.assertEqual(
            extract_weekly_resets(response, now_ms=1_000),
            {"codex": 100, "claude": 200, "grok": 300},
        )

    def test_invalid_and_future_weekly_resets_are_ignored(self):
        response = {
            "protocolVersion": 1,
            "snapshots": [
                {
                    "generatedAtMs": 10,
                    "receivedAtMs": 10,
                    "snapshot": {
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
        snapshot = {
            "schemaVersion": 9,
            "generatedAtMs": 789,
            "timezone": "UTC",
            "today": {},
            "sessions": [],
            "days": [],
        }
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
                {
                    "schemaVersion": 9,
                    "generatedAtMs": 456,
                    "timezone": "Europe/Paris",
                    "today": {},
                    "sessions": [],
                    "days": [],
                }
            ).encode(),
            stderr=b"",
        )
        with self.assertRaisesRegex(ValidationError, "snapshot.timezone"):
            collect_helper_snapshot("tokenbar-helper", 30, "utc")


if __name__ == "__main__":
    unittest.main()
