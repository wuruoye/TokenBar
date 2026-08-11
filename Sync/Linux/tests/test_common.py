import unittest

from tokenbar_sync.common import ValidationError, sanitize_snapshot, validate_envelope


DEVICE_ID = "11111111-1111-4111-8111-111111111111"


def envelope(snapshot=None):
    return {
        "protocolVersion": 1,
        "device": {
            "id": DEVICE_ID,
            "name": "Linux collector",
            "os": "linux",
            "clientVersion": "test/1",
        },
        "generatedAtMs": 1,
        "snapshot": snapshot if snapshot is not None else {"schemaVersion": 9},
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
        with self.assertRaisesRegex(ValidationError, "privacy-sanitized"):
            validate_envelope(envelope({"schemaVersion": 9, "promptPreview": "no"}))

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


if __name__ == "__main__":
    unittest.main()
