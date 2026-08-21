import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REMOTE_APP = ROOT / "backend/api/src/streaming_api/static/app.js"
REMOTE_HTML = ROOT / "backend/api/src/streaming_api/static/index.html"
LOCAL_HTML = ROOT / "server/webapi/static/index.html"


class FrontendContractTests(unittest.TestCase):
    def test_both_portals_load_shared_http_client(self):
        self.assertIn("api-client.js", LOCAL_HTML.read_text(encoding="utf-8"))
        self.assertIn("api-client.js", REMOTE_HTML.read_text(encoding="utf-8"))

    def test_both_login_forms_support_keyboard_and_busy_feedback(self):
        for path in (LOCAL_HTML, REMOTE_HTML):
            html = path.read_text(encoding="utf-8")
            self.assertIn('id="login-form"', html)
            self.assertIn('type="submit"', html)
            self.assertIn('autofocus', html)
            self.assertIn('aria-describedby="login-status login-error"', html)
        for path in (ROOT / "server/webapi/static/app.js", REMOTE_APP):
            source = path.read_text(encoding="utf-8")
            self.assertIn("loginInFlight", source)
            self.assertIn("focusLoginField", source)
            self.assertIn("submitLoginFromKeyboard", source)
            self.assertIn("loginForm.requestSubmit", source)
            self.assertIn('form.setAttribute("aria-busy"', source)
            self.assertIn("Iniciando sesión", source)

    def test_remote_uses_controlled_polling_and_freshness_thresholds(self):
        source = REMOTE_APP.read_text(encoding="utf-8")
        self.assertIn("Promise.allSettled", source)
        self.assertIn("remoteRefreshInFlight", source)
        self.assertIn("remotePollTimer", source)
        self.assertIn("age > 90", source)
        self.assertIn("age > 30", source)
        self.assertNotIn("new EventSource", source)
        self.assertNotIn("setInterval(refresh", source)

    def test_remote_has_full_operational_sections_and_secret_placeholders(self):
        html = REMOTE_HTML.read_text(encoding="utf-8")
        for section_id in (
            "btn-scan-devices",
            "btn-scan-audio",
            "cfg-platform",
            "cfg-bitrate",
            "gpu-encoder-toggle",
            "cfg-overlay-timestamp",
            "config-form",
        ):
            self.assertIn(f'id="{section_id}"', html)
        self.assertIn("Configurada; dejar vacío para conservar", REMOTE_APP.read_text(encoding="utf-8"))
        self.assertIn("Configurada; dejar vacío para conservar", (ROOT / "server/webapi/static/app.js").read_text(encoding="utf-8"))

    def test_remote_state_is_rendered_without_raw_json_or_service_html(self):
        source = REMOTE_APP.read_text(encoding="utf-8")
        self.assertIn('textContent = JSON.stringify(diagnostics', source)
        self.assertIn("servicesEl.replaceChildren()", source)
        self.assertNotIn('id="media-view"', REMOTE_HTML.read_text(encoding="utf-8"))
        self.assertNotIn('id="config-view"', REMOTE_HTML.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
