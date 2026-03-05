Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- Config file ---
$configPath = Join-Path $PSScriptRoot "config.json"
$repoPath   = $null

function Load-Config {
    if (Test-Path $configPath) {
        $json = Get-Content $configPath -Raw | ConvertFrom-Json
        if ($json.repoPath -and (Test-Path (Join-Path $json.repoPath ".git"))) {
            return $json.repoPath
        }
    }
    return $null
}

function Save-Config([string]$Path) {
    @{ repoPath = $Path } | ConvertTo-Json | Set-Content $configPath -Encoding UTF8
}

# --- Helper: run git (10 sec timeout, safe failure) ---
$script:GitTimeoutMs = 10000

function Invoke-Git {
    param([string]$WorkDir, [string[]]$GitArgs, [int]$TimeoutMs = $script:GitTimeoutMs)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = "git"
    $psi.Arguments              = $GitArgs -join " "
    $psi.WorkingDirectory       = $WorkDir
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8
    $p = $null
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutMs)) {
            try { $p.Kill() } catch { }
            $p.WaitForExit(2000) | Out-Null
            return @{ Out = ""; Err = "timeout ($([math]::Round($TimeoutMs/1000))s)"; Code = -1 }
        }
        $stdout = $outTask.GetAwaiter().GetResult()
        $stderr = $errTask.GetAwaiter().GetResult()
        return @{ Out = $stdout.Trim(); Err = $stderr.Trim(); Code = $p.ExitCode }
    } catch {
        if ($p -and -not $p.HasExited) { try { $p.Kill() } catch { } }
        return @{ Out = ""; Err = $_.Exception.Message; Code = -1 }
    }
}

# --- Collect work dirs (main repo only) ---
function Get-WorkDirs {
    if (-not $script:repoPath) { return @() }
    return @(@{ Path = $script:repoPath; Label = "main" })
}

# --- Count: (Commit) uncommitted files, (Push) unpushed commits, (Pull) behind origin ---
function Get-CommitCount {
    $dirs = Get-WorkDirs
    $cnt = 0
    foreach ($d in $dirs) {
        $status = (Invoke-Git $d.Path @("status", "--porcelain")).Out
        if ($status) { $cnt += ($status -split "`n").Count }
    }
    return $cnt
}

function Get-PushCount {
    $dirs = Get-WorkDirs
    $cnt = 0
    foreach ($d in $dirs) {
        $branch = (Invoke-Git $d.Path @("branch", "--show-current")).Out
        if (-not $branch) { continue }
        $ahead = (Invoke-Git $d.Path @("rev-list", "--count", "origin/$branch..HEAD")).Out
        if ($ahead -match "^\d+$") { $cnt += [int]$ahead }
    }
    return $cnt
}

# --- Count commits to pull (behind origin) ---
function Get-PullCount {
    $dirs = Get-WorkDirs
    if ($dirs.Count -eq 0) { return 0 }
    Invoke-Git $script:repoPath @("fetch", "origin") 2>$null | Out-Null
    $cnt = 0
    foreach ($d in $dirs) {
        $branch = (Invoke-Git $d.Path @("branch", "--show-current")).Out
        if (-not $branch) { continue }
        $behind = (Invoke-Git $d.Path @("rev-list", "--count", "HEAD..origin/$branch")).Out
        if ($behind -match "^\d+$") { $cnt += [int]$behind }
    }
    return $cnt
}

# --- Push one dir ---
function Push-Repo([string]$Dir, [string]$Label) {
    $status = Invoke-Git $Dir @("status", "--porcelain")
    if (-not $status.Out) {
        $branch = (Invoke-Git $Dir @("branch", "--show-current")).Out
        if (-not $branch) { return @{ Msg = "$Label : no branch"; Commits = 0 } }
        $ahead = (Invoke-Git $Dir @("rev-list", "--count", "origin/$branch..HEAD")).Out
        $n = if ($ahead -match "^\d+$") { [int]$ahead } else { 0 }
        if ($n -eq 0) { return @{ Msg = "$Label : no changes"; Commits = 0 } }
        $r = Invoke-Git $Dir @("push", "origin", $branch)
        if ($r.Code -ne 0) { return @{ Msg = "$Label : push failed - $($r.Err)"; Commits = 0 } }
        return @{ Msg = "$Label : pushed ($branch)"; Commits = $n }
    }

    Invoke-Git $Dir @("add", "-A") | Out-Null
    $msg = "sync: auto-commit from $env:COMPUTERNAME"
    $r = Invoke-Git $Dir @("commit", "-m", "`"$msg`"")
    if ($r.Code -ne 0) { return @{ Msg = "$Label : commit failed"; Commits = 0 } }

    $branch = (Invoke-Git $Dir @("branch", "--show-current")).Out
    if (-not $branch) { return @{ Msg = "$Label : no branch"; Commits = 0 } }

    $ahead = (Invoke-Git $Dir @("rev-list", "--count", "origin/$branch..HEAD")).Out
    $n = if ($ahead -match "^\d+$") { [int]$ahead } else { 0 }

    $r = Invoke-Git $Dir @("push", "origin", $branch)
    if ($r.Code -ne 0) { return @{ Msg = "$Label : push failed - $($r.Err)"; Commits = 0 } }
    return @{ Msg = "$Label : pushed ($branch)"; Commits = $n }
}

# --- Pull one dir ---
function Pull-Repo([string]$Dir, [string]$Label) {
    $branch = (Invoke-Git $Dir @("branch", "--show-current")).Out
    $behind = 0
    if ($branch) {
        $b = (Invoke-Git $Dir @("rev-list", "--count", "HEAD..origin/$branch")).Out
        if ($b -match "^\d+$") { $behind = [int]$b }
    }
    $r = Invoke-Git $Dir @("pull")
    if ($r.Code -ne 0) { return @{ Msg = "$Label : pull failed - $($r.Err)"; Commits = 0 } }
    $msg = if ($r.Out -match "Already up to date") { "up to date" } else { "updated" }
    return @{ Msg = "$Label : $msg"; Commits = $behind }
}

# --- Balloon ---
function Show-Balloon([string]$Title, [string]$Text, [int]$Ms = 3000) {
    $notifyIcon.BalloonTipTitle = $Title
    $notifyIcon.BalloonTipText  = $Text
    $notifyIcon.ShowBalloonTip($Ms)
}

# --- Actions ---
function Do-SelectFolder {
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description  = "Select git repository folder"
    $dialog.RootFolder   = [System.Environment+SpecialFolder]::MyComputer
    if ($script:repoPath) { $dialog.SelectedPath = $script:repoPath }

    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $selected = $dialog.SelectedPath
        if (Test-Path (Join-Path $selected ".git")) {
            $script:repoPath = $selected
            Save-Config $selected
            Update-MenuState
            Show-Balloon "Git Sync" "Repo set: $selected"
            Refresh-CountCache
        } else {
            [System.Windows.Forms.MessageBox]::Show(
                "Selected folder is not a git repository.`n(.git folder not found)",
                "Git Sync", "OK", "Warning"
            )
        }
    }
}

# --- Push/Pull with progress-based stall detection (7 sec no progress = force stop) ---
$script:pushPullState = $null
$script:pushPullStallSec = 7

function Enable-PushPullButtons {
    $pushBtn.Enabled = $true
    $pullBtn.Enabled = $true
}

function Sync-PushPullButtonState {
    if (-not $script:pushPullState -and (-not $pushBtn.Enabled -or -not $pullBtn.Enabled)) {
        Enable-PushPullButtons
    }
}

function Disable-PushPullButtons {
    $pushBtn.Enabled = $false
    $pullBtn.Enabled = $false
}

function Finish-PushPullState {
    param([string]$Title, [string]$Text)
    if ($script:pushPullState) {
        try {
            $job = $script:pushPullState.Job
            if ($job -and $job.Process -and -not $job.Process.HasExited) {
                $job.Process.Kill()
            }
        } catch { }
        try {
            if ($script:pushPullState.PowerShell) {
                $script:pushPullState.PowerShell.Stop()
                $script:pushPullState.PowerShell.Dispose()
            }
        } catch { }
        try {
            if ($script:pushPullState.Runspace) {
                $script:pushPullState.Runspace.Close()
                $script:pushPullState.Runspace.Dispose()
            }
        } catch { }
        $script:pushPullState = $null
    }
    Enable-PushPullButtons
    if ($Title) { try { Show-Balloon $Title $Text } catch { } }
    try { Refresh-CountCacheSync } catch { }
}

function Check-PushPullState {
    if (-not $script:pushPullState) { return }
    $st = $script:pushPullState
    $job = $st.Job
    try {
        if ($st.PowerShell.InvocationStateInfo.State -eq "Failed") {
            Finish-PushPullState "Error" $st.PowerShell.InvocationStateInfo.Reason.Message
            return
        }
        if (-not $st.PowerShell.IsCompleted) {
            # Check stall: 7 sec without progress
            $last = if ($job) { $job.LastProgressTime } else { $st.LastProgressTime }
            $proc = if ($job) { $job.Process } else { $null }
            if ($last -and $proc -and -not $proc.HasExited) {
                $elapsed = ((Get-Date) - $last).TotalSeconds
                if ($elapsed -gt $script:pushPullStallSec) {
                    Finish-PushPullState "Stalled" "No progress for $($script:pushPullStallSec)s, stopped."
                    return
                }
            }
            return
        }
        # Completed
        $type = $st.Type
        $r = $st.PowerShell.EndInvoke($st.AsyncResult)
        Finish-PushPullState $null $null
        if ($r -and $r.Count -ge 2) {
            $msg = $r[0] -join "`n"
            $commits = $r[1]
            if ($type -eq "push") {
                Show-Balloon "Push Done" "Done: $commits commits`n$msg"
            } else {
                Show-Balloon "Pull Done" "Done: $commits commits`n$msg"
            }
        } else {
            Show-Balloon "Error" "No result returned."
        }
        try { Refresh-CountCacheSync } catch { }
    } catch {
        Finish-PushPullState "Error" $_.Exception.Message
    }
}

$script:pushPullScript = {
    param($job)
    $repoPath = $job.RepoPath
    $type = $job.Type
    $results = @()
    $totalCommits = 0
    $dirs = @(@{ Path = $repoPath; Label = "main" })
    $job.LastProgressTime = Get-Date
    if ($type -eq "push") {
        foreach ($d in $dirs) {
            $status = & git -C $d.Path status --porcelain 2>$null
            if ($status) {
                & git -C $d.Path add -A 2>$null | Out-Null
                & git -C $d.Path commit -m "sync: auto-commit from $env:COMPUTERNAME" 2>$null | Out-Null
            }
            $br = & git -C $d.Path branch --show-current 2>$null
            if (-not $br) { $results += "$($d.Label) : no branch"; continue }
            $ahead = & git -C $d.Path rev-list --count "origin/$br..HEAD" 2>$null
            $n = if ($ahead -match "^\d+$") { [int]$ahead } else { 0 }
            if ($n -eq 0) { $results += "$($d.Label) : no changes"; continue }
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = "git"
            $psi.Arguments = "-C `"$($d.Path)`" push --progress origin $br"
            $psi.WorkingDirectory = $d.Path
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
            $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
            $p = [System.Diagnostics.Process]::Start($psi)
            $job.Process = $p
            $reader = $p.StandardError
            $job.Stderr = [System.Text.StringBuilder]::new()
            $readerThread = [System.Threading.Thread]::new({
                try {
                    while ($true) {
                        $line = $reader.ReadLine()
                        if ($line -eq $null) { break }
                        $job.LastProgressTime = Get-Date
                        [void]$job.Stderr.AppendLine($line)
                    }
                } catch { }
            })
            $readerThread.IsBackground = $true
            $readerThread.Start()
            $p.WaitForExit()
            $readerThread.Join(2000) | Out-Null
            $stdout = $p.StandardOutput.ReadToEnd()
            $stderr = $job.Stderr.ToString().Trim()
            if ($p.ExitCode -eq 0) {
                $results += "$($d.Label) : pushed ($br)"
                $totalCommits += $n
            } else {
                $results += "$($d.Label) : push failed - $stderr"
            }
        }
    } else {
        & git -C $repoPath fetch origin 2>$null | Out-Null
        foreach ($d in $dirs) {
            $br = & git -C $d.Path branch --show-current 2>$null
            $behind = 0
            if ($br) {
                $b = & git -C $d.Path rev-list --count "HEAD..origin/$br" 2>$null
                if ($b -match "^\d+$") { $behind = [int]$b }
            }
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = "git"
            $psi.Arguments = "-C `"$($d.Path)`" pull --progress"
            $psi.WorkingDirectory = $d.Path
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
            $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
            $p = [System.Diagnostics.Process]::Start($psi)
            $job.Process = $p
            $reader = $p.StandardError
            $job.Stderr = [System.Text.StringBuilder]::new()
            $readerThread = [System.Threading.Thread]::new({
                try {
                    while ($true) {
                        $line = $reader.ReadLine()
                        if ($line -eq $null) { break }
                        $job.LastProgressTime = Get-Date
                        [void]$job.Stderr.AppendLine($line)
                    }
                } catch { }
            })
            $readerThread.IsBackground = $true
            $readerThread.Start()
            $p.WaitForExit()
            $readerThread.Join(2000) | Out-Null
            $stdout = $p.StandardOutput.ReadToEnd()
            $stderr = $job.Stderr.ToString().Trim()
            if ($p.ExitCode -eq 0) {
                $msg = if ($stdout -match "Already up to date") { "up to date" } else { "updated" }
                $results += "$($d.Label) : $msg"
                $totalCommits += $behind
            } else {
                $results += "$($d.Label) : pull failed - $stderr"
            }
        }
    }
    ,@($results, $totalCommits)
}

function Do-Push {
    if (-not $script:repoPath) { Do-SelectFolder; return }
    if ($script:pushPullState) { return }
    $path = $script:repoPath
    Disable-PushPullButtons
    Show-Balloon "Git Sync" "Pushing..." 1000
    $job = @{
        Process = $null
        LastProgressTime = Get-Date
        RepoPath = $path
        Type = "push"
    }
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.Open()
    $ps = [System.Management.Automation.PowerShell]::Create().AddScript($script:pushPullScript).AddArgument($job)
    $ps.Runspace = $rs
    $script:pushPullState = @{
        Job = $job
        LastProgressTime = $job.LastProgressTime
        Type = "push"
        PowerShell = $ps
        Runspace = $rs
        AsyncResult = $ps.BeginInvoke()
    }
    Start-PollTimerIfNeeded
}

function Do-Pull {
    if (-not $script:repoPath) { Do-SelectFolder; return }
    if ($script:pushPullState) { return }
    $path = $script:repoPath
    Disable-PushPullButtons
    Show-Balloon "Git Sync" "Pulling..." 1000
    $job = @{
        Process = $null
        LastProgressTime = Get-Date
        RepoPath = $path
        Type = "pull"
    }
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.Open()
    $ps = [System.Management.Automation.PowerShell]::Create().AddScript($script:pushPullScript).AddArgument($job)
    $ps.Runspace = $rs
    $script:pushPullState = @{
        Job = $job
        LastProgressTime = $job.LastProgressTime
        Type = "pull"
        PowerShell = $ps
        Runspace = $rs
        AsyncResult = $ps.BeginInvoke()
    }
    Start-PollTimerIfNeeded
}

# --- Cached counts: (Commit)/(Push) △ | (Pull) ▽ ---
$script:cachedCommitCount = 0
$script:cachedPushCount = 0
$script:cachedPullCount = 0
$script:countJob = $null
$script:countJobStart = $null

function Refresh-CountCache {
    if (-not $script:repoPath) { return }
    if ($script:countJob) {
        if ($script:countJob.State -eq "Running") { return }
        Remove-Job $script:countJob -Force -ErrorAction SilentlyContinue
    }
    $path = $script:repoPath
    $script:countJob = Start-Job -ScriptBlock {
        param($repoPath)
        $commitCnt = 0
        $pushCnt = 0
        $pullCnt = 0
        $dirs = @(@{ Path = $repoPath; Label = "main" })
        foreach ($d in $dirs) {
            $r = & git -C $d.Path status --porcelain 2>$null
            if ($r) { $commitCnt += ($r -split "`n").Count }
            $br = & git -C $d.Path branch --show-current 2>$null
            if ($br) {
                $a = & git -C $d.Path rev-list --count "origin/$br..HEAD" 2>$null
                if ($a -match "^\d+$") { $pushCnt += [int]$a }
            }
        }
        & git -C $repoPath fetch origin 2>$null | Out-Null
        foreach ($d in $dirs) {
            $br = & git -C $d.Path branch --show-current 2>$null
            if ($br) {
                $b = & git -C $d.Path rev-list --count "HEAD..origin/$br" 2>$null
                if ($b -match "^\d+$") { $pullCnt += [int]$b }
            }
        }
        @($commitCnt, $pushCnt, $pullCnt)
    } -ArgumentList $path
    $script:countJobStart = Get-Date
    Start-PollTimerIfNeeded
}

function Check-CountJob {
    if (-not $script:countJob) { return }
    if ($script:countJob.State -eq "Running") {
        if ($script:countJobStart -and ((Get-Date) - $script:countJobStart).TotalSeconds -gt 10) {
            try { Stop-Job $script:countJob -ErrorAction SilentlyContinue } catch { }
            Remove-Job $script:countJob -Force -ErrorAction SilentlyContinue
            $script:countJob = $null
            $script:countJobStart = $null
        }
        return
    }
    if ($script:countJob.State -eq "Failed" -or $script:countJob.State -eq "Stopped") {
        Remove-Job $script:countJob -Force -ErrorAction SilentlyContinue
        $script:countJob = $null
        $script:countJobStart = $null
        return
    }
    if ($script:countJob.State -ne "Completed") { return }
    try {
        $r = Receive-Job $script:countJob
        Remove-Job $script:countJob -Force
        $script:countJob = $null
        if ($r -and $r.Count -ge 3) {
            $script:cachedCommitCount = $r[0]
            $script:cachedPushCount = $r[1]
            $script:cachedPullCount = $r[2]
            if ($countItem.Visible) {
                $up = [char]0x25B3
                $dn = [char]0x25BD
                $countItem.Text = "  $($script:cachedCommitCount)/$($script:cachedPushCount) $up | $($script:cachedPullCount) $dn"
            }
        }
    } catch { }
}

function Refresh-CountCacheSync {
    if (-not $script:repoPath) { return }
    try {
        $script:cachedCommitCount = Get-CommitCount
        $script:cachedPushCount = Get-PushCount
        $script:cachedPullCount = Get-PullCount
        if ($countItem.Visible) {
            $up = [char]0x25B3
            $dn = [char]0x25BD
            $countItem.Text = "  $($script:cachedCommitCount)/$($script:cachedPushCount) $up | $($script:cachedPullCount) $dn"
        }
    } catch { }
}

# --- Update menu text to show current repo and counts ---
function Update-MenuState {
    if ($script:repoPath) {
        $folderBtn.Text = "Repo: $(Split-Path $script:repoPath -Leaf)  ..."
    } else {
        $folderBtn.Text = "Select Repo Folder..."
    }
    Update-CountDisplay
}

function Update-CountDisplay {
    if (-not $script:repoPath) {
        $countItem.Visible = $false
        return
    }
    $countItem.Visible = $true
    $up = [char]0x25B3
    $dn = [char]0x25BD
    if ($script:countJob -and $script:countJob.State -eq "Running") {
        $countItem.Text = "  -/- $up | - $dn"
    } else {
        $countItem.Text = "  $($script:cachedCommitCount)/$($script:cachedPushCount) $up | $($script:cachedPullCount) $dn"
    }
}

# --- Tray icon ---
$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$iconPath = Join-Path $PSScriptRoot "sync-icon.ico"
if (Test-Path $iconPath) {
    $notifyIcon.Icon = New-Object System.Drawing.Icon($iconPath)
} else {
    $notifyIcon.Icon = [System.Drawing.SystemIcons]::Information
}
$notifyIcon.Text    = "Git Sync"
$notifyIcon.Visible = $true

# --- Context menu ---
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.Font = New-Object System.Drawing.Font("Segoe UI", 10)

$folderBtn = $menu.Items.Add("Select Repo Folder...")
$folderBtn.Add_Click({ Do-SelectFolder })

$countItem = $menu.Items.Add(("  0/0 " + [char]0x25B3 + " | 0 " + [char]0x25BD))
$countItem.Enabled = $false

$menu.Items.Add("-") | Out-Null

$pushBtn = $menu.Items.Add("Commit + Push")
$pushBtn.Add_Click({ Do-Push })

$pullBtn = $menu.Items.Add("Pull")
$pullBtn.Add_Click({ Do-Pull })

$menu.Items.Add("-") | Out-Null

$exitBtn = $menu.Items.Add("Exit")
$exitBtn.Add_Click({
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    [System.Windows.Forms.Application]::Exit()
})

$notifyIcon.ContextMenuStrip = $menu

$menu.Add_Opening({
    if ($script:repoPath) {
        Sync-PushPullButtonState
        Refresh-CountCache
        Update-CountDisplay
    }
})

$notifyIcon.Add_Click({
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $menu.Show([System.Windows.Forms.Cursor]::Position)
    }
})

# --- Init ---
$script:repoPath = Load-Config
Update-MenuState

# Poll timer: only runs when a job is active
$pollTimer = New-Object System.Windows.Forms.Timer
$pollTimer.Interval = 500
$pollTimer.Add_Tick({
    try { Check-CountJob } catch { }
    try { Check-PushPullState } catch { }
    try { Sync-PushPullButtonState } catch { }
    try { Stop-PollTimerIfIdle } catch { }
})

function Start-PollTimerIfNeeded {
    if (-not $pollTimer.Enabled) { $pollTimer.Start() }
}

function Stop-PollTimerIfIdle {
    $countRunning = $script:countJob -and (try { $script:countJob.State -eq "Running" } catch { $false })
    $pushPullRunning = $script:pushPullState -and (try { -not $script:pushPullState.PowerShell.IsCompleted } catch { $false })
    if (-not $countRunning -and -not $pushPullRunning) {
        $pollTimer.Stop()
        Sync-PushPullButtonState
    }
}

[System.Windows.Forms.Application]::Run()
