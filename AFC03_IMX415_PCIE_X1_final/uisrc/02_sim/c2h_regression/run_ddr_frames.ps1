param([string]$ModelSimBin='E:\modeltech64_10.6d\win64')
$ErrorActionPreference='Stop'
Push-Location $PSScriptRoot
try {
    $lib='work_ddr_regression'
    if(!(Test-Path -LiteralPath $lib)) {
        & "$ModelSimBin\vlib.exe" $lib
        if($LASTEXITCODE -ne 0){throw 'vlib failed'}
    }
    $sources=@('../../01_rtl/frame_async_fifo.v','../../01_rtl/ddr_frame_store_axi.v',
       '../../01_rtl/ddr_camera_frame_path.v','../../01_rtl/rgb128_byte_stream.v',
       '../../01_rtl/lz77_repeat_encoder.v','../../01_rtl/lz77_frame_formatter.v',
       '../../01_rtl/lz77_c2h_word_packer.v','../../01_rtl/lz77_rgb_c2h_path.v',
       'axi_frame_memory_model.sv','tb_ddr_frame_path.sv','tb_ddr_lz77.sv')
    & "$ModelSimBin\vlog.exe" -work $lib @sources
    if($LASTEXITCODE -ne 0){throw 'vlog failed'}
    @'
onerror {quit -code 1 -f}
onbreak {quit -code 1 -f}
run -all
quit -code 0 -f
'@ | Set-Content -Encoding ascii run_ddr_case.do
    foreach($tb in @('tb_ddr_frame_path','tb_ddr_ring4','tb_ddr_startup','tb_ddr_diagnostics','tb_ddr_lz77','tb_ddr_lz77_startup','tb_ddr_lz77_ring4')) {
        $result=& "$ModelSimBin\vsim.exe" -c -lib $lib $tb -do run_ddr_case.do 2>&1
        $code=$LASTEXITCODE
        $result | Set-Content -Encoding utf8 "$tb.log"
        if($code -ne 0 -or !(($result -join "`n") -match '# PASS ')) {throw "Simulation failed: $tb"}
        $result | Select-String '# PASS '
    }
    python check_ddr_lz77.py
    if($LASTEXITCODE -ne 0){throw 'DDR/LZ77 CRC comparison failed'}
} finally {Pop-Location}
