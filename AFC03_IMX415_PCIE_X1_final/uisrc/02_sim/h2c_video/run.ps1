param([switch]$FullHD)
$ErrorActionPreference='Stop'
$p=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$out=Join-Path $p 'imx415_pcie_4k_Runs/h2c_video_v32_validation_20261021'
$bin='E:/modeltech64_10.6d/win64'
New-Item -ItemType Directory -Force $out | Out-Null
Push-Location $out
try {
    if(!(Test-Path work)){& "$bin/vlib.exe" work | Out-Null}
    & "$bin/vmap.exe" work (Join-Path $out 'work') | Out-Null
    $files=@('gray_pixel_stream.v','gaussian_3x3_stream.v','histogram_equalization_stream.v',
        'median_3x3_stream.v','sobel_3x3_stream.v','lowlight_enhance_stream.v','dehaze_stream.v',
        'image_preprocess_quad.v','video_preprocess_input.v','h2c_video_source.v','lz77_rgb_c2h_path.v') |
        ForEach-Object {Join-Path $p "uisrc/01_rtl/$_"}
    $files+=@((Join-Path $p 'uisrc/03_ip/vid_pipeline/sync_fifo_130.v'),
        (Join-Path $p 'uisrc/03_ip/vid_pipeline/pack4_rgb24_to_128.v'),(Join-Path $PSScriptRoot 'tb_h2v1.sv'))
    & "$bin/vlog.exe" -work work -sv @files *> compile.log
    if($LASTEXITCODE -ne 0){throw "vlog failed: $out/compile.log"}
    "onerror {quit -code 1 -f}`nonbreak {quit -code 1 -f}`nrun -all`nquit -code 0 -f" | Set-Content -Encoding ascii run.do
    # RGB24 transport is line-padded to 16 bytes: tested widths are multiples of 16.
    $cases=@(@{Name='small';W=16;H=16;F=3;B=256;HostInput=1},
        @{Name='odd';W=16;H=3;F=3;B=256;HostInput=1},
        @{Name='camera_regression';W=16;H=16;F=3;B=256;HostInput=0})
    if($FullHD){$cases+=@{Name='1080p';W=1920;H=1080;F=2;B=32768;HostInput=1}}
    foreach($case in $cases){foreach($mode in @(0,8,9)){
        $dir=Join-Path $out "$($case.Name)_mode$mode"
        python (Join-Path $p 'uisrc/02_sim/mode8_9/gen_vectors.py') --width $case.W --height $case.H --frames $case.F --mode $mode --t0 40 --omega 85 --brightness-bias 8 --output $dir
        if($LASTEXITCODE -ne 0){throw 'reference generation failed'}
        Push-Location $dir
        try {
            $result=& "$bin/vsim.exe" -c -modelsimini ../modelsim.ini work.tb_h2v1 "-gW=$($case.W)" "-gH=$($case.H)" "-gFRAMES=$($case.F)" "-gMODE=$mode" "-gBLOCK_BYTES=$($case.B)" "-gHOST=$($case.HostInput)" -do ../run.do 2>&1
            $rc=$LASTEXITCODE
            $result | Set-Content -Encoding utf8 simulation.log
            if($rc -ne 0 -or !(($result -join "`n") -match 'PASS H2V1 fail-closed')){throw "simulation failed: $dir/simulation.log"}
            $result | Select-String '# PASS '
            python (Join-Path $PSScriptRoot 'check_stream.py') . --width $case.W --height $case.H --frames $case.F --block $case.B
            if($LASTEXITCODE -ne 0){throw 'pixel/CRC/frame comparison failed'}
        } finally {Pop-Location}
    }}
} finally {Pop-Location}
