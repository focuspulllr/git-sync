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

# --- Helper: run git ---
function Invoke-Git {
    param([string]$WorkDir, [string[]]$GitArgs)
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
    $p = [System.Diagnostics.Process]::Start($psi)
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    return @{ Out = $stdout.Trim(); Err = $stderr.Trim(); Code = $p.ExitCode }
}

# --- Collect work dirs (main + worktrees) ---
function Get-WorkDirs {
    if (-not $script:repoPath) { return @() }
    $dirs = @(@{ Path = $script:repoPath; Label = "main" })
    $wtRoot = Join-Path $script:repoPath ".claude\worktrees"
    if (Test-Path $wtRoot) {
        Get-ChildItem $wtRoot -Directory | ForEach-Object {
            if (Test-Path (Join-Path $_.FullName ".git") -PathType Leaf) {
                $dirs += @{ Path = $_.FullName; Label = $_.Name }
            }
        }
    }
    return $dirs
}

# --- Push one dir ---
function Push-Repo([string]$Dir, [string]$Label) {
    $status = Invoke-Git $Dir @("status", "--porcelain")
    if (-not $status.Out) { return "$Label : no changes" }

    Invoke-Git $Dir @("add", "-A") | Out-Null
    $r = Invoke-Git $Dir @("commit", "-m", "sync: auto-commit from $env:COMPUTERNAME")
    if ($r.Code -ne 0) { return "$Label : commit failed" }

    $branch = (Invoke-Git $Dir @("branch", "--show-current")).Out
    if (-not $branch) { return "$Label : no branch" }

    $r = Invoke-Git $Dir @("push", "origin", $branch)
    if ($r.Code -ne 0) { return "$Label : push failed - $($r.Err)" }
    return "$Label : pushed ($branch)"
}

# --- Pull one dir ---
function Pull-Repo([string]$Dir, [string]$Label) {
    $r = Invoke-Git $Dir @("pull")
    if ($r.Code -ne 0) { return "$Label : pull failed - $($r.Err)" }
    $msg = if ($r.Out -match "Already up to date") { "up to date" } else { "updated" }
    return "$Label : $msg"
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
        } else {
            [System.Windows.Forms.MessageBox]::Show(
                "Selected folder is not a git repository.`n(.git folder not found)",
                "Git Sync", "OK", "Warning"
            )
        }
    }
}

function Do-Push {
    if (-not $script:repoPath) { Do-SelectFolder; return }
    Show-Balloon "Git Sync" "Pushing..." 1000
    $results = @()
    foreach ($d in Get-WorkDirs) { $results += Push-Repo $d.Path $d.Label }
    Show-Balloon "Push Done" ($results -join "`n")
}

function Do-Pull {
    if (-not $script:repoPath) { Do-SelectFolder; return }
    Show-Balloon "Git Sync" "Pulling..." 1000
    $results = @()
    foreach ($d in Get-WorkDirs) { $results += Pull-Repo $d.Path $d.Label }
    Show-Balloon "Pull Done" ($results -join "`n")
}

# --- Update menu text to show current repo ---
function Update-MenuState {
    if ($script:repoPath) {
        $folderBtn.Text = "Repo: $(Split-Path $script:repoPath -Leaf)  ..."
    } else {
        $folderBtn.Text = "Select Repo Folder..."
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

$notifyIcon.Add_Click({
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $menu.Show([System.Windows.Forms.Cursor]::Position)
    }
})

# --- Init ---
$script:repoPath = Load-Config
Update-MenuState

[System.Windows.Forms.Application]::Run()
