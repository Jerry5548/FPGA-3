param([string]$ModelSimBin='E:\modeltech64_10.6d\win64')
$ErrorActionPreference='Stop'
Push-Location $PSScriptRoot
try {
    $lib='work_histogram_1080p'
    if(!(Test-Path -LiteralPath $lib)) {
        & "$ModelSimBin\vlib.exe" $lib
        if($LASTEXITCODE -ne 0){throw 'vlib failed'}
    }
    & "$ModelSimBin\vlog.exe" -sv -work $lib ../../01_rtl/histogram_equalization_stream.v tb_histogram_1080p.sv
    if($LASTEXITCODE -ne 0){throw 'vlog failed'}
    @'
onerror {quit -code 1 -f}
onbreak {quit -code 1 -f}
run -all
quit -code 0 -f
'@ | Set-Content -Encoding ascii run_histogram_1080p.do
    $result=& "$ModelSimBin\vsim.exe" -c -lib $lib tb_histogram_1080p -do run_histogram_1080p.do 2>&1
    $code=$LASTEXITCODE
    $result | Set-Content -Encoding utf8 histogram_1080p.log
    $result | Select-String '# PASS '
    if($code -ne 0 -or !(($result -join "`n") -match '# PASS ')) {throw '1080p HE simulation failed'}
} finally {Pop-Location}
