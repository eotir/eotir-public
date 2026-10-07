# eotir-render.ps1 -- EOTIR Music Project render helper (Windows, no admin needed).
#
# ASCII ONLY, DELIBERATELY: this runs under Windows PowerShell 5.1, which reads a BOM-less .ps1 as
# ANSI. One smart quote or em dash becomes mojibake and can break parsing far from the cause.
#
# What it does, in plain words: it fetches a render job Ryan assigned to this helper from his
# private file server, makes the video on this computer, checks it, and sends it back.
# Everything it installs lives in ONE folder (default %LOCALAPPDATA%\Eotir). Delete that
# folder and it is all gone. It never installs anything system-wide and never asks for admin.
#
# Package layout (made by videos/render-helper/build_helper_package.py):
#   Start Rendering.cmd  eotir-render.ps1  helper.json  helper_key  known_hosts
#
# Parameters:
#   -CheckOnly   test the computer + the connection to the server, then stop
#   -Job <id>    render a specific job id instead of "the next one assigned to me"
#   -HomeDir     where tools/work files live (tests use a scratch folder)
#   -KeepFiles   do not delete the downloaded job and render after a successful upload
#   -NoWait      if there is no job, say so and stop (default: WAIT and start by itself when one arrives)
#   -PollSeconds how often to look for a job while waiting (default 180)
#   -MaxWaitHours stop waiting after this long (default 0 = keep waiting until you press Q or close the window)
#   -Once        make ONE video and stop (default: keep going - after each video it looks for the next one)
#   -NoUpdate    do not check for a newer version of this script
param(
    [switch]$CheckOnly,
    [string]$Job = "",
    [string]$HomeDir = "",
    [switch]$KeepFiles,
    [switch]$NoWait,
    [int]$PollSeconds = 180,
    [int]$MaxWaitHours = 0,
    [switch]$Once,
    [switch]$NoUpdate
)
$script:SelfPath = $MyInvocation.MyCommand.Path
# A PowerShell 7 parent (or any polluted environment) can leave PSModulePath pointing at modules that Windows
# PowerShell 5.1 cannot load, and then built-in cmdlets such as Get-FileHash "do not exist" (reproduced: hidden child
# of pwsh 7 died at Step 2). This script is written for 5.1, so pin the module path to the ones 5.1 owns.
if ($PSVersionTable.PSVersion.Major -le 5) {
    $env:PSModulePath = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules') + ';' +
        (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules') + ';' +
        (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules')
}

$ErrorActionPreference = 'Continue'    # native tools write to stderr; we check exit codes ourselves
$ProgressPreference    = 'SilentlyContinue'
$PkgDir = Split-Path -Parent $MyInvocation.MyCommand.Path
# Windows refuses file paths over 260 characters, and Remotion's bundled Chrome sits ~145 characters below the
# kit folder. So the install location is kept SHORT (found the hard way: a 269-char path made Node fail with
# ENOENT launching Chrome). If this PC's user-profile path is long, use the shared Public folder instead.
$LongestTail = 'k\xxxxxxxx\remotion-composer\node_modules\.remotion\chrome-headless-shell\win64\chrome-headless-shell-win64\chrome-headless-shell.exe'
if ($HomeDir -eq "") {
    $HomeDir = Join-Path $env:LOCALAPPDATA "Eotir"
    if (($HomeDir.Length + 1 + $LongestTail.Length) -gt 235) { $HomeDir = Join-Path $env:PUBLIC "Eotir" }
}
if (($HomeDir.Length + 1 + $LongestTail.Length) -gt 250) {
    Write-Host ""
    Write-Host "  Oops - something did not work. Nothing on your computer is harmed." -ForegroundColor Red
    Write-Host "  ERROR CODE:    E-CHECK-PATH" -ForegroundColor Yellow
    Write-Host ("  What happened: The install folder path is too long for Windows ({0} characters before the tools are even added)." -f $HomeDir.Length) -ForegroundColor Yellow
    Write-Host "  Please tell Ryan the ERROR CODE above." -ForegroundColor White
    exit 1
}

# ---------------------------------------------------------------- look and feel
$script:StepNames = @(
    "Checking your computer",
    "Getting the video tools ready",
    "Getting the EOTIR render kit",
    "Connecting to Ryan's server",
    "Downloading your video job",
    "Making the video",
    "Sending the finished video back"
)
# How much of the overall bar each step is worth (rough: rendering is by far the longest).
$script:StepWeight = @(2, 6, 14, 2, 8, 58, 10)
$script:CurStep = 0
$script:FirstStep = 1
$script:StopRequested = $false
$script:LogFile = $null
$script:BarWidth = 30

function Write-Log([string]$m) {
    if ($script:LogFile) { try { Add-Content -Path $script:LogFile -Value ("{0} {1}" -f (Get-Date -Format "HH:mm:ss"), $m) } catch {} }
}
function Say([string]$t, [string]$c = "White") { Write-Host $t -ForegroundColor $c; Write-Log $t }
function Hint([string]$t) { Write-Host ("   " + $t) -ForegroundColor DarkGray; Write-Log ("   " + $t) }
function Good([string]$t) { Write-Host ("   [OK] " + $t) -ForegroundColor Green; Write-Log ("OK " + $t) }
function Warn([string]$t) { Write-Host ("   [!] " + $t) -ForegroundColor Yellow; Write-Log ("WARN " + $t) }

function Fmt-Time([double]$sec) {
    if ($sec -lt 0 -or [double]::IsNaN($sec) -or [double]::IsInfinity($sec)) { return "figuring it out..." }
    $s = [int]$sec
    $h = [math]::Floor($s / 3600); $m = [math]::Floor(($s % 3600) / 60); $r = $s % 60
    if ($h -gt 0) { return ("{0}h {1}m" -f $h, $m) }
    if ($m -gt 0) { return ("{0}m {1}s" -f $m, $r) }
    return ("{0}s" -f $r)
}
function Fmt-MB([double]$b) { return ("{0:N1} MB" -f ($b / 1MB)) }

# Press Q to stop. Works in a normal console window; when input is redirected (tests, scheduled runs) there is no
# key to read and this simply never triggers. A Q during a video means "stop after this video is delivered".
function Test-QuitKey {
    try { while ([Console]::KeyAvailable) { $k = [Console]::ReadKey($true); if ($k.Key -eq [ConsoleKey]::Q) { $script:StopRequested = $true } } } catch {}
    return $script:StopRequested
}

function Make-Bar([double]$pct) {
    if ($pct -lt 0) { $pct = 0 }; if ($pct -gt 100) { $pct = 100 }
    $filled = [int][math]::Round($script:BarWidth * $pct / 100)
    return ("[" + ("#" * $filled) + ("-" * ($script:BarWidth - $filled)) + "]")
}

function Overall-Pct([double]$phasePct) {
    # FirstStep is 1 for the first job (setup counts) and 4 for every later job (setup is already done).
    $f = [int]$script:FirstStep; if ($f -lt 1) { $f = 1 }
    $total = 0
    for ($i = $f - 1; $i -lt $script:StepWeight.Count; $i++) { $total += $script:StepWeight[$i] }
    $before = 0
    for ($i = $f - 1; $i -lt $script:CurStep - 1; $i++) { $before += $script:StepWeight[$i] }
    $cur = $script:StepWeight[$script:CurStep - 1] * ($phasePct / 100)
    return (100 * ($before + $cur) / $total)
}

# One redrawing line: "step bar  detail".  `r returns to line start; padded so old text is wiped.
function Show-Progress([double]$phasePct, [string]$detail) {
    if ($script:StopRequested) { $detail += "   [Q pressed: stopping after this video]" }
    $line = "   {0} {1,3}%  {2}" -f (Make-Bar $phasePct), [int]$phasePct, $detail
    $w = 110; try { $w = [Console]::WindowWidth - 2 } catch {}
    if ($line.Length -gt $w) { $line = $line.Substring(0, $w) }
    Write-Host ("`r" + $line.PadRight($w)) -NoNewline -ForegroundColor Cyan
}
function Show-Overall() { }  # overall bar is drawn by Start-Step / End-Step so it never fights the live line

function Start-Step([int]$n) {
    $script:CurStep = $n
    $ov = Overall-Pct 0
    Write-Host ""
    Write-Host ("=== Step {0} of {1}: {2}" -f $n, $script:StepNames.Count, $script:StepNames[$n - 1]) -ForegroundColor Yellow
    Write-Host ("    Overall   {0} {1,3}%" -f (Make-Bar $ov), [int]$ov) -ForegroundColor Magenta
    Write-Log ("STEP {0}: {1}" -f $n, $script:StepNames[$n - 1])
}
function End-Step() { Write-Host ""; $ov = Overall-Pct 100; Write-Host ("    Overall   {0} {1,3}%" -f (Make-Bar $ov), [int]$ov) -ForegroundColor Magenta }

function Show-Banner {
    $g = @{
        'E' = @(' _____ ', '| ____|', '|  _|  ', '| |___ ', '|_____|')
        'O' = @('  ___  ', ' / _ \ ', '| | | |', '| |_| |', ' \___/ ')
        'T' = @(' _____ ', '|_   _|', '  | |  ', '  | |  ', '  |_|  ')
        'I' = @(' ___ ', '|_ _|', ' | | ', ' | | ', '|___|')
        'R' = @(' ____  ', '|  _ \ ', '| |_) |', '|  _ < ', '|_| \_\')
        'M' = @(' __  __ ', '|  \/  |', '| |\/| |', '| |  | |', '|_|  |_|')
        'U' = @(' _   _ ', '| | | |', '| | | |', '| |_| |', ' \___/ ')
        'S' = @(' ____  ', '/ ___| ', '\___ \ ', ' ___) |', '|____/ ')
        'C' = @('  ____ ', ' / ___|', '| |    ', '| |___ ', ' \____|')
        'P' = @(' ____  ', '|  _ \ ', '| |_) |', '|  __/ ', '|_|    ')
        'J' = @('     _ ', '    | |', ' _  | |', '| |_| |', ' \___/ ')
    }
    function Word([string]$w) {
        $rows = @('', '', '', '', '')
        foreach ($ch in $w.ToCharArray()) { for ($i = 0; $i -lt 5; $i++) { $rows[$i] += $g[[string]$ch][$i] } }
        return $rows
    }
    $a = Word "EOTIR"; $b = Word "MUSIC"; $c = Word "PROJECT"
    Write-Host ""
    for ($i = 0; $i -lt 5; $i++) { Write-Host ("  " + $a[$i] + "   " + $b[$i]) -ForegroundColor Cyan }
    for ($i = 0; $i -lt 5; $i++) { Write-Host ("  " + $c[$i]) -ForegroundColor Magenta }
    Write-Host ""
    Write-Host "   ==============  R E N D E R   H E L P E R  ==============" -ForegroundColor Yellow
    Write-Host "   Thank you for lending your computer to the EOTIR Music Project!" -ForegroundColor White
    Write-Host ""
}

# Every failure carries a short CODE (e.g. E-RENDER). The code + an auto-built report are how Ryan finds
# out what went wrong without asking the helper anything (see New-ErrorReport / Send-Report below).
$script:ErrCode = $null
# ScriptBuild is the MONOTONIC release number the self-updater compares (publish_update.py reads this
# line). Bump it on every release; the label is for humans.
$script:ScriptBuild = 5
$script:ScriptVersion = "2026-10-06.5"
$script:StartTime = Get-Date
function Fail([string]$code, [string]$what) { $script:ErrCode = $code; Write-Log ("FAIL [{0}] {1}" -f $code, $what); throw $what }

# ---------------------------------------------------------------- keep the PC awake while we work
try {
    Add-Type -Namespace Eotir -Name Power -MemberDefinition '[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f);' -ErrorAction Stop
    $script:CanKeepAwake = $true
} catch { $script:CanKeepAwake = $false }
function Keep-Awake([bool]$on) {
    if (-not $script:CanKeepAwake) { return }
    if ($on) { [void][Eotir.Power]::SetThreadExecutionState([uint32]2147483649) }   # ES_CONTINUOUS | ES_SYSTEM_REQUIRED
    else     { [void][Eotir.Power]::SetThreadExecutionState([uint32]2147483648) }   # ES_CONTINUOUS
}

# ---------------------------------------------------------------- helpers: running programs with a live bar
function Quote-Arg([string]$a) { if ($a -match '[\s"]') { return '"' + ($a -replace '"', '\"') + '"' } else { return $a } }

function Get-FileLen([string]$p) { if (Test-Path -LiteralPath $p) { return (Get-Item -LiteralPath $p).Length } else { return 0 } }

# Run something hidden; draw a spinner + elapsed + last log line until it exits. Returns exit code.
function Wait-WithSpinner($proc, [string]$label, [string]$logPath) {
    $spin = @('|', '/', '-', '\'); $i = 0; $t0 = Get-Date
    while (-not $proc.HasExited) {
        $last = ""
        if ($logPath -and (Test-Path -LiteralPath $logPath)) {
            try {
                $fs = [IO.File]::Open($logPath, 'Open', 'Read', 'ReadWrite'); $sr = New-Object IO.StreamReader($fs)
                $txt = $sr.ReadToEnd(); $sr.Close(); $fs.Close()
                $ls = @($txt -split "[\r\n]+" | Where-Object { $_.Trim() -ne "" }); if ($ls.Count -gt 0) { $last = $ls[-1].Trim() }
            } catch {}
        }
        $el = ((Get-Date) - $t0).TotalSeconds
        Show-Progress ([math]::Min(95, 100 * (1 - [math]::Exp(-$el / 150)))) ("{0} {1}  working for {2}  {3}" -f $spin[$i % 4], $label, (Fmt-Time $el), $last)
        $i++; Start-Sleep -Milliseconds 400
    }
    $proc.WaitForExit()
    Show-Progress 100 ("{0} done in {1}" -f $label, (Fmt-Time (((Get-Date) - $t0).TotalSeconds)))
    Write-Host ""
    return $proc.ExitCode
}

# Download a URL with curl.exe (built into Windows 10/11) and a real progress bar.
function Download-File([string]$url, [string]$dest, [string]$label) {
    $total = 0
    try { $h = & curl.exe -sIL --max-time 30 $url 2>$null; $m = [regex]::Matches(($h -join "`n"), '(?im)^content-length:\s*(\d+)'); if ($m.Count -gt 0) { $total = [double]$m[$m.Count - 1].Groups[1].Value } } catch {}
    $err = Join-Path $script:Tmp "curl.err"
    $p = Start-Process -FilePath "curl.exe" -ArgumentList @('-fsSL', '--retry', '3', '-C', '-', '-o', (Quote-Arg $dest), (Quote-Arg $url)) -PassThru -WindowStyle Hidden -RedirectStandardError $err
    $null = $p.Handle
    Watch-Transfer $p { Get-FileLen $dest } $total $label
    if ($p.ExitCode -ne 0) { Fail "E-DOWNLOAD" ("Download of {0} failed (code {1}). Is your internet working?" -f $label, $p.ExitCode) }
}

# Poll a byte counter and draw bar + speed + ETA until the process ends.
function Watch-Transfer($proc, [scriptblock]$getBytes, [double]$total, [string]$label, [int]$pollMs = 500) {
    $t0 = Get-Date; $start = & $getBytes; $lastB = $start; $lastT = $t0; $speed = 0
    while (-not $proc.HasExited) {
        $b = & $getBytes; $now = Get-Date
        $dt = ($now - $lastT).TotalSeconds
        if ($dt -ge 1) { $inst = ($b - $lastB) / $dt; $speed = if ($speed -eq 0) { $inst } else { 0.7 * $speed + 0.3 * $inst }; $lastB = $b; $lastT = $now }
        if ($total -gt 0) {
            $pct = 100 * $b / $total; $eta = if ($speed -gt 1) { ($total - $b) / $speed } else { -1 }
            Show-Progress $pct ("{0}  {1} of {2}  {3}/s  about {4} left" -f $label, (Fmt-MB $b), (Fmt-MB $total), (Fmt-MB $speed), (Fmt-Time $eta))
        } else {
            Show-Progress 50 ("{0}  {1} so far  {2}/s" -f $label, (Fmt-MB $b), (Fmt-MB $speed))
        }
        Start-Sleep -Milliseconds $pollMs
    }
    $proc.WaitForExit()
    Show-Progress 100 ("{0}  finished in {1}" -f $label, (Fmt-Time (((Get-Date) - $t0).TotalSeconds)))
    Write-Host ""
}

# ---------------------------------------------------------------- SFTP to Ryan's server
function Get-SftpArgs([string]$batchFile) {
    return @('-b', $batchFile, '-P', "$($script:Cfg.port)", '-i', $script:KeyPath,
        '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes',
        '-o', ("UserKnownHostsFile=" + ($script:KnownHosts -replace '\\', '/')),
        '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=20',
        '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=8',
        ("{0}@{1}" -f $script:Cfg.user, $script:Cfg.host))
}
function Fwd([string]$p) { return ($p -replace '\\', '/') }

function New-Batch([string[]]$lines) {
    $bf = Join-Path $script:Tmp ("b" + [guid]::NewGuid().ToString('N') + ".txt")
    [IO.File]::WriteAllText($bf, (($lines -join "`n") + "`n"))
    return $bf
}
# Run a short sftp command list and wait. Lines starting with '-' are allowed to fail.
function Invoke-Sftp([string[]]$lines) {
    # The server's sshd throttles bursts of new connections (MaxStartups: "kex_exchange_identification:
    # Connection reset" - found when a burst of OTHER connections dropped a helper's very last login and a
    # finished 295 MB upload failed at the final rename). A dropped connection is transient, so retry those
    # (and only those) with a growing pause. Real errors (no such file, permission denied, denied key) are not retried.
    $transient = 'kex_exchange_identification|Connection reset|Connection closed|Connection timed out|Connection refused|Broken pipe|ssh_exchange_identification|Could not resolve|Network is unreachable|No route to host'
    $bf = New-Batch $lines
    $delays = @(4, 10, 20)
    for ($try = 0; $try -le $delays.Count; $try++) {
        $out = & sftp.exe (Get-SftpArgs $bf) 2>&1 | Out-String
        $code = $LASTEXITCODE
        Write-Log ("sftp [{0}] -> exit {1}{2}" -f ($lines -join " ; "), $code, $(if ($try -gt 0) { " (retry $try)" } else { "" }))
        if ($code -eq 0 -or $out -notmatch $transient -or $try -ge $delays.Count) { break }
        Start-Sleep -Seconds $delays[$try]
    }
    Remove-Item -LiteralPath $bf -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Code = $code; Out = $out }
}
# Start a long sftp transfer in the background, return the process (caller watches it).
function Start-SftpBg([string[]]$lines, [string]$tag) {
    $bf = New-Batch $lines
    $o = Join-Path $script:Tmp ("sftp_" + $tag + ".out"); $e = Join-Path $script:Tmp ("sftp_" + $tag + ".err")
    $args2 = (Get-SftpArgs $bf | ForEach-Object { Quote-Arg $_ }) -join ' '
    $p = Start-Process -FilePath "sftp.exe" -ArgumentList $args2 -PassThru -WindowStyle Hidden -RedirectStandardOutput $o -RedirectStandardError $e
    $null = $p.Handle
    return $p
}
function Get-RemoteSize([string]$remotePath) {
    $r = Invoke-Sftp @(("ls -l `"{0}`"" -f $remotePath))
    if ($r.Code -ne 0) { return -1 }
    # sftp prints e.g. "-rw-******    ? 1004     1004      1502230 Oct  5 16:58 path" - the link-count column is a
    # literal "?" (found the hard way), so match columns loosely and anchor on  <size> <Mon> <day>.
    foreach ($ln in ($r.Out -split "`n")) { if ($ln -match '^\S+\s+\S+\s+\S+\s+\S+\s+(\d+)\s+[A-Z][a-z]{2}\s+\d') { return [double]$Matches[1] } }
    return -1
}

function Explain-ConnectError([string]$out) {
    if ($out -match 'Permission denied') { return "The server did not accept this computer's key. Ryan may need to re-enable it." }
    if ($out -match 'Connection (timed out|refused)|Could not resolve|No route|Network is unreachable') { return "Could not reach the server. Check that your internet is working. If it is, the server may be down for a moment." }
    if ($out -match 'REMOTE HOST IDENTIFICATION|Host key verification') { return "The server's ID did not match what we expected. Please do NOT continue - tell Ryan right away." }
    if ($out -match 'banned|Connection closed') { return "The server closed the connection. If you tried several times, it may have paused you for a while. Wait an hour and try again, or tell Ryan." }
    return "The connection failed."
}

# ---------------------------------------------------------------- error reporting
# Last N characters of a text file, read without locking it (Remotion/npm may still be writing).
function Get-TailChars([string]$path, [int]$chars = 4000) {
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return "(no such file)" }
    try {
        $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite'); $sr = New-Object IO.StreamReader($fs)
        $txt = $sr.ReadToEnd(); $sr.Close(); $fs.Close()
        if ($txt.Length -gt $chars) { $txt = "..." + $txt.Substring($txt.Length - $chars) }
        return (($txt -replace "`r", "`n") -replace "`n{2,}", "`n").TrimEnd()
    } catch { return ("(could not read: {0})" -f $_.Exception.Message) }
}

function Get-EnvSummary() {
    $o = New-Object System.Collections.Generic.List[string]
    $o.Add(("Windows        : {0}  64-bit OS={1}" -f [Environment]::OSVersion.VersionString, [Environment]::Is64BitOperatingSystem))
    $o.Add(("PowerShell     : {0}" -f $PSVersionTable.PSVersion))
    $o.Add(("Culture        : {0}" -f (Get-Culture).Name))
    $o.Add(("Processor thrds: {0}" -f [Environment]::ProcessorCount))
    try { $o.Add(("Memory         : {0} GB" -f [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1))) } catch { $o.Add("Memory         : (unreadable)") }
    try { $d = New-Object IO.DriveInfo ((Split-Path -Qualifier $HomeDir).TrimEnd(':')); $o.Add(("Free disk      : {0} GB on {1}" -f [math]::Round($d.AvailableFreeSpace / 1GB, 1), $d.Name)) } catch { $o.Add("Free disk      : (unreadable)") }
    $o.Add(("Install folder : {0}  (length {1})" -f $HomeDir, $HomeDir.Length))
    $o.Add(("Package folder : {0}" -f $PkgDir))
    $o.Add(("Script version : {0}" -f $script:ScriptVersion))
    try { $o.Add(("Node          : {0}" -f ((& node -v 2>$null) -join ""))) } catch { $o.Add("Node          : (not available)") }
    if ($script:Kit) { $o.Add(("Kit            : {0}" -f $script:Kit.version)) }
    if ($script:Cfg) { $o.Add(("Helper account : {0}  server {1}:{2}" -f $script:Cfg.user, $script:Cfg.host, $script:Cfg.port)) }
    foreach ($tool in @('sftp.exe', 'curl.exe', 'tar.exe', 'icacls.exe')) { $c = Get-Command $tool -ErrorAction SilentlyContinue; $o.Add(("{0,-15}: {1}" -f $tool, $(if ($c) { $c.Source } else { "MISSING" }))) }
    return ($o -join "`n")
}

# Build the full report: code, plain message, technical detail, this PC, recent logs. NO key contents, ever.
function New-ErrorReport([string]$code, $err) {
    $stepTxt = if ($script:CurStep -gt 0) { "{0} of {1} - {2}" -f $script:CurStep, $script:StepNames.Count, $script:StepNames[$script:CurStep - 1] } else { "before step 1" }
    $b = New-Object System.Text.StringBuilder
    [void]$b.AppendLine("=== EOTIR RENDER HELPER - ERROR REPORT ===")
    [void]$b.AppendLine(("Error code : {0}" -f $code))
    [void]$b.AppendLine(("Step       : {0}" -f $stepTxt))
    [void]$b.AppendLine(("When (UTC) : {0}" -f (Get-Date).ToUniversalTime().ToString("o")))
    [void]$b.AppendLine(("Running for : {0}" -f (Fmt-Time (((Get-Date) - $script:StartTime).TotalSeconds))))
    [void]$b.AppendLine(("Helper     : {0}" -f $(if ($script:Cfg) { $script:Cfg.user } else { "(config not read yet)" })))
    [void]$b.AppendLine(("Job        : {0}" -f $(if ($script:JobObj) { "{0} -> {1}" -f $script:JobObj.job_id, $script:JobObj.out_name } else { "(none picked yet)" })))
    [void]$b.AppendLine(("Message    : {0}" -f $err.Exception.Message))
    [void]$b.AppendLine("")
    [void]$b.AppendLine("--- technical detail ---")
    [void]$b.AppendLine(("Where : script line {0}" -f $err.InvocationInfo.ScriptLineNumber))
    [void]$b.AppendLine(("Line  : {0}" -f ($err.InvocationInfo.Line -as [string]).Trim()))
    [void]$b.AppendLine("Stack :")
    [void]$b.AppendLine(($err.ScriptStackTrace -as [string]))
    [void]$b.AppendLine("")
    [void]$b.AppendLine("--- this computer ---")
    [void]$b.AppendLine((Get-EnvSummary))
    [void]$b.AppendLine("")
    [void]$b.AppendLine("--- main log (last part) ---")
    [void]$b.AppendLine((Get-TailChars $script:LogFile 6000))
    # Any other log touched during THIS run (npm, browser, render, ffprobe...), newest first.
    $others = @()
    if ($script:LogsDir -and (Test-Path -LiteralPath $script:LogsDir)) {
        $others = @(Get-ChildItem -LiteralPath $script:LogsDir -Filter "*.log" -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -ne $script:LogFile -and $_.LastWriteTime -ge $script:StartTime.AddSeconds(-5) } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 5)
    }
    foreach ($f in $others) { [void]$b.AppendLine(""); [void]$b.AppendLine(("--- {0} (last part) ---" -f $f.Name)); [void]$b.AppendLine((Get-TailChars $f.FullName 4000)) }
    return $b.ToString()
}

# Try to put the report on Ryan's server: results/<helper>/_reports/<time>_<code>.txt
function Send-Report([string]$localPath, [string]$code) {
    try {
        if (-not $script:Cfg -or -not $script:KeyPath -or -not (Test-Path -LiteralPath $script:KeyPath) -or -not (Test-Path -LiteralPath $script:KnownHosts)) { return $false }
        $u = $script:Cfg.user
        $remote = "results/{0}/_reports/{1}_{2}.txt" -f $u, (Get-Date -Format "yyyyMMdd-HHmmss"), $code
        $r = Invoke-Sftp @(("-mkdir `"results/{0}/_reports`"" -f $u), ("put `"{0}`" `"{1}`"" -f (Fwd $localPath), $remote))
        return ($r.Code -eq 0)
    } catch { return $false }
}

# ---------------------------------------------------------------- self-update (signed)
# The updater pulls from a PUBLIC repo, so that repo's contents are NOT trusted: an update is accepted only if
# latest.json carries a valid ssh-keygen signature (-Y) from Ryan's release key, whose PUBLIC half ships in this
# package as allowed_signers. Anyone who can push to the public repo still cannot make this script run
# anything - they cannot forge the signature. A build number that is not newer is ignored (no rollback).
# Only the files named below can ever be replaced; helper.json / helper_key / known_hosts are never touched, and
# "Start Rendering.cmd" is excluded because replacing a batch file while cmd.exe is executing it corrupts the run.
$script:UpdateAllowed = @('eotir-render.ps1', 'How It Works.html')

function Get-Url([string]$url, [string]$dest) {
    & curl.exe -fsSL --max-time 25 --retry 1 -o $dest $url 2>$null
    return ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $dest) -and (Get-Item -LiteralPath $dest).Length -gt 0)
}

function Test-ReleaseSignature([string]$file, [string]$sig, [string]$signers) {
    # cmd's < redirect feeds the exact bytes; PowerShell piping would append a newline and break the signature.
    $c = "ssh-keygen.exe -Y verify -f `"$signers`" -I eotir-helper-release -n eotir-render-helper -s `"$sig`" < `"$file`" 2>&1"
    $o = (& cmd.exe /c $c | Out-String)
    $ok = ($LASTEXITCODE -eq 0 -and $o -match '^Good ')
    Write-Log ("signature check ok={0}: {1}" -f $ok, $o.Trim())
    return $ok
}

# Returns after either carrying on with this version, or (when the user accepts) installing the new one and
# re-running it (then $script:Relaunched is set and the caller must stop).
function Invoke-UpdateCheck {
    if ($NoUpdate) { return }
    $base = ("{0}" -f $script:Cfg.update_url).TrimEnd('/')
    $signers = Join-Path $PkgDir "allowed_signers"
    if ($base -eq "" -or -not (Test-Path -LiteralPath $signers)) { Write-Log "updates: not configured"; return }
    Say "Checking for a newer version of this helper..." White
    $d = Join-Path $script:Tmp "upd"; New-Item -ItemType Directory -Force -Path $d | Out-Null
    $okDl = (Get-Url "$base/latest.json" (Join-Path $d "latest.json")) -and (Get-Url "$base/latest.json.sig" (Join-Path $d "latest.json.sig"))
    if (-not $okDl) { Hint "(Could not check for updates just now - that is fine, carrying on.)"; return }
    if (-not (Test-ReleaseSignature (Join-Path $d "latest.json") (Join-Path $d "latest.json.sig") $signers)) {
        Warn "An update was found but its signature did not check out, so it was IGNORED. Carrying on with this version. (Please tell Ryan.)"
        return
    }
    try { $m = Get-Content -Raw -LiteralPath (Join-Path $d "latest.json") | ConvertFrom-Json } catch { Write-Log "update manifest unreadable"; return }
    if ([int]$m.build -le $script:ScriptBuild) { Good ("This helper is up to date (version {0})." -f $script:ScriptVersion); return }

    Say ""
    Say ("A newer version of this helper is available: {0}" -f $m.version) Yellow
    if ($m.notes) { Hint ("What's new: {0}" -f $m.notes) }
    $ans = "y"
    try {
        if ([Environment]::UserInteractive) { $ans = Read-Host "   Update now? Press Enter for yes, or type n to skip" }
    } catch { $ans = "n" }
    if ($ans -match '^\s*n') { Hint "Okay - keeping the current version for now."; return }

    # Download + verify every file against the SIGNED manifest before touching anything on disk.
    $nd = Join-Path $d "new"; if (Test-Path -LiteralPath $nd) { Remove-Item -LiteralPath $nd -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $nd | Out-Null
    foreach ($f in $m.files) {
        if ($script:UpdateAllowed -notcontains $f.path) { Write-Log ("update: ignoring non-allowed path {0}" -f $f.path); continue }
        $dest = Join-Path $nd $f.path
        if (-not (Get-Url ("$base/files/" + [uri]::EscapeDataString($f.path)) $dest)) { Warn ("Could not download {0}; staying on the current version." -f $f.path); return }
        $got = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash.ToLower()
        if ($got -ne $f.sha256 -or (Get-Item -LiteralPath $dest).Length -ne [int64]$f.bytes) { Warn ("{0} did not match its checksum; update cancelled." -f $f.path); return }
    }
    $newPs = Join-Path $nd "eotir-render.ps1"
    if (Test-Path -LiteralPath $newPs) {
        $t = $null; $pe = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($newPs, [ref]$t, [ref]$pe)
        if ($pe.Count -gt 0) { Warn "The new script does not parse; update cancelled."; return }
    }
    try {
        foreach ($f in $m.files) {
            if ($script:UpdateAllowed -notcontains $f.path) { continue }
            $live = Join-Path $PkgDir $f.path
            if (Test-Path -LiteralPath $live) { Copy-Item -LiteralPath $live -Destination ($live + ".bak") -Force }
            Copy-Item -LiteralPath (Join-Path $nd $f.path) -Destination $live -Force
        }
    } catch { Warn ("Could not install the update here ({0}); staying on the current version." -f $_.Exception.Message); return }
    Good ("Updated to {0}. Restarting the helper with the new version..." -f $m.version)

    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:SelfPath)
    foreach ($k in $script:BoundArgs.Keys) {
        $v = $script:BoundArgs[$k]
        if ($v -is [System.Management.Automation.SwitchParameter]) { if ($v.IsPresent) { $argList += "-$k" } }
        else { $argList += "-$k"; $argList += "$v" }
    }
    $script:Relaunched = $true
    & powershell.exe @argList
    $script:RelaunchCode = $LASTEXITCODE
}

# ---------------------------------------------------------------- finding this helper's next job
# Returns the oldest unfinished job assigned to this helper, or $null. Throws on a listing failure.
function Get-NextJob([bool]$Quiet) {
    $ls = Invoke-Sftp @("ls -1 jobs")
    if ($ls.Code -ne 0) { throw ("Could not look at the job list. " + (Explain-ConnectError $ls.Out)) }
    $ids = @($ls.Out -split "`r?`n" | ForEach-Object { ($_ -replace '^.*/', '').Trim() } | Where-Object { $_ -ne "" -and $_ -notmatch '^(_|sftp>)' })
    $jobDir0 = Join-Path $script:Tmp "jobs"; New-Item -ItemType Directory -Force -Path $jobDir0 | Out-Null
    $have = Invoke-Sftp @("-ls -1 results/$($script:Cfg.user)")
    $done = @($have.Out -split "`r?`n" | ForEach-Object { ($_ -replace '^.*/', '').Trim() })
    $mine = @()
    # One connection for ALL job.json files (a '-' prefix lets a missing one fail without stopping the batch),
    # instead of one login per job: fewer new connections per look = less pressure on the server's connection limit.
    $want = @($ids | Where-Object { $Job -eq "" -or $_ -eq $Job })
    foreach ($id in $want) { Remove-Item -LiteralPath (Join-Path $jobDir0 ($id + ".json")) -Force -ErrorAction SilentlyContinue }
    if ($want.Count -gt 0) {
        [void](Invoke-Sftp @($want | ForEach-Object { "-get `"jobs/$_/job.json`" `"$(Fwd (Join-Path $jobDir0 ($_ + '.json')))`"" }))
    }
    foreach ($id in $want) {
        $jf = Join-Path $jobDir0 ($id + ".json")
        if (-not (Test-Path -LiteralPath $jf)) { continue }
        try { $jj = Get-Content -Raw -LiteralPath $jf | ConvertFrom-Json } catch { continue }
        if ($jj.assigned_to -ne $script:Cfg.user) { continue }
        if ($done -contains $jj.out_name) { if (-not $Quiet) { Hint ("Already finished earlier: {0}" -f $jj.out_name) }; continue }
        $mine += $jj
    }
    if ($mine.Count -eq 0) { return $null }
    return ($mine | Sort-Object created_at | Select-Object -First 1)
}

# ================================================================= MAIN
$script:BoundArgs = $PSBoundParameters
$script:Relaunched = $false
$script:RelaunchCode = 0
$exitCode = 0
$script:Tmp = $null
try {
    Clear-Host
    try { $Host.UI.RawUI.WindowTitle = "EOTIR Music Project - Render Helper" } catch {}
    Show-Banner

    New-Item -ItemType Directory -Force -Path $HomeDir | Out-Null
    $script:Tmp = Join-Path $HomeDir "tmp";  New-Item -ItemType Directory -Force -Path $script:Tmp | Out-Null
    $logs = Join-Path $HomeDir "logs";       New-Item -ItemType Directory -Force -Path $logs | Out-Null
    $script:LogFile = Join-Path $logs ("helper-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
    $script:LogsDir = $logs
    Write-Log ("start; pkg={0} home={1}" -f $PkgDir, $HomeDir)
    Write-Log ("--- environment ---`n" + (Get-EnvSummary))

    Say "Here is what is going to happen. You do not need to do anything - just leave this window open:" White
    Hint "1. We check your computer is ready."
    Hint "2. We download the tools needed to make the video (first time only, a few minutes)."
    Hint "3. We find the video Ryan set aside for you and download its pictures and music."
    Hint "4. Your computer makes the video. THIS IS THE LONG PART (often 1 to 2 hours)."
    Hint "5. We send the finished video back to Ryan. Then you are done!"
    Write-Host ""
    Say "Please:  keep this window open  |  keep your computer plugged in  |  do not shut the lid." Yellow
    Hint "We ask Windows to stay awake while we work. You can keep using your computer, it may just feel slower."

    # ---------- Step 1: computer check
    Start-Step 1
    Say "Making sure your computer is ready to help..." White
    if ([Environment]::OSVersion.Version.Major -lt 10) { Fail "E-CHECK-OS" "This needs Windows 10 or Windows 11." }
    if (-not [Environment]::Is64BitOperatingSystem) { Fail "E-CHECK-OS64" "This needs a 64-bit version of Windows." }
    Good ("Windows version looks fine ({0})." -f [Environment]::OSVersion.Version)
    foreach ($tool in @('sftp.exe', 'curl.exe', 'tar.exe')) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            Fail "E-CHECK-TOOLS" ("Your Windows is missing a built-in tool called {0}. Please tell Ryan - he will help you turn it on (Settings > Apps > Optional features > OpenSSH Client)." -f $tool)
        }
    }
    Good "Windows has the file-transfer tools we need."
    $drive = New-Object IO.DriveInfo ((Split-Path -Qualifier $HomeDir).TrimEnd(':'))
    $freeGB = [math]::Round($drive.AvailableFreeSpace / 1GB, 1)
    if ($freeGB -lt 15) { Fail "E-CHECK-DISK" ("Not enough free space: {0} GB free on drive {1}. We need about 15 GB. Please free some space and run this again." -f $freeGB, $drive.Name) }
    Good ("{0} GB free disk space - plenty." -f $freeGB)
    try {
        $ram = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
        $cores = [Environment]::ProcessorCount
        if ($ram -lt 8) { Warn ("Only {0} GB of memory. Making the video may be slow or fail. We will try anyway." -f $ram) } else { Good ("{0} GB memory and {1} processor threads." -f $ram, $cores) }
    } catch { Hint "(Could not read memory size - that is okay.)" }
    $script:Cfg = Get-Content -Raw -LiteralPath (Join-Path $PkgDir "helper.json") | ConvertFrom-Json
    Good ("This computer is signed up as helper '{0}'." -f $script:Cfg.user)
    Keep-Awake $true

    # The private key must be readable ONLY by you, or Windows' ssh refuses to use it.
    $keyDir = Join-Path $HomeDir "keys"; New-Item -ItemType Directory -Force -Path $keyDir | Out-Null
    $script:KeyPath = Join-Path $keyDir "helper_key"
    $me = "{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME
    # On every run after the first, the key is already locked read-only (that is the point), so unlock
    # it before refreshing it from the package, then lock it again below.
    if (Test-Path -LiteralPath $script:KeyPath) {
        & icacls.exe $script:KeyPath /grant:r ("{0}:(F)" -f $me) | Out-Null
        Remove-Item -LiteralPath $script:KeyPath -Force -ErrorAction SilentlyContinue
    }
    Copy-Item -LiteralPath (Join-Path $PkgDir "helper_key") -Destination $script:KeyPath -Force
    & icacls.exe $script:KeyPath /inheritance:r | Out-Null
    & icacls.exe $script:KeyPath /grant:r ("{0}:(R)" -f $me) | Out-Null
    $script:KnownHosts = Join-Path $keyDir "known_hosts"
    Copy-Item -LiteralPath (Join-Path $PkgDir "known_hosts") -Destination $script:KnownHosts -Force
    End-Step

    # ---------- Is there a newer (signed) version of this script? Offer it before doing real work.
    Invoke-UpdateCheck
    if ($script:Relaunched) { $exitCode = $script:RelaunchCode; Keep-Awake $false; return }

    # ---------- Step 4 early check (connection) -- we test it BEFORE downloading big things
    Say ""
    Say "Quick test: can we reach Ryan's server?" White
    $t = Invoke-Sftp @("ls")
    if ($t.Code -ne 0) { Write-Log $t.Out; Fail "E-CONNECT" ("Could not connect. " + (Explain-ConnectError $t.Out)) }
    Good "Connected to Ryan's server. The connection is secure and the server is who it says it is."
    if ($CheckOnly) { Say "" ; Say "All checks passed. You are ready! You can close this window." Green; Keep-Awake $false; return }

    # ---------- Step 2: Node
    Start-Step 2
    $nodeRoot = Join-Path $HomeDir "node"
    $nodeExe = Get-ChildItem -Path $nodeRoot -Filter node.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $nodeExe) {
        Say "Downloading a small tool called Node.js (it runs the video maker). Only needed once." White
        Hint "It is a free, well-known program. It goes in the Eotir folder only - nothing else on your PC changes."
        New-Item -ItemType Directory -Force -Path $nodeRoot | Out-Null
        $base = "https://nodejs.org/dist/latest-v22.x"
        $sums = Join-Path $script:Tmp "SHASUMS256.txt"
        Download-File "$base/SHASUMS256.txt" $sums "checking the latest version"
        $line = Get-Content -LiteralPath $sums | Where-Object { $_ -match 'node-v22\.[\d\.]+-win-x64\.zip$' } | Select-Object -First 1
        if (-not $line) { Fail "E-NODE-LIST" "Could not find the Node.js download. Please tell Ryan." }
        $want = ($line -split '\s+')[0]; $zipName = ($line -split '\s+')[1]
        $zip = Join-Path $script:Tmp $zipName
        Download-File "$base/$zipName" $zip "Node.js"
        Say "Checking the download is genuine..." White
        $got = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLower()
        if ($got -ne $want) { Remove-Item -LiteralPath $zip -Force; Fail "E-NODE-SUM" "The Node.js download did not match its checksum. Please run this again; if it keeps happening tell Ryan." }
        Good "Download verified."
        Say "Unpacking..." White
        & tar.exe -xf $zip -C $nodeRoot
        if ($LASTEXITCODE -ne 0) { Fail "E-NODE-UNPACK" "Could not unpack Node.js." }
        Remove-Item -LiteralPath $zip -Force
        $nodeExe = Get-ChildItem -Path $nodeRoot -Filter node.exe -Recurse | Select-Object -First 1
    } else { Good "Node.js is already here - skipping." }
    $nodeDir = $nodeExe.DirectoryName
    $env:PATH = "$nodeDir;$env:PATH"
    Good ("Node.js ready ({0})." -f ((& "$nodeDir\node.exe" -v) -join ""))
    End-Step

    # ---------- Step 3: kit
    Start-Step 3
    $kitJson = Join-Path $script:Tmp "kit.json"
    $r = Invoke-Sftp @("get `"jobs/_kit/kit.json`" `"$(Fwd $kitJson)`"")
    if ($r.Code -ne 0) { Write-Log $r.Out; Fail "E-KIT-MISSING" "Could not find the render kit on the server. Please tell Ryan (the kit may not be uploaded yet)." }
    $kit = Get-Content -Raw -LiteralPath $kitJson | ConvertFrom-Json
    $script:Kit = $kit
    $kitDir = Join-Path $HomeDir ("k\" + $kit.sha256.Substring(0, 8))   # short on purpose (MAX_PATH)
    $composer = Join-Path $kitDir "remotion-composer"
    $ready = Join-Path $kitDir "READY"
    if (-not (Test-Path -LiteralPath $ready)) {
        Say ("Downloading the EOTIR render kit (version {0})..." -f $kit.version) White
        Hint "This is the video-making recipe Ryan uses, so your video comes out identical to his."
        $kz = Join-Path $script:Tmp $kit.file
        $p = Start-SftpBg @("get `"jobs/_kit/$($kit.file)`" `"$(Fwd $kz)`"") "kit"
        Watch-Transfer $p { Get-FileLen $kz } ([double]$kit.bytes) "render kit"
        if ($p.ExitCode -ne 0) { Fail "E-KIT-DL" "Could not download the render kit." }
        if ((Get-FileHash -LiteralPath $kz -Algorithm SHA256).Hash.ToLower() -ne $kit.sha256) { Fail "E-KIT-SUM" "The render kit did not match its checksum. Tell Ryan." }
        Good "Kit downloaded and verified."
        if (Test-Path -LiteralPath $kitDir) { Remove-Item -LiteralPath $kitDir -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $kitDir | Out-Null
        & tar.exe -xf $kz -C $kitDir
        if ($LASTEXITCODE -ne 0) { Fail "E-KIT-UNPACK" "Could not unpack the render kit." }
        Remove-Item -LiteralPath $kz -Force
        Say "Installing the video-making parts (this downloads a few hundred MB; first time only)..." White
        Hint "You may see the bar move slowly. That is normal - it is fetching lots of small pieces."
        $log = Join-Path $logs "npm-ci.log"
        $p = Start-Process -FilePath "$nodeDir\npm.cmd" -ArgumentList @('ci', '--no-audit', '--no-fund') -WorkingDirectory $composer -PassThru -WindowStyle Hidden -RedirectStandardOutput $log -RedirectStandardError (Join-Path $logs "npm-ci.err.log")
        $null = $p.Handle
        $code = Wait-WithSpinner $p "installing" $log
        if ($code -ne 0) { Fail "E-KIT-NPM" ("Installing the video tools failed. Please send Ryan the file: " + $log) }
        Say "Getting the built-in video browser Remotion uses (one more download)..." White
        $log2 = Join-Path $logs "browser-ensure.log"
        $p = Start-Process -FilePath (Join-Path $composer "node_modules\.bin\remotion.cmd") -ArgumentList @('browser', 'ensure') -WorkingDirectory $composer -PassThru -WindowStyle Hidden -RedirectStandardOutput $log2 -RedirectStandardError (Join-Path $logs "browser-ensure.err.log")
        $null = $p.Handle
        $code = Wait-WithSpinner $p "browser" $log2
        if ($code -ne 0) { Fail "E-KIT-BROWSER" ("Could not get the video browser. Please send Ryan the file: " + $log2) }
        Set-Content -LiteralPath $ready -Value (Get-Date).ToString("o")
        Good "Render kit installed."
    } else { Good ("Render kit {0} is already installed - skipping." -f $kit.version) }
    End-Step

    # ---------- From here on it is a LOOP: find a job (waiting if there is none), make it, deliver it - then look
    # for the next one, until the user presses Q or closes the window (or -Once / -NoWait / -Job say otherwise).
    while ($true) {
    if ($script:StopRequested) { break }

    # ---------- Step 4: find the job
    Start-Step 4
    Say "Looking for a video job set aside for you..." White
    try { $j = Get-NextJob $false } catch { Fail "E-JOB-LIST" $_.Exception.Message }
    if (-not $j) {
        if ($NoWait) {
            Say ""
            Say "There is no new video job for you right now." Green
            Say "That is fine! Ryan will message you when there is one. You can close this window." White
            Keep-Awake $false; return
        }
        # Waiting mode (default): stay open and start by ourselves the moment a job is assigned to this helper.
        Say ""
        Say "There is no video job for you yet - and that is completely fine!" Green
        Say "Leave this window open. The moment Ryan queues a video for you, it starts all by itself." White
        if ($MaxWaitHours -gt 0) { Hint ("We look every {0} minutes, for up to {1} hours." -f [math]::Round($PollSeconds / 60.0, 1), $MaxWaitHours) }
        else { Hint ("We look every {0} minutes and keep going until you stop us." -f [math]::Round($PollSeconds / 60.0, 1)) }
        Hint "To stop: press the Q key, or just close this window. You can open it again any time."
        Hint "Keep the computer plugged in - it is kept awake while we wait."
        $waitStart = Get-Date; $fails = 0
        while (-not $j) {
            $next = (Get-Date).AddSeconds($PollSeconds)
            while ((Get-Date) -lt $next) {
                if (Test-QuitKey) { Write-Host ""; Say ""; Say "OK - stopping, as you asked. Thank you for helping!" Green; Keep-Awake $false; return }
                $left = ($next - (Get-Date)).TotalSeconds
                Show-Progress (100 * (1 - $left / $PollSeconds)) ("waiting for a job   next look in {0}   waiting so far: {1}   (Q to stop)" -f (Fmt-Time $left), (Fmt-Time (((Get-Date) - $waitStart).TotalSeconds)))
                Start-Sleep -Seconds 1
            }
            Write-Host ""
            if ($MaxWaitHours -gt 0 -and ((Get-Date) - $waitStart).TotalHours -ge $MaxWaitHours) {
                Say ""
                Say ("Nothing came up in {0} hours, so we are stopping to save your electricity." -f $MaxWaitHours) Yellow
                Say "Open this again whenever Ryan messages you that there is a video for you." White
                Keep-Awake $false; return
            }
            # A hiccup in the connection while waiting is not an error: keep waiting, give up only after 5 in a row.
            try { $j = Get-NextJob $true; $fails = 0 }
            catch { $fails++; Write-Log ("wait: job check failed ({0}/5): {1}" -f $fails, $_.Exception.Message); if ($fails -ge 5) { Fail "E-JOB-LIST" ("Lost the connection to the server while waiting. " + $_.Exception.Message) } }
        }
        Write-Host ""
        Say "A video job just arrived - starting!" Green
    }
    $script:JobObj = $j
    Good ("Found your job: {0}" -f $j.job_id)
    Hint ("It will make '{0}' - about {1} of video." -f $j.out_name, (Fmt-Time ([double]$j.expected_duration)))
    if ($j.note) { Hint ("Note from Ryan: {0}" -f $j.note) }
    Hint "Press Q at any time to stop after this video (or just close the window)."
    if ($j.kit_version -and $j.kit_version -ne $kit.version) { Warn ("This job was prepared with kit {0} but the server's kit is {1}. Continuing; tell Ryan if the result looks odd." -f $j.kit_version, $kit.version) }
    End-Step

    # ---------- Step 5: download the job
    Start-Step 5
    $work = Join-Path $HomeDir ("work\" + $j.job_id); New-Item -ItemType Directory -Force -Path $work | Out-Null
    $jz = Join-Path $work "job.zip"
    $need = [double]$j.zip.bytes
    # A job can be REBUILT under the same id (make_job --replace after a fix). Anything left over from an earlier
    # VERSION of it - the zip (same byte size, different contents: found by test), the unpacked files and above all a
    # finished render of the OLD assets - must never be reused for the new one. The zip's SHA-256 is the job's
    # identity: kept beside the work files, and everything is purged when it changes. Leftovers from a run that
    # predates the identity file are kept only if their zip provably IS the current zip (so a verified render that
    # still needs uploading survives an upgrade of this script), otherwise purged.
    $idFile = Join-Path $work "job.identity"
    $prevId = ""
    if (Test-Path -LiteralPath $idFile) { $prevId = (Get-Content -Raw -LiteralPath $idFile).Trim() }
    elseif ((Test-Path -LiteralPath $jz) -and (Get-FileLen $jz) -eq $need) { $prevId = (Get-FileHash -LiteralPath $jz -Algorithm SHA256).Hash.ToLower() }
    $hasLeftovers = ((Get-ChildItem -LiteralPath $work -Force | Where-Object { $_.Name -ne "job.identity" } | Measure-Object).Count -gt 0)
    if ($hasLeftovers -and $prevId -ne $j.zip.sha256) {
        Hint "This job was updated since the last time (or its old files cannot be trusted) - starting it fresh."
        Get-ChildItem -LiteralPath $work -Force | Remove-Item -Recurse -Force
    }
    Set-Content -LiteralPath $idFile -Value $j.zip.sha256 -Encoding ASCII
    if ((Get-FileLen $jz) -ne $need) {
        Say ("Downloading the pictures, video clips and music ({0})..." -f (Fmt-MB $need)) White
        Hint "If your internet drops, just run this again - it carries on where it stopped."
        $p = Start-SftpBg @("reget `"jobs/$($j.job_id)/job.zip`" `"$(Fwd $jz)`"") "job"
        Watch-Transfer $p { Get-FileLen $jz } $need "job files"
        if ($p.ExitCode -ne 0) { Fail "E-JOB-DL" "The download did not finish. Please run this again - it will resume." }
    } else { Good "Job files already downloaded." }
    Say "Checking nothing was damaged in the download..." White
    if ((Get-FileHash -LiteralPath $jz -Algorithm SHA256).Hash.ToLower() -ne $j.zip.sha256) {
        Remove-Item -LiteralPath $jz -Force
        Fail "E-JOB-SUM" "The job file was damaged in transit. Please run this again."
    }
    Good "Download is perfect."
    Say "Unpacking..." White
    $ex = Join-Path $work "extract"
    if (Test-Path -LiteralPath $ex) { Remove-Item -LiteralPath $ex -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $ex | Out-Null
    & tar.exe -xf $jz -C $ex
    if ($LASTEXITCODE -ne 0) { Fail "E-JOB-UNPACK" "Could not unpack the job." }
    $pubDest = Join-Path $composer ("public\" + $j.proj_id)
    if (Test-Path -LiteralPath $pubDest) { Remove-Item -LiteralPath $pubDest -Recurse -Force }
    New-Item -ItemType Directory -Force -Path (Join-Path $composer "public") | Out-Null
    Move-Item -LiteralPath (Join-Path $ex ("public\" + $j.proj_id)) -Destination $pubDest
    $props = Join-Path $ex "remotion_props.json"
    if (-not (Test-Path -LiteralPath $props)) { Fail "E-JOB-PROPS" "The job is missing its instructions file. Tell Ryan." }
    Good "Everything is in place."
    End-Step

    # ---------- Step 6: render
    Start-Step 6
    $outFile = Join-Path $work $j.out_name
    $marker = $outFile + ".verified"
    # A render that already passed its checks is never thrown away: if the upload failed (home internet),
    # running this again must NOT cost another 1-2 hours. The marker records size + length of the exact file.
    $reuse = $false; $mk = $null
    if ((Test-Path -LiteralPath $outFile) -and (Test-Path -LiteralPath $marker)) {
        try {
            $mk = Get-Content -Raw -LiteralPath $marker | ConvertFrom-Json
            if ([int64]$mk.bytes -eq (Get-FileLen $outFile) -and $mk.job_id -eq $j.job_id) { $reuse = $true }
        } catch { $reuse = $false }
    }
    if ($reuse) {
        $durNum = [double]$mk.duration; $outSize = [int64]$mk.bytes; $renderSecs = [double]$mk.render_seconds
        Good "Your finished video from the earlier run is still here and was already checked."
        Hint "No need to make it again - we go straight to sending it."
    } else {
    if (Test-Path -LiteralPath $outFile) { Remove-Item -LiteralPath $outFile -Force }
    if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Force }
    $totalFrames = [int][math]::Round([double]$j.expected_duration * [double]$j.fps)
    $rArgs = @('render', 'Explainer', ("--props=" + (Quote-Arg $props)), ("--output=" + (Quote-Arg $outFile)), '--codec=h264', '--crf=18', '--timeout=120000')
    if ($j.frames) {
        $rArgs += ("--frames=" + $j.frames)
        $fr = $j.frames -split '-'; $totalFrames = [int]$fr[1] - [int]$fr[0] + 1
        Warn ("This is a SHORT TEST job (frames {0}). It will finish quickly." -f $j.frames)
    }
    Say "Now your computer makes the video. This is the long part - the bar will tell you how it is going." White
    Hint "Your fans may spin up and your computer will work hard. That is normal and safe."
    $rlog = Join-Path $logs ("render-{0}.log" -f $j.job_id)
    $rerr = Join-Path $logs ("render-{0}.err.log" -f $j.job_id)
    $t0 = Get-Date
    $p = Start-Process -FilePath (Join-Path $composer "node_modules\.bin\remotion.cmd") -ArgumentList $rArgs -WorkingDirectory $composer -PassThru -WindowStyle Hidden -RedirectStandardOutput $rlog -RedirectStandardError $rerr
    $null = $p.Handle
    $firstFrameT = $null; $firstFrameN = 0; $phase = "getting ready"
    while (-not $p.HasExited) {
        $tail = ""
        foreach ($f in @($rlog, $rerr)) {
            try { $fs = [IO.File]::Open($f, 'Open', 'Read', 'ReadWrite'); $len = $fs.Length; if ($len -gt 6000) { [void]$fs.Seek(-6000, 'End') }; $sr = New-Object IO.StreamReader($fs); $tail += $sr.ReadToEnd(); $sr.Close(); $fs.Close() } catch {}
        }
        $enc = [regex]::Matches($tail, 'Encoded\s+(\d+)/(\d+)')
        $ren = [regex]::Matches($tail, 'Rendered\s+(\d+)/(\d+)')
        $pct = 0; $detail = ""; $el = ((Get-Date) - $t0).TotalSeconds
        if ($ren.Count -gt 0) {
            $n = [int]$ren[$ren.Count - 1].Groups[1].Value; $tot = [int]$ren[$ren.Count - 1].Groups[2].Value; if ($tot -gt 0) { $totalFrames = $tot }
            if ($null -eq $firstFrameT -and $n -gt 0) { $firstFrameT = Get-Date; $firstFrameN = $n }
            $phase = "drawing the frames"; $pct = 100 * $n / $totalFrames
            $eta = -1
            if ($null -ne $firstFrameT -and $n -gt $firstFrameN) { $rate = ($n - $firstFrameN) / ((Get-Date) - $firstFrameT).TotalSeconds; if ($rate -gt 0) { $eta = ($totalFrames - $n) / $rate } }
            $detail = ("{0}: frame {1} of {2}   running {3}   about {4} left" -f $phase, $n, $totalFrames, (Fmt-Time $el), (Fmt-Time $eta))
            if ($enc.Count -gt 0) { $en = [int]$enc[$enc.Count - 1].Groups[1].Value; if ($en -gt 0 -and $n -ge $totalFrames) { $detail = ("packaging the video file: {0} of {1}   running {2}" -f $en, $totalFrames, (Fmt-Time $el)) } }
        } else {
            $pct = [math]::Min(5, $el / 12)
            $detail = ("{0}   running {1}" -f $phase, (Fmt-Time $el))
        }
        Show-Progress $pct $detail
        [void](Test-QuitKey)
        Start-Sleep -Seconds 2
    }
    $p.WaitForExit()
    Write-Host ""
    if ($p.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $outFile)) {
        Fail "E-RENDER" ("The video maker stopped with a problem. Please send Ryan these two files: {0}  and  {1}" -f $rlog, $rerr)
    }
    $renderSecs = ((Get-Date) - $t0).TotalSeconds
    Good ("Video made in {0}." -f (Fmt-Time $renderSecs))

    Say "Checking the video is the right length..." White
    $probeLog = Join-Path $logs "ffprobe.log"
    $dur = (& (Join-Path $composer "node_modules\.bin\remotion.cmd") ffprobe -v error -show_entries format=duration -of csv=p=0 $outFile 2>$null | Out-String).Trim()
    $durNum = 0.0
    if (-not [double]::TryParse($dur, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$durNum)) { Fail "E-VERIFY-PROBE" "Could not read the finished video's length. Tell Ryan." }
    $expect = if ($j.frames) { $totalFrames / [double]$j.fps } else { [double]$j.expected_duration }
    Write-Log ("duration {0} expected {1}" -f $durNum, $expect)
    # Frame-range test jobs are exact; full videos get 3 s of slack because the container length also reflects
    # the audio track (measured: Camp Bravo props end 235.1 s, shipped mp4 236.14 s). A truncated render is
    # off by far more than that, which is what this guards against.
    $tol = if ($j.frames) { 1.5 } else { 3.0 }
    if ([math]::Abs($durNum - $expect) -gt $tol) { Fail "E-VERIFY-LENGTH" ("The video is {0:N1}s long but should be about {1:N1}s. Not sending it. Please tell Ryan." -f $durNum, $expect) }
    $outSize = Get-FileLen $outFile
    # Full videos are tens of MB; 1 MB catches a truncated or blank render. A short frame-range TEST clip can
    # legitimately be smaller, so it only has to be non-trivial.
    $minSize = if ($j.frames) { 100KB } else { 1MB }
    if ($outSize -lt $minSize) { Fail "E-VERIFY-SIZE" "The finished video is suspiciously small. Not sending it. Please tell Ryan." }
    Good ("Length {0:N1}s, size {1}. Looks right!" -f $durNum, (Fmt-MB $outSize))
    ([ordered]@{ job_id = $j.job_id; bytes = $outSize; duration = $durNum; render_seconds = [int]$renderSecs } | ConvertTo-Json) | Set-Content -LiteralPath $marker -Encoding ASCII
    }
    End-Step

    # ---------- Step 7: upload
    Start-Step 7
    $rdir = "results/{0}" -f $script:Cfg.user
    $sha = (Get-FileHash -LiteralPath $outFile -Algorithm SHA256).Hash.ToLower()
    # The partial's name carries this exact file's hash, so a resumed upload (reput) can only ever continue
    # a partial of THIS file - never splice onto a half-file from a different render of the same name.
    $part = "$rdir/$($j.out_name).$($sha.Substring(0, 8)).partial"; $final = "$rdir/$($j.out_name)"
    Say ("Sending the finished video back to Ryan ({0})..." -f (Fmt-MB $outSize)) White
    Hint "Uploading can take a while on home internet. If it stops, run this again - it carries on where it stopped."
    # sftp's `reput` ONLY works when a partial already exists on the server ("stat remote: No such file"
    # otherwise - found by test), so choose by what is actually there:
    #   nothing -> put | smaller partial -> reput (resume) | exact size -> nothing to send | bigger -> start over
    $have = Get-RemoteSize $part
    $cmds = @()
    if ($have -gt $outSize) { $cmds += "-rm `"$part`""; $have = 0 }
    if ($have -gt 0 -and $have -lt $outSize) { Hint ("Found {0} of your video already on the server - carrying on from there." -f (Fmt-MB $have)) }
    $verb = if ($have -gt 0 -and $have -lt $outSize) { "reput" } else { "put" }
    $cmds += ("{0} `"{1}`" `"{2}`"" -f $verb, (Fwd $outFile), $part)
    if ($have -eq $outSize) { Hint "The whole video is already on the server - just finishing up."; $p = Start-SftpBg @("ls `"$part`"") "up" }
    else { $p = Start-SftpBg $cmds "up" }
    $t1 = Get-Date; $remote = 0; $lastPoll = (Get-Date).AddSeconds(-20); $spin = @('|', '/', '-', '\'); $i = 0
    while (-not $p.HasExited) {
        if (((Get-Date) - $lastPoll).TotalSeconds -ge 30) { $sz = Get-RemoteSize $part; if ($sz -ge 0) { $remote = $sz }; $lastPoll = Get-Date }
        $el = ((Get-Date) - $t1).TotalSeconds; $pct = 100 * $remote / $outSize
        $eta = -1; if ($remote -gt 0 -and $el -gt 5) { $eta = ($outSize - $remote) / ($remote / $el) }
        Show-Progress $pct ("{0} sent {1} of {2}   about {3} left" -f $spin[$i % 4], (Fmt-MB $remote), (Fmt-MB $outSize), (Fmt-Time $eta)); $i++
        [void](Test-QuitKey)
        Start-Sleep -Milliseconds 800
    }
    $p.WaitForExit()
    Write-Host ""
    if ($p.ExitCode -ne 0) { Fail "E-UPLOAD" "The upload did not finish. Please run this again - it carries on where it stopped, and your finished video is kept so nothing is made twice." }
    Say "Checking Ryan's server received every byte..." White
    $sz = Get-RemoteSize $part
    if ($sz -ne $outSize) { Fail "E-UPLOAD-SIZE" ("The server has {0} bytes but we sent {1}. Please run this again." -f $sz, $outSize) }
    $report = Join-Path $work ($j.out_name + ".json")
    $rep = [ordered]@{
        job_id = $j.job_id; helper = $script:Cfg.user; out_name = $j.out_name; bytes = $outSize; sha256 = $sha
        duration = $durNum; render_seconds = [int]$renderSecs; cores = [Environment]::ProcessorCount
        kit_version = $kit.version; finished_utc = (Get-Date).ToUniversalTime().ToString("o")
    }
    ($rep | ConvertTo-Json) | Set-Content -LiteralPath $report -Encoding ASCII
    # Finalize in two steps that are each safe to repeat (a retried connection must not trip over work already done):
    # 1) put the video in place - skipped if the final file is already there at the right size; 2) put the report.
    if ((Get-RemoteSize $final) -ne $outSize) {
        $fin = Invoke-Sftp @("-rm `"$final`"", "rename `"$part`" `"$final`"")
        if ($fin.Code -ne 0 -and (Get-RemoteSize $final) -ne $outSize) { Write-Log $fin.Out; Fail "E-UPLOAD-FINAL" "The video arrived but could not be finalized. Tell Ryan - it is safe on his server." }
    }
    $fin2 = Invoke-Sftp @("put `"$(Fwd $report)`" `"$final.json`"")
    if ($fin2.Code -ne 0) { Write-Log $fin2.Out; Fail "E-UPLOAD-FINAL" "The video arrived but its report could not be sent. Tell Ryan - the video is safe on his server." }
    Good "Delivered! Ryan's server has your video."
    End-Step

    if (-not $KeepFiles) {
        Hint "Cleaning up the big temporary files to give your disk space back..."
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $pubDest -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host ""
    Say "============================================================" Green
    Say "   ALL DONE - THANK YOU!" Green
    Say ("   '{0}' is on its way into the EOTIR Music Project." -f $j.out_name) Green
    Say ("   Total time for this run: {0}" -f (Fmt-Time (((Get-Date) - $script:StartTime).TotalSeconds))) Green
    Say "============================================================" Green
    if ($Once -or $Job -ne "" -or (Test-QuitKey)) {
        if ($script:StopRequested) { Say "Stopping, as you asked." White }
        Say "You can close this window. Your computer is free to sleep again." White
        break
    }
    Say ""
    Say "Looking for the next video for you...  (press Q at any time to stop)" Cyan
    $script:FirstStep = 4
    }   # end of the keep-going loop
}
catch {
    $exitCode = 1
    $err = $_
    # An unexpected crash (not one of our own Fail calls) still gets a code, with the script line in it.
    $code = if ($script:ErrCode) { $script:ErrCode } else { "E-SCRIPT-L{0}" -f $err.InvocationInfo.ScriptLineNumber }
    Write-Log ("FAILED [{0}]: {1}" -f $code, $err.Exception.Message); Write-Log ($err | Out-String)
    $reportPath = $null; $sent = $false
    try {
        $reportPath = Join-Path $(if ($script:LogsDir) { $script:LogsDir } else { $env:TEMP }) ("ERROR-REPORT-{0}-{1}.txt" -f (Get-Date -Format "yyyyMMdd-HHmmss"), $code)
        Set-Content -LiteralPath $reportPath -Value (New-ErrorReport $code $err) -Encoding ASCII
        Write-Host ""; Write-Host "   (Writing a report and sending it to Ryan...)" -ForegroundColor DarkGray
        $sent = Send-Report $reportPath $code
    } catch { Write-Log ("could not build/send report: " + $_.Exception.Message) }
    Write-Host ""; Write-Host ""
    Write-Host "------------------------------------------------------------" -ForegroundColor Red
    Write-Host "  Oops - something did not work. Nothing on your computer is harmed." -ForegroundColor Red
    Write-Host ""
    Write-Host ("  ERROR CODE:    " + $code) -ForegroundColor Yellow
    Write-Host ("  What happened: " + $err.Exception.Message) -ForegroundColor Yellow
    Write-Host ""
    if ($sent) {
        Write-Host "  A full report was sent to Ryan automatically." -ForegroundColor Green
        Write-Host "  Just tell him the ERROR CODE above - he already has the details." -ForegroundColor White
    } else {
        Write-Host "  The report could not be sent automatically (no connection?)." -ForegroundColor Yellow
        Write-Host "  Please send Ryan the ERROR CODE above and this file:" -ForegroundColor White
        if ($reportPath) { Write-Host ("     " + $reportPath) -ForegroundColor Cyan }
    }
    Write-Host ""
    Write-Host "  You can also just run this again - it picks up where it left off." -ForegroundColor White
    Write-Host "------------------------------------------------------------" -ForegroundColor Red
}
finally {
    Keep-Awake $false
}
exit $exitCode
