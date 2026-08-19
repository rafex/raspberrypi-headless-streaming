import sys
import unittest
from pathlib import Path

from fastapi import HTTPException
from starlette.requests import Request


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend/api/src"))

from streaming_api.auth import _validate_mtls  # noqa: E402


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


if __name__ == "__main__":
    unittest.main()
