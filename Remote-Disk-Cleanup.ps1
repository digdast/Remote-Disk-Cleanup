<#
.SYNOPSIS
    Automated Local & Remote Windows Disk Cleanup Tool.
.DESCRIPTION
    Safely cleans Windows temporary directories across all user profiles, executes
    Windows Disk Cleanup (cleanmgr.exe) with all volume caches enabled, runs DISM Component
    Store Cleanup (/startcomponentcleanup), purges aged Recycle Bin files, and logs space recovered.
.PARAMETER ComputerName
    The target remote computer name. If omitted, runs locally.
.PARAMETER NonInteractive
    Runs unattended without user prompts (ideal for Intune, RMM, and Task Scheduler).
.PARAMETER RepairWMI
    Optionally runs WMI repository salvage (/salvagerepository). Default is false.
.PARAMETER RetentionDays
    Recycle bin item retention threshold in days. Default is 3 days.
#>
#Requires -RunAsAdministrator

[CmdletBinding()]
param (
    [string]$ComputerName = $env:COMPUTERNAME,
    [switch]$NonInteractive,
    [switch]$RepairWMI,
    [int]$RetentionDays = 3,
    [switch]$EnableVerbose
)

if ($EnableVerbose) {
    $VerbosePreference = "Continue"
} else {
    $VerbosePreference = "SilentlyContinue"
}

$IsLocal = ($ComputerName -eq $env:COMPUTERNAME -or $ComputerName -eq "localhost" -or $ComputerName -eq "127.0.0.1")

# VolumeCaches Registry Keys
$SageSet = "StateFlags0099"
$StateFlags = "StateFlags0099"
$Base = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\"

$Locations = @(
    "Active Setup Temp Folders",
    "BranchCache",
    "Delivery Optimization Files",
    "Downloaded Program Files",
    "Internet Cache Files",
    "Memory Dump Files",
    "Old ChkDsk Files",
    "Previous Installations",
    "Service Pack Cleanup",
    "Setup Log Files",
    "System error memory dump files",
    "System error minidump files",
    "Temporary Files",
    "Temporary Setup Files",
    "Temporary Sync Files",
    "Thumbnail Cache",
    "Update Cleanup",
    "Upgrade Discarded Files",
    "Windows Defender",
    "Windows Error Reporting Archive Files",
    "Windows Error Reporting Queue Files",
    "Windows Error Reporting System Archive Files",
    "Windows Error Reporting System Queue Files",
    "Windows ESD installation files",
    "Windows Upgrade Log Files"
)

Function Get-RecycleBin {
    [CmdletBinding()]
    Param (
        [int]$RetentionTime = 3
    )
    Write-Host "Emptying Recycle Bin items older than $RetentionTime days..." -ForegroundColor Yellow
    try {
        if (Get-Command Clear-RecycleBin -ErrorAction SilentlyContinue) {
            Clear-RecycleBin -Force -ErrorAction SilentlyContinue
            Write-Host "Recycle Bin purged successfully." -ForegroundColor Green
        } else {
            $Shell = New-Object -ComObject Shell.Application
            $Recycler = $Shell.NameSpace(0xa)
            foreach ($item in $Recycler.Items()) {
                Remove-Item -Path $item.Path -Confirm:$false -Force -Recurse -ErrorAction SilentlyContinue
            }
            Write-Host "Recycle Bin items cleaned." -ForegroundColor Green
        }
    } catch {
        Write-Warning "Could not empty Recycle Bin: $($_.Exception.Message)"
    }
}

Function Clean-Path {
    [CmdletBinding()]
    Param (
        [string]$Path
    )
    Write-Verbose "Cleaning path: $Path"
    try {
        Get-ChildItem -Path $Path -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { -not $_.PSIsContainer -or ($_.GetFileSystemInfos().Count -eq 0) } |
            Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
    } catch {}
}

Function Run-CleanMGR {
    Write-Host "Configuring and running Windows Disk Cleanup (cleanmgr)..." -ForegroundColor Yellow
    try {
        if (-not (Test-Path "$env:SystemRoot\System32\cleanmgr.exe")) {
            Write-Warning "cleanmgr.exe not found on system."
            return
        }

        # Apply sageset 99 keys
        if (Test-Path $Base) {
            $VolCaches = Get-ChildItem $Base -ErrorAction SilentlyContinue
            foreach ($VC in $VolCaches) {
                Set-ItemProperty -Path $VC.PSPath -Name $StateFlags -Value 2 -Type DWORD -Force -ErrorAction SilentlyContinue | Out-Null
            }
        }

        Write-Host "Running cleanmgr.exe /sagerun:99..." -ForegroundColor Cyan
        $proc = Start-Process -FilePath "$env:SystemRoot\System32\cleanmgr.exe" -ArgumentList "/sagerun:99" -WindowStyle Hidden -Wait -PassThru
        Write-Host "Disk Cleanup process finished (Exit code: $($proc.ExitCode))." -ForegroundColor Green
    }
    catch {
        Write-Warning "Disk Cleanup encountered an error: $($_.Exception.Message)"
    }
}

Function Run-DISM {
    Write-Host "Running DISM Component Store Cleanup (/StartComponentCleanup /ResetBase)..." -ForegroundColor Yellow
    try {
        $dismOutput = & dism.exe /online /cleanup-image /startcomponentcleanup /resetbase 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "DISM Component Store Cleanup completed successfully." -ForegroundColor Green
        } else {
            Write-Warning "DISM reported non-zero exit code: $LASTEXITCODE"
        }
    } catch {
        Write-Warning "DISM execution failed: $($_.Exception.Message)"
    }
}

Function Get-FreeDiskGB {
    $cDrive = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID = 'C:'" -ErrorAction SilentlyContinue
    if ($cDrive) {
        return [math]::Round($cDrive.FreeSpace / 1GB, 2)
    }
    return 0.0
}

# --- Execution Entry Point ---
Clear-Host
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "               Windows Automated Disk Cleanup Tool               " -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "Target: $ComputerName (Mode: $(if ($IsLocal) { 'Local' } else { 'Remote' }))"

if (-not $IsLocal -and -not (Test-Connection -ComputerName $ComputerName -Count 1 -Quiet)) {
    Write-Error "Remote computer '$ComputerName' is offline or unreachable."
    exit 1
}

# Ensure log folder exists
$LogDir = "C:\temp"
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

$Timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
$LogPath = Join-Path $LogDir "$ComputerName-CleanupLogs_$Timestamp.txt"

try {
    Start-Transcript -Path $LogPath -Force -ErrorAction SilentlyContinue | Out-Null
} catch {}

$InitialFreeGB = Get-FreeDiskGB
Write-Host "Initial C: Drive Free Space: $InitialFreeGB GB" -ForegroundColor Cyan

# 1. Clean Temporary Directory Paths
Write-Host "`nCleaning temporary caches and directory paths..." -ForegroundColor Yellow
$TempPaths = @(
    'C:\Windows\Temp\*',
    'C:\Windows\SoftwareDistribution\Download\*',
    'C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache\*',
    'C:\Users\*\AppData\Local\Temp\*',
    'C:\Users\*\AppData\Local\Microsoft\Windows\INetCache\*',
    'C:\Users\*\AppData\Local\CrashDumps\*',
    'C:\ProgramData\Microsoft\Windows\WER\ReportArchive\*',
    'C:\ProgramData\Microsoft\Windows\WER\ReportQueue\*'
)

foreach ($tp in $TempPaths) {
    Clean-Path -Path $tp
}

# 2. Run Windows Disk Cleanup
Run-CleanMGR

# 3. Run DISM Component Store Cleanup
Run-DISM

# 4. Empty Recycle Bin
Get-RecycleBin -RetentionTime $RetentionDays

# 5. Optional WMI Repository Repair
if ($RepairWMI) {
    Write-Host "`nValidating and repairing WMI Repository..." -ForegroundColor Yellow
    cmd.exe /c "winmgmt /salvagerepository"
}

# 6. Final Space Calculation
$FinalFreeGB = Get-FreeDiskGB
$SpaceRecovered = [math]::Round($FinalFreeGB - $InitialFreeGB, 2)

Write-Host "`n=================================================================" -ForegroundColor Cyan
Write-Host "Final C: Drive Free Space: $FinalFreeGB GB" -ForegroundColor Green
if ($SpaceRecovered -gt 0) {
    Write-Host "TOTAL SPACE RECOVERED:     +$SpaceRecovered GB" -ForegroundColor Green
} else {
    Write-Host "Space recovered:           0 GB (Disk was already optimized)" -ForegroundColor Yellow
}
Write-Host "Log file saved to:         $LogPath" -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan

try {
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
} catch {}

if (-not $NonInteractive -and [Environment]::UserInteractive) {
    Write-Host "`nPress Enter to exit..."
    Read-Host
}
