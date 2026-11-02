$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$release = Join-Path $root 'imx415_pcie_4k_Runs/debug_release_ddr_v26_20261009'
$phy = Join-Path $root 'imx415_pcie_4k_Runs/phy_1'
$syn = Join-Path $root 'imx415_pcie_4k_Runs/syn_1'
$freezePath = Join-Path $PSScriptRoot 'ddr_v26_sources.json'
$freeze = Get-Content -LiteralPath $freezePath -Raw -Encoding UTF8 | ConvertFrom-Json
$phyLog = Get-Content -LiteralPath "$phy/rebuild_ddr_v26.console.log" -Raw
$synLog = Get-Content -LiteralPath "$syn/rebuild_ddr_v26.console.log" -Raw
if ($phyLog -match 'ERROR:' -or $synLog -match 'ERROR:') { throw 'TD error in build log' }
if ($phyLog -notmatch 'finish command "bitgen -bit imx415_pcie_4k.bit"') { throw 'Bitgen completion missing' }
$buildStart = (Get-Item -LiteralPath "$phy/rebuild_ddr_v26.console.log").CreationTime
foreach ($name in 'imx415_pcie_4k.bit','imx415_pcie_4k_compress.bit','imx415_pcie_4k_phy.ts','imx415_pcie_4k_pr.timing') {
    if ((Get-Item -LiteralPath "$phy/$name").LastWriteTime -lt $buildStart) { throw "Stale artifact: $name" }
}
foreach ($entry in $freeze.sources.PSObject.Properties) {
    $hash = (Get-FileHash -LiteralPath (Join-Path $root $entry.Name) -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -ne $entry.Value) { throw "Source changed during build: $($entry.Name)" }
}
$timing = Get-Content -LiteralPath "$phy/imx415_pcie_4k_phy.ts" -Raw
if ($timing -notmatch 'SWNS:\s*([-\d.]+)ns') { throw 'Setup timing missing' }
$setup = [double]$Matches[1]
if ($timing -notmatch 'HWNS:\s*([-\d.]+)ns') { throw 'Hold timing missing' }
$hold = [double]$Matches[1]
if (Test-Path -LiteralPath "$release/release_manifest.json") { throw 'Release already finalized; do not overwrite' }
New-Item -ItemType Directory -Path $release -Force | Out-Null
function Copy-ReleaseFile($source, $relative) {
    $dest = Join-Path $release $relative
    New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $dest
}
Copy-ReleaseFile "$phy/imx415_pcie_4k.bit" 'imx415_pcie_4k_ddr_v26.bit'
Copy-ReleaseFile "$phy/imx415_pcie_4k_compress.bit" 'imx415_pcie_4k_ddr_v26_compress.bit'
Copy-ReleaseFile "$phy/imx415_pcie_4k_phy.ts" 'timing.ts'
Copy-ReleaseFile "$phy/imx415_pcie_4k_pr.timing" 'routed_timing.rpt'
Copy-ReleaseFile "$phy/imx415_pcie_4k_pr.timing" 'final_timing.rpt'
Copy-ReleaseFile "$phy/imx415_pcie_4k_phy.area" 'implementation.area'
Copy-ReleaseFile "$phy/rebuild_ddr_v26.console.log" 'implementation_bitgen.console.log'
Copy-ReleaseFile "$syn/rebuild_ddr_v26.console.log" 'synthesis.console.log'
Copy-ReleaseFile "$syn/imx415_pcie_4k_gate.area" 'synthesis.area'
Copy-ReleaseFile "$PSScriptRoot/ddr_first_fault_v26.md" 'development.md'
Copy-ReleaseFile "$PSScriptRoot/ddr_v26_release_readme.md" 'README.md'
Copy-ReleaseFile $freezePath 'sources.json'
foreach ($name in 'test_lz77_frames.sh','diag_lz77.sh','decode_ddr_fault.py','view_lz77_image.sh','mode_control.sh') {
    Copy-ReleaseFile "$root/deploy/$name" "deploy/$name"
}
foreach ($entry in $freeze.sources.PSObject.Properties) {
    Copy-ReleaseFile (Join-Path $root $entry.Name) "source_snapshot/$($entry.Name)"
}
foreach ($name in 'tb_ddr_frame_path','tb_ddr_startup','tb_ddr_diagnostics','tb_ddr_lz77','tb_ddr_lz77_startup') {
    Copy-ReleaseFile "$root/uisrc/02_sim/c2h_regression/$name.log" "simulation/$name.log"
}
foreach ($name in 'edge_ddr_mode5','edge_ddr_mode6','edge_runtime') {
    Copy-ReleaseFile "$root/uisrc/02_sim/edge_port/$name.log" "simulation/$name.log"
}
$files = [ordered]@{}
foreach ($file in (Get-ChildItem -LiteralPath $release -File -Recurse | Sort-Object FullName)) {
    $relative = $file.FullName.Substring($release.Length + 1).Replace('\','/')
    if ($relative -in 'SHA256SUMS','release_manifest.json') { continue }
    $files[$relative] = [ordered]@{bytes=$file.Length;sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
}
$manifest = [ordered]@{
    version='0x56440026'
    status='RTL/regression/synthesis/place/route/bitgen complete; diagnostic only; hardware unverified'
    timing_closed=($setup -ge 0 -and $hold -ge 0)
    setup_wns_ns=$setup
    hold_wns_ns=$hold
    built_at=(Get-Date -Format o)
    original_project='imx415_pcie_4k.al'
    sources=$freeze.sources
    artifacts=$files
    warning_notes=@('Check actual TD logs and timing reports; no hardware root-cause fix claimed',
        'ERAM reset TMR-5506','MIPI mixed clock fanout PHY-5060','DDR BUFG cascade CLKST-5093',
        'PCIe requested 62.5 MHz versus actual 125 MHz USR-6144','Timing optimization OPT-6001')
}
$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText("$release/release_manifest.json", ($manifest | ConvertTo-Json -Depth 10), $utf8)
$sums = @($files.GetEnumerator() | ForEach-Object { "$($_.Value.sha256)  $($_.Key)" })
$sums += "$((Get-FileHash -LiteralPath "$release/release_manifest.json" -Algorithm SHA256).Hash.ToLowerInvariant())  release_manifest.json"
[IO.File]::WriteAllText("$release/SHA256SUMS", (($sums -join "`n") + "`n"), $utf8)
foreach ($entry in $files.GetEnumerator()) {
    if ((Get-FileHash -LiteralPath (Join-Path $release $entry.Key) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $entry.Value.sha256) {
        throw "Packaged hash mismatch: $($entry.Key)"
    }
}
Write-Output "Release: $release"
Write-Output "Source hashes verified: $(@($freeze.sources.PSObject.Properties).Count)"
Write-Output "Artifacts verified: $($files.Count); setup WNS=$setup ns; hold WNS=$hold ns"
