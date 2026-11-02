# 自主图像链迁移到 PCIe 工程的状态

日期：2026-09-25。

## 已完成

- 目标工程保留原 PCIe/MIPI/SGDMA 顶层；原工程备份在 `backups/before_migration_20260925`。
- `image_preprocess_quad` 已插入 `cam_video_source` 的 `sat_tdata_128` 后、PCIe C2H FIFO 前。
- 三种预处理模式通过 BAR 寄存器控制：

```text
0xA4 = 0 彩色
0xA4 = 1 灰度
0xA4 = 2 灰度+高斯
0xA4 = 3 灰度+均衡
0xA4 = 4 灰度+高斯+均衡
```

- 仅 1920×1080 模式启用预处理；4K/720p 自动旁路，避免固定尺寸行缓存误用。
- LZ77、CRC32、帧封装、RGB128字节适配和 C2H 宽度适配模块已加入工程并实例化在 `u_lz77_rgb_c2h`。
- `compress_active` 只在 1080p 且 BAR 压缩控制有效时选择 LZ77 C2H 分支；默认保持原始视频 C2H 分支。
- TD 综合成功，日志为 `imx415_pcie_4k_Runs/syn_1/migrate_syn2.log`。

## 资源估计

综合层次报告中的新增模块估计：

```text
u_project_preprocess : LUT logic 2110, ripple 608, seq 612, DSP 14
u_lz77_rgb_c2h       : LUT logic 192, ripple 95, seq 414
```

这是综合估计；PCIe工程整体时序仍未签核，当前 Setup WNS 约 `-27 ns`，需要重新整理约束和跨时钟路径。

## 尚未完成

- 新版 PCIe 工程的物理布局布线和 bitgen；
- PCIe 压缩模式的 FPGA 上板验证；
- RK3576 C2H DMA接收程序；
- LZ77帧落盘、CRC校验和解码后的逐字节比较；
- 压缩模式下的 FIFO 深度、丢帧、延迟和压缩率报告。

当前迁移结果是可综合的开发基线，原始 C2H 视频路径仍作为默认旁路保留。
