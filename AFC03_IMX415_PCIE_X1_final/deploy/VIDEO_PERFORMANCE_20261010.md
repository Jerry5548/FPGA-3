# 1080p 性能开发与板端定位

目标：不降分辨率，普通模式 60 个新画面/秒；LZ77＋YOLO 同时开启时，
完整解压、完成检测和实际显示分别达到 20–30 FPS。重复帧不计入验收。
本次是第一阶段软件优化与测量工具，尚未实测达到上述目标。

## 已修改

- YOLO 先筛选目标/类别阈值，再计算保留候选的坐标；原模型、阈值、标签、NMS、
  颜色顺序和框坐标映射不变。保留 sparse=False 的原后处理供离线等价对照。
- YOLO_PERF 每 0.5 秒打印区间平均 wait/pre/npu/post/draw/push/cycle_ms。
  YOLO FPS 计数在同帧绘框及提交显示之后，DISPLAY FPS 由显示分支单独测量。
- VIDEO_HEADLESS=1 使用 fakesink，跳过 OSD/色彩转换/KMS，OUTPUT 表示消费速率，
  不是屏幕显示 FPS。YOLO boxes 下依然推理并绘框，以便隔离最后的显示开销。
- hardware.log 被动采样 BAR0 帧计数、丢帧、压缩量、CPU/NPU 频率和温度。
  摄像头计数仅取 0x88 低 24 位，高 8 位是诊断标志。此值是 FPGA 摄像头管线
  的帧事件计数，不等价于传感器直接测量的 XVS；需结合完整性/丢帧计数解释。
- benchmark_video_paths.sh 顺序运行 8 个独立测试，collect_video_perf.py 打包本轮
  对应目录，包含 rx/gst/hardware/寄存器/dmesg。一次只能有一个采集程序。

本次未改 FPGA RTL/位流、内核驱动、接收器协议及播放器原有停止顺序。
原工程保持 v26；性能修改只涉及部署软件。更新包含全部相关文件，无需重新综合。

## 本机验证

Python、Bash 语法通过。25 组 NumPy 合成输出覆盖空检测、稀疏检测、阈值边界与
类别过滤后空检测，优化前后 boxes/scores/classes 数组完全一致，输入不被修改。
Windows 本机合成微基准：空检测约 3.56→0.11 ms；稀疏检测约 4.36→1.16 ms。
仅表示本机后处理函数收益，不代表 RK3576 推理或视频性能，不验证真实检测准确率。
本机没有 RKNN/GStreamer 摄像头环境；实际播放/时序/长期完整性需板端复测。

## 板端执行

把更新后的 deploy 文件同步到 /home/linaro/deploy。停止现有播放器后：

```bash
cd /home/linaro/deploy
sha256sum -c SHA256SUMS
python3 test_yolo_postprocess_perf.py
YOLO_MODEL=/home/linaro/rock/yolo/yolov5s_relu.rknn \
bash benchmark_video_paths.sh 1 188 30
```

测试约 4–7 分钟，含初始化/退出。保持场景、光照和模式一致。headless 阶段黑屏
属于预期。单轮开始前后数秒受启动/停止影响，稳态统计排除前 3 秒及最后 3 秒。
timeout 的 exit=124 是定时结束；不表示性能或完整性通过。出现非预期退出停止批次，
保留本轮错误日志，不能把不完整批次当作性能通过。输出 ZIP 用 Xftp 下载。
raw 停止阶段已有的 DMA 超时信息也被保留，需和运行阶段超时区分。

不跑完整批次时可分别执行，Ctrl+C 后等进程退出再切换：

```bash
VIDEO_HEADLESS=1 YOLO_MODEL= bash play_raw_video.sh 1 188
YOLO_MODEL= bash play_raw_video.sh 1 188
YOLO_MODEL=/home/linaro/rock/yolo/yolov5s_relu.rknn bash play_raw_video.sh 1 188
VIDEO_HEADLESS=1 YOLO_MODEL= bash play_lz77_video.sh 1 188
YOLO_MODEL=/home/linaro/rock/yolo/yolov5s_relu.rknn bash play_lz77_video.sh 1 188
```

离线检验 CPU CRC/解压上限：

```bash
cd /home/linaro/deploy/rk3576
python3 benchmark_video_decode.py --receiver ./rk3576_lz77_rx
```

## 瓶颈与后续改造

1080p RGB24 每帧 6,220,800 字节。20/30/60 FPS 的原始像素吞吐分别为
124.416/186.624/373.248 MB/s，均未计 PCIe 协议和系统拷贝开销。
压缩帧平均大小取本轮 PERF，不能假设 LZ77 必然省带宽。

1. **普通 27→60 FPS**：先比较 FPGA 摄像头管线计数、raw gate/drop 与无显示 OUTPUT。
   只有摄像头管线约 60 而 OUTPUT 约 27，才优先检查 DMA 描述符供给、调度与门控；
   OUTPUT 约 60 而 DISPLAY 约 27，优先检查显示/OSD/转换及内存访问。
   驱动 S_PARM 仅返回固定模式参数，--set-parm=60 不会实际重配传感器。
   驱动目前可接受 >=99% 的短帧，FPS 上升还需检查完整有效图像，不只看计数。
2. **LZ77 吞吐优化候选（2026-10-14）**：literal seed 发射时并行接收下一字节；独立
   ModelSim 中 10,000 个无重复 literal 从约 20,000 拍降到 10,002 拍。单字节输入
   上限仍约 125 MB/s；20 FPS 的 RGB24 输入约 124.4 MB/s，几乎没有余量，30 FPS
   仍需多字节/流水编码设计。当前仅做 distance=1 连续重复；灰度仍传 RGB24 三份同值，
   单通道格式需要另行定义兼容协议。
3. **DMA 分包优化候选（2026-10-14）**：C2H EOP 从每 1 KiB 调整为每 16 KiB，
   字符设备仍同步提交/map/unmap；原 64 KiB read 候选未通过 2026-10-16 上板验证，
   当前恢复 4 KiB 请求，跨多次 read 重组 FPGA 的 16 KiB 包；连续缓冲/描述符预提交未实现。
   ModelSim 验证每 1024 个 C2H beat 产生 EOP 且最终短包保留；目标板还需验证 SGDMA
   EOP 完成语义、尾包、停止和超时恢复。这不是将 PCIe TLP 设置为 16 KiB，亦未实现
   预提交或持久映射缓冲环。
4. **YOLO 17→20–30 FPS**：17 FPS 周期约 58.8 ms；20/30 FPS 预算 50/33.3 ms。
   历史 NPU 28.7 ms 单次读数不等价于当前均值；若仍接近该值，30 FPS 串行链路
   只剩约 4.6 ms 做预处理/后处理/绘框/提交，需要减少拷贝、RGA 缩放、C++/RKNN
   内存接口或有界流水线并发。优先按本轮 YOLO_PERF 最大耗时项改造。
   异步显示必须保留同帧对应关系；显示旧框覆盖新帧不能替代推理帧率。
5. **稳定性**：v26 实现报告 Setup WNS=-23.098ns、Hold WNS=-1.008ns，时序未闭合。
   先排查约束/跨时钟和组合路径，不能直接倍频追吞吐；重新布局布线后做完整性验收。

判定同时开启达标需稳态 DISPLAY、完整解压 FPS、YOLO 完成 FPS 均满足目标，
且 CRC/解码/几何/DDR/FIFO/压缩错误为零；另报告跳过整帧计数及端到端延迟。
