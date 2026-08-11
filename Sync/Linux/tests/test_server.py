import http.client
import hashlib
import json
import sqlite3
import tempfile
import threading
import time
import unittest
from pathlib import Path

from tokenbar_sync.common import MAX_BODY_BYTES, canonical_json
from tokenbar_sync.server import (
    MAX_FUTURE_CLOCK_SKEW_MS,
    SnapshotRepository,
    TokenBarHTTPServer,
    build_server,
    parse_server_token_hashes,
)


TOKEN = "local-test-token-32-characters-long"
SECOND_TOKEN = "second-local-token-32-characters-long"
DEVICE_A = "11111111-1111-4111-8111-111111111111"
DEVICE_B = "00000000-0000-4000-8000-000000000000"


def zero_tokens():
    return {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "reasoning": 0}


def zero_totals():
    return {
        "tokens": zero_tokens(),
        "costUsd": 0,
        "requestCount": 0,
        "sessionCount": 0,
    }


def make_envelope(device_id=DEVICE_A, generated=100, value=1):
    return {
        "protocolVersion": 1,
        "device": {
            "id": device_id,
            "name": f"Device {device_id[0]}",
            "os": "linux",
            "clientVersion": "test/1",
        },
        "generatedAtMs": generated,
        "snapshot": {
            "schemaVersion": 9,
            "generatedAtMs": generated,
            "timezone": "UTC",
            "today": zero_totals(),
            "sessions": [],
            "days": [],
            "value": value,
            "promptPreview": None,
        },
    }


class ServerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.database = str(Path(self.temp.name) / "sync.sqlite3")
        self.server = TokenBarHTTPServer(
            ("127.0.0.1", 0),
            SnapshotRepository(self.database),
            TOKEN,
            (hashlib.sha256(SECOND_TOKEN.encode("ascii")).digest(),),
        )
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.port = self.server.server_address[1]

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.temp.cleanup()

    def request(self, method, path, body=None, token=TOKEN, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        request_headers = dict(headers or {})
        if token is not None:
            request_headers["Authorization"] = f"Bearer {token}"
        encoded = None
        if body is not None:
            encoded = canonical_json(body).encode("utf-8")
            request_headers["Content-Type"] = "application/json"
        connection.request(method, path, body=encoded, headers=request_headers)
        response = connection.getresponse()
        raw = response.read()
        connection.close()
        return response.status, json.loads(raw)

    def put(self, value, **kwargs):
        return self.request(
            "PUT", f"/v1/snapshots/{value['device']['id']}", value, **kwargs
        )

    def test_health_is_unauthenticated(self):
        status, body = self.request("GET", "/healthz", token=None)
        self.assertEqual(status, 200)
        self.assertEqual(body, {"ok": True, "protocolVersion": 1})

    def test_v1_requires_bearer_authentication(self):
        status, _body = self.request("GET", "/v1/snapshots", token=None)
        self.assertEqual(status, 401)
        status, _body = self.request("GET", "/v1/unknown", token=None)
        self.assertEqual(status, 401)
        status, _body = self.request("GET", "/v1/snapshots?unexpected=1", token=None)
        self.assertEqual(status, 401)
        status, _body = self.request("GET", "/v1/snapshots", token="wrong")
        self.assertEqual(status, 401)
        status, _body = self.request("GET", "/v1/snapshots", token=SECOND_TOKEN)
        self.assertEqual(status, 200)
        status, _body = self.put(make_envelope(), token="wrong")
        self.assertEqual(status, 401)

    def test_create_retry_update_and_older_conflict(self):
        original = make_envelope(generated=100, value=1)
        status, created = self.put(original)
        self.assertEqual(status, 201)
        self.assertEqual(created["status"], "created")
        received = created["receivedAtMs"]

        status, retried = self.put(original)
        self.assertEqual(status, 200)
        self.assertEqual(retried, {"status": "retry", "receivedAtMs": received})

        status, _body = self.put(make_envelope(generated=99, value=2))
        self.assertEqual(status, 409)
        status, _body = self.put(make_envelope(generated=100, value=2))
        self.assertEqual(status, 409)

        status, updated = self.put(make_envelope(generated=101, value=3))
        self.assertEqual(status, 200)
        self.assertEqual(updated["status"], "updated")

        status, listed = self.request("GET", "/v1/snapshots")
        self.assertEqual(status, 200)
        self.assertEqual(len(listed["snapshots"]), 1)
        self.assertEqual(listed["snapshots"][0]["generatedAtMs"], 101)
        self.assertEqual(listed["snapshots"][0]["snapshot"]["value"], 3)

    def test_latest_per_device_has_stable_device_id_order(self):
        self.assertEqual(self.put(make_envelope(DEVICE_A, 10))[0], 201)
        self.assertEqual(self.put(make_envelope(DEVICE_B, 20))[0], 201)
        status, listed = self.request("GET", "/v1/snapshots")
        self.assertEqual(status, 200)
        ids = [item["device"]["id"] for item in listed["snapshots"]]
        self.assertEqual(ids, sorted(ids))

    def test_durable_across_repository_reopen(self):
        self.assertEqual(self.put(make_envelope())[0], 201)
        reopened = SnapshotRepository(self.database)
        self.assertEqual(reopened.list_snapshots()[0]["device"]["id"], DEVICE_A)

    def test_in_memory_repository_keeps_its_schema_and_rows(self):
        repository = SnapshotRepository(":memory:")
        repository.upsert(make_envelope())
        self.assertEqual(repository.list_snapshots()[0]["device"]["id"], DEVICE_A)

    def test_download_resanitizes_stored_snapshot(self):
        self.assertEqual(self.put(make_envelope())[0], 201)
        connection = sqlite3.connect(self.database)
        snapshot = make_envelope()["snapshot"]
        snapshot["promptPreview"] = "must not leave storage"
        connection.execute(
            "UPDATE snapshots SET snapshot_json = ? WHERE device_id = ?",
            (canonical_json(snapshot), DEVICE_A),
        )
        connection.commit()
        connection.close()

        status, listed = self.request("GET", "/v1/snapshots")

        self.assertEqual(status, 200)
        self.assertIsNone(listed["snapshots"][0]["snapshot"]["promptPreview"])

    def test_validation_and_privacy_rejections(self):
        mismatch = make_envelope()
        status, _ = self.request(
            "PUT", f"/v1/snapshots/{DEVICE_B}", mismatch
        )
        self.assertEqual(status, 400)

        bad_os = make_envelope()
        bad_os["device"]["os"] = "freebsd"
        self.assertEqual(self.put(bad_os)[0], 400)

        unsanitized = make_envelope()
        unsanitized["snapshot"]["sessionPath"] = "/private/session.jsonl"
        self.assertEqual(self.put(unsanitized)[0], 400)

    def test_request_size_limit_is_enforced_before_body_read(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        connection.putrequest("PUT", f"/v1/snapshots/{DEVICE_A}")
        connection.putheader("Authorization", f"Bearer {TOKEN}")
        connection.putheader("Content-Type", "application/json")
        connection.putheader("Content-Length", str(MAX_BODY_BYTES + 1))
        connection.endheaders()
        response = connection.getresponse()
        response.read()
        connection.close()
        self.assertEqual(response.status, 413)

    def test_future_generated_timestamp_is_rejected_before_storage(self):
        future = time.time_ns() // 1_000_000 + MAX_FUTURE_CLOCK_SKEW_MS + 10_000
        self.assertEqual(self.put(make_envelope(generated=future))[0], 400)

    def test_server_requires_a_strong_token_and_loopback_by_default(self):
        with self.assertRaisesRegex(ValueError, "32..512"):
            build_server("127.0.0.1:18765", ":memory:", "short")
        with self.assertRaisesRegex(ValueError, "loopback"):
            build_server("0.0.0.0:18765", ":memory:", TOKEN)
        with self.assertRaisesRegex(ValueError, "required"):
            build_server("127.0.0.1:18765", ":memory:", "")
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            parse_server_token_hashes("not-a-hash")
        digest = hashlib.sha256(SECOND_TOKEN.encode("ascii")).hexdigest()
        self.assertEqual(
            parse_server_token_hashes(digest),
            (bytes.fromhex(digest),),
        )


if __name__ == "__main__":
    unittest.main()
