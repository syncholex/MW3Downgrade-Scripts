@echo off
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex ((Get-Content -LiteralPath '%~f0' -Raw) -split '#PS#')[2]"
pause
exit /b
#PS#
& {
$appId = "42690"
$dest = "C:\Games\MW3"
$deepVerify = $false   # set to $true to also compare SHA256 hashes (slow on large installs)
$sep = [char]92

$steamPath = (Get-ItemProperty -Path "HKCU:\Software\Valve\Steam" -ErrorAction SilentlyContinue).SteamPath
if (-not $steamPath) { Write-Host "Steam path not found in the registry."; return }
$steamPath = [IO.Path]::GetFullPath($steamPath.Replace([char]47, $sep))
$content = [IO.Path]::Combine($steamPath, "steamapps", "content")
$src = [IO.Path]::Combine($content, "app_$appId")
Write-Host "Looking in: $src"
if (-not (Test-Path -LiteralPath $src)) {
    Write-Host "Source folder not found. Folders that exist in content:"
    Get-ChildItem -LiteralPath $content -Directory -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  $($_.Name)" }
    return
}

# Build the file list (later depots overwrite earlier ones, same as the robocopy merge)
$map = @{}
foreach ($depot in Get-ChildItem -LiteralPath $src -Directory) {
    $root = $depot.FullName.TrimEnd($sep)
    foreach ($f in Get-ChildItem -LiteralPath $depot.FullName -Recurse -File -Force) {
        $rel = $f.FullName.Substring($root.Length).TrimStart($sep)
        $map[$rel] = $f
    }
}
if ($map.Count -eq 0) { Write-Host "No files found in $src"; return }
$total = ($map.Values | Measure-Object -Property Length -Sum).Sum
Write-Host ("Copying {0} files ({1:N0} MB)..." -f $map.Count, ($total / 1MB))

if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }

# Copy with progress bar
$buf = New-Object byte[] 4MB
$done = 0L
$sw = [Diagnostics.Stopwatch]::StartNew()
$last = 0
foreach ($rel in $map.Keys) {
    $f = $map[$rel]
    $t = Join-Path $dest $rel
    $td = Split-Path $t -Parent
    if (-not (Test-Path -LiteralPath $td)) { New-Item -ItemType Directory -Path $td -Force | Out-Null }
    $in = [IO.File]::OpenRead($f.FullName)
    $out = [IO.File]::Create($t)
    try {
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            $out.Write($buf, 0, $n)
            $done += $n
            if (($sw.ElapsedMilliseconds - $last) -gt 200) {
                $last = $sw.ElapsedMilliseconds
                $pct = [int](100 * $done / [Math]::Max($total, 1))
                Write-Progress -Activity "Copying files" -Status ("{0:N0} / {1:N0} MB - {2}" -f ($done / 1MB), ($total / 1MB), $f.Name) -PercentComplete $pct
            }
        }
    } finally { $in.Close(); $out.Close() }
    (Get-Item -LiteralPath $t).LastWriteTime = $f.LastWriteTime
}
Write-Progress -Activity "Copying files" -Completed

# Verify
$bad = @()
$i = 0
foreach ($rel in $map.Keys) {
    $i++
    Write-Progress -Activity "Verifying files" -Status "$i / $($map.Count)" -PercentComplete ([int](100 * $i / $map.Count))
    $f = $map[$rel]
    $t = Join-Path $dest $rel
    if (-not (Test-Path -LiteralPath $t)) { $bad += $rel; continue }
    if ((Get-Item -LiteralPath $t).Length -ne $f.Length) { $bad += $rel; continue }
    if ($deepVerify) {
        if ((Get-FileHash -LiteralPath $t).Hash -ne (Get-FileHash -LiteralPath $f.FullName).Hash) { $bad += $rel }
    }
}
Write-Progress -Activity "Verifying files" -Completed

if ($bad.Count -gt 0) {
    Write-Host "VERIFICATION FAILED for $($bad.Count) file(s). Source files were NOT deleted:"
    $bad | Select-Object -First 20 | ForEach-Object { Write-Host "  $_" }
    return
}

Write-Host "All $($map.Count) files verified. Removing source files..."
foreach ($depot in Get-ChildItem -LiteralPath $src -Directory) { Remove-Item -LiteralPath $depot.FullName -Recurse -Force }
if (-not (Get-ChildItem -LiteralPath $src -Force)) { Remove-Item -LiteralPath $src -Force }

Write-Host "The folder to select is $dest"
explorer $dest
Write-Host "Done"
}
#PS#
