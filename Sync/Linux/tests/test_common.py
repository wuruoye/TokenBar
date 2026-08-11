import unittest

from tokenbar_sync.common import (
    ValidationError,
    json_loads_strict,
    sanitize_snapshot,
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
        self.assertEqual(clean["workspaceLabel"], "safe-label")
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


if __name__ == "__main__":
    unittest.main()
