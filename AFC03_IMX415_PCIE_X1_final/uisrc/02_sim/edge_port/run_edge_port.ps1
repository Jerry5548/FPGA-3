param([string]$ModelSimBin='E:\modeltech64_10.6d\win64',[switch]$SkipHD)
$ErrorActionPreference='Stop'
Push-Location $PSScriptRoot
try {
    $lib='work_edge_port'
    if(!(Test-Path -LiteralPath $lib)) {
        & "$ModelSimBin\vlib.exe" $lib
        if($LASTEXITCODE -ne 0){throw 'vlib failed'}
    }
    & "$ModelSimBin\vlog.exe" -sv -work $lib ../../01_rtl/gray_pixel_stream.v ../../01_rtl/gaussian_3x3_stream.v ../../01_rtl/histogram_equalization_stream.v ../../01_rtl/median_3x3_stream.v ../../01_rtl/sobel_3x3_stream.v ../../01_rtl/lowlight_enhance_stream.v ../../01_rtl/dehaze_stream.v ../../01_rtl/image_preprocess_quad.v tb_quad_modes.sv
    if($LASTEXITCODE -ne 0){throw 'vlog failed'}
    $cases=@(@(4,2,5),@(8,4,5),@(16,6,5))
    if(!$SkipHD){$cases+=,@(1920,1080,2)}
    foreach($case in $cases) {
        $w,$h,$n=$case
        $vectors="vectors_${w}x${h}"
        python generate_quad_vectors.py --width $w --height $h --frames $n --out $vectors
        if($LASTEXITCODE -ne 0){throw 'reference generation failed'}
        $modes=if($w -eq 8){@(0,1,2,3,4,5,6)}else{@(5,6)}
        foreach($mode in $modes) {
            $gaps=if($w -eq 1920){0}else{1}
            $result=& "$ModelSimBin\vsim.exe" -c -lib $lib tb_quad_modes "-gW=$w" "-gH=$h" "-gFRAMES=$n" "-gMODE=$mode" "-gGAPS=$gaps" "+VECTORS=$vectors" -do run_case.do 2>&1
            $code=$LASTEXITCODE
            $result | Set-Content -Encoding utf8 "quad_${w}x${h}_mode${mode}.log"
            $text=$result -join "`n"
            if($code -ne 0 -or $text -notmatch '# PASS ' -or $text -match '\*\* (Fatal|Error)') {
                throw "Simulation failed ${w}x${h} mode=$mode"
            }
            $result | Select-String '# PASS '
        }
    }
} finally {Pop-Location}
