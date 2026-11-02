# PCIe工程迁移状态

目标工程：`AFC03_IMX415_PCIE_X1_test/IMX415_PCIE_X1`。

## 已迁移

- `image_preprocess_quad` 已接在 `cam_video_source` 的 `sat_tdata_128` 后；
- PCIe已有 C2H AXI-Stream 旁路保持不变；
- BAR寄存器 `0xA4` 控制预处理模式：0彩色、1灰度、2高斯、3均衡、4组合；
- 非 1920×1080 模式自动旁路预处理，避免固定尺寸行缓存误用；
- LZ77核心、帧封装、CRC、RGB128字节适配和 C2H 宽度适配已加入工程源码；
- 原工程已备份到 `backups/before_migration_20260925`。

## 当前压缩分支

`lz77_rgb_c2h_path` 已组合：

```text
cam_tdata[127:0]
  → rgb128_byte_stream
  → lz77_repeat_encoder
  → lz77_frame_formatter
  → 32→128 C2H AXI-Stream
```

压缩分支源码已登记到 TD 工程，但尚未替换 PCIe 顶层的 C2H 原始视频选择器；原视频仍是默认输出。
接下来需要把 `compress_active` 加入顶层，并在 1080p 时选择压缩分支。
