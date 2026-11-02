# TD 综合文件列表修复（2026-10-08）

截图中的 HDL-8007 / HDL-7144 对应最新 syn_1/run.log：
`pcie_ddr_camera` 被当成 black box。实际 RTL 文件存在，但 TD 工程 .al
和由 GUI 生成的 syn_1 .prj 中缺少四个 DDR RTL 及 ui_ddr.ipc 条目。
因此模块无法展开。日志证实文件列表缺失；无法仅凭日志确定由哪次保存造成。

直接修复原工程 `imx415_pcie_4k.al` 和 syn_1/phy_1 .prj。补入：

- uisrc/01_rtl/frame_async_fifo.v
- uisrc/01_rtl/ddr_frame_store_axi.v
- uisrc/01_rtl/ddr_camera_frame_path.v
- uisrc/01_rtl/pcie_ddr_camera.v
- uisrc/03_ip/al_ip/ui_ddr/ui_ddr.ipc

另将顶层 fifo_fill_level、fifo_in_tready、fc_in_tready 的显式声明移到
首次使用之前，消除三条 HDL-7225 警告。未修改数据通路行为。
模式 5～7 的边缘检测预留与本次错误无关。

## 验证范围

使用 TD DefaultFlow 的 read_design 阶段（包含 elaborate 和 IP 约束读入）
在独立目录 imx415_pcie_4k_Runs/check_ddr_filelist_20261008 验证通过，
进程退出 0，错误及 critical warning 均为 0。上述模块均完成展开，
已导出 imx415_pcie_4k_elaborate.db。
本次尚未重新运行 optimize_rtl/optimize_gate、布局布线或生成新位流。
2026-10-06 的独立 v23 调试发布包、manifest、位流保持不变，
其时序未闭合的限制依旧存在。当前工作源码与冻结 manifest 因本次修复不同。

## TD 操作

关闭旧工程；若提示保存，不保存旧窗口的工程文件列表。
重新打开原工程 imx415_pcie_4k.al，再启动综合。
确认文件树中出现上述四个 RTL 和 ui_ddr.ipc。
不要只重试旧窗口中的 Run：旧内存文件列表可能再次生成缺文件的 .prj。

修改前文件及失败日志保存在 backups/before_td_filelist_fix_20261008。

此前另存的 fixed.al 文件名与内部工程名不一致，触发 PRJ-8643；
已按用户要求移除该文件，后续只维护原工程，不另建 fix 工程。

补充验证：从原工程根目录直接打开 imx415_pcie_4k.al，完成 elaborate，
退出 0，错误和 critical warning 为 0。日志为验证目录中的
check_original.console.log。打开 .al 时以工程根目录为工作目录，
避免相对 IP 文件路径解析错误。ui_ddr.sv 由 IPC 自动带入，不重复添加。
