param([string]$ModelSimBin='E:\modeltech64_10.6d\win64')
$ErrorActionPreference='Stop'
Push-Location $PSScriptRoot
try {
    # Use the vendor interface, but never its hardware calibration behavior.
    $vendor=Get-Content -Raw ../../03_ip/al_ip/ui_ddr/ui_ddr.sv
    $headerEnd=$vendor.IndexOf(');',$vendor.IndexOf('module ui_ddr'))+2
    if($headerEnd -lt 100){throw 'ui_ddr interface not found'}
    ($vendor.Substring(0,$headerEnd)+"`nendmodule`n") | Set-Content -Encoding ascii ui_ddr_status_stub.sv
    $lib='work_ddr_status'
    if(!(Test-Path -LiteralPath $lib)) { & "$ModelSimBin\vlib.exe" $lib }
    & "$ModelSimBin\vlog.exe" -sv -work $lib ../../01_rtl/frame_async_fifo.v ../../01_rtl/ddr_frame_store_axi.v ../../01_rtl/ddr_camera_frame_path.v ../../01_rtl/pcie_ddr_camera.v ui_ddr_status_stub.sv tb_ddr_status.sv
    if($LASTEXITCODE -ne 0){throw 'vlog failed'}
    $result=& "$ModelSimBin\vsim.exe" -c -lib $lib tb_ddr_status -do 'onerror {quit -code 1 -f}; onbreak {quit -code 1 -f}; run -all; quit -code 0 -f' 2>&1
    $code=$LASTEXITCODE
    $result | Set-Content -Encoding utf8 ddr_status.log
    if($code -ne 0 -or ($result -join "`n") -notmatch '# PASS '){throw 'DDR status regression failed'}
    $result | Select-String '# PASS '
} finally {Pop-Location}
