# RK3576 C2H/LZ77 development acceptance record

日期：2026-09-25

## 已完成

- `rk3576_lz77_rx.c`：从 `/dev/sgdma0_c2h_0` 阻塞读取 C2H 字节流；支持任意 read 分片、LZ77 帧同步、帧长度检查、Token 解码、CRC32 校验和二进制帧输出。
- `make_test_frame.py`：生成与 `lz77_frame_formatter.v` 相同格式的测试帧。
- `test_lz77_frame.py`：验证尺寸、帧号、Token、长度、CRC 和无损恢复。
- `test_crc_error.py`：修改 payload 后确认 CRC 错误被拒绝。
- `test_stream_parser.py`：用 1～37 字节随机分片模拟 DMA read，连续恢复 5 帧。

## 本机验证结果

```text
PASS RK3576-compatible LZ77 frame
PASS corrupted payload rejected
PASS fragmented C2H stream framing: 5 frames
```

Windows 工作区没有 AArch64 交叉编译器，因此 C 程序尚未在本机生成 RK3576 可执行文件；在 RK3576 上执行 `build.sh` 后再运行 `run_offline_test.sh`。

## 上板验收

1. `ls -l /dev/sgdma0_c2h_0` 能看到 C2H 设备。
2. FPGA 开启压缩模式，使用 1920×1080 输入。
3. `rk3576_lz77_rx -d /dev/sgdma0_c2h_0 -o /userdata/lz77/frame -n 100 -v` 连续接收 100 帧。
4. `crc_errors=0 decode_errors=0 format_errors=0`。
5. `frames=100`，输出帧号连续，统计 compression_ratio、fps 和 elapsed_s。
6. 解码输出的每帧原始字节数应为 `1920*1080*4`（PCIe `cam_video_source` 当前输出 RGBX128）。

注意：真实 C2H DMA、端到端延迟、丢帧和长时间稳定性必须在新版 FPGA bitstream 上板后执行；离线测试已经覆盖协议和解码逻辑。
