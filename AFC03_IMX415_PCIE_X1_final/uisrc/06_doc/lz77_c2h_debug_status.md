# LZ77 C2H 调试位流状态

日期：2026-10-02

## 已完成

- 修正 `lz77_rgb_c2h_path.v` 的 AXI4-Stream TKEEP：2 字节输出为 `0x0003`，4 字节输出为 `0x000F`。
- 修正 `rgb128_byte_stream.v` 的 1920×1080 固定帧计数保护。
- 修正 `pack4_rgb24_to_128.v`/`cam_video_source.v` 的最后一行 `frame_last` 传递。
- 增加 BAR0 压缩诊断寄存器：
  - `0xAC` 压缩路径原始字节数
  - `0xB0` 压缩字节数
  - `0xB4` Token 数
  - `0xB8` 完成帧数
  - `0xBC` 压缩路径错误数
  - `0xC0` 压缩状态
  - `0xC4` 已握手 C2H beat 数
- 版本号改为 `0x56440021`，用于确认上板位流版本。
- 修正 `lz77_c2h_word_packer.v` 在已有 14 字节缓存后遇到 4 字节输入时的边界死锁；该死锁会导致首帧成功、后续帧 C2H 停止。
- ModelSim C2H 回归通过：6 帧、反压、TKEEP/TLAST 检查均通过。
- TD 综合、布局布线、bitgen 完成。

## 最新位流

```text
imx415_pcie_4k_Runs/phy_1/imx415_pcie_4k.bit
imx415_pcie_4k_Runs/phy_1/imx415_pcie_4k_compress.bit
imx415_pcie_4k_Runs/phy_1/cw/compiled.bit
```

最新压缩位流 SHA256：

```text
AE27A19FB27F27818DA27AED5DC680B9441A7FB5D3CF7FDBED2B104DC32F75A3
```

## 时序限制

```text
Setup WNS ≈ -24.0 ns
Hold WNS  ≈ -2.9 ns
```

该位流用于功能调试，不能称为时序签核版。

## 上板诊断

下载最新位流并重新运行 `pcie_setup.sh` 后：

```bash
busybox devmem 0x2120005c 32
busybox devmem 0x212000ac 32
busybox devmem 0x212000b0 32
busybox devmem 0x212000b4 32
busybox devmem 0x212000b8 32
busybox devmem 0x212000bc 32
busybox devmem 0x212000c0 32
busybox devmem 0x212000c4 32
```

版本必须为 `0x56440021`。开启压缩后，先观察 `0xC4` 是否增加：

- `0xC4=0`：压缩分支没有输出或没有和 C2H 握手；
- `0xC4>0` 且 `0xB8=0`：有输出但没有形成完整帧；
- `0xB8>0`：FPGA 已完成 JPEG/LZ77 帧封装，问题在 DMA 接收边界或设备端。
