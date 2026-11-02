$ErrorActionPreference='Stop'
$projectRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$phyRoot=Join-Path $projectRoot 'imx415_pcie_4k_Runs/phy_1'
$timing=Get-Content -Raw (Join-Path $phyRoot 'imx415_pcie_4k_phy.ts')
if($timing -notmatch 'SWNS:\s*([-\d.]+)ns, STNS:\s*([-\d.]+)ns'){throw 'Setup status missing'}
$setup=[double]$Matches[1];$setupTns=[double]$Matches[2]
if($timing -notmatch 'HWNS:\s*([-\d.]+)ns, HTNS:\s*([-\d.]+)ns'){throw 'Hold status missing'}
$hold=[double]$Matches[1];$holdTns=[double]$Matches[2]
if($setup -lt 0 -or $hold -lt 0 -or $setupTns -ne 0 -or $holdTns -ne 0){throw 'Routed timing failed; no candidate package'}
$bit=Join-Path $phyRoot 'imx415_pcie_4k_mipi_v27.bit'
if(!(Test-Path -LiteralPath $bit)){throw 'Explicit v27 bitstream missing'}
$release=Join-Path $projectRoot 'imx415_pcie_4k_Runs/debug_release_mipi_v27_20261014'
if(Test-Path -LiteralPath $release){throw 'Release directory exists; do not overwrite it'}
New-Item -ItemType Directory -Path $release | Out-Null
Copy-Item -LiteralPath $bit -Destination $release
$payload=@('validate_board_clock.sh','monitor_video_perf.py','play_raw_video.sh',
 'play_lz77_video.sh','test_lz77_frames.sh','diag_lz77.sh','decode_ddr_fault.py',
 'mode_control.sh','view_lz77_image.sh','display_lz77_video.py','rknn_yolo_backend.py',
 'yolo_reference.py','yolo_draw.py','collect_video_perf.py','benchmark_video_paths.sh')
$deploy=Join-Path $release 'deploy'
New-Item -ItemType Directory -Path $deploy | Out-Null
foreach($name in $payload){Copy-Item -LiteralPath (Join-Path $projectRoot "deploy/$name") -Destination $deploy}
$rk=Join-Path $deploy 'rk3576'
New-Item -ItemType Directory -Path $rk | Out-Null
Get-ChildItem -LiteralPath (Join-Path $projectRoot 'rk3576') -File |
 Where-Object Extension -In @('.c','.py','.sh','.md') | Copy-Item -Destination $rk
# Transfer shell scripts with LF independently of the Windows source endings.
foreach($file in Get-ChildItem -LiteralPath $deploy -Recurse -File -Filter *.sh){
 $bytes=[IO.File]::ReadAllBytes($file.FullName)
 $text=[Text.Encoding]::UTF8.GetString($bytes).Replace("`r`n","`n")
 [IO.File]::WriteAllText($file.FullName,$text,(New-Object Text.UTF8Encoding $false))
}
$boardReadme=Join-Path $projectRoot 'uisrc/06_doc/mipi_v27_board_steps.md'
Copy-Item -LiteralPath $boardReadme -Destination (Join-Path $release 'README.md')
$reports=Join-Path $release 'reports'
New-Item -ItemType Directory -Path $reports | Out-Null
foreach($name in @('imx415_pcie_4k_phy.ts','imx415_pcie_4k_pr.timing',
 'imx415_pcie_4k_chk.timing','imx415_pcie_4k_phy.area','route_flow.status',
 'mipi_v27_implementation.console.log','mipi_v27_bitgen.console.log')) {
 Copy-Item -LiteralPath (Join-Path $phyRoot $name) -Destination $reports
}
Copy-Item -LiteralPath (Join-Path $projectRoot 'imx415_pcie_4k_Runs/syn_1/mipi_v27_synthesis.console.log') -Destination $reports
Copy-Item -LiteralPath (Join-Path $projectRoot 'uisrc/06_doc/mipi_v27_fix_20261014.md') -Destination $reports
$tests=Join-Path $release 'simulation'
New-Item -ItemType Directory -Path $tests | Out-Null
Get-ChildItem -LiteralPath (Join-Path $projectRoot 'uisrc/02_sim/mipi_scan') -File |
 Where-Object Extension -In @('.sv','.ps1','.log','.do') | Copy-Item -Destination $tests
$sources=@('imx415_pcie_4k.al','uisrc/03_ip/mipi_csi_2/auto_delay_ctl.v',
 'uisrc/03_ip/mipi_csi_2/csi_rx_phy.v','uisrc/03_ip/mipi_csi_2/csi_rx_hs_data_phy.v',
 'uisrc/01_rtl/param_imx415.v','uisrc/01_rtl/imx415_pcie_top.v',
 'uisrc/03_ip/vid_pipeline/cam_video_source.v','uisrc/04_pin/imx415_pcie.sdc',
 'al_ip/ui_pll.v','al_ip/ui_pll.ipc','al_ip/PH1_LOGIC_PCIE.sdc',
 'al_ip/PH1_LOGIC_PCIE_ph1_pcie_core_pll.v','al_ip/PH1_LOGIC_PCIE_ph1_pcie_clock_ctrl.v')
foreach($rel in $sources){
 $dest=Join-Path $release "source_snapshot/$rel"
 New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
 Copy-Item -LiteralPath (Join-Path $projectRoot $rel) -Destination $dest
}
$manifest=[ordered]@{version='0x56440027';status='RTL regression and routed timing checked; board verification pending';
 created_at=(Get-Date -Format o);setup_wns_ns=$setup;hold_wns_ns=$hold;
 pcie_usr_6144_resolved=$false;board_60fps_verified=$false;
 rollback='D:/FPGA/AFC03_IMX415_PCIE_X1_test2/IMX415_PCIE_X1';files=[ordered]@{}}
foreach($file in Get-ChildItem -LiteralPath $release -Recurse -File){
 $rel=$file.FullName.Substring($release.Length+1).Replace('\','/')
 $manifest.files[$rel]=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLower()
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $release 'manifest.json') -Encoding utf8
$deploySums=foreach($file in Get-ChildItem -LiteralPath $deploy -Recurse -File){
 $rel=$file.FullName.Substring($deploy.Length+1).Replace('\','/')
 "$((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLower())  $rel"
}
$deploySums | Set-Content -LiteralPath (Join-Path $deploy 'SHA256SUMS') -Encoding ascii
$releaseSums=foreach($file in Get-ChildItem -LiteralPath $release -Recurse -File){
 $rel=$file.FullName.Substring($release.Length+1).Replace('\','/')
 "$((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLower())  $rel"
}
$releaseSums | Set-Content -LiteralPath (Join-Path $release 'SHA256SUMS') -Encoding ascii
Compress-Archive -LiteralPath $release -DestinationPath "$release.zip"
Write-Output "Release: $release"
Write-Output "Zip: $release.zip"
