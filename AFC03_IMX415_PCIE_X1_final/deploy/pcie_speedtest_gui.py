#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
PCIe DMA 仪表盘测速工具
Target: RK3576 + Anlogic FPGA (SGDMA)
Device: /dev/sgdma0_c2h_0 (FPGA→Host), /dev/sgdma0_h2c_0 (Host→FPGA)
Requires: python3-tk (apt install python3-tk)
"""

import tkinter as tk
from tkinter import ttk, messagebox
import math
import time
import os
import threading
import struct

# ── 常量 ──
C2H_DEV = "/dev/sgdma0_c2h_0"
H2C_DEV = "/dev/sgdma0_h2c_0"
MAX_SPEED_MB = 500       # Gen2 x1 理论最大 ~500 MB/s
GAUGE_MIN = 0
GAUGE_MAX = MAX_SPEED_MB
UPDATE_INTERVAL_MS = 100  # GUI 刷新间隔

# ── 配色 ──
BG_DARK   = "#1a1a2e"
BG_PANEL  = "#16213e"
FG_TEXT   = "#e0e0e0"
FG_DIM    = "#8899aa"
GREEN     = "#00e676"
YELLOW    = "#ffea00"
RED       = "#ff1744"
CYAN      = "#00bcd4"
ORANGE    = "#ff9100"
NEEDLE    = "#ff5252"
GAUGE_BG  = "#0f3460"


class GaugeWidget(tk.Canvas):
    """仪表盘控件 — 圆弧+指针+数字"""

    def __init__(self, parent, size=300, label="Speed", unit="MB/s",
                 min_val=0, max_val=500, **kw):
        super().__init__(parent, width=size, height=size * 0.75,
                         bg=BG_DARK, highlightthickness=0, **kw)
        self.size = size
        self.cx = size / 2
        self.cy = size * 0.55
        self.r = size * 0.38
        self.min_val = min_val
        self.max_val = max_val
        self.label = label
        self.unit = unit
        self.value = 0.0
        self._draw_static()
        self._needle_id = None
        self._text_id = None
        self._label_id = None
        self.set_value(0)

    def _val_to_angle(self, val):
        """值 → 角度 (225° ~ -45°, 即从左下到右下跨 270°)"""
        frac = (val - self.min_val) / (self.max_val - self.min_val)
        frac = max(0, min(1, frac))
        return math.radians(225 - frac * 270)

    def _draw_static(self):
        cx, cy, r = self.cx, self.cy, self.r
        # 外弧背景
        self._draw_arc(cx, cy, r + 8, 225, -270, width=16, outline="#0a0a1a")
        # 绿色区间 0~60%
        self._draw_arc(cx, cy, r, 225, -162, width=10, outline=GREEN)
        # 黄色区间 60~80%
        self._draw_arc(cx, cy, r, 63, -54, width=10, outline=YELLOW)
        # 红色区间 80~100%
        self._draw_arc(cx, cy, r, 9, -54, width=10, outline=RED)

        # 刻度线和数字
        ticks = 11
        for i in range(ticks):
            frac = i / (ticks - 1)
            angle = math.radians(225 - frac * 270)
            val = self.min_val + frac * (self.max_val - self.min_val)
            # 大刻度
            x1 = cx + (r - 20) * math.cos(angle)
            y1 = cy - (r - 20) * math.sin(angle)
            x2 = cx + (r - 6) * math.cos(angle)
            y2 = cy - (r - 6) * math.sin(angle)
            self.create_line(x1, y1, x2, y2, fill=FG_DIM, width=2)
            # 数字
            xt = cx + (r - 34) * math.cos(angle)
            yt = cy - (r - 34) * math.sin(angle)
            self.create_text(xt, yt, text=f"{int(val)}", fill=FG_DIM,
                             font=("Consolas", 8))

        # 小刻度
        small_ticks = 50
        for i in range(small_ticks + 1):
            if i % (small_ticks // (ticks - 1)) == 0:
                continue
            frac = i / small_ticks
            angle = math.radians(225 - frac * 270)
            x1 = cx + (r - 12) * math.cos(angle)
            y1 = cy - (r - 12) * math.sin(angle)
            x2 = cx + (r - 6) * math.cos(angle)
            y2 = cy - (r - 6) * math.sin(angle)
            self.create_line(x1, y1, x2, y2, fill="#334455", width=1)

        # 中心装饰圆
        self.create_oval(cx - 8, cy - 8, cx + 8, cy + 8,
                         fill=NEEDLE, outline="#cc0000")

        # 标签
        self._label_id = self.create_text(
            cx, cy + r * 0.45, text=self.label,
            fill=CYAN, font=("Arial", 11, "bold"))

    def _draw_arc(self, cx, cy, r, start, extent, **kw):
        self.create_arc(cx - r, cy - r, cx + r, cy + r,
                        start=start, extent=extent, style=tk.ARC, **kw)

    def set_value(self, val):
        self.value = val
        cx, cy, r = self.cx, self.cy, self.r
        angle = self._val_to_angle(val)

        # 删旧指针和数字
        if self._needle_id:
            self.delete(self._needle_id)
        if self._text_id:
            self.delete(self._text_id)

        # 指针
        nx = cx + (r - 24) * math.cos(angle)
        ny = cy - (r - 24) * math.sin(angle)
        self._needle_id = self.create_line(
            cx, cy, nx, ny, fill=NEEDLE, width=3, arrow=tk.LAST, arrowshape=(10, 12, 4))

        # 数字显示
        color = GREEN if val < self.max_val * 0.6 else (
            YELLOW if val < self.max_val * 0.8 else RED)
        self._text_id = self.create_text(
            cx, cy + r * 0.22,
            text=f"{val:.1f} {self.unit}",
            fill=color, font=("Consolas", 16, "bold"))


class HistoryGraph(tk.Canvas):
    """实时折线图"""

    def __init__(self, parent, width=400, height=120, max_val=500, **kw):
        super().__init__(parent, width=width, height=height,
                         bg=BG_PANEL, highlightthickness=1,
                         highlightbackground="#334455", **kw)
        self.w = width
        self.h = height
        self.max_val = max_val
        self.data = []
        self.max_points = 200

    def add_point(self, val):
        self.data.append(val)
        if len(self.data) > self.max_points:
            self.data.pop(0)
        self._redraw()

    def _redraw(self):
        self.delete("all")
        if len(self.data) < 2:
            return
        w, h = self.w, self.h
        pad = 5
        n = len(self.data)

        # 网格
        for i in range(5):
            y = pad + (h - 2 * pad) * i / 4
            self.create_line(pad, y, w - pad, y, fill="#1a2a3a", dash=(2, 4))
            val = self.max_val * (1 - i / 4)
            self.create_text(pad + 2, y - 6, text=f"{int(val)}",
                             fill=FG_DIM, font=("Consolas", 7), anchor=tk.W)

        # 折线
        points = []
        for i, v in enumerate(self.data):
            x = pad + (w - 2 * pad) * i / (self.max_points - 1)
            frac = min(v / self.max_val, 1.0)
            y = (h - pad) - frac * (h - 2 * pad)
            points.append((x, y))

        if len(points) >= 2:
            flat = [c for p in points for c in p]
            self.create_line(*flat, fill=CYAN, width=1.5, smooth=True)


class DMASpeedTester:
    """DMA 读写测速核心"""

    def __init__(self):
        self.running = False
        self._thread = None
        self.current_speed = 0.0   # MB/s
        self.total_bytes = 0
        self.elapsed = 0.0
        self.error_msg = ""
        self.direction = "c2h"     # c2h 或 h2c
        self.block_size = 1048576  # 1MB
        self.lock = threading.Lock()

    def start(self, direction="c2h", block_size=1048576):
        if self.running:
            return
        self.direction = direction
        self.block_size = block_size
        self.running = True
        self.total_bytes = 0
        self.elapsed = 0.0
        self.current_speed = 0.0
        self.error_msg = ""
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def stop(self):
        self.running = False
        if self._thread:
            self._thread.join(timeout=3)
            self._thread = None

    def _run(self):
        dev_path = C2H_DEV if self.direction == "c2h" else H2C_DEV

        if not os.path.exists(dev_path):
            with self.lock:
                self.error_msg = f"设备不存在: {dev_path}"
                self.running = False
            return

        try:
            if self.direction == "c2h":
                self._run_c2h(dev_path)
            else:
                self._run_h2c(dev_path)
        except Exception as e:
            with self.lock:
                self.error_msg = str(e)
                self.running = False

    def _run_c2h(self, dev_path):
        """C2H: FPGA → Host (read from device)"""
        buf = bytearray(self.block_size)
        window_bytes = 0
        window_start = time.monotonic()

        fd = os.open(dev_path, os.O_RDONLY)
        try:
            start_time = time.monotonic()
            while self.running:
                n = os.readv(fd, [buf])
                if n <= 0:
                    # 设备可能需要重新打开
                    time.sleep(0.001)
                    continue
                with self.lock:
                    self.total_bytes += n
                window_bytes += n

                now = time.monotonic()
                dt = now - window_start
                if dt >= 0.1:
                    speed = window_bytes / dt / (1024 * 1024)
                    with self.lock:
                        self.current_speed = speed
                        self.elapsed = now - start_time
                    window_bytes = 0
                    window_start = now
        finally:
            os.close(fd)
            self.running = False

    def _run_h2c(self, dev_path):
        """H2C: Host → FPGA (write to device)"""
        # 生成测试数据 pattern
        buf = bytearray(self.block_size)
        for i in range(0, len(buf), 4):
            struct.pack_into('<I', buf, i, i // 4)

        window_bytes = 0
        window_start = time.monotonic()

        fd = os.open(dev_path, os.O_WRONLY)
        try:
            start_time = time.monotonic()
            while self.running:
                n = os.write(fd, buf)
                if n <= 0:
                    time.sleep(0.001)
                    continue
                with self.lock:
                    self.total_bytes += n
                window_bytes += n

                now = time.monotonic()
                dt = now - window_start
                if dt >= 0.1:
                    speed = window_bytes / dt / (1024 * 1024)
                    with self.lock:
                        self.current_speed = speed
                        self.elapsed = now - start_time
                    window_bytes = 0
                    window_start = now
        finally:
            os.close(fd)
            self.running = False


class App:
    def __init__(self, root):
        self.root = root
        root.title("PCIe DMA 仪表盘测速 — Anlogic FPGA")
        root.configure(bg=BG_DARK)
        root.resizable(True, True)

        self.tester = DMASpeedTester()
        self.peak_speed = 0.0
        self.history_c2h = []
        self.history_h2c = []

        self._build_ui()
        self._poll()

    def _build_ui(self):
        root = self.root

        # ── 顶栏 ──
        top = tk.Frame(root, bg=BG_DARK)
        top.pack(fill=tk.X, padx=10, pady=(10, 0))

        tk.Label(top, text="? PCIe DMA Speed Test", bg=BG_DARK, fg=CYAN,
                 font=("Arial", 16, "bold")).pack(side=tk.LEFT)

        # 设备状态
        self.lbl_status = tk.Label(top, text="", bg=BG_DARK, fg=FG_DIM,
                                   font=("Consolas", 10))
        self.lbl_status.pack(side=tk.RIGHT)
        self._update_device_status()

        # ── 仪表盘区域 ──
        gauge_frame = tk.Frame(root, bg=BG_DARK)
        gauge_frame.pack(fill=tk.X, padx=10, pady=5)

        # C2H 仪表盘
        left = tk.Frame(gauge_frame, bg=BG_DARK)
        left.pack(side=tk.LEFT, expand=True, fill=tk.BOTH)
        tk.Label(left, text="C2H (FPGA → Host)", bg=BG_DARK, fg=GREEN,
                 font=("Arial", 11, "bold")).pack()
        self.gauge_c2h = GaugeWidget(left, size=320, label="C2H Read",
                                     max_val=MAX_SPEED_MB)
        self.gauge_c2h.pack(pady=2)

        # H2C 仪表盘
        right = tk.Frame(gauge_frame, bg=BG_DARK)
        right.pack(side=tk.RIGHT, expand=True, fill=tk.BOTH)
        tk.Label(right, text="H2C (Host → FPGA)", bg=BG_DARK, fg=ORANGE,
                 font=("Arial", 11, "bold")).pack()
        self.gauge_h2c = GaugeWidget(right, size=320, label="H2C Write",
                                     max_val=MAX_SPEED_MB)
        self.gauge_h2c.pack(pady=2)

        # ── 历史图 ──
        hist_frame = tk.Frame(root, bg=BG_DARK)
        hist_frame.pack(fill=tk.X, padx=10, pady=2)
        tk.Label(hist_frame, text="实时带宽历史", bg=BG_DARK, fg=FG_DIM,
                 font=("Arial", 9)).pack(anchor=tk.W)
        self.history_graph = HistoryGraph(hist_frame, width=660, height=100,
                                         max_val=MAX_SPEED_MB)
        self.history_graph.pack(fill=tk.X, expand=True)

        # ── 控制面板 ──
        ctrl = tk.Frame(root, bg=BG_PANEL, relief=tk.FLAT, bd=0)
        ctrl.pack(fill=tk.X, padx=10, pady=8)

        # 方向选择
        dir_frame = tk.Frame(ctrl, bg=BG_PANEL)
        dir_frame.pack(side=tk.LEFT, padx=15, pady=8)
        tk.Label(dir_frame, text="方向:", bg=BG_PANEL, fg=FG_TEXT,
                 font=("Arial", 10)).pack(side=tk.LEFT)
        self.var_dir = tk.StringVar(value="c2h")
        for txt, val in [("C2H (读)", "c2h"), ("H2C (写)", "h2c")]:
            tk.Radiobutton(dir_frame, text=txt, variable=self.var_dir,
                           value=val, bg=BG_PANEL, fg=FG_TEXT,
                           selectcolor=BG_DARK, activebackground=BG_PANEL,
                           activeforeground=CYAN,
                           font=("Arial", 10)).pack(side=tk.LEFT, padx=5)

        # 块大小
        bs_frame = tk.Frame(ctrl, bg=BG_PANEL)
        bs_frame.pack(side=tk.LEFT, padx=15, pady=8)
        tk.Label(bs_frame, text="块大小:", bg=BG_PANEL, fg=FG_TEXT,
                 font=("Arial", 10)).pack(side=tk.LEFT)
        self.var_bs = tk.StringVar(value="1MB")
        self.combo_bs = ttk.Combobox(bs_frame, textvariable=self.var_bs,
                                     values=["4KB", "64KB", "256KB", "1MB", "4MB"],
                                     width=8, state="readonly")
        self.combo_bs.pack(side=tk.LEFT, padx=5)

        # 按钮
        btn_frame = tk.Frame(ctrl, bg=BG_PANEL)
        btn_frame.pack(side=tk.RIGHT, padx=15, pady=8)

        self.btn_start = tk.Button(
            btn_frame, text="? 开始测速", command=self._start,
            bg=GREEN, fg="#000", font=("Arial", 11, "bold"),
            activebackground="#00c853", width=12, relief=tk.FLAT)
        self.btn_start.pack(side=tk.LEFT, padx=4)

        self.btn_stop = tk.Button(
            btn_frame, text="? 停止", command=self._stop,
            bg=RED, fg="#fff", font=("Arial", 11, "bold"),
            activebackground="#d50000", width=8, relief=tk.FLAT,
            state=tk.DISABLED)
        self.btn_stop.pack(side=tk.LEFT, padx=4)

        self.btn_reset = tk.Button(
            btn_frame, text="? 重置", command=self._reset,
            bg="#455a64", fg="#fff", font=("Arial", 10),
            activebackground="#607d8b", width=6, relief=tk.FLAT)
        self.btn_reset.pack(side=tk.LEFT, padx=4)

        # ── 统计信息栏 ──
        stat = tk.Frame(root, bg=BG_DARK)
        stat.pack(fill=tk.X, padx=10, pady=(0, 10))

        stats_data = [
            ("当前速度", "speed"),
            ("峰值速度", "peak"),
            ("平均速度", "avg"),
            ("传输总量", "total"),
            ("运行时间", "time"),
        ]
        self.stat_labels = {}
        for title, key in stats_data:
            f = tk.Frame(stat, bg=BG_PANEL, padx=10, pady=4)
            f.pack(side=tk.LEFT, expand=True, fill=tk.X, padx=2)
            tk.Label(f, text=title, bg=BG_PANEL, fg=FG_DIM,
                     font=("Arial", 8)).pack()
            lbl = tk.Label(f, text="--", bg=BG_PANEL, fg=FG_TEXT,
                           font=("Consolas", 12, "bold"))
            lbl.pack()
            self.stat_labels[key] = lbl

        # ── 底栏 ──
        bottom = tk.Frame(root, bg=BG_DARK)
        bottom.pack(fill=tk.X, padx=10, pady=(0, 5))
        self.lbl_info = tk.Label(
            bottom, text="PCIe Gen2 x1 理论带宽: 500 MB/s | 有效: ~350-420 MB/s",
            bg=BG_DARK, fg=FG_DIM, font=("Arial", 8))
        self.lbl_info.pack(side=tk.LEFT)
        self.lbl_error = tk.Label(
            bottom, text="", bg=BG_DARK, fg=RED, font=("Arial", 9))
        self.lbl_error.pack(side=tk.RIGHT)

    def _update_device_status(self):
        c2h_ok = os.path.exists(C2H_DEV)
        h2c_ok = os.path.exists(H2C_DEV)
        if c2h_ok and h2c_ok:
            self.lbl_status.config(text="● C2H ?  H2C ?", fg=GREEN)
        elif c2h_ok:
            self.lbl_status.config(text="● C2H ?  H2C ?", fg=YELLOW)
        elif h2c_ok:
            self.lbl_status.config(text="● C2H ?  H2C ?", fg=YELLOW)
        else:
            self.lbl_status.config(text="● 设备未就绪", fg=RED)

    def _parse_block_size(self):
        mapping = {
            "4KB": 4096,
            "64KB": 65536,
            "256KB": 262144,
            "1MB": 1048576,
            "4MB": 4194304,
        }
        return mapping.get(self.var_bs.get(), 1048576)

    def _start(self):
        direction = self.var_dir.get()
        bs = self._parse_block_size()

        dev = C2H_DEV if direction == "c2h" else H2C_DEV
        if not os.path.exists(dev):
            messagebox.showerror("设备错误", f"设备不存在: {dev}\n请先加载 anlogic_pci 驱动")
            return

        self.peak_speed = 0.0
        self.tester.start(direction=direction, block_size=bs)
        self.btn_start.config(state=tk.DISABLED)
        self.btn_stop.config(state=tk.NORMAL)
        self.combo_bs.config(state=tk.DISABLED)
        self.lbl_error.config(text="")

    def _stop(self):
        self.tester.stop()
        self.btn_start.config(state=tk.NORMAL)
        self.btn_stop.config(state=tk.DISABLED)
        self.combo_bs.config(state="readonly")

    def _reset(self):
        self._stop()
        self.gauge_c2h.set_value(0)
        self.gauge_h2c.set_value(0)
        self.peak_speed = 0.0
        self.history_graph.data.clear()
        self.history_graph._redraw()
        for lbl in self.stat_labels.values():
            lbl.config(text="--")
        self.lbl_error.config(text="")
        self._update_device_status()

    def _format_bytes(self, b):
        if b < 1024:
            return f"{b} B"
        elif b < 1024 * 1024:
            return f"{b / 1024:.1f} KB"
        elif b < 1024 * 1024 * 1024:
            return f"{b / (1024 * 1024):.1f} MB"
        else:
            return f"{b / (1024 * 1024 * 1024):.2f} GB"

    def _format_time(self, t):
        if t < 60:
            return f"{t:.1f}s"
        m = int(t) // 60
        s = t - m * 60
        return f"{m}m {s:.0f}s"

    def _poll(self):
        """定时刷新 GUI"""
        with self.tester.lock:
            speed = self.tester.current_speed
            total = self.tester.total_bytes
            elapsed = self.tester.elapsed
            err = self.tester.error_msg
            running = self.tester.running
            direction = self.tester.direction

        if running or speed > 0:
            # 更新仪表盘
            if direction == "c2h":
                self.gauge_c2h.set_value(speed)
            else:
                self.gauge_h2c.set_value(speed)

            # 历史图
            self.history_graph.add_point(speed)

            # 峰值
            if speed > self.peak_speed:
                self.peak_speed = speed

            # 平均
            avg = (total / (1024 * 1024)) / elapsed if elapsed > 0.01 else 0

            # 统计信息
            self.stat_labels["speed"].config(
                text=f"{speed:.1f} MB/s",
                fg=GREEN if speed > 0 else FG_TEXT)
            self.stat_labels["peak"].config(text=f"{self.peak_speed:.1f} MB/s")
            self.stat_labels["avg"].config(text=f"{avg:.1f} MB/s")
            self.stat_labels["total"].config(text=self._format_bytes(total))
            self.stat_labels["time"].config(text=self._format_time(elapsed))

        if err:
            self.lbl_error.config(text=f"错误: {err}")

        if not running and self.btn_stop.cget("state") == tk.NORMAL:
            self._stop()

        self.root.after(UPDATE_INTERVAL_MS, self._poll)


def main():
    root = tk.Tk()

    # 尝试获取屏幕大小适配
    try:
        sw = root.winfo_screenwidth()
        sh = root.winfo_screenheight()
        ww, wh = 700, 620
        x = (sw - ww) // 2
        y = (sh - wh) // 2
        root.geometry(f"{ww}x{wh}+{x}+{y}")
    except Exception:
        root.geometry("700x620")

    app = App(root)
    root.mainloop()


if __name__ == "__main__":
    main()
