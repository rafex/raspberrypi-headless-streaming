import sys
import unittest
from unittest.mock import patch
from pathlib import Path

from fastapi import HTTPException
from starlette.requests import Request


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend/api/src"))

from streaming_api.auth import (  # noqa: E402
    _validate_mtls,
    create_portal_session,
    portal_session_claims,
    validate_portal_session,
)
from streaming_api.settings import settings  # noqa: E402


def request_with_headers(*headers: tuple[str, str]) -> Request:
    return Request(
        {
            "type": "http",
            "method": "GET",
            "path": "/",
            "headers": [(key.encode(), value.encode()) for key, value in headers],
        }
    )


class MtlsValidationTests(unittest.TestCase):
    def test_verify_header_alone_is_not_trusted(self):
        request = request_with_headers(("x-ssl-client-verify", "SUCCESS"))

        with self.assertRaises(HTTPException) as context:
            _validate_mtls(request)

        self.assertEqual(context.exception.status_code, 401)

    def test_forwarded_client_certificate_is_trusted(self):
        request = request_with_headers(
            ("x-ssl-client-verify", "SUCCESS"),
            ("x-ssl-client-cert", "base64-certificate"),
            ("x-ssl-client-dn", "CN=raspi3b"),
        )

        self.assertEqual(_validate_mtls(request), ("CN=raspi3b", ""))


class PortalSessionTests(unittest.TestCase):
    def test_portal_session_contains_csrf_and_expires_in_two_hours(self):
        with (
            patch.object(settings, "portal_session_secret", "test-session-secret"),
            patch.object(settings, "portal_session_ttl_seconds", 7_200),
            patch("streaming_api.auth.time.time", return_value=1_000),
        ):
            token, expires_at, csrf_token = create_portal_session()

        self.assertEqual(expires_at, 8_200)
        self.assertTrue(csrf_token)
        with patch.object(settings, "portal_session_secret", "test-session-secret"), patch(
            "streaming_api.auth.time.time", return_value=1_001
        ):
            self.assertTrue(validate_portal_session(token))
            self.assertEqual(portal_session_claims(token)["csrf"], csrf_token)

        with patch.object(settings, "portal_session_secret", "test-session-secret"), patch(
            "streaming_api.auth.time.time", return_value=8_200
        ):
            self.assertFalse(validate_portal_session(token))


if __name__ == "__main__":
    unittest.main()
