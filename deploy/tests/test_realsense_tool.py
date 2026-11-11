"""deploy/realsense_tool.py 的單元測試 (不需要接相機)。

執行 (需要 numpy 與含 aruco 的 OpenCV;機台上是 python3-numpy / python3-opencv):
  python3 -m unittest discover -s deploy/tests -v
"""
from __future__ import annotations

import io
import json
import re
import sys
import tempfile
import time
import unittest
import zlib
from datetime import datetime
from pathlib import Path
from contextlib import contextmanager
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import cv2  # noqa: E402
import numpy as np  # noqa: E402

import realsense_tool as rt  # noqa: E402


def answers_from(seq):
    it = iter(seq)
    return lambda _prompt="": next(it)


class FakeAutoCalibDevice:
    """記錄呼叫順序的假 auto_calibrated_device。"""

    def __init__(self, table=None):
        self.table = list(table or [1, 2, 3, 4])
        self.calls: list[str] = []

    def get_calibration_table(self):
        self.calls.append("get")
        return list(self.table)

    def set_calibration_table(self, table):
        self.calls.append("set")
        self.table = list(table)

    def write_calibration(self):
        self.calls.append("write")

    def reset_to_factory_calibration(self):
        self.calls.append("reset")


class HealthTest(unittest.TestCase):
    def test_small_value_is_good(self):
        self.assertEqual(rt.classify_health(0.1)[0], "good")
        self.assertEqual(rt.classify_health(-0.24)[0], "good")

    def test_middle_range_recommends_recalibration(self):
        self.assertEqual(rt.classify_health(0.25)[0], "recommend")
        self.assertEqual(rt.classify_health(-0.6)[0], "recommend")
        self.assertEqual(rt.classify_health(1.0)[0], "recommend")

    def test_large_value_requires_recalibration(self):
        self.assertEqual(rt.classify_health(1.01)[0], "required")
        self.assertEqual(rt.classify_health(-3)[0], "required")

    def test_messages_are_traditional_chinese(self):
        self.assertIn("良好", rt.classify_health(0.1)[1])
        self.assertIn("建議重新校正", rt.classify_health(0.5)[1])
        self.assertIn("必須重新校正", rt.classify_health(2)[1])

    def test_non_finite_value_is_reported_as_invalid(self):
        self.assertEqual(rt.classify_health(float("nan"))[0], "invalid")


class InputTest(unittest.TestCase):
    def test_parse_mm_accepts_value_in_range(self):
        self.assertAlmostEqual(rt.parse_mm(" 175.5 ", 50, 300), 175.5)

    def test_parse_mm_rejects_text_and_out_of_range(self):
        for bad in ["", "abc", "0", "-5", "1e9", "nan", "inf"]:
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                rt.parse_mm(bad, 1, 2000)

    def test_ask_mm_warns_when_letter_target_was_shrunk_onto_a4(self):
        # 官方標靶是 US Letter;A4 印表機「縮小超出的頁面」會縮成 210/215.9 = 97.3%,175 mm → 170.2 mm
        out = io.StringIO()
        with mock.patch("sys.stdout", new=out):
            value = rt.ask_mm("左右圓點中心間距", 100, 250, 175.0, input_fn=answers_from(["170.2", "y"]))
        self.assertEqual(value, 170.2)
        self.assertIn("100%", out.getvalue())

    def test_ask_mm_accepts_normal_printer_variation_silently(self):
        # 白皮書:不同印表機最多約 0.5% 誤差,不該跳警告
        out = io.StringIO()
        with mock.patch("sys.stdout", new=out):
            value = rt.ask_mm("左右圓點中心間距", 100, 250, 175.0, input_fn=answers_from(["175.8"]))
        self.assertEqual(value, 175.8)
        self.assertNotIn("注意", out.getvalue())

    def test_ask_mm_ignores_ruler_resolution_on_small_sizes(self):
        # 直尺刻度 0.5 mm:方格 30 mm 量成 30.5 mm (1.7%) 是正常讀數誤差,不該警告
        out = io.StringIO()
        with mock.patch("sys.stdout", new=out):
            value = rt.ask_mm("實測方格邊長", 5, 100, 30.0, input_fn=answers_from(["30.5"]))
        self.assertEqual(value, 30.5)
        self.assertNotIn("注意", out.getvalue())

    def test_ask_mm_still_warns_when_small_board_was_scaled(self):
        out = io.StringIO()
        with mock.patch("sys.stdout", new=out):
            rt.ask_mm("實測方格邊長", 5, 100, 30.0, input_fn=answers_from(["28.2", "y"]))  # 「符合頁面」約 94%
        self.assertIn("注意", out.getvalue())

    def test_ask_mm_enter_uses_design_value(self):
        # 照我們產生 / 官方的尺寸 100% 列印時,直接按 Enter 就好,不用每次量
        with mock.patch("sys.stdout", new=io.StringIO()):
            self.assertEqual(rt.ask_mm("左右圓點中心間距", 100, 250, 175.0, input_fn=answers_from([""])), 175.0)
            self.assertIsNone(rt.ask_mm("左右圓點中心間距", 100, 250, 175.0, input_fn=answers_from(["q"])))

    def test_ask_mm_without_design_enter_cancels(self):
        self.assertIsNone(rt.ask_mm("真實距離", 60, 10000, input_fn=answers_from([""])))

    def test_rgb_calibration_does_not_ask_board_size(self):
        prompts = []

        def inp(p=""):
            prompts.append(p)
            return ""

        with mock.patch.object(rt, "confirm_preparation", return_value=True), \
                mock.patch.object(rt, "open_camera", side_effect=rt.ToolError("stop")), \
                mock.patch("sys.stdout", new=io.StringIO()):
            with self.assertRaises(rt.ToolError):
                rt.run_rgb_calibration(inp)
        self.assertFalse(any("邊長" in p for p in prompts))

    def test_ask_yes_no_defaults_to_no(self):
        self.assertFalse(rt.ask_yes_no("寫入?", input_fn=lambda _: ""))
        self.assertFalse(rt.ask_yes_no("寫入?", input_fn=lambda _: "n"))
        self.assertTrue(rt.ask_yes_no("寫入?", input_fn=lambda _: "Y"))

    def test_ask_yes_no_reprompts_on_garbage(self):
        answers = iter(["maybe", "y"])
        with mock.patch("sys.stdout", new=io.StringIO()):
            self.assertTrue(rt.ask_yes_no("寫入?", input_fn=lambda _: next(answers)))


class BackupAndWriteTest(unittest.TestCase):
    def test_backup_file_name_contains_datetime_and_serial(self):
        with tempfile.TemporaryDirectory() as d:
            dev = FakeAutoCalibDevice([9, 8, 7])
            path = rt.backup_calibration(dev, "123456789012", Path(d), when=datetime(2026, 11, 9, 14, 3, 5))
            self.assertIn("20261109-140305", path.name)
            self.assertIn("123456789012", path.name)
            data = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(data["table"], [9, 8, 7])
            self.assertEqual(data["serial"], "123456789012")

    def test_backup_never_overwrites_existing_file(self):
        with tempfile.TemporaryDirectory() as d:
            dev = FakeAutoCalibDevice()
            when = datetime(2026, 11, 9, 14, 3, 5)
            p1 = rt.backup_calibration(dev, "SN", Path(d), when=when)
            p2 = rt.backup_calibration(dev, "SN", Path(d), when=when)
            self.assertNotEqual(p1, p2)
            self.assertTrue(p1.exists() and p2.exists())

    def test_backup_leaves_no_temp_file_and_is_valid_json(self):
        with tempfile.TemporaryDirectory() as d:
            path = rt.backup_calibration(FakeAutoCalibDevice(), "SN", Path(d), table=[3, 2, 1])
            self.assertEqual([p.name for p in Path(d).iterdir()], [path.name])
            self.assertEqual(json.loads(path.read_text(encoding="utf-8"))["table"], [3, 2, 1])

    def test_write_to_camera_backs_up_original_table_before_writing(self):
        # 不能在寫入時才讀相機的表:暫時套用新表後,相機回報的可能已經是新表
        with tempfile.TemporaryDirectory() as d:
            dev = FakeAutoCalibDevice([5, 5, 5])
            rt.write_to_camera(dev, [5, 5, 5], original_table=[1, 1, 1], serial="SN", backup_dir=Path(d))
            self.assertEqual(dev.calls, ["set", "write"])
            backups = list(Path(d).glob("*.json"))
            self.assertEqual(len(backups), 1)
            self.assertEqual(json.loads(backups[0].read_text(encoding="utf-8"))["table"], [1, 1, 1])

    def test_write_to_camera_aborts_when_backup_fails(self):
        dev = FakeAutoCalibDevice()
        with tempfile.TemporaryDirectory() as d:
            blocker = Path(d) / "not_a_dir"
            blocker.write_text("x")
            with self.assertRaises(rt.ToolError):
                rt.write_to_camera(dev, [5], original_table=[1], serial="SN", backup_dir=blocker)
        self.assertNotIn("write", dev.calls)
        self.assertNotIn("set", dev.calls)

    def test_failed_flash_write_says_state_is_uncertain_and_names_backup(self):
        dev = FakeAutoCalibDevice()
        dev.write_calibration = mock.Mock(side_effect=RuntimeError("hw monitor timeout"))
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(rt.ToolError) as cm:
                rt.write_to_camera(dev, [5], original_table=[1], serial="SN", backup_dir=Path(d))
            backup = next(Path(d).glob("*.json"))
        self.assertIn("不確定", str(cm.exception))
        self.assertIn(backup.name, str(cm.exception))

    def test_offer_write_does_nothing_when_user_declines(self):
        with tempfile.TemporaryDirectory() as d, mock.patch("sys.stdout", new=io.StringIO()):
            dev = FakeAutoCalibDevice()
            wrote = rt.offer_write(dev, [5], original_table=[1], serial="SN", backup_dir=Path(d),
                                   input_fn=lambda _: "")
            self.assertEqual(list(Path(d).iterdir()), [])
        self.assertFalse(wrote)
        self.assertEqual(dev.calls, [])

    def test_offer_write_writes_when_user_confirms(self):
        with tempfile.TemporaryDirectory() as d, mock.patch("sys.stdout", new=io.StringIO()):
            dev = FakeAutoCalibDevice()
            wrote = rt.offer_write(dev, [5], original_table=[1], serial="SN", backup_dir=Path(d),
                                   input_fn=lambda _: "y")
        self.assertTrue(wrote)
        self.assertEqual(dev.calls, ["set", "write"])


class FakeSensor:
    """記錄 set_option 的假深度 sensor;fail_on 的 option 設定時丟 RuntimeError。"""

    def __init__(self, fail_on=None):
        self.values = {"emitter": 1.0, "thermal": 1.0, "ae": 0.0}
        self.fail_on = fail_on

    def supports(self, opt):
        return True

    def get_option(self, opt):
        return self.values[opt]

    def set_option(self, opt, value):
        if opt == self.fail_on:
            raise RuntimeError(f"cannot set {opt}")
        self.values[opt] = value


def fake_cam_with_sensor(sensor):
    cam = mock.Mock()
    cam.rs.option.emitter_enabled = "emitter"
    cam.rs.option.thermal_compensation = "thermal"
    cam.rs.option.enable_auto_exposure = "ae"
    cam.dev.first_depth_sensor.return_value = sensor
    return cam


class CalibrationModeTest(unittest.TestCase):
    def test_options_are_restored_after_use(self):
        sensor = FakeSensor()
        with rt.calibration_mode(fake_cam_with_sensor(sensor), rt.EMITTER_OFF):
            self.assertEqual(sensor.values, {"emitter": 0, "thermal": 0, "ae": 1})
        self.assertEqual(sensor.values, {"emitter": 1.0, "thermal": 1.0, "ae": 0.0})

    def test_emitter_on_mode(self):
        sensor = FakeSensor()
        sensor.values["emitter"] = 0.0
        with rt.calibration_mode(fake_cam_with_sensor(sensor), rt.EMITTER_ON):
            self.assertEqual(sensor.values["emitter"], 1)
        self.assertEqual(sensor.values["emitter"], 0.0)

    def test_partial_setup_failure_restores_options_already_changed(self):
        sensor = FakeSensor(fail_on="thermal")
        with self.assertRaises(RuntimeError), mock.patch("sys.stderr", new=io.StringIO()):
            with rt.calibration_mode(fake_cam_with_sensor(sensor), rt.EMITTER_OFF):
                self.fail("不應該進到 with 區塊")
        self.assertEqual(sensor.values["emitter"], 1.0)


class EmitterPerCalibrationTest(unittest.TestCase):
    """官方 realsense-viewer:On-Chip / Tare (含 health check) 開 emitter,Focal Length 關。"""

    def _emitter_used(self, fn):
        seen = []

        @contextmanager
        def fake_mode(cam, emitter):
            seen.append(emitter)
            raise RuntimeError("stop here")
            yield  # noqa: unreachable

        with mock.patch.object(rt, "calibration_mode", fake_mode), self.assertRaises(RuntimeError):
            fn(mock.Mock())
        return seen

    def test_on_chip_and_tare_use_emitter_on(self):
        self.assertEqual(self._emitter_used(lambda c: rt._run_occ(c, rt.SCAN_INTRINSIC)), [rt.EMITTER_ON])
        self.assertEqual(self._emitter_used(lambda c: rt._run_tare(c, 500)), [rt.EMITTER_ON])

    def test_focal_length_uses_emitter_off(self):
        self.assertEqual(self._emitter_used(lambda c: rt._run_focal(c, 175, 100, 0)), [rt.EMITTER_OFF])


class HealthCheckTest(unittest.TestCase):
    def test_health_check_restores_table_even_when_occ_fails(self):
        cam = mock.Mock()
        cam.auto = FakeAutoCalibDevice([4, 4])
        with mock.patch.object(rt, "_run_occ", side_effect=RuntimeError("timeout")), \
                mock.patch("sys.stdout", new=io.StringIO()):
            with self.assertRaises(RuntimeError):
                rt.health_check(cam, [1, 1])
        self.assertEqual(cam.auto.table, [1, 1])
        self.assertNotIn("write", cam.auto.calls)


class DepthFillStatsTest(unittest.TestCase):
    def test_fill_and_distance(self):
        depth = np.full((144, 256), 500, dtype=np.uint16)
        depth[:36, :] = 0  # 上方 1/4 量不到
        s = rt.depth_fill_stats(depth, 0.001)
        self.assertAlmostEqual(s["fill"], 0.75)
        self.assertAlmostEqual(s["dist_m"], 0.5)

    def test_all_invalid_has_no_distance(self):
        s = rt.depth_fill_stats(np.zeros((144, 256), dtype=np.uint16), 0.001)
        self.assertEqual(s["fill"], 0.0)
        self.assertIsNone(s["dist_m"])
        self.assertIn("量不到", rt._stats_text(s))

    def test_fill_level_uses_official_35_percent(self):
        self.assertEqual(rt.fill_level(0.9), "ok")
        self.assertEqual(rt.fill_level(0.5), "warn")
        self.assertEqual(rt.fill_level(0.35), "bad")  # 白皮書:要 > 35%
        self.assertEqual(rt.fill_level(0.05), "bad")


class TareDistanceTest(unittest.TestCase):
    def test_close_to_measured_is_accepted_and_rounded(self):
        with mock.patch("sys.stdout", new=io.StringIO()):
            self.assertEqual(rt.ask_tare_distance(0.500, answers_from(["502.6"])), 503)

    def test_mismatch_asks_again(self):
        with mock.patch("sys.stdout", new=io.StringIO()) as out:
            gt = rt.ask_tare_distance(0.500, answers_from(["1000", "n", "505"]))
        self.assertEqual(gt, 505)
        self.assertIn("相差", out.getvalue())

    def test_mismatch_can_be_confirmed(self):
        with mock.patch("sys.stdout", new=io.StringIO()):
            self.assertEqual(rt.ask_tare_distance(0.500, answers_from(["600", "y"])), 600)

    def test_blank_cancels(self):
        with mock.patch("sys.stdout", new=io.StringIO()):
            self.assertIsNone(rt.ask_tare_distance(0.5, answers_from([""])))

    def test_tare_asks_distance_after_preview(self):
        order = []
        cam = mock.Mock()
        with mock.patch.object(rt, "confirm_preparation", return_value=True), \
                mock.patch.object(rt, "open_camera", return_value=cam), \
                mock.patch.object(rt, "require_depth_ready", return_value=True), \
                mock.patch.object(rt, "preview_depth_target",
                                  side_effect=lambda *a: order.append("preview") or {"fill": 0.9, "dist_m": 0.5}), \
                mock.patch.object(rt, "ask_tare_distance", side_effect=lambda *a: order.append("ask") or 500), \
                mock.patch.object(rt, "_depth_flow", return_value="ok"), \
                mock.patch("sys.stdout", new=io.StringIO()):
            self.assertEqual(rt.run_tare(answers_from([])), "ok")
        self.assertEqual(order, ["preview", "ask"])


class WebPreviewTest(unittest.TestCase):
    def setUp(self):
        # 不要寫到真的 ~/.config/spoonfull/preview_token (那是使用者書籤裡的網址)
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        for patcher in (mock.patch.object(rt, "WEB_TOKEN_PATH", Path(tmp.name) / "preview_token"),
                        mock.patch.object(rt, "_web_token", None)):
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_serves_page_and_mjpeg_stream_then_closes(self):
        import urllib.error
        import urllib.request
        with mock.patch.dict("os.environ", {"SSH_CONNECTION": "10.0.0.5 5000 10.0.0.9 22"}):
            web = rt.WebPreview("深度預覽", port=0)
        try:
            token = rt.web_token()
            self.assertEqual(web.url, f"http://10.0.0.9:{web.port}/{token}/")
            base = f"http://127.0.0.1:{web.port}/{token}"
            with urllib.request.urlopen(base + "/", timeout=5) as page:
                self.assertIn("stream", page.read().decode())
            for guess in ("/", "/stream", "/index.html"):  # 不知道隨機路徑就看不到
                with self.subTest(guess=guess), self.assertRaises(urllib.error.HTTPError):
                    urllib.request.urlopen(f"http://127.0.0.1:{web.port}{guess}", timeout=5)
            with urllib.request.urlopen(base + "/stream", timeout=5) as resp:
                self.assertIn("multipart/x-mixed-replace", resp.headers["Content-Type"])
                # 先連線、後有畫面:第一個送出的不能是空的 JPEG
                self.assertIsNone(web.show(np.zeros((40, 60, 3), np.uint8)))
                head = resp.read(120)
                self.assertNotIn(b"Content-Length: 0\r\n", head)
                self.assertIn(b"\xff\xd8", head)  # 標頭之後是 JPEG 開頭
        finally:
            web.close()
            web.close()  # 可重複呼叫

    def test_ssh_choice_3_is_text_only_and_remembered(self):
        with mock.patch.object(rt, "_HAS_LOCAL_GUI", False), mock.patch.object(rt, "_preview_choice", None), \
                mock.patch("sys.stdout", new=io.StringIO()):
            self.assertFalse(rt.open_preview("x", answers_from(["3"])).active)
            self.assertFalse(rt.open_preview("x", answers_from([])).active)  # 第二次不再問

    def test_token_is_saved_and_reused_across_runs(self):
        import stat
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "preview_token"
            with mock.patch.object(rt, "WEB_TOKEN_PATH", path), mock.patch.object(rt, "_web_token", None):
                first = rt.web_token()
            self.assertEqual(path.read_text(encoding="utf-8").strip(), first)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            with mock.patch.object(rt, "WEB_TOKEN_PATH", path), mock.patch.object(rt, "_web_token", None):
                self.assertEqual(rt.web_token(), first)  # 模擬下次執行:網址不變

    def test_ipv6_url_has_brackets(self):
        with mock.patch.dict("os.environ", {"SSH_CONNECTION": "fe80::1 5000 2001:db8::9 22"}):
            self.assertEqual(rt._machine_ip(), "[2001:db8::9]")


class KeyDecodeTest(unittest.TestCase):
    def test_terminal_space_and_q(self):
        self.assertEqual(rt.decode_terminal_keys(b" "), "capture")
        self.assertEqual(rt.decode_terminal_keys(b"q"), "quit")
        self.assertEqual(rt.decode_terminal_keys(b"Q"), "quit")

    def test_terminal_arrow_keys_are_ignored(self):
        for seq in (b"\x1b[A", b"\x1b[D", b"\x1b", b"\x1bOQ"):
            with self.subTest(seq=seq):
                self.assertIsNone(rt.decode_terminal_keys(seq))

    def test_gui_space_and_q(self):
        self.assertEqual(rt.decode_gui_key(32), "capture")
        self.assertEqual(rt.decode_gui_key(ord("q")), "quit")
        self.assertEqual(rt.decode_gui_key(27), "quit")
        self.assertIsNone(rt.decode_gui_key(-1))

    def test_gui_arrow_keys_are_ignored(self):
        # GTK 方向鍵 0xFF51..0xFF54;舊寫法 & 0xFF 後 0x51 = 'Q' 會被誤判成結束
        for k in (0xFF51, 0xFF52, 0xFF53, 0xFF54, 0x250000):
            with self.subTest(k=hex(k)):
                self.assertIsNone(rt.decode_gui_key(k))


class DepthFlowTest(unittest.TestCase):
    """_depth_flow 的安全行為:拒絕寫入要還原;寫入時備份的是校正前的原始表。"""

    INTR = {
        "depth": {"fx": 640.0, "fy": 640.0, "ppx": 424.0, "ppy": 240.0},
        "rgb": {"fx": 910.0, "fy": 910.0, "ppx": 640.0, "ppy": 360.0},
        "extrinsics": {"translation_m": [0.015, 0.0, 0.0]},
    }

    def _run(self, answer, backup_dir):
        # 假裝 get_calibration_table 讀到的是「目前生效」的表 (set 之後就變新表),這是最壞的情況
        cam = mock.Mock(serial="SN")
        cam.auto = FakeAutoCalibDevice([1, 1, 1])
        healths = iter([0.6, 0.1])
        with mock.patch.object(rt, "read_intrinsics", return_value=self.INTR), \
                mock.patch.object(rt, "health_check", side_effect=lambda c, t: next(healths)), \
                mock.patch.object(rt, "open_camera", return_value=cam), \
                mock.patch.object(rt, "BACKUP_DIR", backup_dir), \
                mock.patch("sys.stdout", new=io.StringIO()) as out:
            result = rt._depth_flow(cam, "測試校正", lambda: ([7, 7, 7], {"ratio": 1.0}), input_fn=lambda _: answer)
        return cam.auto, result, out.getvalue()

    def test_declining_write_restores_original_table(self):
        with tempfile.TemporaryDirectory() as d:
            auto, result, out = self._run("", Path(d))
            self.assertEqual(list(Path(d).glob("*.json")), [])
        self.assertNotIn("write", auto.calls)
        self.assertEqual(auto.table, [1, 1, 1])
        self.assertIn("未寫入相機", result)
        self.assertIn("校正前", out)
        self.assertIn("校正後", out)

    def test_confirmed_write_backs_up_original_table_not_the_new_one(self):
        with tempfile.TemporaryDirectory() as d:
            auto, result, out = self._run("y", Path(d))
            backups = list(Path(d).glob("*.json"))
            self.assertEqual(len(backups), 1)
            self.assertEqual(json.loads(backups[0].read_text(encoding="utf-8"))["table"], [1, 1, 1])
        self.assertEqual(auto.calls[-3:], ["set", "write", "get"])  # 寫入後讀回 flash 確認
        self.assertIn("已讀回相機確認", out)
        self.assertEqual(auto.table, [7, 7, 7])
        self.assertIn("已寫入相機", result)

    def test_interrupted_calibration_restores_original(self):
        # 白皮書:On-Chip 跑完 ASIC 會讓新校正保持生效,所以校正中途中斷也要把原本的表設回去
        cam = mock.Mock(serial="SN")
        cam.auto = FakeAutoCalibDevice([1, 1, 1])

        def interrupted():
            cam.auto.table = [9, 9, 9]  # 模擬韌體已經套用了一半的新校正
            raise KeyboardInterrupt

        with mock.patch.object(rt, "read_intrinsics", return_value=self.INTR), \
                mock.patch.object(rt, "health_check", return_value=0.6), \
                mock.patch("sys.stdout", new=io.StringIO()):
            with self.assertRaises(KeyboardInterrupt):
                rt._depth_flow(cam, "測試校正", interrupted, input_fn=lambda _: "y")
        self.assertEqual(cam.auto.table, [1, 1, 1])
        self.assertNotIn("write", cam.auto.calls)

    def test_error_after_applying_new_table_restores_original(self):
        cam = mock.Mock(serial="SN")
        cam.auto = FakeAutoCalibDevice([1, 1, 1])
        calls = iter([0.6])

        def health(c, t):
            try:
                return next(calls)
            except StopIteration:
                raise rt.ToolError("串流中斷") from None

        with mock.patch.object(rt, "read_intrinsics", return_value=self.INTR), \
                mock.patch.object(rt, "health_check", side_effect=health), \
                mock.patch.object(rt, "open_camera", return_value=cam), \
                mock.patch("sys.stdout", new=io.StringIO()):
            with self.assertRaises(rt.ToolError):
                rt._depth_flow(cam, "測試校正", lambda: ([7, 7, 7], {}), input_fn=lambda _: "y")
        self.assertEqual(cam.auto.table, [1, 1, 1])
        self.assertNotIn("write", cam.auto.calls)


    def test_failed_health_after_calibration_still_offers_write(self):
        cam = mock.Mock(serial="SN")
        cam.auto = FakeAutoCalibDevice([1, 1, 1])
        healths = iter([0.6])

        def health(c, t):
            try:
                return next(healths)
            except StopIteration:
                raise RuntimeError("Not enough depth pixels! - low fill factor)") from None

        asked = []
        with mock.patch.object(rt, "read_intrinsics", return_value=self.INTR), \
                mock.patch.object(rt, "health_check", side_effect=health), \
                mock.patch.object(rt, "open_camera", return_value=cam), \
                mock.patch("sys.stdout", new=io.StringIO()) as out:
            result = rt._depth_flow(cam, "測試校正", lambda: ([7, 7, 7], {}),
                                    input_fn=lambda p: asked.append(p) or "")
        self.assertTrue(any("寫入相機" in p for p in asked))
        self.assertIn("無法確認校正結果", out.getvalue())
        self.assertIn("→ 失敗", result)
        self.assertEqual(cam.auto.table, [1, 1, 1])

    def test_failed_health_before_calibration_can_cancel(self):
        cam = mock.Mock(serial="SN")
        cam.auto = FakeAutoCalibDevice([1, 1, 1])
        run = mock.Mock()
        with mock.patch.object(rt, "read_intrinsics", return_value=self.INTR), \
                mock.patch.object(rt, "health_check", side_effect=RuntimeError("low fill factor")), \
                mock.patch("sys.stdout", new=io.StringIO()):
            result = rt._depth_flow(cam, "測試校正", run, input_fn=lambda _: "n")
        run.assert_not_called()
        self.assertIn("取消", result)


    def test_interrupt_after_flash_write_keeps_new_table(self):
        cam = mock.Mock(serial="SN")
        cam.auto = FakeAutoCalibDevice([1, 1, 1])
        with mock.patch.object(rt, "health_check", return_value=0.5), \
                mock.patch.object(rt, "offer_write", side_effect=rt.InterruptedAfterWrite(Path("b.json"))), \
                mock.patch("sys.stdout", new=io.StringIO()) as out:
            with self.assertRaises(KeyboardInterrupt):
                rt._depth_flow(cam, "測試校正", lambda: ([7, 7, 7], {}), input_fn=lambda _: "y")
        self.assertEqual(cam.auto.table, [7, 7, 7])  # flash 已是新表,不能把 RAM 設回舊表
        self.assertIn("已寫入相機", out.getvalue())


class SignalDeferTest(unittest.TestCase):
    def test_ctrl_c_inside_block_is_raised_after_it(self):
        import os
        import signal
        done = []
        with self.assertRaises(KeyboardInterrupt):
            with rt.signals_deferred():
                os.kill(os.getpid(), signal.SIGINT)
                time.sleep(0.05)
                done.append("寫入完成")
        self.assertEqual(done, ["寫入完成"])
        self.assertIs(signal.getsignal(signal.SIGINT), signal.default_int_handler)

    def test_write_interrupted_midway_still_completes(self):
        import os
        import signal
        auto = FakeAutoCalibDevice([1, 1])
        real_write = auto.write_calibration

        def slow_write():
            os.kill(os.getpid(), signal.SIGINT)
            time.sleep(0.05)
            real_write()

        auto.write_calibration = slow_write
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(rt.InterruptedAfterWrite):
                rt.write_to_camera(auto, [2, 2], [1, 1], "SN", Path(d))
        self.assertEqual(auto.calls[-1], "write")
        self.assertEqual(auto.table, [2, 2])


class GuidedHealthCacheTest(unittest.TestCase):
    def test_same_table_is_measured_once_in_guided_mode(self):
        cam = mock.Mock()
        cam.auto = FakeAutoCalibDevice([1, 1])
        with mock.patch.object(rt, "_guided_health", {}), \
                mock.patch.object(rt, "_run_occ", return_value=([9, 9], 0.2)) as occ, \
                mock.patch("sys.stdout", new=io.StringIO()):
            self.assertEqual(rt.health_check(cam, [1, 1]), 0.2)
            self.assertEqual(rt.health_check(cam, [1, 1]), 0.2)
            rt.health_check(cam, [5, 5])
        self.assertEqual(occ.call_count, 2)

    def test_menu_mode_always_measures(self):
        cam = mock.Mock()
        cam.auto = FakeAutoCalibDevice([1, 1])
        with mock.patch.object(rt, "_run_occ", return_value=([9, 9], 0.2)) as occ, \
                mock.patch("sys.stdout", new=io.StringIO()):
            rt.health_check(cam, [1, 1])
            rt.health_check(cam, [1, 1])
        self.assertEqual(occ.call_count, 2)
        self.assertIsNone(rt._guided_health)

    def test_guided_has_no_separate_final_health_step(self):
        self.assertEqual(sum("Health check" in t for t, _, _ in rt.GUIDED_STEPS), 1)

    def test_guided_ctrl_c_still_prints_summary(self):
        steps = [("A", "", lambda f: "ok"), ("B", "", mock.Mock(side_effect=KeyboardInterrupt)), ("C", "", None)]
        with mock.patch.object(rt, "GUIDED_STEPS", steps), mock.patch("sys.stdout", new=io.StringIO()) as out:
            rt.run_guided(answers_from(["", ""]))
        text = out.getvalue()
        self.assertIn("摘要", text)
        self.assertRegex(text, r"B\s+已中斷")
        self.assertRegex(text, r"C\s+未執行")
        self.assertIsNone(rt._guided_health)


class FirmwareTest(unittest.TestCase):
    def test_outdated(self):
        self.assertTrue(rt.firmware_outdated("5.13.0.55", "5.16.0.1"))
        self.assertFalse(rt.firmware_outdated("5.16.0.1", "5.16.0.1"))
        self.assertFalse(rt.firmware_outdated("5.17.0.10", "5.16.0.1"))
        self.assertFalse(rt.firmware_outdated("", "5.16.0.1"))  # 讀不到就不提醒


class RestoreBackupTest(unittest.TestCase):
    def _cam(self, table):
        cam = mock.Mock(serial="SN1")
        cam.auto = FakeAutoCalibDevice(table)
        return cam

    def _write_backup(self, d, name, **kw):
        data = {"format": "spoonfull-realsense-calib-backup/1", "serial": "SN1",
                "created": "2026-11-01T10:00:00", "table": [5, 5, 5]}
        data.update(kw)
        (Path(d) / name).write_text(json.dumps(data), encoding="utf-8")

    def test_restores_chosen_backup_after_backing_up_current(self):
        with tempfile.TemporaryDirectory() as d:
            self._write_backup(d, "calib_20261101-100000_SN1.json")
            cam = self._cam([1, 1, 1])
            with mock.patch.object(rt, "BACKUP_DIR", Path(d)), \
                    mock.patch.object(rt, "open_camera", return_value=cam), \
                    mock.patch("sys.stdout", new=io.StringIO()) as out:
                result = rt.run_restore_backup(answers_from(["1", "y"]))
            backups = rt.list_backups("SN1", Path(d))
            self.assertEqual(len(backups), 2)  # 原本的 + 寫入前自動備份的
            newest = json.loads(backups[0].read_text(encoding="utf-8"))
        self.assertEqual(newest["table"], [1, 1, 1])
        self.assertEqual(cam.auto.table, [5, 5, 5])
        self.assertIn("write", cam.auto.calls)
        self.assertIn("已還原", result)
        self.assertIn("已讀回相機確認", out.getvalue())

    def test_declining_does_not_write(self):
        with tempfile.TemporaryDirectory() as d:
            self._write_backup(d, "calib_20261101-100000_SN1.json")
            cam = self._cam([1, 1, 1])
            with mock.patch.object(rt, "BACKUP_DIR", Path(d)), \
                    mock.patch.object(rt, "open_camera", return_value=cam), \
                    mock.patch("sys.stdout", new=io.StringIO()):
                self.assertEqual(rt.run_restore_backup(answers_from(["1", ""])), "取消")
        self.assertNotIn("write", cam.auto.calls)

    def test_rejects_wrong_serial_and_bad_length(self):
        with tempfile.TemporaryDirectory() as d:
            self._write_backup(d, "a.json", serial="OTHER")
            self._write_backup(d, "b.json", table=[5, 5])
            self._write_backup(d, "c.json", table=[5, 999, 5])
            for name in ("a.json", "b.json", "c.json"):
                with self.subTest(name=name), self.assertRaises(rt.ToolError):
                    rt.load_backup(Path(d) / name, "SN1", 3)

    def test_only_this_cameras_backups_newest_first(self):
        with tempfile.TemporaryDirectory() as d:
            for n in ("calib_20261101-100000_SN1.json", "calib_20261105-100000_SN1.json",
                      "calib_20261103-100000_SN2.json"):
                self._write_backup(d, n)
            names = [p.name for p in rt.list_backups("SN1", Path(d))]
        self.assertEqual(names, ["calib_20261105-100000_SN1.json", "calib_20261101-100000_SN1.json"])

    def test_menu_has_restore_and_range_message(self):
        self.assertIn("run_restore_backup", [n for _, _, n in rt.MENU])
        with mock.patch("sys.stdout", new=io.StringIO()) as out:
            rt.main_menu(answers_from(["", "99", "0"]))
        self.assertIn("0～15", out.getvalue())


class FirmwareUpdateTest(unittest.TestCase):
    def test_version_from_official_names(self):
        self.assertEqual(rt.firmware_version_from_name("Signed_Image_UVC_5_17_3_10.bin"), "5.17.3.10")
        self.assertEqual(rt.firmware_version_from_name("D4XX_FW_Image-5.16.0.1.bin"), "5.16.0.1")
        self.assertEqual(rt.firmware_version_from_name("firmware.bin"), "")

    def test_extract_single_bin_from_zip_ignoring_paths(self):
        import zipfile
        with tempfile.TemporaryDirectory() as d:
            z = Path(d) / "fw.zip"
            with zipfile.ZipFile(z, "w") as f:
                f.writestr("../../evil/Signed_Image_UVC_5_17_3_10.bin", b"FW")
                f.writestr("Release_Notes.pdf", b"x")
            out_dir = Path(d) / "out"
            out_dir.mkdir()
            out = rt.extract_firmware(z, out_dir)
            self.assertEqual(out.parent, out_dir)  # 不會跟著 zip 裡的 ../ 寫到外面
            self.assertEqual(out.read_bytes(), b"FW")

    def test_zip_with_two_bins_is_rejected(self):
        import zipfile
        with tempfile.TemporaryDirectory() as d:
            z = Path(d) / "fw.zip"
            with zipfile.ZipFile(z, "w") as f:
                f.writestr("a.bin", b"1")
                f.writestr("b.bin", b"2")
            with self.assertRaises(rt.ToolError):
                rt.extract_firmware(z, Path(d))

    def test_flash_runs_detached_and_reports_new_version(self):
        cam = mock.Mock(serial="SN1", firmware="5.13.0.55")
        cam.name = "Intel RealSense D435"
        cam.auto = FakeAutoCalibDevice([1, 1])
        new = mock.Mock(firmware="5.17.3.10")
        with tempfile.TemporaryDirectory() as d:
            fw = Path(d) / "Signed_Image_UVC_5_17_3_10.bin"
            fw.write_bytes(b"FW")
            with mock.patch.object(rt.shutil, "which", return_value="/usr/local/bin/rs-fw-update"), \
                    mock.patch.object(rt, "open_camera", return_value=cam), \
                    mock.patch.object(rt, "BACKUP_DIR", Path(d) / "bk"), \
                    mock.patch.object(rt, "_wait_for_camera", return_value=new), \
                    mock.patch.object(rt.subprocess, "run", return_value=mock.Mock(returncode=0)) as run, \
                    mock.patch("sys.stdout", new=io.StringIO()):
                result = rt.run_firmware_update(answers_from([str(fw), "y"]))
            self.assertEqual(len(list((Path(d) / "bk").glob("*.json"))), 1)  # 更新前先備份校正表
        args, kwargs = run.call_args
        self.assertEqual(args[0], ["/usr/local/bin/rs-fw-update", "-f", str(fw), "-s", "SN1"])
        self.assertTrue(kwargs["start_new_session"])  # Ctrl-C / 斷線不會傳給燒錄程式
        self.assertIn("5.17.3.10", result)

    def _flash(self, returncode, new_fw):
        cam = mock.Mock(serial="SN1", firmware="5.13.0.55")
        cam.auto = FakeAutoCalibDevice([1, 1])
        with tempfile.TemporaryDirectory() as d:
            fw = Path(d) / "Signed_Image_UVC_5_17_3_10.bin"
            fw.write_bytes(b"FW")
            with mock.patch.object(rt.shutil, "which", return_value="rs-fw-update"), \
                    mock.patch.object(rt, "open_camera", return_value=cam), \
                    mock.patch.object(rt, "BACKUP_DIR", Path(d) / "bk"), \
                    mock.patch.object(rt, "_wait_for_camera", return_value=mock.Mock(firmware=new_fw)), \
                    mock.patch.object(rt.subprocess, "run", return_value=mock.Mock(returncode=returncode)), \
                    mock.patch("sys.stdout", new=io.StringIO()):
                return rt.run_firmware_update(answers_from([str(fw), "y"]))

    def test_crash_after_successful_flash_counts_as_success(self):
        # rs-fw-update 2.59.1 實機:印出 successfully updated 後 segfault,結束碼 -11
        self.assertIn("5.17.3.10", self._flash(-11, "5.17.3.10"))

    def test_unchanged_version_is_failure_even_with_exit_0(self):
        with self.assertRaises(rt.ToolError):
            self._flash(0, "5.13.0.55")

    def test_same_version_is_skipped(self):
        cam = mock.Mock(serial="SN1", firmware="5.17.3.10")
        with tempfile.TemporaryDirectory() as d:
            fw = Path(d) / "Signed_Image_UVC_5_17_3_10.bin"
            fw.write_bytes(b"FW")
            with mock.patch.object(rt.shutil, "which", return_value="rs-fw-update"), \
                    mock.patch.object(rt, "open_camera", return_value=cam), \
                    mock.patch.object(rt.subprocess, "run") as run, \
                    mock.patch("sys.stdout", new=io.StringIO()):
                self.assertEqual(rt.run_firmware_update(answers_from([str(fw)])), "不需要更新")
        run.assert_not_called()


class UsbPowerTest(unittest.TestCase):
    def _dt(self, d, enable, max_ma):
        (Path(d) / "usb_max_current_enable").write_bytes(enable.to_bytes(4, "big"))
        (Path(d) / "max_current").write_bytes(max_ma.to_bytes(4, "big"))

    def test_3a_supply_without_override_is_limited(self):
        with tempfile.TemporaryDirectory() as d:
            self._dt(d, 0, 3000)
            with mock.patch.object(rt, "DT_POWER", Path(d)):
                self.assertTrue(rt.usb_current_limited())
            self._dt(d, 1, 3000)
            with mock.patch.object(rt, "DT_POWER", Path(d)):
                self.assertFalse(rt.usb_current_limited())
            self._dt(d, 0, 5000)
            with mock.patch.object(rt, "DT_POWER", Path(d)):
                self.assertFalse(rt.usb_current_limited())

    def test_not_a_pi5_is_not_limited(self):
        with mock.patch.object(rt, "DT_POWER", Path("/nonexistent")):
            self.assertFalse(rt.usb_current_limited())

    def test_disconnect_with_overcurrent_explains_power(self):
        with mock.patch.object(rt, "recent_usb_overcurrent", return_value=True), \
                mock.patch("sys.stdout", new=io.StringIO()) as out:
            rt.explain_camera_error(RuntimeError("usb device disconnected"))
        self.assertIn("5V/5A", out.getvalue())

    def test_unrelated_error_prints_nothing(self):
        with mock.patch.object(rt, "recent_usb_overcurrent", return_value=True), \
                mock.patch("sys.stdout", new=io.StringIO()) as out:
            rt.explain_camera_error(RuntimeError("Not enough depth pixels"))
        self.assertEqual(out.getvalue(), "")

    def test_restore_failure_after_disconnect_does_not_ask_to_replug(self):
        sensor = FakeSensor()
        cam = fake_cam_with_sensor(sensor)
        with mock.patch("sys.stderr", new=io.StringIO()) as err:
            with self.assertRaises(RuntimeError):
                with rt.calibration_mode(cam, rt.EMITTER_ON):
                    sensor.fail_on = "emitter"
                    sensor.set_option = mock.Mock(side_effect=RuntimeError("failed to set power state"))
                    raise RuntimeError("usb device disconnected")
        self.assertIn("自動回到預設設定", err.getvalue())
        self.assertNotIn("請拔插", err.getvalue())


def synthetic_ir_target(cx=640, cy=360, w=250, h=143, background=40, dot=15):
    """暗的 IR 畫面 + 模糊的 4 個圓點 (寬:高 = 175:100) + 一個不在長方形上的干擾點 (像手指陰影)。"""
    img = np.full((720, 1280), background, np.uint8)
    rng = np.random.default_rng(0)
    img = np.clip(img.astype(int) + rng.integers(-3, 4, img.shape), 0, 255).astype(np.uint8)
    pts = [(cx - w // 2, cy - h // 2), (cx + w // 2, cy - h // 2), (cx - w // 2, cy + h // 2), (cx + w // 2, cy + h // 2)]
    for x, y in pts + [(cx - w, cy + h)]:
        cv2.circle(img, (x, y), 9, dot, -1)
    return cv2.GaussianBlur(img, (9, 9), 0), pts


class IrTargetTest(unittest.TestCase):
    def test_finds_four_dots_and_ignores_distractor(self):
        img, pts = synthetic_ir_target()
        dots = rt.find_target_dots(img)
        self.assertIsNotNone(dots)
        for (x, y), (ex, ey) in zip(dots, pts):
            self.assertLess(abs(x - ex) + abs(y - ey), 4)

    def test_no_target_returns_none(self):
        self.assertIsNone(rt.find_target_dots(np.full((720, 1280), 40, np.uint8)))

    def test_distance_from_dot_spacing(self):
        img, _ = synthetic_ir_target(w=250)
        dots = rt.find_target_dots(img)
        # 針孔模型:fx 642、實際 175 mm、畫面 250 px → 約 449 mm (太近)
        self.assertAlmostEqual(rt.target_distance_mm(dots, 642.0, 175.0), 449.4, delta=10)

    def test_ready_only_depends_on_sdk_detection(self):
        inside = [(600, 330), (720, 330), (600, 400), (720, 400)]
        # SDK 左右都找到:就算暗、距離不在建議範圍,也只是提醒,不擋開始
        blocking, hints = rt.ir_target_status(inside, inside, None, None, 700, 32783, 246)
        self.assertEqual(blocking, [])
        self.assertTrue(any("70 cm" in h for h in hints))
        self.assertTrue(any("很暗" in h for h in hints))

    def test_explains_why_sdk_cannot_find(self):
        inside = [(600, 330), (720, 330), (600, 400), (720, 400)]
        outside = [(300, 330), (420, 330), (300, 400), (420, 400)]  # 在中央白框左邊
        blocking, _ = rt.ir_target_status(None, None, outside, None, 900, 8000, 16)
        text = "".join(blocking)
        self.assertIn("左鏡頭的圓點不在中央方框內", text)
        self.assertIn("右鏡頭找不到 4 個圓點", text)
        blocking, _ = rt.ir_target_status(inside, None, inside, inside, 900, 8000, 16)
        self.assertIn("SDK 認不出來", "".join(blocking))

    def test_sdk_roi_check(self):
        self.assertTrue(rt.dots_inside_sdk_roi([(600, 330), (720, 330), (600, 400), (720, 400)]))
        self.assertFalse(rt.dots_inside_sdk_roi([(600, 330), (720, 330), (600, 470), (720, 470)]))  # 太靠下緣


class RetryTest(unittest.TestCase):
    def test_failure_shows_guide_and_retries(self):
        calls = iter([RuntimeError("Failed to extract target information\nfrom the captured frames!"), "ok"])

        def attempt():
            r = next(calls)
            if isinstance(r, Exception):
                raise r
            return r

        with mock.patch("sys.stdout", new=io.StringIO()) as out:
            self.assertEqual(rt.run_with_retry("Focal Length 校正", attempt, answers_from([""])), "ok")
        text = out.getvalue()
        self.assertIn("找不到標靶的 4 個圓點", text)
        self.assertIn("不要用手拿", text)
        self.assertIn("第 2 次嘗試", text)

    def test_declining_retry_returns_failure(self):
        with mock.patch("sys.stdout", new=io.StringIO()) as out:
            result = rt.run_with_retry("On-Chip 校正", mock.Mock(side_effect=RuntimeError(
                "Not enough depth pixels! - low fill factor)")), answers_from(["n"]))
        self.assertTrue(result.startswith("失敗:Not enough depth pixels"))
        self.assertIn("有效深度太少", out.getvalue())

    def test_ctrl_c_is_not_swallowed(self):
        with self.assertRaises(KeyboardInterrupt):
            rt.run_with_retry("x", mock.Mock(side_effect=KeyboardInterrupt), answers_from([]))

    def test_focal_length_retries_with_fresh_preview(self):
        previews = []
        flows = iter([RuntimeError("Failed to extract target information"), "完成"])

        def flow(*a, **k):
            r = next(flows)
            if isinstance(r, Exception):
                raise r
            return r

        with mock.patch.object(rt, "confirm_preparation", return_value=True), \
                mock.patch.object(rt, "open_camera", return_value=mock.Mock()), \
                mock.patch.object(rt, "require_depth_ready", return_value=True), \
                mock.patch.object(rt, "preview_ir_target", side_effect=lambda *a: previews.append(1) or True), \
                mock.patch.object(rt, "_depth_flow", side_effect=flow), \
                mock.patch("sys.stdout", new=io.StringIO()):
            result = rt.run_focal_length(answers_from(["", "", "", ""]))  # 寬、高、調整方式、要重試
        self.assertEqual(result, "完成")
        self.assertEqual(len(previews), 2)  # 重試時重新預覽


def board_view(dx=0.0, dy=0.0, n=24, jitter=0.0):
    """假的 ChArUco 偵測結果:n 個角點排成 6x4 格,整體平移 (dx, dy)。"""
    ids = np.arange(n).reshape(-1, 1)
    pts = np.array([[[300 + (i % 6) * 60 + dx + jitter, 200 + (i // 6) * 60 + dy]] for i in range(n)], np.float32)
    return ids, pts


class AutoCaptureTest(unittest.TestCase):
    def _hold(self, auto, view, t0, seconds, fps=30):
        shot = None
        for k in range(int(seconds * fps)):
            t = t0 + k / fps
            ok, status, _ = auto.step(*view, t)
            if ok:
                auto.mark_taken(*view, t)
                shot = t
                break
        return shot, status

    def test_takes_photo_after_holding_still(self):
        auto = rt.AutoCapture((1280, 720))
        shot, _ = self._hold(auto, board_view(), 0.0, 2.0)
        self.assertIsNotNone(shot)
        self.assertGreaterEqual(shot, rt.RGB_STILL_S)  # 要先穩定一段時間,不是一偵測到就拍

    def test_moving_board_is_not_taken(self):
        auto = rt.AutoCapture((1280, 720))
        for k in range(60):  # 每張移動 5 px
            ok, status, _ = auto.step(*board_view(dx=5 * k), k / 30)
            self.assertFalse(ok)
        self.assertIn("拿穩", status)

    def test_too_few_corners_is_not_taken(self):
        auto = rt.AutoCapture((1280, 720))
        shot, status = self._hold(auto, board_view(n=8), 0.0, 2.0)
        self.assertIsNone(shot)
        self.assertIn("角點", status)

    def test_same_pose_is_not_taken_twice_but_new_pose_is(self):
        auto = rt.AutoCapture((1280, 720))
        first, _ = self._hold(auto, board_view(), 0.0, 2.0)
        again, status = self._hold(auto, board_view(dx=10), first + 0.1, 3.0)  # 只差 10 px
        self.assertIsNone(again)
        self.assertIn("太像", status)
        moved, _ = self._hold(auto, board_view(dx=300), first + 5, 3.0)  # 換到別的位置
        self.assertIsNotNone(moved)
        self.assertEqual(len(auto.taken), 2)


class ReprojectionTest(unittest.TestCase):
    def test_region_errors_split_center_and_edge(self):
        size = (1280, 720)
        observed = np.array([[640, 360], [10, 10], [1270, 710]], dtype=np.float64)
        projected = observed + np.array([[1, 0], [3, 4], [0, 5]], dtype=np.float64)
        e = rt.region_errors(observed, projected, size)
        self.assertEqual((e["n_center"], e["n_edge"]), (1, 2))
        self.assertAlmostEqual(e["center"], 1.0)
        self.assertAlmostEqual(e["edge"], 5.0)
        self.assertAlmostEqual(e["all"], np.sqrt((1 + 25 + 25) / 3))

    def test_region_errors_handles_empty_region(self):
        e = rt.region_errors(np.array([[640.0, 360.0]]), np.array([[641.0, 360.0]]), (1280, 720))
        self.assertIsNone(e["edge"])

    def test_recommendation_prefers_clearly_better_opencv_result(self):
        self.assertIn("建議採用", rt.recommend_rgb({"all": 1.2}, {"all": 0.3}))

    def test_recommendation_when_no_clear_improvement(self):
        self.assertNotIn("建議採用", rt.recommend_rgb({"all": 0.40}, {"all": 0.38}))

    def test_recommendation_warns_when_opencv_error_is_high(self):
        self.assertIn("重新拍攝", rt.recommend_rgb({"all": 3.0}, {"all": 1.5}))


class RgbRecordTest(unittest.TestCase):
    def test_record_contains_required_fields(self):
        k = np.array([[900.0, 0, 640], [0, 900, 360], [0, 0, 1]])
        rec = rt.build_rgb_record(
            serial="SN1", image_size=(1280, 720), camera_matrix=k, dist=np.zeros(5),
            err_sdk={"all": 1.0, "center": 0.5, "edge": 1.5, "n_center": 1, "n_edge": 1},
            err_cv={"all": 0.3, "center": 0.2, "edge": 0.4, "n_center": 1, "n_edge": 1},
            n_images=20, square_mm=30.0, marker_mm=22.0, when=datetime(2026, 11, 9, 10, 0, 0),
        )
        self.assertEqual(rec["serial"], "SN1")
        self.assertEqual(rec["resolution"], {"width": 1280, "height": 720})
        self.assertEqual(rec["camera_matrix"][0][0], 900.0)
        self.assertEqual(len(rec["dist_coeffs"]), 5)
        self.assertEqual(rec["reprojection_error_px"]["sdk_factory"]["all"], 1.0)
        self.assertEqual(rec["reprojection_error_px"]["opencv"]["all"], 0.3)
        self.assertTrue(rec["date"].startswith("2026-11-09"))
        json.dumps(rec)  # 必須可以序列化

    def test_load_rgb_record_reports_corrupt_file(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "rgb_intrinsics.json"
            p.write_text("{not json", encoding="utf-8")
            with self.assertRaises(rt.ToolError):
                rt.load_rgb_record(p)

    def test_load_rgb_record_rejects_bad_matrix_shape(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "rgb_intrinsics.json"
            p.write_text(json.dumps({"camera_matrix": [[1, 2]], "dist_coeffs": [0, 0, 0, 0, 0]}), encoding="utf-8")
            with self.assertRaises(rt.ToolError):
                rt.load_rgb_record(p)

    def test_load_rgb_record_missing_file_returns_none(self):
        self.assertIsNone(rt.load_rgb_record(Path(tempfile.gettempdir()) / "nope_rgb_intrinsics.json"))


class SideBySideTest(unittest.TestCase):
    def test_side_by_side_lists_before_and_after(self):
        text = rt.format_side_by_side({"fx": 640.0, "health": 0.4}, {"fx": 641.5, "health": 0.1})
        self.assertIn("校正前", text)
        self.assertIn("校正後", text)
        self.assertRegex(text, r"fx.*640\.0.*641\.5")
        self.assertRegex(text, r"health.*0\.4.*0\.1")

    def test_side_by_side_marks_missing_values(self):
        text = rt.format_side_by_side({"health": 0.4}, {})
        self.assertRegex(text, r"health.*0\.4.*-")


class CharucoTest(unittest.TestCase):
    def setUp(self):
        self.helper = rt.CharucoHelper(cv2)
        self.board = self.helper.make_board(30.0, 22.0)

    def test_board_image_is_fully_detected(self):
        img = self.helper.board_image(self.board, (2100, 1500))
        img = cv2.copyMakeBorder(img, 100, 100, 100, 100, cv2.BORDER_CONSTANT, value=255)
        corners, ids = self.helper.detect(self.board, img)
        self.assertEqual(len(ids), 6 * 4)

    def test_object_points_are_in_mm(self):
        obj = self.helper.object_points(self.board, np.array([0, 5, 23]))
        np.testing.assert_allclose(obj[0], [30, 30, 0], atol=1e-3)
        np.testing.assert_allclose(obj[2], [180, 120, 0], atol=1e-3)

    def test_calibration_recovers_known_intrinsics(self):
        size = (1280, 720)
        k_true = np.array([[910.0, 0, 652.0], [0, 905.0, 355.0], [0, 0, 1]])
        views = synth_views(self.helper, self.board, k_true, size)
        self.assertGreaterEqual(len(views), 8)
        result = rt.calibrate_rgb(views, size)
        self.assertLess(abs(result["camera_matrix"][0, 0] - 910) / 910, 0.02)
        self.assertLess(abs(result["camera_matrix"][1, 1] - 905) / 905, 0.02)

        k_wrong = k_true.copy()
        k_wrong[0, 0] *= 1.05
        err_sdk = rt.evaluate_intrinsics(views, k_wrong, np.zeros(5), size)
        err_cv = rt.evaluate_intrinsics(views, result["camera_matrix"], result["dist"], size)
        self.assertLess(err_cv["all"], err_sdk["all"])
        self.assertLess(err_cv["all"], 1.0)


def synth_views(helper, board, k, size):
    """把 ChArUco 板用已知內參 (無畸變) 透視投影到多個姿態,再偵測角點。"""
    px_per_mm = 8
    img = helper.board_image(board, (210 * px_per_mm, 150 * px_per_mm))
    h_img, w_img = img.shape
    board_pts = np.array([[0, 0, 0], [210, 0, 0], [210, 150, 0], [0, 150, 0]], dtype=np.float64)
    src = np.array([[0, 0], [w_img, 0], [w_img, h_img], [0, h_img]], dtype=np.float32)
    views = []
    poses = [
        ((0.0, 0.0, 0.0), (-105, -75, 330)), ((0.35, 0.0, 0.0), (-105, -75, 340)),
        ((-0.35, 0.0, 0.0), (-105, -75, 340)), ((0.0, 0.35, 0.0), (-105, -75, 340)),
        ((0.0, -0.35, 0.0), (-105, -75, 340)), ((0.2, 0.2, 0.3), (-150, -110, 380)),
        ((-0.2, 0.25, -0.3), (-40, -40, 360)), ((0.25, -0.2, 0.1), (-170, -40, 400)),
        ((-0.25, -0.25, 0.0), (-50, -120, 400)), ((0.1, 0.3, 0.5), (-110, -60, 300)),
    ]
    for rvec, tvec in poses:
        proj, _ = cv2.projectPoints(board_pts, np.array(rvec), np.array(tvec, dtype=np.float64), k, np.zeros(5))
        hmat = cv2.getPerspectiveTransform(src, proj.reshape(-1, 2).astype(np.float32))
        frame = cv2.warpPerspective(img, hmat, size, borderValue=200)
        corners, ids = helper.detect(board, frame)
        if ids is not None and len(ids) >= 6:
            views.append((helper.object_points(board, ids), corners.reshape(-1, 2)))
    return views


class PdfTest(unittest.TestCase):
    def test_pdf_places_board_at_exact_physical_size_on_a4_landscape(self):
        img = np.full((1500, 2100), 255, dtype=np.uint8)
        pdf = rt.build_board_pdf(img, 210.0, 150.0, ["ChArUco 7x5"])
        self.assertTrue(pdf.startswith(b"%PDF-"))
        self.assertTrue(pdf.rstrip().endswith(b"%%EOF"))
        self.assertIn(b"/MediaBox [0 0 841.89 595.28]", pdf)
        self.assertIn(b"/PrintScaling /None", pdf)
        # 圖片的放置矩陣:寬 210 mm = 595.28 pt,高 150 mm = 425.20 pt
        self.assertRegex(pdf.decode("latin-1"), r"595\.28 0 0 425\.20 [\d.]+ [\d.]+ cm")

    def test_pdf_image_stream_roundtrips(self):
        img = (np.arange(60, dtype=np.uint8).reshape(6, 10) * 4).astype(np.uint8)
        pdf = rt.build_board_pdf(img, 100.0, 60.0, [])
        m = re.search(rb"/Width 10 /Height 6 .*?stream\n(.*?)\nendstream", pdf, re.S)
        self.assertIsNotNone(m)
        self.assertEqual(zlib.decompress(m.group(1)), img.tobytes())

    def test_pdf_xref_offsets_and_stream_lengths_are_correct(self):
        img = np.full((30, 42), 128, dtype=np.uint8)
        pdf = rt.build_board_pdf(img, 210.0, 150.0, ["a (b) c"])
        startxref = int(re.search(rb"startxref\n(\d+)\n", pdf).group(1))
        self.assertTrue(pdf[startxref:].startswith(b"xref\n"))
        entries = re.findall(rb"(\d{10}) 00000 n ", pdf[startxref:])
        self.assertEqual(len(entries), 6)
        for num, off in enumerate(entries, 1):
            self.assertTrue(pdf[int(off):].startswith(f"{num} 0 obj\n".encode()), num)
        for m in re.finditer(rb"/Length (\d+) >>\nstream\n", pdf):
            data_end = m.end() + int(m.group(1))
            self.assertTrue(pdf[data_end:].startswith(b"\nendstream"))

    def test_pdf_rejects_board_larger_than_page(self):
        with self.assertRaises(ValueError):
            rt.build_board_pdf(np.zeros((10, 10), dtype=np.uint8), 300.0, 150.0, [])


class ErrorPathTest(unittest.TestCase):
    def test_missing_pyrealsense_gives_chinese_message(self):
        with mock.patch.dict(sys.modules, {"pyrealsense2": None}):
            with self.assertRaises(rt.ToolError) as cm:
                rt.import_rs()
        self.assertIn("pyrealsense2", str(cm.exception))
        self.assertIn("build-librealsense.sh", str(cm.exception))

    def test_missing_opencv_gives_chinese_message(self):
        with mock.patch.dict(sys.modules, {"cv2": None}):
            with self.assertRaises(rt.ToolError) as cm:
                rt.import_cv2()
        self.assertIn("OpenCV", str(cm.exception))

    def test_materials_are_listed_before_the_menu(self):
        out = io.StringIO()
        with mock.patch("sys.stdout", new=out):
            rt.main_menu(input_fn=answers_from(["", "0"]))
        text = out.getvalue()
        self.assertLess(text.index("所需材料"), text.index("Spoonfull RealSense 相機維護工具"))
        for must in (rt.TARGET_PDF_URL, "ChArUco", "100%", "硬板", "尺", "捲尺", "US Letter", "A4"):
            self.assertIn(must, text)

    def test_quitting_at_materials_skips_the_menu(self):
        out = io.StringIO()
        with mock.patch("sys.stdout", new=out):
            self.assertEqual(rt.main_menu(input_fn=answers_from(["q"])), 0)
        self.assertNotIn("Spoonfull RealSense 相機維護工具", out.getvalue())

    def test_p_generates_the_charuco_pdf_first(self):
        with mock.patch.object(rt, "run_generate_charuco_pdf", return_value="ok") as gen, \
                mock.patch("sys.stdout", new=io.StringIO()):
            rt.main_menu(input_fn=answers_from(["p", "0"]))
        gen.assert_called_once()

    def test_option_13_also_lists_materials(self):
        out = io.StringIO()
        with mock.patch("sys.stdout", new=out):
            rt.show_targets()
        self.assertIn("所需材料", out.getvalue())
        self.assertIn("捲尺", out.getvalue())

    def test_menu_exits_on_zero_and_survives_tool_errors(self):
        # 第一個 Enter:看完材料清單;每個項目結束後按 Enter 回主選單
        answers = iter(["", "2", "", "99", "0"])
        out = io.StringIO()

        def boom():
            raise rt.ToolError("找不到 RealSense 相機")

        with mock.patch.object(rt, "open_camera", side_effect=boom), mock.patch("sys.stdout", new=out):
            code = rt.main_menu(input_fn=lambda _: next(answers))
        self.assertEqual(code, 0)
        self.assertIn("找不到 RealSense 相機", out.getvalue())
        self.assertIn("無效的選項", out.getvalue())

    def test_info_returns_empty_only_for_unsupported_fields(self):
        rs = mock.Mock()
        dev = mock.Mock()
        dev.supports.return_value = False
        self.assertEqual(rt._info(rs, dev, "x"), "")

    def test_info_propagates_real_device_errors(self):
        rs = mock.Mock()
        dev = mock.Mock()
        dev.supports.return_value = True
        dev.get_info.side_effect = RuntimeError("usb error")
        with self.assertRaises(RuntimeError):
            rt._info(rs, dev, "x")

    def test_non_d400_device_is_rejected(self):
        dev = mock.Mock()
        dev.get_info.side_effect = lambda key: {"name": "Intel RealSense L515", "product_line": "L500"}[key]
        rs = mock.Mock()
        rs.camera_info.name = "name"
        rs.camera_info.product_line = "product_line"
        with self.assertRaises(rt.ToolError) as cm:
            rt.check_d400(rs, dev)
        self.assertIn("D400", str(cm.exception))


if __name__ == "__main__":
    unittest.main()
