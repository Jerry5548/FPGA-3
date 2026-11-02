param([string]$ModelSimBin='E:\modeltech64_10.6d\win64')
$ErrorActionPreference='Stop'
Push-Location $PSScriptRoot
try {
    if(!(Test-Path -LiteralPath work_scan)){ & "$ModelSimBin/vlib.exe" work_scan }
    & "$ModelSimBin/vlog.exe" -sv -work work_scan ../../03_ip/mipi_csi_2/auto_delay_ctl.v tb_auto_delay.sv 'D:/TD_Release_2026.1_SP2.200.067/sim_release/ph1/ph1_logic_dynamic_idelay.v' ../../03_ip/mipi_csi_2/csi_rx_hs_data_phy.v tb_ph1a_delay.sv
    if($LASTEXITCODE -ne 0){throw 'Scan compilation failed'}
    @'
onerror {quit -code 1 -f}
onbreak {quit -code 1 -f}
run -all
quit -code 0 -f
'@ | Set-Content -Encoding ascii run_scan.do
    $result=& "$ModelSimBin/vsim.exe" -c -lib work_scan tb_auto_delay -do run_scan.do 2>&1
    $code=$LASTEXITCODE
    $result | Set-Content -Encoding utf8 scan.log
    $result | Select-String '# PASS |Fatal|Error'
    if($code -ne 0 -or ($result -join "`n") -notmatch 'PASS all MIPI scan tests'){throw 'Scan tests failed'}
    $result=& "$ModelSimBin/vsim.exe" -c -lib work_scan tb_ph1a_delay -do run_scan.do 2>&1
    $code=$LASTEXITCODE
    $result | Set-Content -Encoding utf8 ph1a_delay.log
    $result | Select-String '# PASS |Fatal|Error'
    if($code -ne 0 -or ($result -join "`n") -notmatch 'PASS PH1A vendor IDELAY'){throw 'PH1A delay tests failed'}
} finally {Pop-Location}
