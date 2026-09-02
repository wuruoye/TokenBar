import unittest

from tokenbar_sync.common import (
    ValidationError,
    apply_partition_delta,
    incremental_delta,
    json_loads_strict,
    materialize_snapshot,
    partition_manifest,
    sanitize_snapshot,
    snapshot_partitions,
    validate_envelope,
)


DEVICE_ID = "11111111-1111-4111-8111-111111111111"


def zero_tokens():
    return {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "reasoning": 0}


def zero_totals():
    return {
        "tokens": zero_tokens(),
        "costUsd": 0,
        "requestCount": 0,
        "sessionCount": 0,
    }


def envelope(snapshot=None):
    default_snapshot = {
        "schemaVersion": 9,
        "generatedAtMs": 1,
        "timezone": "UTC",
        "today": zero_totals(),
        "sessions": [],
        "days": [],
    }
    return {
        "protocolVersion": 1,
        "device": {
            "id": DEVICE_ID,
            "name": "Linux collector",
            "os": "linux",
            "clientVersion": "test/1",
        },
        "generatedAtMs": 1,
        "snapshot": snapshot if snapshot is not None else default_snapshot,
    }


class CommonTests(unittest.TestCase):
    def test_incremental_partitions_round_trip_and_replace_history(self):
        snapshot = envelope()["snapshot"]
        snapshot["days"] = [{
            "date": "2026-08-11",
            "tokens": zero_tokens(),
            "costUsd": 0,
            "requestCount": 1,
            "sessionCount": 0,
            "models": [],
        }]
        snapshot["sessions"] = [{
            "id": "session/a",
            "platform": "codex",
            "startedAtMs": 1,
            "endedAtMs": 2,
            "tokens": zero_tokens(),
            "costUsd": 0,
            "models": [],
            "requests": [],
        }]
        previous = snapshot_partitions(snapshot)
        rebuilt = materialize_snapshot(previous)
        self.assertEqual(rebuilt, snapshot)

        current = dict(snapshot)
        current["generatedAtMs"] = 2
        current["days"] = [{**snapshot["days"][0], "requestCount": 2}]
        current["sessions"] = []
        current_parts = snapshot_partitions(current)
        upserts, deletes, manifest = incremental_delta(
            current_parts,
            partition_manifest(previous),
        )
        self.assertIn("summary", upserts)
        self.assertEqual(len(deletes), 1)
        self.assertEqual(apply_partition_delta(snapshot, upserts, deletes), current)
        self.assertEqual(manifest, partition_manifest(current_parts))

    def test_incremental_delta_rejects_private_content(self):
        snapshot = envelope()["snapshot"]
        with self.assertRaisesRegex(ValidationError, "privacy-sanitized"):
            apply_partition_delta(
                snapshot,
                {"summary": {"promptPreview": "private"}},
                [],
            )

    def test_recursive_sanitizer(self):
        source = {
            "schemaVersion": 9,
            "request": {
                "promptPreview": "private prompt",
                "outputPreview": "private answer",
                "sessionPath": "/private/session.jsonl",
                "nested": [{"workspacePath": "C:\\Users\\example", "title": "secret"}],
            },
            "workspaceLabel": "safe-label",
            "api_key": "credential-value",
            "authToken": "credential-value",
            "tokens": {"output": 42},
            "unknownPath": "/private/absolute/path",
        }
        clean = sanitize_snapshot(source)
        self.assertEqual(clean["request"]["promptPreview"], None)
        self.assertEqual(clean["request"]["outputPreview"], None)
        self.assertEqual(clean["request"]["sessionPath"], None)
        self.assertEqual(clean["request"]["nested"][0]["workspacePath"], None)
        self.assertEqual(clean["request"]["nested"][0]["title"], None)
        self.assertIsNone(clean["workspaceLabel"])
        self.assertNotIn("api_key", clean)
        self.assertNotIn("authToken", clean)
        self.assertEqual(clean["tokens"]["output"], 42)
        self.assertIsNone(clean["unknownPath"])

    def test_validate_rejects_unsanitized_snapshot(self):
        value = envelope()
        value["snapshot"]["promptPreview"] = "no"
        with self.assertRaisesRegex(ValidationError, "privacy-sanitized"):
            validate_envelope(value)

    def test_strict_json_rejects_duplicate_keys_and_wide_integers(self):
        with self.assertRaisesRegex(ValueError, "duplicate JSON object key"):
            json_loads_strict('{"value":1,"value":2}')
        with self.assertRaisesRegex(ValidationError, "signed 64-bit"):
            sanitize_snapshot({"value": 2**63})

    def test_validate_contract_fields(self):
        valid = envelope()
        self.assertIs(validate_envelope(valid, path_device_id=DEVICE_ID), valid)
        cases = []
        wrong_protocol = envelope()
        wrong_protocol["protocolVersion"] = 2
        cases.append(wrong_protocol)
        wrong_path = envelope()
        cases.append((wrong_path, "22222222-2222-4222-8222-222222222222"))
        wrong_os = envelope()
        wrong_os["device"]["os"] = "freebsd"
        cases.append(wrong_os)
        zero_time = envelope()
        zero_time["generatedAtMs"] = 0
        cases.append(zero_time)
        array_snapshot = envelope()
        array_snapshot["snapshot"] = []
        cases.append(array_snapshot)
        bad_name = envelope()
        bad_name["device"]["name"] = "\n"
        cases.append(bad_name)
        uppercase_id = envelope()
        uppercase_device_id = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
        uppercase_id["device"]["id"] = uppercase_device_id
        cases.append((uppercase_id, uppercase_device_id))
        mismatched_snapshot_time = envelope()
        mismatched_snapshot_time["snapshot"]["generatedAtMs"] = 2
        cases.append(mismatched_snapshot_time)
        extra_field = envelope()
        extra_field["token"] = "no"
        cases.append(extra_field)
        for case in cases:
            with self.subTest(case=case):
                if isinstance(case, tuple):
                    value, path_id = case
                else:
                    value, path_id = case, DEVICE_ID
                with self.assertRaises(ValidationError):
                    validate_envelope(value, path_device_id=path_id)

    def test_validate_rejects_a_snapshot_the_mac_cannot_decode(self):
        value = envelope()
        value["snapshot"]["today"] = {}
        with self.assertRaisesRegex(ValidationError, "snapshot.today.tokens"):
            validate_envelope(value, path_device_id=DEVICE_ID)

        value = envelope()
        value["snapshot"]["today"]["requestCount"] = -1
        with self.assertRaisesRegex(ValidationError, "must be nonnegative"):
            validate_envelope(value, path_device_id=DEVICE_ID)

        invalid_cases = []

        empty_session_id = envelope()
        empty_session_id["snapshot"]["sessions"] = [{
            "id": "",
            "startedAtMs": 1,
            "endedAtMs": 2,
            "tokens": zero_tokens(),
            "costUsd": 0,
            "models": [],
            "requests": [],
        }]
        invalid_cases.append(empty_session_id)

        invalid_agent_type = envelope()
        invalid_agent_type["snapshot"]["sessions"] = [{
            "id": "session",
            "startedAtMs": 1,
            "endedAtMs": 2,
            "tokens": zero_tokens(),
            "costUsd": 0,
            "models": [],
            "requests": [{
                "id": "request",
                "sessionId": "session",
                "physicalSessionId": "physical",
                "isSubagent": False,
                "agent": 1,
                "model": "",
                "provider": "",
                "startedAtMs": 1,
                "endedAtMs": 2,
                "tokens": zero_tokens(),
                "costUsd": 0,
                "costSource": "unknown",
            }],
        }]
        invalid_cases.append(invalid_agent_type)

        duplicate_dates = envelope()
        day = {
            "date": "2026-08-11",
            "tokens": zero_tokens(),
            "costUsd": 0,
            "requestCount": 0,
            "sessionCount": 0,
            "models": [],
        }
        duplicate_dates["snapshot"]["days"] = [day, dict(day)]
        invalid_cases.append(duplicate_dates)

        future_range = envelope()
        future_range["snapshot"]["weeklySinceReset"] = {
            "startedAtMs": future_range["generatedAtMs"] + 1,
            "totals": zero_totals(),
        }
        invalid_cases.append(future_range)

        wide_schema = envelope()
        wide_schema["snapshot"]["schemaVersion"] = 2**63
        invalid_cases.append(wide_schema)

        control_timezone = envelope()
        control_timezone["snapshot"]["timezone"] = "UTC\n"
        invalid_cases.append(control_timezone)

        for invalid in invalid_cases:
            with self.subTest(invalid=invalid):
                with self.assertRaises(ValidationError):
                    validate_envelope(invalid, path_device_id=DEVICE_ID)

    def test_validate_timing_summary_contract(self):
        valid = envelope()
        valid["snapshot"]["today"].update({
            "tokens": {**zero_tokens(), "output": 100},
            "averageGenerationTokensPerSecond": 50.0,
            "timedGeneratedTokens": 100,
            "totalModelDurationMs": 2_000,
            "timedRequestCount": 1,
        })
        self.assertIs(validate_envelope(valid, path_device_id=DEVICE_ID), valid)

        partial = envelope()
        partial["snapshot"]["today"]["timedGeneratedTokens"] = 100
        with self.assertRaisesRegex(ValidationError, "all timing summary fields"):
            validate_envelope(partial, path_device_id=DEVICE_ID)

        inconsistent = envelope()
        inconsistent["snapshot"]["today"].update({
            "tokens": {**zero_tokens(), "output": 100},
            "averageGenerationTokensPerSecond": 10.0,
            "timedGeneratedTokens": 100,
            "totalModelDurationMs": 2_000,
            "timedRequestCount": 1,
        })
        with self.assertRaisesRegex(ValidationError, "inconsistent timing totals"):
            validate_envelope(inconsistent, path_device_id=DEVICE_ID)

        invalid_day = envelope()
        invalid_day["snapshot"]["days"] = [{
            "date": "2026-08-11",
            "tokens": zero_tokens(),
            "costUsd": 0,
            "requestCount": 1,
            "sessionCount": 1,
            "timedGeneratedTokens": 100,
            "totalModelDurationMs": 0,
            "timedRequestCount": 1,
            "models": [],
        }]
        with self.assertRaisesRegex(ValidationError, "positive token and duration totals"):
            validate_envelope(invalid_day, path_device_id=DEVICE_ID)

        excessive = envelope()
        excessive["snapshot"]["today"].update({
            "averageGenerationTokensPerSecond": 50.0,
            "timedGeneratedTokens": 100,
            "totalModelDurationMs": 2_000,
            "timedRequestCount": 1,
        })
        with self.assertRaisesRegex(ValidationError, "more tokens than it contains"):
            validate_envelope(excessive, path_device_id=DEVICE_ID)


if __name__ == "__main__":
    unittest.main()
