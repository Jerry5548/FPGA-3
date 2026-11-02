param([string]$ModelSimBin='E:\modeltech64_10.6d\win64')
$ErrorActionPreference='Stop'
$project=(Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$output=Join-Path $project 'imx415_pcie_4k_Runs\blk1_bram_sim_20261017'
New-Item -ItemType Directory -Force $output | Out-Null
Push-Location $output
try {
    if(!(Test-Path -LiteralPath 'work')) {
        & "$ModelSimBin\vlib.exe" work
        if($LASTEXITCODE -ne 0){throw 'vlib failed'}
    }
    & "$ModelSimBin\vmap.exe" work (Join-Path $output 'work')
    if($LASTEXITCODE -ne 0){throw 'vmap failed'}
    $rtl=Join-Path $project 'uisrc\01_rtl\lz77_rgb_c2h_path.v'
    $tb=Join-Path $PSScriptRoot 'tb_blk1_bram.sv'
    & "$ModelSimBin\vlog.exe" -work work -sv $rtl $tb
    if($LASTEXITCODE -ne 0){throw 'vlog failed'}
    @'
onerror {quit -code 1 -f}
onbreak {quit -code 1 -f}
run -all
quit -code 0 -f
'@ | Set-Content -Encoding ascii run_blk1.do
    $cases=@(
        @{Name='block16';W=32;H=8;Block=16;Frames=12},
        @{Name='block256';W=64;H=17;Block=256;Frames=12},
        @{Name='block32k';W=256;H=96;Block=32768;Frames=6},
        @{Name='rgb1080_block32k';W=1920;H=1080;Block=32768;Frames=3},
        @{Name='rgb1080_block64k_reference';W=1920;H=1080;Block=65536;Frames=1}
    )
    foreach($case in $cases) {
        $dir=Join-Path $output $case.Name
        New-Item -ItemType Directory -Force $dir | Out-Null
        Push-Location $dir
        try {
            $result=& "$ModelSimBin\vsim.exe" -c -modelsimini ../modelsim.ini work.tb_blk1_bram `
                "-gW=$($case.W)" "-gH=$($case.H)" "-gBLOCK=$($case.Block)" "-gFRAMES=$($case.Frames)" `
                -do ../run_blk1.do 2>&1
            $status=$LASTEXITCODE
            $result | Set-Content -Encoding utf8 simulation.log
            if($status -ne 0 -or !(($result -join "`n") -match '# PASS BLK1 BRAM')){
                throw "BLK1 simulation failed: $($case.Name)"
            }
            $result | Select-String '# PASS BLK1'
            python (Join-Path $PSScriptRoot 'check_blk1_bram.py') . `
                --width $case.W --height $case.H --block $case.Block --frames $case.Frames
            if($LASTEXITCODE -ne 0){throw "Decoded stream mismatch: $($case.Name)"}
        } finally {Pop-Location}
    }
    python (Join-Path $PSScriptRoot 'check_blk1_crc.py')
    if($LASTEXITCODE -ne 0){throw 'CRC equation check failed'}
    Write-Output "PASS complete BLK1 BRAM regression. Logs: $output"
} finally {Pop-Location}
