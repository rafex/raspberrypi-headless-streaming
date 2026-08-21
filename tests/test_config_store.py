import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("config_store", ROOT / "server/webapi/config_store.py")
config_store = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(config_store)


BASE = {
    "platform": "youtube",
    "width": 1280,
    "height": 720,
    "fps": 30,
    "bitrate": 2_500_000,
    "preset": "veryfast",
    "video_source": "auto",
    "audio_source": "auto",
    "audio_channels": 1,
    "audio_rate": 44100,
}


class ConfigStoreTests(unittest.TestCase):
    def test_blank_stream_keys_preserve_existing_values(self):
        current = {"STREAM_KEY": "youtube-old", "STREAM_KEY_META": "facebook-old"}
        result = config_store.validate_config({**BASE, "stream_key": "", "stream_key_meta": ""}, current=current)
        self.assertEqual(result["STREAM_KEY"], "youtube-old")
        self.assertEqual(result["STREAM_KEY_META"], "facebook-old")

    def test_non_blank_stream_key_replaces_existing_value(self):
        result = config_store.validate_config(
            {**BASE, "stream_key": "youtube-new"},
            current={"STREAM_KEY": "youtube-old"},
        )
        self.assertEqual(result["STREAM_KEY"], "youtube-new")

    def test_missing_stream_key_is_still_rejected_without_existing_value(self):
        with self.assertRaises(config_store.ConfigValidationError):
            config_store.validate_config(BASE, current={})


if __name__ == "__main__":
    unittest.main()
