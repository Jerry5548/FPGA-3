# v26 灰度异常帧诊断包

沿用原工程 imx415_pcie_4k.al，版本寄存器为 0x56440026。
本版增加首个 DDR 拒收帧的原因、帧 ID、接收字数及首次异常位置记录。
数据路径、灰度/中值/Sobel 算法、启动跳帧策略和完整性验收要求保持原样。
这是用于定位问题的诊断版本，尚未证明或修复灰度偶发失败的根因。

## 烧录和复制

1. 停止 GStreamer、dd、C2H/V4L2 接收程序。
2. 烧录本目录 imx415_pcie_4k_ddr_v26.bit。另一个 _compress.bit
   是同一设计的 TD 压缩下载文件，不是摄像头压缩模式。
3. 用 Xftp 将本包 deploy 目录内的文件覆盖到 /home/linaro/deploy/。
   不要删除板上其他 deploy 文件；保留内核模块、rk3576 接收程序和 build.sh。
   接收程序继续使用 lz77-rx-geometry-20261006b，不需要重新编译。
4. 按此前已成功的板卡启动流程，使 PCIe 完成枚举并加载驱动。
   本次不需要更改设备树。旧 pcie_setup.sh 在设备树状态非 okay 时可能
   自动修补 DTB，不要在未确认状态时盲目重复执行。

## 单终端测试

确认没有其他接收程序运行，在 root 终端执行：

```bash
cd /home/linaro/deploy
ls -l /dev/ANLOGIC-PCI0_c2h_0
busybox devmem 0x2120005c 32
```

设备必须存在，版本必须是 0x56440026，再执行：

```bash
bash view_lz77_image.sh 1 188 --save-only
```

此命令自动软复位、等待 DDR 校准、先启动接收再启动 FPGA，最后停止采集并保存日志。
不需要第二个终端，也不要另外手动写启动寄存器。它不占用显示输出，188 在保存模式下
不参与显示。通过时在打印的 /home/linaro/lz77-images/mode1.XXXXXX 目录中生成 BMP。

通过要求：receiver_exit=0、test_exit=0、frames=1、raw=6220800，CRC/解码/格式及
DDR_INVALID 等完整性错误均为零。DDR_STARTUP_SKIPS=1；DDR_NO_SLOT 可非零，
表示双槽忙时跳过整个输入帧。通过一轮不能证明偶发错误已修复。

## 出错后保存

出现 DDR_INVALID 或其他错误时，先保存本轮结果。日志已经写入打印的
/tmp/lz77-diag.XXXXXX，至少包含 first_fault.log、before.log、before_stop.log、
after.log、ddr_timeline.log、rx.log 和 dmesg.log。

例如打印 Logs: /tmp/lz77-diag.Abc123，则执行下面命令；请替换为实际路径：

```bash
cat /tmp/lz77-diag.Abc123/first_fault.log
chown -R linaro:linaro /tmp/lz77-diag.Abc123
```

随后通过 Xftp 以 linaro 登录，下载整个目录以及本次 mode1 图像目录。
不要更改整个 /tmp 的权限。下次软复位会清除硬件故障记录，但已保存的日志仍保留；
重启会丢失 /tmp 内容，因此先下载日志。

如果设备不存在或版本不符，先停止测试并提供 ls、lspci -nn、dmesg 输出。

## 验证和限制

本次最终时序：setup WNS **−23.098 ns**，hold WNS **−1.008 ns**，时序未闭合。
ERAM 异步复位、MIPI 时钟混合扇出、DDR BUFG 级联及 PCIe 请求 62.5 MHz/
实际 125 MHz 等告警仍存在。尚无 v26 上板结果，此包仅供诊断。

- DDR 100 帧、启停、背压、故障注入及 DDR→LZ77 解码回归通过。
- 首错快照覆盖提前 LAST、缺 LAST、EOL、SOF/ID、capture bad、AXI 写响应，
  检查锁存不覆盖、停用保留、复位清除、跨时钟一致性。
- 模式 5/6 经 DDR→LZ77 逐像素/CRC 回归通过；99 帧模式切换测试通过。
- 实际综合、布局布线、位流生成状态与最终 WNS 见 release_manifest.json、timing.ts
  及构建日志。负裕量意味着时序未闭合，不能承诺上板稳定性。
- v26 尚未上板验证，未解决或验收灰度偏暗、中值散点、Sobel 稀疏等画质问题。
  CRC 通过仅说明所校验的数据一致，不能证明预处理算法或硬件时序正确。

source_snapshot 为构建输入归档，不是另建的 fix 工程。旧版本发布包保持不变。
SHA256SUMS 可核对发布文件；development.md 描述新增寄存器的准确含义。
