# v30 mode8/9 低照度增强与去雾交付

2026-10-18：v30 在 v29 BLK1 基础上加入彩色预处理：mode 8=低照度增强（gamma=0.5），
mode 9=去雾（暗通道先验、3×3 最小值、透射率恢复）。模式保留 RGB24，不转灰度。
BAR0+0xA4 写入 8 或 9；mode7 仍保留。v30 版本寄存器为 `0x56440030`，
去雾协议错误寄存器为 BAR0+0x120。

## 已验证

- mode8 独立模块：2560 像素逐像素、RGB/X/SOF/EOL 通过。
- mode8/9 综合预处理链：64×40、4×2、64×40 连续、12×3、4×3，均通过间隙、连续帧、
  高亮区、mode7 保持、颜色、SOF/EOL、帧尾 drain。
- 1920×1080 五帧：原图、mode8、mode9、亮区和连续帧通过逐像素参考。
- mode8/9→RGB24 pack→DDR→BLK1→接收解码：每种 4 帧，CRC、帧号、背压、startup skip、
  RGB24 字节序通过。
- 原有 0–6 模式：4×2、8×4、16×6 和 1920×1080 mode5/6 回归通过。

## 资源与时序

最终布局布线报告（PH1A90SEG324 speed2）：

| 项目 | 结果 |
|---|---:|
| Setup WNS/TNS | +0.102 ns / 0 |
| Hold WNS/TNS | +0.020 ns / 0 |
| ERAM20K | 235/272（86.40%） |
| DSP | 74/240 |
| 寄存器 | 42337 |
| LUT6 | 34889 |
| STA coverage | 99.54% |

仍存在历史 PCIe `USR-6144`（PLL 声明请求 62.5 MHz、工具报告实际/时序约束 125 MHz），本轮未修改 PCIe IP/SDC。
最终布线报告为 Routed/Confidence=Routed；没有因为该告警伪造时序约束。

## v30 bit

```text
imx415_pcie_4k_Runs/mode8_9_v30_phy_20261018/imx415_pcie_4k_compress.bit
SHA256 1B93C8BC0E70FA18A7E6831D6BE5ED979860366CBF1996F991A6BD76E5A74258
```

这是本轮生成的 compress bit，可由用户通过 TD 下载。当前 deploy 不包含 bit；bit 文件在原工程 Runs 目录，
请核对路径和 SHA256 后再下载。v26/v28 回退目录和旧 bit 未覆盖。

## 上板步骤

使用原有 TD 下载流程配置 FPGA，并在新配置就绪后让 RK3576 重新枚举 PCIe。
仅 JTAG 临时配置时不要再给 FPGA 断电，否则会丢失该配置。然后把本 deploy 内容同步到 `/home/linaro/deploy`。板端执行：

```bash
cd /home/linaro/deploy
sha256sum -c SHA256SUMS
cd rk3576
bash build.sh && ./rk3576_lz77_rx --self-test-crc
python3 test_lz77_blocks.py --receiver ./rk3576_lz77_rx
python3 test_receiver_pipeline.py --receiver ./rk3576_lz77_rx
cd /home/linaro/deploy
busybox devmem 0x2120005c 32
# 应为 0x56440030
bash test_lz77_frames.sh 0x21200000 3 0
```

mode8/9 先用未压缩验证：

```bash
YOLO_MODEL= bash play_raw_video.sh 8 188
# Ctrl+C 停止后再运行下一项
YOLO_MODEL= bash play_raw_video.sh 9 188
```

再验证压缩：

```bash
bash test_lz77_frames.sh 0x21200000 3 8
bash test_lz77_frames.sh 0x21200000 3 9
YOLO_MODEL= bash play_lz77_video.sh 8 188
# Ctrl+C 停止后再运行下一项
YOLO_MODEL= bash play_lz77_video.sh 9 188
```

每项观察实时 FPS、`PRE_DEHAZE_ERRORS`（mode9 应为 0）、CRC/decode/format 错误和 DDR_NO_SLOT。
mode8/9 脚本在检测到旧版本时会拒绝启动，不会把旧 bit 当成新功能运行。


mode8 使用相同逐通道 Gamma 表，保留彩色但不承诺 RGB 比例或色调完全不变。
mode9 是固定大气光 A=220、OMEGA=95%、t0=25 的局部暗通道近似，不能替代自适应大气光估计；
实拍可能压暗亮区或放大噪声，须上板评估画质。两者均保持四像素/周期；这不代表已达到
端到端 60 FPS。mode9 的最小帧尾空闲要求为 IMAGE_WIDTH/4+12 个时钟（1080p 为492拍）。
原有 HE 模式自己的 LUT 构建空闲要求继续保留。先停止播放器再切换模式。
本轮不改变既有原图 BLK1 约17 FPS的吞吐瓶颈，不承诺新模式达到20–30 FPS。
