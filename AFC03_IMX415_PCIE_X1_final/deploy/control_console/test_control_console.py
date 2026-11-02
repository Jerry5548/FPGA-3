import importlib.util
import json
import shlex
import unittest
from pathlib import Path
from threading import Thread
from http.server import ThreadingHTTPServer
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from unittest.mock import patch

MODULE_PATH = Path(__file__).with_name("control_console.py")
SPEC = importlib.util.spec_from_file_location("control_console", MODULE_PATH)
app = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(app)


class ValidationTests(unittest.TestCase):
    def setUp(self):
        self.settings = {
            "host": "192.168.137.194", "username": "linaro", "port": 22,
            "deploy_dir": "/home/linaro/deploy",
        }

    def test_dynamic_board_addresses_are_accepted(self):
        for host in ("192.168.137.194", "192.168.137.42", "rk3576.local"):
            with self.subTest(host=host):
                self.assertEqual(app.validate_settings({**self.settings, "host": host})["host"], host)

    def test_invalid_network_and_path_values_are_rejected(self):
        for key, value in (("host", "127.0.0.1;whoami"), ("username", "root;id"),
                           ("port", 0), ("deploy_dir", "/home/linaro/../tmp")):
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                app.validate_settings({**self.settings, key: value})

    def test_start_command_is_fixed_and_shell_quoted(self):
        cmd = app.build_remote_command("start", self.settings, {
            "source": "lz77", "mode": "9", "connector": "188", "yolo": True,
            "model": "/home/linaro/deploy/yolo/yolov5s_relu.rknn", "kms_overlay": True,
        })
        self.assertIn("web_control_board.sh start", cmd)
        self.assertIn("lz77 9 188 1", cmd)
        self.assertEqual(shlex.split(cmd)[-2:], ["1", "20"])

    def test_dma_wait_start_and_live_change_are_validated(self):
        for value in (0, 10, 20, "0", "10", "20"):
            with self.subTest(value=value):
                cmd = app.build_remote_command("dma-wait-set", self.settings, {"dma_wait_us": value})
                self.assertEqual(shlex.split(cmd)[-1], str(value))
                for mode in app.VALID_MODES:
                    cmd = app.build_remote_command("start", self.settings, {
                        "source": "lz77", "mode": mode, "dma_wait_us": value})
                    self.assertEqual(shlex.split(cmd)[-1], str(value))
        for value in (-1, 1, 30, 50, True, False, None, "20;id", "20\n", 20.0):
            with self.subTest(value=value), self.assertRaises(ValueError):
                app.build_remote_command("dma-wait-set", self.settings, {"dma_wait_us": value})

    def test_dma_status_uses_actual_readback_and_reports_old_driver(self):
        current = app.board_dma_status("DMA_WAIT_SUPPORTED=1\nDMA_WAIT_US=20\nDMA_PROFILE=N\n")
        self.assertEqual(current, {"dma_wait_supported": True, "dma_wait_us": 20,
                                   "dma_profile_enabled": False})
        old = app.board_dma_status("DMA_WAIT_SUPPORTED=0\nDMA_WAIT_US=unavailable\n")
        self.assertFalse(old["dma_wait_supported"])
        self.assertIsNone(old["dma_wait_us"])
        self.assertIsNone(app.board_dma_status("READY")["dma_wait_supported"])
        self.assertIsNone(app.board_dma_status("DMA_WAIT_US=999\n")["dma_wait_us"])

    def test_start_rejects_invalid_budget_before_ssh(self):
        with patch.object(app.subprocess, "run") as run, self.assertRaises(ValueError):
            app.run_remote("start", {**self.settings, "source": "lz77", "dma_wait_us": "20;id"})
        run.assert_not_called()

    def test_arbitrary_action_and_invalid_start_values_are_rejected(self):
        with self.assertRaises(ValueError):
            app.build_remote_command("shell", self.settings, {})
        with self.assertRaises(ValueError):
            app.build_remote_command("start", self.settings, {"source": "raw;id"})

    def test_boolean_flags_are_not_coerced_from_strings(self):
        with self.assertRaises(ValueError):
            app.build_remote_command("start", self.settings, {"yolo": "false"})


class SshTests(unittest.TestCase):
    def test_invokes_ssh_in_batch_mode_without_password_argument(self):
        completed = type("Completed", (), {"returncode": 0, "stdout": "READY", "stderr": ""})()
        with patch.object(app.shutil, "which", return_value="ssh.exe"), \
             patch.object(app.subprocess, "run", return_value=completed) as run:
            result = app.run_remote("ping", {
                "host": "192.168.137.22", "username": "linaro", "port": 22,
                "deploy_dir": "/home/linaro/deploy",
            })
        self.assertTrue(result["ok"])
        args = run.call_args.args[0]
        self.assertIn("BatchMode=yes", args)
        self.assertIn("linaro@192.168.137.22", args)
        self.assertFalse(any("password" in arg.lower() for arg in args))

    def test_remote_device_permission_error_is_not_misreported_as_ssh_auth_failure(self):
        completed = type("Completed", (), {
            "returncode": 1, "stdout": "", "stderr": "devmem: can't open '/dev/mem': Permission denied",
        })()
        with patch.object(app.shutil, "which", return_value="ssh.exe"), \
             patch.object(app.subprocess, "run", return_value=completed):
            result = app.run_remote("start", {
                "host": "192.168.137.22", "username": "linaro", "port": 22,
                "deploy_dir": "/home/linaro/deploy", "source": "raw", "mode": "0",
                "connector": "188", "yolo": False,
            })
        self.assertFalse(result["ok"])
        self.assertIn("/dev/mem", result["output"])
        self.assertNotIn("SSH 密钥登录", result["output"])

    def test_ssh_publickey_failure_gets_actionable_hint(self):
        completed = type("Completed", (), {
            "returncode": 255, "stdout": "", "stderr": "linaro@192.168.137.22: Permission denied (publickey).",
        })()
        with patch.object(app.shutil, "which", return_value="ssh.exe"), \
             patch.object(app.subprocess, "run", return_value=completed):
            result = app.run_remote("ping", {
                "host": "192.168.137.22", "username": "linaro", "port": 22,
                "deploy_dir": "/home/linaro/deploy",
            })
        self.assertIn("SSH 密钥登录", result["output"])


class HttpTests(unittest.TestCase):
    def setUp(self):
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), app.Handler)
        self.thread = Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)

    def test_page_has_fresh_token_and_no_remote_preview(self):
        page = urlopen(self.base + "/").read().decode("utf-8")
        self.assertIn("慧眼哨兵", page)
        self.assertNotIn("__TOKEN__", page)
        self.assertIn("本版不传视频流", page)
        self.assertIn('id="dmaWait"', page)
        self.assertIn('value="20" selected', page)
        self.assertIn('data-action="dma-wait-set"', page)

    def test_dma_action_reaches_bridge_and_returns_confirmed_budget(self):
        payload = {"action": "dma-wait-set", "host": "192.168.137.194", "dma_wait_us": "20"}
        response = {"ok": True, "output": "DMA_WAIT_SUPPORTED=1\nDMA_WAIT_US=20\n",
                    "dma_wait_supported": True, "dma_wait_us": 20, "dma_profile_enabled": False}
        request = Request(self.base + "/api/action", data=json.dumps(payload).encode(),
                          headers={"Content-Type": "application/json", "X-Control-Token": app.TOKEN},
                          method="POST")
        with patch.object(app, "run_remote", return_value=response) as run:
            with urlopen(request) as reply:
                self.assertEqual(json.load(reply)["dma_wait_us"], 20)
        run.assert_called_once_with("dma-wait-set", payload)

    def test_actions_require_page_token(self):
        request = Request(self.base + "/api/action", data=json.dumps({"action": "ping"}).encode(),
                          headers={"Content-Type": "application/json"}, method="POST")
        with self.assertRaises(HTTPError) as exc:
            urlopen(request)
        self.assertEqual(exc.exception.code, 403)
        exc.exception.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
