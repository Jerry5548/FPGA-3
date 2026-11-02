$ErrorActionPreference='Stop'
$p=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$out=Join-Path $p 'imx415_pcie_4k_Runs/mode8_9_ddr_20261018'
$bin='E:/modeltech64_10.6d/win64'
New-Item -ItemType Directory -Force $out | Out-Null
Push-Location $out
try {
    if(!(Test-Path work)){& "$bin/vlib.exe" work}
    & "$bin/vmap.exe" work (Join-Path $out 'work')
    $files=@('frame_async_fifo.v','ddr_frame_store_axi.v','ddr_camera_frame_path.v','lz77_rgb_c2h_path.v',
        'gray_pixel_stream.v','gaussian_3x3_stream.v','histogram_equalization_stream.v','median_3x3_stream.v',
        'sobel_3x3_stream.v','lowlight_enhance_stream.v','dehaze_stream.v','image_preprocess_quad.v') |
        ForEach-Object {Join-Path $p "uisrc/01_rtl/$_"}
    $files+=@((Join-Path $p 'uisrc/03_ip/vid_pipeline/pack4_rgb24_to_128.v'),
        (Join-Path $p 'uisrc/02_sim/c2h_regression/axi_frame_memory_model.sv'),(Join-Path $PSScriptRoot 'tb_enhance_ddr.sv'))
    & "$bin/vlog.exe" -sv -work work @files
    if($LASTEXITCODE -ne 0){throw 'vlog failed'}
    "onerror {quit -code 1 -f}`nonbreak {quit -code 1 -f}`nrun -all`nquit -code 0 -f" | Set-Content -Encoding ascii run.do
    foreach($mode in @(8,9)){
        $dir=Join-Path $out "mode$mode"
        python (Join-Path $PSScriptRoot 'gen_vectors.py') --width 16 --height 16 --frames 5 --mode $mode --output $dir
        if($LASTEXITCODE -ne 0){throw 'reference generation failed'}
        Push-Location $dir
        try{
            $result=& "$bin/vsim.exe" -c -modelsimini ../modelsim.ini work.tb_enhance_ddr "-gMODE=$mode" -do ../run.do 2>&1
            $rc=$LASTEXITCODE
            $result | Set-Content -Encoding utf8 simulation.log
            if($rc -ne 0 -or !(($result -join "`n") -match 'zero integrity errors')){throw "DDR mode $mode failed"}
            $result | Select-String '# PASS '
            python (Join-Path $PSScriptRoot 'check_ddr.py') .
            if($LASTEXITCODE -ne 0){throw 'decode mismatch'}
        }finally{Pop-Location}
    }
}finally{Pop-Location}
