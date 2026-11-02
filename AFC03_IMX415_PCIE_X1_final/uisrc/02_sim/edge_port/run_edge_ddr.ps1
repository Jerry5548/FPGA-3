param([string]$ModelSimBin='E:\modeltech64_10.6d\win64')
$ErrorActionPreference='Stop'
Push-Location $PSScriptRoot
try {
    $lib='work_edge_ddr'
    if(!(Test-Path -LiteralPath $lib)) {
        & "$ModelSimBin\vlib.exe" $lib
        if($LASTEXITCODE -ne 0){throw 'vlib failed'}
    }
    $rtl='../../01_rtl/'
    $sources=@('frame_async_fifo.v','ddr_frame_store_axi.v','ddr_camera_frame_path.v','rgb128_byte_stream.v',
       'lz77_repeat_encoder.v','lz77_frame_formatter.v','lz77_c2h_word_packer.v','lz77_rgb_c2h_path.v',
       'gray_pixel_stream.v','gaussian_3x3_stream.v','histogram_equalization_stream.v',
       'median_3x3_stream.v','sobel_3x3_stream.v','lowlight_enhance_stream.v','dehaze_stream.v','image_preprocess_quad.v') | ForEach-Object {$rtl+$_}
    $sources+=@('../../03_ip/vid_pipeline/pack4_rgb24_to_128.v','../c2h_regression/axi_frame_memory_model.sv','tb_edge_ddr_lz77.sv','tb_edge_runtime.sv')
    & "$ModelSimBin\vlog.exe" -sv -work $lib @sources
    if($LASTEXITCODE -ne 0){throw 'vlog failed'}
    python generate_quad_vectors.py --width 16 --height 16 --frames 5 --out vectors_16x16
    if($LASTEXITCODE -ne 0){throw 'reference generation failed'}
    foreach($mode in @(5,6)) {
        $result=& "$ModelSimBin\vsim.exe" -c -lib $lib tb_edge_ddr_lz77 "-gMODE=$mode" -do run_case.do 2>&1
        $code=$LASTEXITCODE
        $text=$result -join "`n"
        $result | Set-Content -Encoding utf8 "edge_ddr_mode${mode}.log"
        if($code -ne 0 -or $text -notmatch '# PASS ' -or $text -match '\*\* (Fatal|Error)'){throw "Edge DDR mode=$mode failed"}
        $result | Select-String '# PASS '
    }
    python generate_quad_vectors.py --width 8 --height 4 --frames 99 --out vectors_runtime
    if($LASTEXITCODE -ne 0){throw 'runtime reference generation failed'}
    $result=& "$ModelSimBin\vsim.exe" -c -lib $lib tb_edge_runtime "+VECTORS=vectors_runtime" -do run_case.do 2>&1
    $code=$LASTEXITCODE
    $text=$result -join "`n"
    $result | Set-Content -Encoding utf8 "edge_runtime.log"
    if($code -ne 0 -or $text -notmatch '# PASS ' -or $text -match '\*\* (Fatal|Error)'){throw 'Runtime mode switching failed'}
    $result | Select-String '# PASS '
    python check_edge_ddr.py
    if($LASTEXITCODE -ne 0){throw 'reference/CRC decode failed'}
} finally {Pop-Location}
