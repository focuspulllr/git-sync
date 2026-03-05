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

# --- Push/Pull background job (buttons disabled, 10s safety) ---
$script:pushPullJob = $null
$script:pushPullJobStart = $null
$script:pushPullJobType = $null
$script:pushPullSafetyTimer = $null

function Enable-PushPullButtons {
    $pushBtn.Enabled = $true
    $pullBtn.Enabled = $true
}

function Sync-PushPullButtonState {
    if (-not $script:pushPullJob -and (-not $pushBtn.Enabled -or -not $pullBtn.Enabled)) {
        Enable-PushPullButtons
        if ($script:pushPullSafetyTimer) {
            try { $script:pushPullSafetyTimer.Stop(); $script:pushPullSafetyTimer.Dispose() } catch { }
            $script:pushPullSafetyTimer = $null
        }
    }
}

function Disable-PushPullButtons {
    $pushBtn.Enabled = $false
    $pullBtn.Enabled = $false
}

function Finish-PushPullJob {
    param([string]$Title, [string]$Text)
    try { Stop-Job $script:pushPullJob -ErrorAction SilentlyContinue } catch { }
    try { Remove-Job $script:pushPullJob -Force -ErrorAction SilentlyContinue } catch { }
    $script:pushPullJob = $null
    $script:pushPullJobStart = $null
    $script:pushPullJobType = $null
    try {
        if ($script:pushPullSafetyTimer) {
            $script:pushPullSafetyTimer.Stop()
            $script:pushPullSafetyTimer.Dispose()
        }
    } catch { }
    $script:pushPullSafetyTimer = $null
    Enable-PushPullButtons
    if ($Title) { try { Show-Balloon $Title $Text } catch { } }
    try { Refresh-CountCacheSync } catch { }
}

function Check-PushPullJob {
    if (-not $script:pushPullJob) { return }
    try {
        $state = $script:pushPullJob.State
    } catch {
        Finish-PushPullJob "Error" "Job state inaccessible."
        return
    }
    if ($state -eq "Running") {
        if ($script:pushPullJobStart -and ((Get-Date) - $script:pushPullJobStart).TotalSeconds -gt 10) {
            Finish-PushPullJob "Timeout" "Job exceeded 10s, re-enabled."
            return
        }
        return
    }
    if ($state -eq "Failed" -or $state -eq "Stopped" -or $state -eq "Blocked" -or $state -eq "Disconnected") {
        Finish-PushPullJob "Error" "Job $state."
        return
    }
    $type = $script:pushPullJobType
    try {
        $r = Receive-Job $script:pushPullJob
        if ($r -and $r.Count -ge 2) {
            $msg = $r[0] -join "`n"
            $commits = $r[1]
            if ($type -eq "push") {
                Finish-PushPullJob "Push Done" "Done: $commits commits`n$msg"
            } else {
                Finish-PushPullJob "Pull Done" "Done: $commits commits`n$msg"
            }
        } else {
            Finish-PushPullJob "Error" "Job returned no result."
        }
    } catch {
        Finish-PushPullJob "Error" $_.Exception.Message
    }
}

function Do-Push {
    if (-not $script:repoPath) { Do-SelectFolder; return }
    if ($script:pushPullJob -and $script:pushPullJob.State -eq "Running") { return }
    $path = $script:repoPath
    Disable-PushPullButtons
    Show-Balloon "Git Sync" "Pushing..." 1000
    $script:pushPullJob = Start-Job -ScriptBlock {
        param($repoPath)
        $results = @()
        $totalCommits = 0
        $dirs = @(@{ Path = $repoPath; Label = "main" })
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
            $err = & git -C $d.Path push origin $br 2>&1
            if ($LASTEXITCODE -eq 0) {
                $results += "$($d.Label) : pushed ($br)"
                $totalCommits += $n
            } else {
                $results += "$($d.Label) : push failed - $err"
            }
        }
        ,@($results, $totalCommits)
    } -ArgumentList $path
    $script:pushPullJobStart = Get-Date
    $script:pushPullJobType = "push"
    Start-PollTimerIfNeeded
    $script:pushPullSafetyTimer = New-Object System.Windows.Forms.Timer
    $script:pushPullSafetyTimer.Interval = 10000
    $script:pushPullSafetyTimer.Add_Tick({
        $script:pushPullSafetyTimer.Stop()
        try {
            if ($script:pushPullJob -and $script:pushPullJob.State -eq "Running") {
                Finish-PushPullJob "Timeout" "Job exceeded 10s, re-enabled."
            }
        } catch { Enable-PushPullButtons }
    })
    $script:pushPullSafetyTimer.Start()
}

function Do-Pull {
    if (-not $script:repoPath) { Do-SelectFolder; return }
    if ($script:pushPullJob -and $script:pushPullJob.State -eq "Running") { return }
    $path = $script:repoPath
    Disable-PushPullButtons
    Show-Balloon "Git Sync" "Pulling..." 1000
    $script:pushPullJob = Start-Job -ScriptBlock {
        param($repoPath)
        & git -C $repoPath fetch origin 2>$null | Out-Null
        $results = @()
        $totalCommits = 0
        $dirs = @(@{ Path = $repoPath; Label = "main" })
        foreach ($d in $dirs) {
            $br = & git -C $d.Path branch --show-current 2>$null
            $behind = 0
            if ($br) {
                $b = & git -C $d.Path rev-list --count "HEAD..origin/$br" 2>$null
                if ($b -match "^\d+$") { $behind = [int]$b }
            }
            $out = & git -C $d.Path pull 2>&1
            if ($LASTEXITCODE -eq 0) {
                $msg = if ($out -match "Already up to date") { "up to date" } else { "updated" }
                $results += "$($d.Label) : $msg"
                $totalCommits += $behind
            } else {
                $results += "$($d.Label) : pull failed - $out"
            }
        }
        ,@($results, $totalCommits)
    } -ArgumentList $path
    $script:pushPullJobStart = Get-Date
    $script:pushPullJobType = "pull"
    Start-PollTimerIfNeeded
    $script:pushPullSafetyTimer = New-Object System.Windows.Forms.Timer
    $script:pushPullSafetyTimer.Interval = 10000
    $script:pushPullSafetyTimer.Add_Tick({
        $script:pushPullSafetyTimer.Stop()
        try {
            if ($script:pushPullJob -and $script:pushPullJob.State -eq "Running") {
                Finish-PushPullJob "Timeout" "Job exceeded 10s, re-enabled."
            }
        } catch { Enable-PushPullButtons }
    })
    $script:pushPullSafetyTimer.Start()
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
    try { Check-PushPullJob } catch { }
    try { Sync-PushPullButtonState } catch { }
    try { Stop-PollTimerIfIdle } catch { }
})

function Start-PollTimerIfNeeded {
    if (-not $pollTimer.Enabled) { $pollTimer.Start() }
}

function Stop-PollTimerIfIdle {
    $countRunning = $script:countJob -and (try { $script:countJob.State -eq "Running" } catch { $false })
    $pushPullRunning = $script:pushPullJob -and (try { $script:pushPullJob.State -eq "Running" } catch { $false })
    if (-not $countRunning -and -not $pushPullRunning) {
        $pollTimer.Stop()
        Sync-PushPullButtonState
    }
}

[System.Windows.Forms.Application]::Run()
