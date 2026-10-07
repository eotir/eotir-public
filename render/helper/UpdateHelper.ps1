# EOTIR Music Project - one-time helper updater (for helpers installed before self-update worked).
# ASCII only (Windows PowerShell 5.1). Safe to run more than once. Never touches helper_key or known_hosts.
$ErrorActionPreference = 'Stop'
$Base = "https://raw.githubusercontent.com/eotir/eotir-public/main/render/helper"
$ReleasePub = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJY5e32+Zjez/6J5BOK7rauDzhZrbsmNhhg6c4NbFnAY eotir-helper-release"
$Dir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Stop-Here([string]$msg) { Write-Host ""; Write-Host "   $msg" -ForegroundColor Red; Write-Host "   Nothing was changed. Please send Ryan a screenshot of this window."; exit 1 }

Write-Host ""
Write-Host "  EOTIR MUSIC PROJECT - Helper updater" -ForegroundColor Cyan
Write-Host "  This brings your helper up to date. It keeps your key and settings."
Write-Host ""

function Test-HelperDir([string]$d) { return ($d -and (Test-Path -LiteralPath (Join-Path $d "helper_key")) -and (Test-Path -LiteralPath (Join-Path $d "helper.json"))) }
if (-not (Test-HelperDir $Dir)) {
    # Not run from inside the helper folder: look for it in the usual places.
    $found = @()
    foreach ($r in @("$env:USERPROFILE\Desktop", "$env:USERPROFILE\Downloads", "$env:USERPROFILE\Documents", "$env:USERPROFILE\OneDrive", "$env:LOCALAPPDATA", "C:\Users\Public")) {
        if (Test-Path -LiteralPath $r) {
            $found += @(Get-ChildItem -LiteralPath $r -Filter helper_key -Recurse -Depth 4 -File -ErrorAction SilentlyContinue | ForEach-Object { $_.DirectoryName } | Where-Object { Test-HelperDir $_ })
        }
    }
    $found = @($found | Select-Object -Unique)
    if ($found.Count -eq 1) { $Dir = $found[0]; Write-Host ("  Found your helper folder: " + $Dir) -ForegroundColor White }
    else {
        Write-Host "  I could not find your helper folder by myself." -ForegroundColor Yellow
        Write-Host "  Open it in File Explorer, click the address bar, copy the path, and paste it here."
        $typed = (Read-Host "  Folder path").Trim().Trim('"')
        if (-not (Test-HelperDir $typed)) { Stop-Here "That folder does not have helper_key and helper.json in it." }
        $Dir = $typed
    }
}
if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue) -or -not (Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue)) {
    Stop-Here "Windows is missing curl or OpenSSH (normally built in). Please tell Ryan."
}

$tmp = Join-Path $env:TEMP ("eotir-upd-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    function Get-Url([string]$u, [string]$dest) {
        & curl.exe -fsSL --max-time 60 --retry 2 -o $dest $u 2>$null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $dest)) { Stop-Here "Could not download $u (is the internet working?)" }
    }
    Write-Host "  1/4  Downloading the signed update list..." -ForegroundColor White
    Get-Url "$Base/latest.json" "$tmp\latest.json"
    Get-Url "$Base/latest.json.sig" "$tmp\latest.json.sig"

    Write-Host "  2/4  Checking Ryan's digital signature..." -ForegroundColor White
    $signers = "$tmp\allowed_signers"
    [IO.File]::WriteAllText($signers, ('eotir-helper-release namespaces="eotir-render-helper" ' + $ReleasePub + "`n"), (New-Object Text.UTF8Encoding($false)))
    $o = (& cmd.exe /c "ssh-keygen.exe -Y verify -f `"$signers`" -I eotir-helper-release -n eotir-render-helper -s `"$tmp\latest.json.sig`" < `"$tmp\latest.json`" 2>&1" | Out-String)
    if ($LASTEXITCODE -ne 0 -or $o -notmatch '^Good ') { Stop-Here "The signature did not check out, so the update was REFUSED." }
    $m = Get-Content -Raw -LiteralPath "$tmp\latest.json" | ConvertFrom-Json

    Write-Host "  3/4  Downloading and checking the new files..." -ForegroundColor White
    $allowed = @("eotir-render.ps1", "How It Works.html")
    foreach ($f in $m.files) {
        if ($allowed -notcontains $f.path) { continue }
        $dest = Join-Path $tmp $f.path
        Get-Url ("$Base/files/" + [uri]::EscapeDataString($f.path)) $dest
        $got = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash.ToLower()
        if ($got -ne $f.sha256 -or (Get-Item -LiteralPath $dest).Length -ne [int64]$f.bytes) { Stop-Here "$($f.path) did not match its checksum." }
    }
    $t = $null; $pe = $null; [void][System.Management.Automation.Language.Parser]::ParseFile("$tmp\eotir-render.ps1", [ref]$t, [ref]$pe)
    if ($pe.Count -gt 0) { Stop-Here "The new script does not parse." }

    Write-Host "  4/4  Installing..." -ForegroundColor White
    foreach ($f in $m.files) {
        if ($allowed -notcontains $f.path) { continue }
        $live = Join-Path $Dir $f.path
        if (Test-Path -LiteralPath $live) { Copy-Item -LiteralPath $live -Destination ($live + ".bak") -Force }
        Copy-Item -LiteralPath (Join-Path $tmp $f.path) -Destination $live -Force
    }
    Copy-Item -LiteralPath $signers -Destination (Join-Path $Dir "allowed_signers") -Force
    # helper.json: keep host/port/user, just add or fix the update address.
    $cfgPath = Join-Path $Dir "helper.json"
    $cfg = Get-Content -Raw -LiteralPath $cfgPath | ConvertFrom-Json
    if ($cfg.PSObject.Properties.Name -contains "update_url") { $cfg.update_url = $Base } else { $cfg | Add-Member -NotePropertyName update_url -NotePropertyValue $Base }
    [IO.File]::WriteAllText($cfgPath, (($cfg | ConvertTo-Json) + "`n"), (New-Object Text.UTF8Encoding($false)))
    Write-Host ""
    Write-Host ("  DONE. Your helper is now version {0}. From now on it updates itself." -f $m.version) -ForegroundColor Green
    Write-Host "  Close this window and double-click Start Rendering.cmd as usual."
} catch {
    Stop-Here ("Something unexpected went wrong: " + $_.Exception.Message)
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host ""
