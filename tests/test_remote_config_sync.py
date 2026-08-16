import importlib.util
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def load_module(name: str, relative_path: str):
    path = ROOT / relative_path
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class RemoteConfigSyncTests(unittest.TestCase):
    def test_agent_applies_all_overlay_controls(self):
        agent = load_module("backend_control_agent", "scripts/backend-control-agent.py")
        config = {
            "OVERLAY_LOGO_ENABLED": "false",
            "OVERLAY_BANNER_ENABLED": "true",
            "OVERLAY_TEXT_ENABLED": "false",
            "OVERLAY_TIMESTAMP_POS": "br",
        }

        with tempfile.TemporaryDirectory() as directory:
            env_path = Path(directory) / "streaming.env"
            changed = agent.apply_config(env_path, config)

            self.assertEqual(set(changed), set(config))
            self.assertEqual(agent.read_env(env_path), config)

    def test_health_reporter_exposes_all_overlay_controls(self):
        reporter = load_module("health_reporter", "scripts/health-reporter.py")
        config = {
            "OVERLAY_LOGO_ENABLED": "false",
            "OVERLAY_BANNER_ENABLED": "true",
            "OVERLAY_TEXT_ENABLED": "false",
            "OVERLAY_TIMESTAMP": "true",
            "OVERLAY_TIMESTAMP_POS": "br",
        }

        with tempfile.TemporaryDirectory() as directory:
            reporter.STREAMING_ENV = Path(directory) / "streaming.env"
            reporter.STREAMING_ENV.write_text(
                "\n".join(f"{key}={value}" for key, value in config.items()) + "\n",
                encoding="utf-8",
            )

            reported = reporter.safe_stream_config()

            for key, value in config.items():
                self.assertEqual(reported[key], value)


if __name__ == "__main__":
    unittest.main()
