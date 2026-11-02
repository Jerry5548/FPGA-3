param([switch]$FullHD)
$ErrorActionPreference='Stop'
$project=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$out=Join-Path $project 'imx415_pcie_4k_Runs/mode8_9_validation_20261018'
$bin='E:/modeltech64_10.6d/win64'
New-Item -ItemType Directory -Force $out | Out-Null
Push-Location $out
try {
    if(!(Test-Path work)){& "$bin/vlib.exe" work}
    & "$bin/vmap.exe" work (Join-Path $out 'work')
    $files=@('gray_pixel_stream.v','gaussian_3x3_stream.v','histogram_equalization_stream.v',
        'median_3x3_stream.v','sobel_3x3_stream.v','lowlight_enhance_stream.v','dehaze_stream.v','image_preprocess_quad.v') |
        ForEach-Object {Join-Path $project "uisrc/01_rtl/$_"}
    & "$bin/vlog.exe" -work work -sv @files (Join-Path $PSScriptRoot 'tb_modes.sv')
    if($LASTEXITCODE -ne 0){throw 'vlog failed'}
    "onerror {quit -code 1 -f}`nonbreak {quit -code 1 -f}`nrun -all`nquit -code 0 -f" |
        Set-Content -Encoding ascii run.do
    $cases=@(@{Name='small';W=64;H=40;F=8;G=1;B=1100},@{Name='narrow';W=4;H=2;F=8;G=1;B=1100},
        @{Name='continuous';W=64;H=40;F=8;G=0;B=1100},@{Name='odd_tight';W=12;H=3;F=8;G=1;B=12},
        @{Name='narrow_odd';W=4;H=3;F=8;G=0;B=12})
    if($FullHD){$cases+=@{Name='1080p';W=1920;H=1080;F=5;G=1;B=12}}
    foreach($case in $cases){
        $dir=Join-Path $out $case.Name
        python (Join-Path $PSScriptRoot 'gen_vectors.py') --width $case.W --height $case.H --frames $case.F --output $dir
        if($LASTEXITCODE -ne 0){throw 'reference generation failed'}
        Push-Location $dir
        try{
            $result=& "$bin/vsim.exe" -c -modelsimini ../modelsim.ini work.tb_modes "-gW=$($case.W)" "-gH=$($case.H)" "-gFRAMES=$($case.F)" "-gGAPS=$($case.G)" "-gBLANK=$($case.B)" -do ../run.do 2>&1
            $rc=$LASTEXITCODE
            $result | Set-Content -Encoding utf8 simulation.log
            if($rc -ne 0 -or !(($result -join "`n") -match 'PASS mode8/9 real quad')){throw "simulation failed $($case.Name); see $dir/simulation.log"}
            $result | Select-String 'PASS mode8/9'
        }finally{Pop-Location}
    }
}finally{Pop-Location}
