param([string]$ModelSimBin='E:\modeltech64_10.6d\win64')
$ErrorActionPreference='Stop'
Push-Location $PSScriptRoot
try {
    $lib='work_frames_regression'
    if(!(Test-Path -LiteralPath $lib)) {
        & "$ModelSimBin\vlib.exe" $lib
        if($LASTEXITCODE -ne 0){throw 'vlib failed'}
    }
    $sources=@(
        '../../01_rtl/rgb128_byte_stream.v',
        '../../01_rtl/lz77_repeat_encoder.v',
        '../../01_rtl/lz77_frame_formatter.v',
        '../../01_rtl/lz77_c2h_word_packer.v',
        '../../01_rtl/lz77_rgb_c2h_path.v',
        '../../03_ip/vid_pipeline/sync_fifo_130.v',
        '../../01_rtl/image_preprocess_quad.v',
        '../../01_rtl/median_3x3_stream.v',
        '../../01_rtl/sobel_3x3_stream.v',
        '../../01_rtl/gray_pixel_stream.v',
        '../../01_rtl/gaussian_3x3_stream.v',
        '../../01_rtl/histogram_equalization_stream.v',
        'tb_c2h.sv','tb_c2h_frame_faults.sv','tb_fifo_registered.sv',
        'tb_formatter_eof.sv','tb_packer_boundary.sv',
        'tb_preprocess_handshake.sv','tb_rgb_repeated_sof.sv',
        'tb_encoder_throughput.sv','tb_encoder_runs.sv','tb_packer_16k.sv','tb_c2h_16k.sv',
        'tb_quad_throughput.sv','tb_quad_runs.sv'
    )
    & "$ModelSimBin\vlog.exe" -work $lib @sources
    if($LASTEXITCODE -ne 0){throw 'vlog failed'}
    @'
onerror {quit -code 1 -f}
onbreak {quit -code 1 -f}
run -all
quit -code 0 -f
'@ | Set-Content -Encoding ascii run_frame_case.do
    foreach($tb in @('tb_c2h','tb_c2h_frame_faults','tb_fifo_registered',
                      'tb_formatter_eof','tb_packer_boundary',
                      'tb_preprocess_handshake','tb_rgb_repeated_sof',
                      'tb_encoder_throughput','tb_encoder_runs','tb_packer_16k',
                      'tb_c2h_16k','tb_quad_throughput','tb_quad_runs')) {
        $result=& "$ModelSimBin\vsim.exe" -c -lib $lib $tb -do run_frame_case.do 2>&1
        $code=$LASTEXITCODE
        $result | Set-Content -Encoding utf8 "$tb.log"
        if($code -ne 0 -or !(($result -join "`n") -match '# PASS ')) {
            throw "Simulation failed: $tb (see $PSScriptRoot\$tb.log)"
        }
        $result | Select-String '# PASS '
    }
    python check_frame_streams.py
    if($LASTEXITCODE -ne 0){throw 'decoded-byte comparison failed'}
    python check_c2h_16k.py
    if($LASTEXITCODE -ne 0){throw '16 KiB C2H capture comparison failed'}
    python check_quad_throughput.py
    if($LASTEXITCODE -ne 0){throw 'Quad throughput stream decode failed'}
    python check_quad_crc.py
    if($LASTEXITCODE -ne 0){throw 'Quad parallel CRC equations invalid'}
} finally {Pop-Location}
