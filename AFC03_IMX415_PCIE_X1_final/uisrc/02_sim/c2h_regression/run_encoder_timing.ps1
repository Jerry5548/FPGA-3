param([string]$ModelSimBin='E:\modeltech64_10.6d\win64')
$ErrorActionPreference='Stop'
$project=(Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$output=Join-Path $project 'imx415_pcie_4k_Runs\encoder_pipeline_equivalence_20261017'
New-Item -ItemType Directory -Force $output | Out-Null
$reference=Join-Path $project 'backups\before_encoder_pipeline_20261017\lz77_rgb_c2h_path.v'
if(!(Test-Path -LiteralPath $reference)){throw "Missing preserved reference: $reference"}
$old=Get-Content -LiteralPath $reference -Raw
$match=[regex]::Match($old,'(?s)module lz77_quad_encoder\(.*?endmodule')
if(!$match.Success){throw 'Reference encoder not found'}
$oldModule=$match.Value.Replace('module lz77_quad_encoder(','module lz77_quad_encoder_reference(')
[IO.File]::WriteAllText((Join-Path $output 'encoder_reference.v'),$oldModule,(New-Object Text.UTF8Encoding($false)))
Push-Location $output
try {
    if(!(Test-Path -LiteralPath 'work')){
        & "$ModelSimBin\vlib.exe" work
        if($LASTEXITCODE -ne 0){throw 'vlib failed'}
    }
    & "$ModelSimBin\vmap.exe" work (Join-Path $output 'work')
    if($LASTEXITCODE -ne 0){throw 'vmap failed'}
    $sources=@(
        (Join-Path $project 'uisrc\01_rtl\lz77_rgb_c2h_path.v'),
        (Join-Path $project 'uisrc\01_rtl\frame_async_fifo.v'),
        'encoder_reference.v',
        (Join-Path $PSScriptRoot 'tb_quad_encoder_equivalence.sv'),
        (Join-Path $PSScriptRoot 'tb_quad_runs.sv'),
        (Join-Path $PSScriptRoot 'tb_quad_throughput.sv'),
        (Join-Path $PSScriptRoot 'tb_frame_async_fifo.sv')
    )
    & "$ModelSimBin\vlog.exe" -sv -work work @sources
    if($LASTEXITCODE -ne 0){throw 'vlog failed'}
    @'
onerror {quit -code 1 -f}
onbreak {quit -code 1 -f}
run -all
quit -code 0 -f
'@ | Set-Content -Encoding ascii run_timing_case.do
    $cases=@(
        @{Top='tb_quad_encoder_equivalence';Args=@();Name='encoder_equivalence'},
        @{Top='tb_quad_runs';Args=@();Name='encoder_runs'},
        @{Top='tb_quad_throughput';Args=@();Name='legacy_throughput'},
        @{Top='tb_frame_async_fifo';Args=@();Name='fifo4'},
        @{Top='tb_frame_async_fifo';Args=@('-gAW=12','-gN=20000');Name='fifo12'}
    )
    foreach($case in $cases){
        $caseArgs=$case.Args
        $result=& "$ModelSimBin\vsim.exe" -c -lib work $case.Top @caseArgs -do run_timing_case.do 2>&1
        $status=$LASTEXITCODE
        $result | Set-Content -Encoding utf8 "$($case.Name).log"
        if($status -ne 0 -or !(($result -join "`n") -match '# PASS ') -or
           (($result -join "`n") -match '\*\* (Fatal|Error)')){throw "Failed $($case.Name)"}
        $result | Select-String '# PASS '
    }
    # Compare the emitted legacy frame using the independent Python decoder.
    $script=@'
from pathlib import Path
import sys
sys.path.insert(0,str(Path(sys.argv[1])/'rk3576'))
from lz77_decode import decode_frame
wire=bytes.fromhex(Path('quad_throughput.hex').read_text())
raw=bytes.fromhex(Path('quad_throughput_raw.hex').read_text())
image,meta=decode_frame(wire,expect_rgb24=True)
assert image==raw and meta['frame_id']==77
print('PASS pipelined legacy frame: exact pixels, CRC, geometry and frame ID')
'@
    $script | Set-Content -Encoding ascii check_legacy_stream.py
    python check_legacy_stream.py $project
    if($LASTEXITCODE -ne 0){throw 'legacy decoder mismatch'}
    python (Join-Path $PSScriptRoot 'check_gray_increment.py')
    if($LASTEXITCODE -ne 0){throw 'Gray pointer proof failed'}
    Write-Output "PASS encoder/FIFO timing regression; logs: $output"
} finally {Pop-Location}
