"""deploy/spoonfull.py 的單元測試 (不需要 GPIO、systemd、sudo)。

執行:python3 -m unittest discover -s deploy/tests -v
"""
from __future__ import annotations

import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import spoonfull as sf  # noqa: E402


class FakeRunner:
    """記錄要執行的指令,不真的執行。capture 的回應可以預先設定。"""

    def __init__(self, outputs=None, fail=()):
        self.commands: list[tuple[list[str], bool]] = []
        self.installed: dict[str, tuple[str, str]] = {}
        self.outputs = outputs or {}
        self.fail = set(fail)
        self.timeouts: dict[str, float | None] = {}

    def run(self, args, sudo=False, check=True, timeout=sf.CMD_TIMEOUT_S):
        self.commands.append((list(args), sudo))
        self.timeouts[" ".join(args)] = timeout
        ok = " ".join(args) not in self.fail
        if check and not ok:
            raise sf.ToolError(f"指令失敗:{' '.join(args)}")
        return ok

    def capture(self, args, timeout=None):
        self.commands.append((list(args), False))
        return self.outputs.get(" ".join(args), "")

    def install_text(self, content, dest, mode="644"):
        self.installed[str(dest)] = (content, mode)
        self.commands.append((["install", "-m", mode, "<text>", str(dest)], True))

    def joined(self):
        return [" ".join(a) for a, _ in self.commands]


def answers(*seq):
    it = iter(seq)
    return lambda _prompt="": next(it)


class TemplateTest(unittest.TestCase):
    def test_kiosk_unit_uses_user_and_runs_recover_script(self):
        unit = sf.render_unit(sf.KIOSK_UNIT, "alice")
        self.assertIn("User=alice", unit)
        self.assertNotIn("__USER__", unit)
        self.assertIn("ExecStartPre=-/bin/sh /opt/spoonfull/spoonfull-recover.sh /opt/spoonfull", unit)
        self.assertIn("ExecStart=/opt/spoonfull/spoonfull_flutter_app", unit)

    def test_hx711_unit_runs_this_file_in_bridge_mode(self):
        unit = sf.render_unit(sf.HX711_UNIT, "alice")
        self.assertIn("User=alice", unit)
        self.assertIn("ExecStart=/usr/bin/python3 /opt/spoonfull/spoonfull.py hx711-bridge", unit)

    def test_render_rejects_unsafe_user_names(self):
        for bad in ["", "root;rm", "a b", "../x", "Alice\n[Service]", "alice\n"]:
            with self.subTest(bad=bad), self.assertRaises(sf.ToolError):
                sf.render_unit(sf.KIOSK_UNIT, bad)

    def test_udev_rules_cover_realsense_hid_and_serial(self):
        self.assertIn('ATTRS{idVendor}=="8086"', sf.UDEV_RULES)
        self.assertIn('KERNEL=="hidraw*"', sf.UDEV_RULES)
        self.assertIn('KERNEL=="ttyUSB*"', sf.UDEV_RULES)
        self.assertIn('KERNEL=="ttyACM*"', sf.UDEV_RULES)


class RunnerTest(unittest.TestCase):
    def test_sudo_prefix_only_when_not_root(self):
        self.assertEqual(sf.Runner(euid=1000).command(["systemctl", "start", "x"], sudo=True),
                         ["sudo", "systemctl", "start", "x"])
        self.assertEqual(sf.Runner(euid=0).command(["systemctl", "start", "x"], sudo=True),
                         ["systemctl", "start", "x"])
        self.assertEqual(sf.Runner(euid=1000).command(["ls"], sudo=False), ["ls"])

    def test_missing_program_becomes_tool_error(self):
        with mock.patch("sys.stdout", new=io.StringIO()), self.assertRaises(sf.ToolError) as cm:
            sf.Runner(euid=1000).run(["definitely-not-a-real-program-xyz"])
        self.assertIn("找不到", str(cm.exception))

    def test_timeout_respects_check(self):
        r = sf.Runner(euid=1000)
        slow = [sys.executable, "-c", "import time; time.sleep(5)"]
        with mock.patch("sys.stdout", new=io.StringIO()):
            self.assertFalse(r.run(slow, check=False, timeout=0.5))
            with self.assertRaises(sf.ToolError) as cm:
                r.run(slow, timeout=0.5)
        self.assertIn("秒", str(cm.exception))

    def test_failed_command_raises_unless_check_false(self):
        r = sf.Runner(euid=1000)
        with mock.patch("sys.stdout", new=io.StringIO()):
            self.assertFalse(r.run([sys.executable, "-c", "import sys; sys.exit(3)"], check=False))
            with self.assertRaises(sf.ToolError):
                r.run([sys.executable, "-c", "import sys; sys.exit(3)"])


class InstallTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.here = Path(self.tmp.name)
        for name in ("spoonfull-recover.sh", "realsense_bridge.py", "realsense_tool.py", "spoonfull.py"):
            (self.here / name).write_text("#", encoding="utf-8")

    def tearDown(self):
        self.tmp.cleanup()

    def _install(self, *ans, app_exists=True):
        runner = FakeRunner()
        with mock.patch.object(sf, "HERE", self.here), \
                mock.patch.object(sf, "app_installed", return_value=app_exists), \
                mock.patch.object(sf, "pyrealsense_available", return_value=True), \
                mock.patch.object(sf, "user_exists", side_effect=lambda u: u in ("alice", "bob", "root")), \
                mock.patch("sys.stdout", new=io.StringIO()) as out:
            sf.install_device(runner, input_fn=answers(*ans), current_user="alice")
        return runner, out.getvalue()

    def test_root_or_unknown_account_is_rejected_before_any_change(self):
        for user in ("root", "nobody_here"):
            with self.subTest(user=user):
                with self.assertRaises(sf.ToolError):
                    runner, _ = self._install(user, "", "", "")
                runner = FakeRunner()  # _install 丟例外時拿不到 runner;改直接呼叫確認沒有指令
                with mock.patch.object(sf, "HERE", self.here), \
                        mock.patch.object(sf, "user_exists", side_effect=lambda u: u == "root"), \
                        mock.patch("sys.stdout", new=io.StringIO()), self.assertRaises(sf.ToolError):
                    sf.install_device(runner, input_fn=answers(user, "", "", ""), current_user="alice")
                self.assertEqual(runner.commands, [])

    def test_apt_has_no_timeout(self):
        # apt 被逾時殺掉會留下 dpkg 鎖;改成不設 timeout,要中斷由使用者 Ctrl-C
        runner, _ = self._install("", "", "", "")
        apt = [c for c in runner.timeouts if c.startswith("apt-get")]
        self.assertTrue(apt)
        self.assertTrue(all(runner.timeouts[c] is None for c in apt))

    def test_default_answers_install_without_autostart_or_hx711(self):
        # 帳號 Enter=alice、開機自動啟動 Enter=否、HX711 Enter=否
        runner, _ = self._install("", "", "", "")
        cmds = runner.joined()
        self.assertEqual(runner.installed["/etc/udev/rules.d/99-spoonfull-hardware.rules"][0], sf.UDEV_RULES)
        self.assertIn("User=alice", runner.installed["/etc/systemd/system/spoonfull-kiosk.service"][0])
        self.assertIn("usermod -aG video,dialout,plugdev alice", cmds)
        self.assertIn("systemctl disable --now spoonfull-kiosk.service", cmds)
        self.assertNotIn("systemctl enable spoonfull-kiosk.service", cmds)
        self.assertNotIn("/etc/systemd/system/spoonfull-hx711.service", runner.installed)
        self.assertIn("chown -R alice /opt/spoonfull", cmds)
        self.assertTrue(any(c.endswith("/opt/spoonfull/spoonfull-recover.sh") for c in cmds))
        self.assertTrue(any(c.endswith("/opt/spoonfull/spoonfull.py") for c in cmds))

    def test_autostart_and_hx711_when_answered_yes(self):
        runner, _ = self._install("", "y", "y", "", "n")  # 最後一個:要現在校正 HX711 嗎 → 否
        cmds = runner.joined()
        self.assertIn("systemctl enable spoonfull-kiosk.service", cmds)
        self.assertIn("/etc/systemd/system/spoonfull-hx711.service", runner.installed)
        self.assertIn("systemctl enable --now spoonfull-hx711.service", cmds)

    def test_other_user_name_is_used(self):
        runner, _ = self._install("bob", "", "", "")
        self.assertIn("User=bob", runner.installed["/etc/systemd/system/spoonfull-kiosk.service"][0])

    def test_downloads_app_only_when_missing_and_confirmed(self):
        runner, _ = self._install("", "", "", "", "", app_exists=False)  # 最後的 Enter = 下載 (預設是)
        self.assertTrue(any(c.startswith("curl ") for c in runner.joined()))
        runner, _ = self._install("", "", "", "", app_exists=True)
        self.assertFalse(any(c.startswith("curl ") for c in runner.joined()))

    def test_missing_support_files_stop_before_touching_the_system(self):
        (self.here / "spoonfull-recover.sh").unlink()
        runner = FakeRunner()
        with mock.patch.object(sf, "HERE", self.here), mock.patch("sys.stdout", new=io.StringIO()):
            with self.assertRaises(sf.ToolError) as cm:
                sf.install_device(runner, input_fn=answers("", "", ""), current_user="alice")
        self.assertIn("spoonfull-recover.sh", str(cm.exception))
        self.assertEqual(runner.commands, [])


class Hx711Test(unittest.TestCase):
    def test_reading_line_format_matches_app_parser(self):
        # App 的 LineScaleReader 依這個格式解析,不能改
        self.assertEqual(sf.format_reading(420.0, True), "ST,GS,   420.0 g")
        self.assertEqual(sf.format_reading(-3.25, False), "US,GS,    -3.2 g")

    def test_stability_needs_five_close_readings(self):
        self.assertFalse(sf.is_stable([1.0, 1.0, 1.0, 1.0], 2.0))
        self.assertTrue(sf.is_stable([1.0, 2.0, 1.5, 1.0, 2.9], 2.0))
        self.assertFalse(sf.is_stable([1.0, 2.0, 1.5, 1.0, 3.1], 2.0))

    def test_calibrate_computes_scale_and_saves_config(self):
        with tempfile.TemporaryDirectory() as d:
            cfg_path = Path(d) / "hx711.json"
            sensor = sf.FakeHX711(grams=500.0)
            sensor.t = 100  # 跳過開頭的晃動
            zero = sf.FakeHX711(grams=0.0)
            zero.t = 100
            seq = iter([zero, sensor])

            class Switching:
                def read_median(self, n=5):
                    return current.read_median(n)

            current = next(seq)

            def ask(_prompt):
                nonlocal current
                value = ""
                if "砝碼" in _prompt:
                    current = next(seq)
                return value

            with mock.patch.object(sf, "HX711_CONFIG", cfg_path), mock.patch("sys.stdout", new=io.StringIO()):
                cfg = sf.calibrate_hx711(Switching(), 500.0, {"dout": 5, "sck": 6}, input_fn=ask)
            saved = json.loads(cfg_path.read_text(encoding="utf-8"))
        self.assertAlmostEqual(cfg["scale"], 100.0, delta=0.5)
        self.assertEqual(saved["dout"], 5)
        self.assertAlmostEqual(saved["scale"], cfg["scale"])

    def test_calibrate_rejects_no_change(self):
        with tempfile.TemporaryDirectory() as d, mock.patch.object(sf, "HX711_CONFIG", Path(d) / "h.json"), \
                mock.patch("sys.stdout", new=io.StringIO()):
            sensor = sf.FakeHX711(grams=0.0)
            sensor.t = 100
            with self.assertRaises(sf.ToolError):
                sf.calibrate_hx711(sensor, 500.0, {}, input_fn=lambda _: "")

    def test_bridge_loop_with_fake_sensor_reaches_stable_reading(self):
        lines: list[str] = []
        sf.bridge_loop(sf.FakeHX711(), {"offset": 8000, "scale": 100.0}, lines.append,
                       period=0, stable_g=2.0, iterations=15, sleep=lambda _: None)
        self.assertEqual(len(lines), 15)
        self.assertTrue(lines[0].startswith("US,GS,"))
        self.assertEqual(lines[-1], "ST,GS,   420.0 g")

    def test_bridge_loop_reports_sensor_not_ready(self):
        class Dead:
            def read_median(self, n=5):
                return None

        lines: list[str] = []
        sf.bridge_loop(Dead(), {"offset": 0, "scale": 1.0}, lines.append, period=0, stable_g=2.0,
                       iterations=2, sleep=lambda _: None)
        self.assertEqual(lines, ["ERR,HX711 not ready", "ERR,HX711 not ready"])

    def test_load_config_rejects_bad_values(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "hx711.json"
            p.write_text(json.dumps({"offset": 1, "scale": 0}), encoding="utf-8")
            with mock.patch.object(sf, "HX711_CONFIG", p), self.assertRaises(sf.ToolError):
                sf.load_hx711_config()
            p.write_text("{bad", encoding="utf-8")
            with mock.patch.object(sf, "HX711_CONFIG", p), self.assertRaises(sf.ToolError):
                sf.load_hx711_config()

    def test_load_config_defaults_when_missing(self):
        with tempfile.TemporaryDirectory() as d, mock.patch.object(sf, "HX711_CONFIG", Path(d) / "none.json"):
            cfg = sf.load_hx711_config()
        self.assertEqual((cfg["dout"], cfg["sck"], cfg["scale"]), (5, 6, 1.0))


class Hx711ServiceTest(unittest.TestCase):
    def test_service_is_restarted_even_when_action_fails(self):
        runner = FakeRunner(outputs={"systemctl is-active spoonfull-hx711.service": "active",
                                     "systemctl is-enabled spoonfull-hx711.service": "enabled"})

        def boom():
            raise sf.ToolError("讀不到 HX711")

        with mock.patch("sys.stdout", new=io.StringIO()), self.assertRaises(sf.ToolError):
            sf._with_hx711_service_paused(runner, answers(""), boom)
        cmds = runner.joined()
        self.assertIn("systemctl stop spoonfull-hx711.service", cmds)
        self.assertIn("systemctl start spoonfull-hx711.service", cmds)

    def test_not_found_unit_counts_as_not_installed(self):
        runner = FakeRunner(outputs={"systemctl is-enabled spoonfull-hx711.service": "not-found"})
        with mock.patch("sys.stdout", new=io.StringIO()):
            self.assertEqual(sf.hx711_service(runner, answers()), "未安裝")

    def test_config_owned_by_other_account_is_refused(self):
        # 服務以 pi 執行、讀 /home/pi/.config;用 admin 登入校正會寫錯檔案
        with tempfile.TemporaryDirectory() as d:
            unit = Path(d) / "spoonfull-hx711.service"
            unit.write_text(sf.render_unit(sf.HX711_UNIT, "pi"), encoding="utf-8")
            with mock.patch.object(sf, "HX711_UNIT_PATH", unit), \
                    mock.patch.object(sf.getpass, "getuser", return_value="admin"), \
                    mock.patch("sys.stdout", new=io.StringIO()):
                with self.assertRaises(sf.ToolError) as cm:
                    sf.hx711_calibrate(FakeRunner(), answers("500"))
        self.assertIn("pi", str(cm.exception))

    def test_bridge_mode_reports_bad_config_and_exits_1(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "hx711.json"
            p.write_text("{bad", encoding="utf-8")
            with mock.patch.object(sf, "HX711_CONFIG", p), mock.patch("sys.stderr", new=io.StringIO()) as err:
                self.assertEqual(sf.main(["hx711-bridge"]), 1)
        self.assertIn("無法讀取", err.getvalue())


class RestoreTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        (self.dir / "spoonfull-recover.sh").write_text("#", encoding="utf-8")

    def tearDown(self):
        self.tmp.cleanup()

    def _restore(self, *ans):
        runner = FakeRunner()
        with mock.patch.object(sf, "INSTALL_DIR", self.dir), mock.patch("sys.stdout", new=io.StringIO()) as out:
            result = sf.restore_previous_app(runner, answers(*ans))
        return runner, result, out.getvalue()

    def test_nothing_to_restore_without_markers(self):
        (self.dir / "app.spoonfull-old").write_text("old", encoding="utf-8")
        runner, result, _ = self._restore()
        self.assertEqual(result, "沒有可還原的版本")
        self.assertEqual(runner.commands, [])

    def test_restoring_unconfirmed_build_marks_it_bad(self):
        # 不記成壞版本的話,還原後 App 又會自動把同一版裝回來 (update_service.dart 只跳過 .update-bad-build)
        (self.dir / "app.spoonfull-old").write_text("old", encoding="utf-8")
        (self.dir / ".update-pending").write_text("42", encoding="utf-8")
        (self.dir / ".boot-count").write_text("1", encoding="utf-8")
        runner, result, _ = self._restore("y", "n")
        self.assertEqual((self.dir / ".update-bad-build").read_text(encoding="utf-8"), "42")
        self.assertFalse((self.dir / ".update-pending").exists())
        self.assertFalse((self.dir / ".boot-count").exists())
        self.assertTrue((self.dir / ".update-in-progress").exists())  # 讓 recover.sh 走「換回舊檔」分支
        cmds = runner.joined()
        self.assertIn("systemctl stop spoonfull-kiosk.service", cmds)
        self.assertTrue(cmds[-1].startswith("sh ") and cmds[-1].endswith("spoonfull-recover.sh " + self.dir.as_posix()))
        self.assertEqual(result, "已還原上一版")

    def test_declining_changes_nothing(self):
        (self.dir / "app.spoonfull-old").write_text("old", encoding="utf-8")
        (self.dir / ".update-pending").write_text("42", encoding="utf-8")
        runner, result, _ = self._restore("n")
        self.assertEqual(result, "取消")
        self.assertTrue((self.dir / ".update-pending").exists())
        self.assertEqual(runner.commands, [])


class MenuTest(unittest.TestCase):
    def test_zero_exits(self):
        with mock.patch("sys.stdout", new=io.StringIO()):
            self.assertEqual(sf.main_menu(FakeRunner(), input_fn=answers("0")), 0)

    def test_invalid_choice_is_reported(self):
        with mock.patch("sys.stdout", new=io.StringIO()) as out:
            sf.main_menu(FakeRunner(), input_fn=answers("42", "0"))
        self.assertIn("無效的選項", out.getvalue())

    def test_tool_errors_are_shown_and_menu_continues(self):
        with mock.patch.object(sf, "start_app", side_effect=sf.ToolError("找不到 systemctl")), \
                mock.patch("sys.stdout", new=io.StringIO()) as out:
            code = sf.main_menu(FakeRunner(), input_fn=answers("2", "", "0"))
        self.assertEqual(code, 0)
        self.assertIn("找不到 systemctl", out.getvalue())

    def test_running_as_root_is_refused(self):
        with mock.patch("sys.stdout", new=io.StringIO()) as out:
            code = sf.main([], euid=0)
        self.assertEqual(code, 1)
        self.assertIn("一般使用者", out.getvalue())


if __name__ == "__main__":
    unittest.main()
