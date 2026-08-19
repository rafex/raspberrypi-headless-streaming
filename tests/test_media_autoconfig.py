import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("media_autoconfig", ROOT / "scripts/media_autoconfig.py")
media = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(media)


EASYCAP_INFO = """
Driver name : uvcvideo
Card type   : AV TO USB2.0
        Video Capture
"""
EASYCAP_FORMATS = """
[0]: 'YUYV' (YUYV 4:2:2)
    Size: Discrete 720x480
        Interval: Discrete 0.033s (30.000 fps)
    Size: Discrete 720x576
        Interval: Discrete 0.040s (25.000 fps)
"""
CODEC_INFO = "Card type : bcm2835-codec-codec"
WEBCAM_INFO = "Card type : C920\nVideo Capture"
WEBCAM_FORMATS = """
[0]: 'MJPG' (Motion-JPEG, compressed)
    Size: Discrete 1280x720
        Interval: Discrete 0.033s (30.000 fps)
"""
ARECORD = """
card 0: MS210x [MS210x], device 0: USB Audio [USB Audio]
card 1: C920 [C920], device 0: USB Audio [USB Audio]
card 2: BOYALINK [BOYALINK], device 0: USB Audio [USB Audio]
"""


class MediaAutoconfigTests(unittest.TestCase):
    def runner(self, command):
        if command[:3] == ["v4l2-ctl", "--device", "/dev/video0"]:
            return EASYCAP_INFO if command[-1] == "--info" else EASYCAP_FORMATS
        if command[:3] == ["v4l2-ctl", "--device", "/dev/video1"]:
            return WEBCAM_INFO if command[-1] == "--info" else WEBCAM_FORMATS
        if command == ["arecord", "-l"]:
            return ARECORD
        if command[:2] == ["arecord", "--dump-hw-params"]:
            return "CHANNELS: 2\nRATE: 48000\n"
        return ""

    def test_easycap_mode_and_encoder_nodes_are_handled(self):
        found = media.list_video_devices(self.runner, ["/dev/video0", "/dev/video1", "/dev/video10"])
        self.assertEqual([item["device"] for item in found], ["/dev/video0", "/dev/video1"])
        result = media.detect_media(
            {"VIDEO_SOURCE": "auto", "AUDIO_SOURCE": "auto"},
            runner=self.runner,
            video_devices=["/dev/video0", "/dev/video1", "/dev/video10"],
            audio_output=ARECORD,
            audio_ids={"0": "MS210x", "1": "C920", "2": "BOYALINK"},
            libcamera_available=False,
        )
        self.assertEqual(result["video"]["device"], "/dev/video0")
        self.assertEqual(result["video"]["format"], "YUYV")
        self.assertEqual(result["video"]["width"], 720)
        self.assertEqual(result["video"]["height"], 480)
        self.assertEqual(result["video"]["fps"], 30)
        self.assertEqual(media.shell_env(result)["VIDEO_INPUT_FORMAT"], "yuyv422")

    def test_audio_priority_boya_then_easycap_then_webcam(self):
        result = media.detect_media(
            {"VIDEO_SOURCE": "auto", "AUDIO_SOURCE": "auto"},
            runner=self.runner,
            video_devices=["/dev/video0"],
            audio_output=ARECORD,
            audio_ids={"0": "MS210x", "1": "C920", "2": "BOYALINK"},
            libcamera_available=False,
        )
        self.assertEqual(result["audio"]["kind"], "boya")

        without_boya = ARECORD.replace("card 2: BOYALINK [BOYALINK], device 0: USB Audio [USB Audio]\n", "")
        result = media.detect_media(
            {"VIDEO_SOURCE": "auto", "AUDIO_SOURCE": "auto"},
            runner=self.runner,
            video_devices=["/dev/video0"],
            audio_output=without_boya,
            audio_ids={"0": "MS210x", "1": "C920"},
            libcamera_available=False,
        )
        self.assertEqual(result["audio"]["card_id"], "MS210x")
        self.assertEqual(result["audio"]["channels"], 2)
        self.assertEqual(result["audio"]["rate"], 48000)
        self.assertEqual(media.shell_env(result)["AUDIO_DEVICE_RESOLVED"], "hw:CARD=MS210x,DEV=0")

        without_easycap = without_boya.replace("card 0: MS210x [MS210x], device 0: USB Audio [USB Audio]\n", "")
        result = media.detect_media(
            {"VIDEO_SOURCE": "auto", "AUDIO_SOURCE": "auto"},
            runner=self.runner,
            video_devices=["/dev/video1"],
            audio_output=without_easycap,
            audio_ids={"1": "C920"},
            libcamera_available=False,
        )
        self.assertEqual(result["audio"]["kind"], "webcam")

    def test_generic_hdmi_capture_matches_stream_output(self):
        modes = [
            {"format": "MJPG", "width": 1920, "height": 1080, "fps": 30},
            {"format": "MJPG", "width": 1280, "height": 720, "fps": 30},
            {"format": "YUYV", "width": 1280, "height": 720, "fps": 10},
        ]
        selected = media._best_mode(modes, easycap=False)
        self.assertEqual(
            selected,
            {"format": "MJPG", "width": 1280, "height": 720, "fps": 30},
        )

    def test_fallbacks_to_libcamera_and_silence(self):
        result = media.detect_media(
            {"VIDEO_SOURCE": "auto", "AUDIO_SOURCE": "auto"},
            runner=lambda command: "",
            video_devices=[],
            audio_output="",
            audio_ids={},
            libcamera_available=True,
        )
        self.assertEqual(result["video"]["backend"], "libcamera")
        self.assertEqual(result["audio"]["kind"], "none")

    def test_missing_manual_boya_falls_back_to_hdmi_audio(self):
        hdmi_audio = "card 0: MS2109 [MS2109], device 0: USB Audio [USB Audio]\n"
        result = media.detect_media(
            {
                "VIDEO_SOURCE": "auto",
                "AUDIO_SOURCE": "manual",
                "AUDIO_DEVICE": "plughw:CARD=BOYALINK,DEV=0",
            },
            runner=self.runner,
            video_devices=[],
            audio_output=hdmi_audio,
            audio_ids={"0": "MS2109"},
            libcamera_available=False,
        )
        self.assertEqual(result["audio"]["card_id"], "MS2109")
        self.assertIn("fuente manual no disponible", result["audio"]["reason"])

    def test_hdmi_capture_audio_beats_webcam(self):
        hdmi = {"name": "USB Video: USB Video", "easycap": False}
        ms2109 = {"name": "USB Audio", "card_id": "MS2109", "kind": "usb"}
        webcam = {"name": "USB Audio", "card_id": "C920", "kind": "webcam"}
        self.assertGreater(media._audio_score(ms2109, hdmi), media._audio_score(webcam, hdmi))

    def test_usb_audio_capture_is_classified_and_prioritized(self):
        kind = media._audio_kind(
            "USB Audio",
            "Device",
            {"vendor": "0d8c", "product": "0014", "manufacturer": "C-Media Electronics Inc.", "product_name": "USB Audio Device"},
        )
        self.assertEqual(kind, "usb_capture")
        self.assertGreater(
            media._audio_score({"kind": kind}, None),
            media._audio_score({"kind": "hdmi_capture"}, None),
        )


if __name__ == "__main__":
    unittest.main()
