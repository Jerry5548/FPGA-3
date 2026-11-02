#!/usr/bin/env python3
"""Loopback-only web UI for the RK3576 FPGA video controls."""
from __future__ import annotations

import ipaddress
import json
import os
import re
import secrets
import shlex
import shutil
import subprocess
import threading
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
BOARD_SCRIPT_NAME = "web_control_board.sh"
TOKEN = secrets.token_urlsafe(32)
PORT = int(os.environ.get("FPGA_CONTROL_PORT", "8765"))
MAX_BODY = 8192
VALID_MODES = {"0", "1", "2", "3", "4", "5", "6", "8", "9"}
VALID_DMA_WAIT = {"0", "10", "20"}


def validate_dma_wait(value=20) -> str:
    value = str(value)
    if value not in VALID_DMA_WAIT:
        raise ValueError("DMA 等待预算只能选择 0、10 或 20 微秒")
    return value


def board_dma_status(output: str) -> dict:
    supported = re.search(r"^DMA_WAIT_SUPPORTED=([01])$", output, re.M)
    actual = re.search(r"^DMA_WAIT_US=([0-9]+)$", output, re.M)
    profiling = re.search(r"^DMA_PROFILE=([01YyNn])$", output, re.M)
    return {
        "dma_wait_supported": bool(int(supported[1])) if supported else None,
        "dma_wait_us": int(actual[1]) if actual and 0 <= int(actual[1]) <= 50 else None,
        "dma_profile_enabled": profiling[1] in "1Yy" if profiling else None,
    }


def validate_settings(data: dict) -> dict:
    host = str(data.get("host", "")).strip()
    if not host or len(host) > 253:
        raise ValueError("请填写板卡 IP 或主机名")
    try:
        ipaddress.ip_address(host)
    except ValueError:
        if not re.fullmatch(r"(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(?:\.(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?))*", host):
            raise ValueError("板卡地址格式不正确")
    user = str(data.get("username", "linaro")).strip()
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.-]{0,31}", user):
        raise ValueError("SSH 用户名格式不正确")
    try:
        port = int(data.get("port", 22))
    except (TypeError, ValueError):
        raise ValueError("SSH 端口必须是数字")
    if not 1 <= port <= 65535:
        raise ValueError("SSH 端口范围应为 1–65535")
    deploy = str(data.get("deploy_dir", "/home/linaro/deploy")).strip()
    if not re.fullmatch(r"/[A-Za-z0-9_./-]{1,180}", deploy) or ".." in deploy.split("/"):
        raise ValueError("板端 deploy 路径必须是绝对路径，且不能包含 ..")
    return {"host": host, "username": user, "port": port, "deploy_dir": deploy}


def build_remote_command(action: str, settings: dict, data: dict) -> str:
    script = settings["deploy_dir"].rstrip("/") + "/" + BOARD_SCRIPT_NAME
    args = ["bash", script, action, settings["deploy_dir"]]
    if action == "start":
        source = data.get("source", "raw")
        mode = str(data.get("mode", "0"))
        connector = str(data.get("connector", "188"))
        yolo_value = data.get("yolo", False)
        kms_value = data.get("kms_overlay", True)
        if not isinstance(yolo_value, bool) or not isinstance(kms_value, bool):
            raise ValueError("YOLO/KMS 开关值无效")
        yolo = yolo_value
        model = str(data.get("model", "/home/linaro/deploy/yolo/yolov5s_relu.rknn"))
        kms = kms_value
        if source not in ("raw", "lz77"):
            raise ValueError("视频源只能选择原图或 LZ77")
        if mode not in VALID_MODES:
            raise ValueError("不支持此 FPGA 模式")
        if not re.fullmatch(r"[0-9]{1,6}", connector):
            raise ValueError("HDMI connector ID 必须为数字")
        if not re.fullmatch(r"/[A-Za-z0-9_./-]{1,200}", model) or ".." in model.split("/"):
            raise ValueError("模型路径格式不正确")
        args.extend([source, mode, connector, "1" if yolo else "0", model,
                     "1" if kms else "0", validate_dma_wait(data.get("dma_wait_us", 20))])
    elif action == "dma-wait-set":
        args.append(validate_dma_wait(data.get("dma_wait_us", 20)))
    if action not in {"ping", "status", "start", "stop", "snapshot", "record-start", "record-stop", "capture-status", "dma-wait-set"}:
        raise ValueError("不支持的控制操作")
    return " ".join(shlex.quote(part) for part in args)


def run_remote(action: str, data: dict) -> dict:
    settings = validate_settings(data)
    # Prefer Windows OpenSSH over sandbox or packaging shims named ssh.
    windir = os.environ.get("WINDIR", r"C:\Windows")
    windows_ssh = Path(windir) / "System32" / "OpenSSH" / "ssh.exe"
    ssh = str(windows_ssh) if windows_ssh.is_file() else shutil.which("ssh")
    if ssh and Path(ssh).suffix.lower() in {".bat", ".cmd"}:
        ssh = None
    if not ssh:
        raise RuntimeError("找不到 Windows OpenSSH 的 ssh.exe；请在 Windows 功能中安装 OpenSSH Client")
    remote = build_remote_command(action, settings, data)
    target = f"{settings['username']}@{settings['host']}"
    command = [ssh, "-p", str(settings["port"]), "-T", "-o", "BatchMode=yes",
               "-o", "ConnectTimeout=6", "-o", "ServerAliveInterval=3",
               "-o", "ServerAliveCountMax=2", target, remote]
    timeout = 35 if action in {"stop", "record-stop"} else 20
    result = subprocess.run(command, capture_output=True, text=True, timeout=timeout,
                            encoding="utf-8", errors="replace", check=False)
    output = (result.stdout + result.stderr).strip()
    if result.returncode != 0:
        # Only classify SSH's public-key authentication diagnostic here.
        # Remote programs can also print "Permission denied" for /dev/mem,
        # capture devices or files after SSH has already authenticated.
        if re.search(r"Permission denied \(publickey(?:,[^)]+)?\)", output):
            output += "\n请先配置 Windows OpenSSH 密钥登录；网页不会保存 SSH 密码。"
        elif "REMOTE HOST IDENTIFICATION HAS CHANGED" in output:
            output += "\n板卡主机指纹变化，请先在 PowerShell 核对并更新 known_hosts。"
    return {"ok": result.returncode == 0, "returncode": result.returncode,
            "output": output or ("操作完成" if result.returncode == 0 else "SSH 命令失败"),
            **board_dma_status(output)}


class Handler(BaseHTTPRequestHandler):
    server_version = "FPGAControl/1.0"

    def log_message(self, fmt, *args):
        print("[%s] %s" % (self.log_date_time_string(), fmt % args))

    def _json(self, status: int, value: dict):
        body = json.dumps(value, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/":
            body = (HERE / "index.html").read_text(encoding="utf-8").replace("__TOKEN__", TOKEN).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/api/health":
            self._json(200, {"ok": True, "app": "FPGA 控制台"})
        else:
            self._json(404, {"ok": False, "output": "Not found"})

    def do_POST(self):
        if self.path != "/api/action":
            self._json(404, {"ok": False, "output": "Not found"})
            return
        if not secrets.compare_digest(self.headers.get("X-Control-Token", ""), TOKEN):
            self._json(403, {"ok": False, "output": "页面令牌无效，请刷新控制台"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > MAX_BODY:
                raise ValueError("请求大小无效")
            data = json.loads(self.rfile.read(length))
            if not isinstance(data, dict):
                raise ValueError("请求格式无效")
            result = run_remote(str(data.get("action", "")), data)
            self._json(200 if result["ok"] else 502, result)
        except (ValueError, json.JSONDecodeError) as exc:
            self._json(400, {"ok": False, "output": str(exc)})
        except subprocess.TimeoutExpired:
            self._json(504, {"ok": False, "output": "SSH 操作超时；请检查板卡连接和播放日志"})
        except Exception as exc:
            self._json(500, {"ok": False, "output": f"{type(exc).__name__}: {exc}"})


class LocalServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    if not 1024 <= PORT <= 65535:
        raise SystemExit("FPGA_CONTROL_PORT must be between 1024 and 65535")
    server = LocalServer(("127.0.0.1", PORT), Handler)
    url = f"http://127.0.0.1:{PORT}/"
    print(f"FPGA web control ready: {url}")
    print("Loopback only. Close this window to stop the local control service.")
    threading.Timer(0.7, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever(poll_interval=0.25)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
