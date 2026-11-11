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
import unittest
import zlib
from datetime import datetime
from pathlib import Path
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
        with rt.calibration_mode(fake_cam_with_sensor(sensor)):
            self.assertEqual(sensor.values, {"emitter": 0, "thermal": 0, "ae": 1})
        self.assertEqual(sensor.values, {"emitter": 1.0, "thermal": 1.0, "ae": 0.0})

    def test_partial_setup_failure_restores_options_already_changed(self):
        sensor = FakeSensor(fail_on="thermal")
        with self.assertRaises(RuntimeError), mock.patch("sys.stderr", new=io.StringIO()):
            with rt.calibration_mode(fake_cam_with_sensor(sensor)):
                self.fail("不應該進到 with 區塊")
        self.assertEqual(sensor.values["emitter"], 1.0)


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
            auto, result, _ = self._run("y", Path(d))
            backups = list(Path(d).glob("*.json"))
            self.assertEqual(len(backups), 1)
            self.assertEqual(json.loads(backups[0].read_text(encoding="utf-8"))["table"], [1, 1, 1])
        self.assertEqual(auto.calls[-2:], ["set", "write"])
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
