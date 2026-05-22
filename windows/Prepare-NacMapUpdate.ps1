<#
.SYNOPSIS
    NAC Wave 4 Map Update - USB Preparation Script (Windows 10/11)

.DESCRIPTION
    Prepares a USB drive with the latest European cartography (map-eur 17.0.0-r0)
    for PSA/Stellantis vehicles with NAC Wave 4 infotainment.

    Map updates do NOT require a license file or UIN.
    You MUST install the firmware update (44.07.33.32) BEFORE this map update.

.PARAMETER TarFile
    Path to a pre-downloaded .tar map file. Downloaded automatically if omitted.

.PARAMETER SkipFormat
    Don't format the USB drive (it must already be FAT32 with MBR).

.EXAMPLE
    .\Prepare-NacMapUpdate.ps1
    .\Prepare-NacMapUpdate.ps1 -TarFile "C:\Downloads\maps.tar"
#>

[CmdletBinding()]
param(
    [string]$TarFile = "",
    [switch]$SkipFormat
)

# ── Require Administrator ──────────────────────────────────────────────────
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host ""
    Write-Host "  This script must be run as Administrator." -ForegroundColor Red
    Write-Host "  Right-click PowerShell and choose 'Run as administrator'," -ForegroundColor Red
    Write-Host "  then run this script again." -ForegroundColor Red
    Write-Host ""
    exit 1
}

# ── Configuration ──────────────────────────────────────────────────────────
$MapVersion   = "17.0.0-r0"
$MapUrl       = "https://download-cde.tomtom.com/OEM/PSA/MAP/PSA_map-eur_17.0.0-r0-NAC_EUR_WAVE4.tar"
$MapFilename  = "PSA_map-eur_17.0.0-r0-NAC_EUR_WAVE4.tar"
$FallbackUrls = @(
    "http://download.tomtom.com/OEM/PSA/MAP/PSA_map-eur_17.0.0-r0-NAC_EUR_WAVE4.tar"
)
$ExpectedSize = 20403312640

$MaxRetries     = 50
$RetryDelayBase = 5
$RetryDelayCap  = 120

# ── Helpers ────────────────────────────────────────────────────────────────
function Write-Info    { param($Msg) Write-Host "[INFO] $Msg" -ForegroundColor Cyan }
function Write-Ok      { param($Msg) Write-Host "[ OK ] $Msg" -ForegroundColor Green }
function Write-Warn    { param($Msg) Write-Host "[WARN] $Msg" -ForegroundColor Yellow }
function Write-Err     { param($Msg) Write-Host "[ERR ] $Msg" -ForegroundColor Red }
function Write-Header  { param($Msg) Write-Host "`n-- $Msg --`n" -ForegroundColor Cyan }

# ── Firmware prerequisite check ────────────────────────────────────────────
function Test-FirmwarePrerequisite {
    Write-Header "Firmware Prerequisite Check"

    Write-Host "  This map update (17.0.0-r0) requires NAC Wave 4 firmware."
    Write-Host "  Compatible firmware versions: 42.x or 44.x (Wave 4)"
    Write-Host ""
    Write-Host "  If you're not sure, check on the NAC screen:"
    Write-Host "    Settings > System info > System version"
    Write-Host ""
    Write-Host "  What firmware version is currently installed?"
    Write-Host "    1) 44.07.33.32 or newer  (latest Wave 4 - ideal)"
    Write-Host "    2) 44.xx.xx.xx           (older Wave 4 - should work)"
    Write-Host "    3) 42.xx.xx.xx           (early Wave 4 - should work)"
    Write-Host "    4) 31.xx.xx.xx or older  (Wave 3 or older - won't work!)"
    Write-Host "    5) I'm not sure / skip this check"
    Write-Host ""
    $choice = Read-Host "Select [1-5]"

    switch ($choice) {
        "1" { Write-Ok "Firmware is compatible." }
        "2" { Write-Ok "Firmware is compatible." }
        "3" { Write-Ok "Firmware is compatible." }
        "4" {
            Write-Err "Your firmware is too old for this map update."
            Write-Host ""
            Write-Host "  Install NAC Wave 4 firmware first."
            Write-Host "  Use: .\Prepare-NacFirmwareUpdate.ps1"
            exit 1
        }
        "5" { Write-Warn "Skipping check. If the map install fails, update firmware first." }
        default { Write-Warn "Invalid choice. Proceeding anyway." }
    }
}

# ── USB Drive Selection ────────────────────────────────────────────────────
function Select-UsbDrive {
    Write-Header "USB Drive Selection"

    $usbDrives = Get-Disk | Where-Object {
        ($_.BusType -eq 'USB') -and ($_.Size -gt 0)
    } | Sort-Object Number

    if (-not $usbDrives -or @($usbDrives).Count -eq 0) {
        Write-Err "No USB drives detected. Make sure your USB drive is plugged in."
        exit 1
    }

    # Check minimum size for maps (~19 GB)
    $tooSmall = @()
    Write-Host "Available USB drives:"
    Write-Host ""
    $i = 1
    foreach ($d in $usbDrives) {
        $sizeGb = [math]::Round($d.Size / 1GB, 1)
        $sizeNote = ""
        if ($d.Size -lt 21474836480) {
            $sizeNote = " (TOO SMALL for maps!)"
            $tooSmall += $d.Number
        }
        Write-Host "  $i) Disk $($d.Number): $($d.FriendlyName)  ($sizeGb) GB $sizeNote" -ForegroundColor White
        $i++
    }
    Write-Host ""

    if (@($usbDrives).Count -eq 1) {
        $selected = $usbDrives[0]
        Write-Info "Only one USB drive found: Disk $($selected.Number)"
    } else {
        $choice = Read-Host "Select drive number"
        $idx = [int]$choice - 1
        if ($idx -lt 0 -or $idx -ge @($usbDrives).Count) {
            Write-Err "Invalid selection."
            exit 1
        }
        $selected = $usbDrives[$idx]
    }

    if ($selected.Number -in $tooSmall) {
        Write-Err "Drive is too small. Map update is ~19 GB. Use a 32 GB+ drive."
        exit 1
    }

    if ($selected.Number -eq 0) {
        Write-Err "REFUSED: Disk 0 is typically your system drive!"
        exit 1
    }

    $sizeGb = [math]::Round($selected.Size / 1GB, 1)
    Write-Host ""
    Write-Warn "Selected: Disk $($selected.Number) - $($selected.FriendlyName) ($sizeGb) GB"
    Write-Warn "ALL DATA ON THIS DRIVE WILL BE ERASED!"
    Write-Host ""
    $confirm = Read-Host "Type 'YES' to confirm"
    if ($confirm -ne 'YES') {
        Write-Info "Aborted."
        exit 0
    }

    return $selected
}

# ── Format USB as FAT32 ───────────────────────────────────────────────────
function Format-UsbDrive {
    param($Disk)

    Write-Header "Formatting USB Drive as FAT32"

    Write-Info "Cleaning disk $($Disk.Number)..."
    # Clear the disk and create MBR + single FAT32 partition
    Clear-Disk -Number $Disk.Number -RemoveData -RemoveOEM -Confirm:$false -ErrorAction SilentlyContinue

    Start-Sleep -Seconds 2
    Update-StorageProviderCache

    $currentDisk = Get-Disk -Number $Disk.Number
    if ($currentDisk.PartitionStyle -ne 'RAW') {
        Write-Info "Disk is already initialized. Converting to MBR..."
        Set-Disk -Number $Disk.Number -PartitionStyle MBR -ErrorAction Stop
    } else {
        Write-Info "Initializing with MBR partition table..."
        Initialize-Disk -Number $Disk.Number -PartitionStyle MBR -ErrorAction Stop
    }   

    Write-Info "Creating FAT32 partition..."
    $partition = New-Partition -DiskNumber $Disk.Number -UseMaximumSize -IsActive -AssignDriveLetter
    $driveLetter = $partition.DriveLetter

    $sizeGb = [math]::Round($Disk.Size / 1GB, 1)

    if ($sizeGb -le 32) {
        Format-Volume -DriveLetter $driveLetter -FileSystem FAT32 -NewFileSystemLabel "NAC_MAP" -Confirm:$false | Out-Null
    } else {
        Write-Info "Drive is $sizeGb GB. Using format.com for large FAT32..."
        $formatResult = & cmd.exe /c "echo Y | format ${driveLetter}: /FS:FAT32 /Q /V:NAC_MAP" 2>&1
        $vol = Get-Volume -DriveLetter $driveLetter -ErrorAction SilentlyContinue
        if ($vol.FileSystemType -ne 'FAT32' -and $vol.FileSystem -ne 'FAT32') {
            Write-Warn "Windows format didn't produce FAT32. Trying diskpart..."
            $dpScript = @"
select disk $($Disk.Number)
clean
create partition primary size=32768
select partition 1
active
format fs=fat32 quick label=NAC_MAP
assign letter=$driveLetter
"@
            $dpScript | diskpart.exe | Out-Null
        }
    }

    Write-Ok "Drive formatted as FAT32 (MBR) - drive letter ${driveLetter}:"
    return "${driveLetter}:"
}

# ── Download with auto-resume ──────────────────────────────────────────────
function Save-WithResume {
    param(
        [string]$Url,
        [string]$Dest,
        [long]$ExpSize
    )

    $attempt = 0
    $delay = $RetryDelayBase

    while ($attempt -lt $MaxRetries) {
        $attempt++
        $currentSize = 0

        if (Test-Path $Dest) {
            $currentSize = (Get-Item $Dest).Length
            if ($currentSize -ge $ExpSize -and $ExpSize -gt 0) {
                return $true
            }
            if ($currentSize -gt 0 -and $attempt -gt 1) {
                $currentMb = [math]::Round($currentSize / 1MB)
                $totalMb   = [math]::Round($ExpSize / 1MB)
                Write-Info "Resuming from $currentMb / $totalMb MB  (attempt $attempt/$MaxRetries)..."
            }
        } elseif ($attempt -gt 1) {
            Write-Info "Retrying from scratch  (attempt $attempt/$MaxRetries)..."
        }

        try {
            if ($currentSize -gt 0) {
                $request = [System.Net.HttpWebRequest]::Create($Url)
                $request.AddRange($currentSize)
                $request.Timeout = 30000
                $request.ReadWriteTimeout = 120000
                $request.AllowAutoRedirect = $true

                $response = $request.GetResponse()
                $stream = $response.GetResponseStream()
                $fileStream = [System.IO.FileStream]::new($Dest, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write)

                $buffer = New-Object byte[] 131072
                $totalRead = $currentSize
                $expectedTotal = $currentSize + $response.ContentLength
                $lastReport = Get-Date

                while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $fileStream.Write($buffer, 0, $read)
                    $totalRead += $read
                    $now = Get-Date
                    if (($now - $lastReport).TotalSeconds -ge 2) {
                        $pct = if ($expectedTotal -gt 0) { [math]::Round(($totalRead / $expectedTotal) * 100, 1) } else { 0 }
                        $dlMb = [math]::Round($totalRead / 1MB)
                        Write-Progress -Activity "Downloading maps" -Status "$dlMb MB downloaded ($pct)%" -PercentComplete ([math]::Min($pct, 100))
                        $lastReport = $now
                    }
                }

                $fileStream.Close(); $stream.Close(); $response.Close()
                Write-Progress -Activity "Downloading maps" -Completed
            } else {
                $bitsOk = $false
                try {
                    Import-Module BitsTransfer -ErrorAction Stop
                    Start-BitsTransfer -Source $Url -Destination $Dest -DisplayName "NAC Maps" -Description "Downloading map-eur $MapVersion (~19 GB)"
                    $bitsOk = $true
                } catch {
                    Write-Warn "BITS transfer failed, falling back to .NET download..."
                }

                if (-not $bitsOk) {
                    $request = [System.Net.HttpWebRequest]::Create($Url)
                    $request.Timeout = 30000
                    $request.ReadWriteTimeout = 120000
                    $request.AllowAutoRedirect = $true

                    $response = $request.GetResponse()
                    $stream = $response.GetResponseStream()
                    $fileStream = [System.IO.FileStream]::new($Dest, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)

                    $buffer = New-Object byte[] 131072
                    $totalRead = 0
                    $expectedTotal = $response.ContentLength
                    $lastReport = Get-Date

                    while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                        $fileStream.Write($buffer, 0, $read)
                        $totalRead += $read
                        $now = Get-Date
                        if (($now - $lastReport).TotalSeconds -ge 2) {
                            $pct = if ($expectedTotal -gt 0) { [math]::Round(($totalRead / $expectedTotal) * 100, 1) } else { 0 }
                            $dlMb = [math]::Round($totalRead / 1MB)
                            Write-Progress -Activity "Downloading maps" -Status "$dlMb MB downloaded ($pct)%" -PercentComplete ([math]::Min($pct, 100))
                            $lastReport = $now
                        }
                    }

                    $fileStream.Close(); $stream.Close(); $response.Close()
                    Write-Progress -Activity "Downloading maps" -Completed
                }
            }

            if (Test-Path $Dest) {
                $finalSize = (Get-Item $Dest).Length
                if ($finalSize -gt 5000000000) { return $true }
                else { Write-Warn "File too small ($finalSize bytes). Retrying..." }
            }
        } catch {
            Write-Warn "Download interrupted: $($_.Exception.Message)"
        }

        Write-Warn "Waiting ${delay}s before retry..."
        Start-Sleep -Seconds $delay
        $delay = [math]::Min($delay * 2, $RetryDelayCap)
    }

    return $false
}

function Save-Map {
    param([string]$Dest)

    Write-Header "Downloading European Map"
    Write-Info "Version:  map-eur $MapVersion"
    Write-Info "Size:     ~19 GB ($ExpectedSize bytes)"
    Write-Info "Source:   TomTom CDN"
    Write-Info "Download will auto-resume if the connection drops."
    Write-Host ""

    if (Test-Path $Dest) {
        $existing = (Get-Item $Dest).Length
        if ($existing -eq $ExpectedSize) {
            Write-Ok "File already fully downloaded ($ExpectedSize) bytes."
            return
        } elseif ($existing -gt 0) {
            $existingMb = [math]::Round($existing / 1MB)
            Write-Info "Found partial download: $existingMb MB. Will resume."
        }
    }

    Write-Info "Downloading from TomTom CDN..."
    Write-Host "  $MapUrl"
    Write-Host ""

    if (Save-WithResume -Url $MapUrl -Dest $Dest -ExpSize $ExpectedSize) {
        Write-Ok "Download complete."
        return
    }

    Write-Warn "Primary URL failed. Trying fallback..."
    foreach ($url in $FallbackUrls) {
        if (Test-Path $Dest) { Remove-Item $Dest -Force }
        Write-Info "Trying: $url"
        if (Save-WithResume -Url $url -Dest $Dest -ExpSize $ExpectedSize) {
            Write-Ok "Download complete."
            return
        }
    }

    Write-Err "All download URLs failed."
    Write-Host "  Partial download kept at: $Dest"
    Write-Host "  Download manually from: https://sites.google.com/view/nac-rcc/system/nac/wave-4"
    Write-Host "  Then re-run: .\Prepare-NacMapUpdate.ps1 -TarFile `"path\to\file.tar`""
    exit 1
}

# ── Validate map ───────────────────────────────────────────────────────────
function Test-MapFile {
    param([string]$Path)

    Write-Header "Validating Map File"

    $size = (Get-Item $Path).Length
    Write-Info "File size: $size bytes"

    if ($size -eq $ExpectedSize) {
        Write-Ok "Size matches expected ($ExpectedSize) bytes."
    } else {
        Write-Warn "Size $size doesn't match expected $ExpectedSize. Could be a re-upload."
    }

    Write-Info "Checking archive integrity (this may take a moment for 19 GB)..."
    $tarCheck = & tar.exe tf $Path 2>&1 
    if ($LASTEXITCODE -ne 0 -or $tarCheck.Count -lt 5) {
        Write-Err "Archive appears corrupted. Re-download it."
        exit 1
    }

    if ($tarCheck -match "SWL/") {
        Write-Ok "Contains SWL/ directory structure."
    } else {
        Write-Err "No SWL/ directory found. Wrong file?"
        exit 1
    }
}

# ── Extract map to USB ─────────────────────────────────────────────────────
function Expand-ToUsb {
    param([string]$TarPath, [string]$UsbRoot)

    Write-Header "Extracting Map to USB"
    Write-Info "Extracting ~19 GB archive. This will take quite a while..."
    Write-Info "(USB 2.0 write speeds make this 15-30 min)"

    & tar.exe xf $TarPath -C $UsbRoot 2>&1 | Where-Object { $_ -notmatch "unknown extended header" }

    if (Test-Path (Join-Path $UsbRoot "SWL")) {
        Write-Ok "Extraction complete. SWL\ directory present."
    } else {
        Write-Err "SWL\ directory missing after extraction!"
        exit 1
    }
}

# ── Summary ────────────────────────────────────────────────────────────────
function Show-Summary {
    param([string]$UsbRoot)

    Write-Header "USB Drive Ready - Map Update!"

    Write-Host "USB contents:" -ForegroundColor White
    Get-ChildItem $UsbRoot -Recurse -Depth 2 -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Write-Host "  $($_.FullName.Replace($UsbRoot, 'USB:'))" }
    Write-Host ""
    Write-Host "  [+] No license file needed for map updates" -ForegroundColor Green
    Write-Host ""

    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host "  MAP INSTALLATION INSTRUCTIONS" -ForegroundColor Cyan
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  PREREQUISITE: Firmware must be 44.07.33.32 or newer!" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  1. Start the car (engine on or READY mode for hybrid)"
    Write-Host "  2. Insert USB drive"
    Write-Host "  3. Choose which countries to install"
    Write-Host "     (all existing maps are deleted first)"
    Write-Host "  4. Installation takes 45-90 minutes (19 GB via USB 2.0)"
    Write-Host "     Keep the engine running the entire time!" -ForegroundColor Red
    Write-Host "     A long drive is ideal."
    Write-Host "  5. System reboots when done"
    Write-Host ""
    Write-Host "  Safely eject: right-click drive in Explorer > Eject"
    Write-Host ""
}

# ── Main ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  NAC Wave 4 Map Update - USB Prep (Windows)" -ForegroundColor Cyan
Write-Host "  Target: map-eur $MapVersion" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Get-Command tar.exe -ErrorAction SilentlyContinue)) {
    Write-Err "tar.exe not found. Requires Windows 10 version 1803 or later."
    exit 1
}

Test-FirmwarePrerequisite

$disk = Select-UsbDrive

if (-not $SkipFormat) {
    $usbRoot = Format-UsbDrive -Disk $disk
} else {
    $partition = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter }
    if (-not $partition) {
        Write-Err "No mounted partition found on Disk $($disk.Number)."
        exit 1
    }
    $usbRoot = "$($partition.DriveLetter):"
    Write-Info "Using existing partition: $usbRoot"
}

$tarPath = ""
if ($TarFile) {
    if (-not (Test-Path $TarFile)) {
        Write-Err "File not found: $TarFile"
        exit 1
    }
    $tarPath = $TarFile
    Write-Info "Using provided file: $tarPath"
} else {
    $tarPath = Join-Path $env:TEMP $MapFilename
    Save-Map -Dest $tarPath
}

Test-MapFile -Path $tarPath
Expand-ToUsb -TarPath $tarPath -UsbRoot $usbRoot

Show-Summary -UsbRoot $usbRoot

Write-Ok "Done! Safely eject the USB drive before removing it."
Write-Host ""
