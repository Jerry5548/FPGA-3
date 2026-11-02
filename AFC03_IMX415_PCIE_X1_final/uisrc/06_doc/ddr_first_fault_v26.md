# v26：首个 DDR 拒收帧诊断

目标：定位 v25 灰度启动测试间歇出现的 DDR_INVALID=1。
版本 0x56440026，沿用原 imx415_pcie_4k.al。原 v25 发布包保持不变。
本次只增加观测，不修改灰度/中值/Sobel 算法、压缩协议、启动跳帧数、
DDR 接收/拒绝规则或软复位语义。它是诊断版，不是已验证的根因修复。

## 为什么需要这个版本

两次灰度保存测试都解码出完整 frame=2，同时 DDR_INVALID=1；
其中提供的时间线显示 sample 1 即出现拒收，停机前已为 1，随后未增加。
DDR 读写及 FIFO 丢数为零。现有信息提示启动阶段某帧被拒收，但不能
区分短帧、标记或 ID 异常。CRC 通过不能验证压缩前的图像算法或时序。

## 寄存器

BAR0+0x100～0x11C 是同一 256 位快照。记录在 DDR 域的首个拒收事件
锁存，经握手状态邮箱整体复制到 user_clk 域，之后直到复位保持不变。
驱动未改，顶层读截获范围及 case 均扩展为 16 位地址，避免 0x100 与
0x00 别名。初次锁存到寄存器可见存在 CDC 延迟；测试结束后保存快照。

| 偏移 | 内容 |
| --- | --- |
| 100 | bit31=记录有效；bit6:0=该拒收帧累计错误原因 |
| 104 | 被拒收帧的 capture frame ID |
| 108 | 拒收时已经接收的 128 位字数量；乘 16 为字节数 |
| 10C | 该帧首个异常的输入字索引（从 0 开始） |
| 110 | 高 16 位：期望行号；低 16 位：期望行内 128 位字索引（均从 0 开始） |
| 114 | 首个异常现场标记，见下 |
| 118 | 首个异常现场的输入 capture ID（仅在输入事件有效） |
| 11C | 期望一帧 128 位字数量；1080p RGB24 为 388800 |

原因位可组合：

- bit0：旧帧尚未完成就遇到新 SOF。
- bit1：旧帧尚未完成就遇到不同 capture ID。
- bit2：LAST 早于期望帧长度。
- bit3：期望最后一个字处缺少 LAST。
- bit4：EOL 与期望行尾位置不符。
- bit5：观察到捕获 FIFO 的帧 bad 标记。
- bit6：AXI 写响应 BRESP/BID 不符。

114 位定义：bit0 SOF、bit1 EOL、bit2 LAST、bit3 BAD、bit4 期望 EOL、
bit5 期望 LAST、bit7:6 BRESP、bit11:8 BID、bit14:12 写状态机状态。
写状态：0 IDLE、1 FILL、2 ADDR、3 DATA、4 RESP。
B 响应事件中，索引/位置表示该 burst 后的下一个输入位置，不表示某个
DDR 字节确实损坏；输入标记与输入 ID 此时不具有诊断意义。
输入事件的 B 响应字段同样不具有诊断意义。

原因掩码累计的是整帧错误；位置/现场只描述该帧最早的异常。
接收字数包含提前 LAST 的那拍，不包含打断旧帧的新 SOF 拍。
该快照与 D8 拒收事件同步产生；正常帧或主动启动跳过不会生成快照。
不会记录读取侧的故障，读取侧仍通过 E0 及原状态位诊断。

## 验证

已通过 DDR 100 帧、启动保护及 DDR→LZ77 解码回归。
新增仿真检查短帧、错误 EOL、缺失 LAST、提前 SOF/ID、仅 ID 变化、
捕获 bad 标记、BRESP 错误，以及首条记录不被覆盖、停用不清除、
复位清除、CDC 后字段一致、正常帧不产生记录。
Python 解码器通过字段/字节数/BRESP、无故障、错误版本和缺失字段检查。
2026-10-09 本次最终时序报告：setup WNS −23.098 ns、hold WNS −1.008 ns，
时序未闭合。完整构建状态和文件哈希见发布包 release_manifest.json。
ERAM 异步复位、MIPI 时钟混合扇出、DDR BUFG 级联、PCIe 请求 62.5 MHz/
实际 125 MHz 等告警仍存在，尚无 v26 上板证据。

## 上板时怎么做

位流准备完成后才上传配套脚本。烧录 v26，将发布包 deploy 下的
test_lz77_frames.sh、diag_lz77.sh、decode_ddr_fault.py、view_lz77_image.sh
复制到 /home/linaro/deploy，保留现有 rk3576 接收程序。
停止其他 GStreamer/C2H/V4L2 使用者，执行：

```bash
cd /home/linaro/deploy
busybox devmem 0x2120005c 32
bash view_lz77_image.sh 1 188 --save-only
```

版本应为 0x56440026。先使用一帧灰度保存流程复现既有触发条件。
测试脚本即使拒收计数非零也会先停止生产端、保存现场并解码，再返回失败。
查看打印目录里的 first_fault.log；如失败，先复制整个日志目录再运行其他
测试，因为下一次脚本会软复位并清除硬件首故障记录。

重点返回 first_fault.log、after.log、before.log、before_stop.log、
ddr_timeline.log、rx.log 和 dmesg.log。若本次没有复现，记录为“未复现”，
不能仅因诊断版本一次通过就认定问题消失。此版本不改变 Sobel 阈值，
也不宣称中值图散点或偏暗问题已解决。

以上命令要求 PCIe 已枚举、驱动已加载且 C2H 设备存在。烧录后按此前成功的流程
重启并初始化板卡。现有 pcie_setup.sh 在设备树状态非 okay 时会调用设备树修补脚本，
因此不要在未确认状态时直接运行它。本次不需要改设备树；若缺少 C2H 设备，先保留
`lspci -nn`、`ls /dev/ANLOGIC*` 和 `dmesg` 输出再定位初始化问题。

日志目录由 root 创建，Xftp 使用 linaro 登录时可先执行下列命令。将目录替换为本次
实际打印的 Logs 路径，只调整这个诊断目录：

```bash
chown -R linaro:linaro /tmp/lz77-diag.实际后缀
```
