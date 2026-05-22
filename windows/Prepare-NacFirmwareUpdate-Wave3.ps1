<#
.SYNOPSIS
    NAC Wave 3 Firmware Update - USB Preparation Script (Windows 10/11)

.DESCRIPTION
    Prepares a USB drive with the last NAC Wave 3 firmware (42.03.33.42_NAC-r0)
    for PSA/Stellantis vehicles (Peugeot, Citroen, DS, Opel/Vauxhall).

.PARAMETER Uin
    Your NAC unit's 20-character hex ID. Prompted interactively if omitted.

.PARAMETER TarFile
    Path to a pre-downloaded .tar firmware file. Downloaded automatically if omitted.

.PARAMETER SkipFormat
    Don't format the USB drive (it must already be FAT32 with MBR).

.EXAMPLE
    .\Prepare-NacFirmwareUpdate.ps1
    .\Prepare-NacFirmwareUpdate.ps1 -Uin "0D01071F79D4D1E3643C"
    .\Prepare-NacFirmwareUpdate.ps1 -TarFile "C:\Downloads\firmware.tar"

.NOTES
    How to find your UIN:
      1. Insert any FAT32 USB into the car
      2. On the NAC screen: Settings > System info > System version
      3. Choose "Export to USB"
      4. Two files are created: instkey_<UIN>.xml and packageslist_<UIN>.txt
      5. The UIN is the 20-character hex string in those filenames
#>

[CmdletBinding()]
param(
    [string]$Uin = "",
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
#https://ds4emloty3shq.cloudfront.net/CONTINENTAL/NAC_EU/ovip-int-firmware-version/PSA_ovip-int-firmware-version_42-03-33-42_NAC-r0_NAC_EUR_WAVE3.tar
$FirmwareVersion = "42.03.33.42_NAC-r0"
$UpdateId        = "001315031622734386"

$FirmwareUrl      = "https://ds4emloty3shq.cloudfront.net/CONTINENTAL/NAC_EU/ovip-int-firmware-version/PSA_ovip-int-firmware-version_42-03-33-42_NAC-r0_NAC_EUR_WAVE3.tar"
$FirmwareFilename = "PSA_ovip-int-firmware-version_42-03-33-42_NAC-r0_NAC_EUR_WAVE3.tar"
$FallbackUrls     = @(
    "https://ds4emloty3shq.cloudfront.net/CONTINENTAL/NAC_EU/ovip-int-firmware-version/PSA_ovip-int-firmware-version_42-03-33-42_NAC-r0_NAC_EUR_WAVE3.tar"
)

$ExpectedSize = 6158254080

$MaxRetries     = 50
$RetryDelayBase = 5
$RetryDelayCap  = 120

# ── Helpers ────────────────────────────────────────────────────────────────
function Write-Info    { param($Msg) Write-Host "[INFO] $Msg" -ForegroundColor Cyan }
function Write-Ok      { param($Msg) Write-Host "[ OK ] $Msg" -ForegroundColor Green }
function Write-Warn    { param($Msg) Write-Host "[WARN] $Msg" -ForegroundColor Yellow }
function Write-Err     { param($Msg) Write-Host "[ERR ] $Msg" -ForegroundColor Red }
function Write-Header  { param($Msg) Write-Host "`n-- $Msg --`n" -ForegroundColor Cyan }

# ── UIN Prompt ─────────────────────────────────────────────────────────────
function Get-Uin {
    if ($script:Uin) {
        Write-Info "UIN provided: $($script:Uin)"
    } else {
        Write-Header "NAC Unit Identification (UIN)"
        Write-Host "  Your UIN is a 20-character hex string that identifies your NAC unit."
        Write-Host ""
        Write-Host "  How to find it:"
        Write-Host "    1. Insert any FAT32-formatted USB into the car"
        Write-Host "    2. On the NAC screen: Settings > System info > System version"
        Write-Host "    3. Choose 'Export to USB' (or 'Export configuration')"
        Write-Host "    4. Two files are created on the USB:"
        Write-Host "       instkey_<UIN>.xml  and  packageslist_<UIN>.txt"
        Write-Host "    5. The UIN is the 20-character hex string in those filenames"
        Write-Host "       Example: 0D01071F79D4D1E3643C"
        Write-Host ""
        $script:Uin = Read-Host "Enter your UIN (20 hex characters)"
    }

    $script:Uin = $script:Uin.Trim().ToUpper() -replace '\s',''

    if ($script:Uin -notmatch '^[0-9A-F]{20}$') {
        Write-Err "Invalid UIN: '$($script:Uin)'"
        Write-Err "Must be exactly 20 hexadecimal characters (0-9, A-F)."
        exit 1
    }

    $script:LicenseFilename = "license_$($script:Uin)_$UpdateId.key"
    $script:LicenseUrl = "https://majestic-web.mpsa.com/mjf00-web/rest/LicenseDownload?mediaVersion=$UpdateId&uin=$($script:Uin)"

    Write-Ok "UIN: $($script:Uin)"
}

# ── USB Drive Selection ────────────────────────────────────────────────────
function Select-UsbDrive {
    Write-Header "USB Drive Selection"

    $removable = Get-Disk | Where-Object { $_.BusType -eq 'USB' -or $_.BusType -eq 'SCSI' } |
        Where-Object { $_.Size -gt 0 } |
        Sort-Object Number

    # Filter to truly removable drives (exclude large external HDDs as safety measure)
    $usbDrives = $removable | Where-Object {
        $_.MediaType -eq 'Removable' -or $_.Size -lt 256GB
    }

    if (-not $usbDrives -or @($usbDrives).Count -eq 0) {
        # Fallback: show all USB bus devices
        $usbDrives = Get-Disk | Where-Object { $_.BusType -eq 'USB' -and $_.Size -gt 0 }
    }

    if (-not $usbDrives -or @($usbDrives).Count -eq 0) {
        Write-Err "No USB drives detected. Make sure your USB drive is plugged in."
        exit 1
    }

    Write-Host "Available USB drives:"
    Write-Host ""
    $i = 1
    foreach ($d in $usbDrives) {
        $sizeGb = [math]::Round($d.Size / 1GB, 1)
        Write-Host "  $i Disk $($d.Number): $($d.FriendlyName)  ($sizeGb) GB" -ForegroundColor White
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

    # Safety: refuse if it looks like a system drive
    $sysDisks = (Get-Partition -DiskNumber 0 -ErrorAction SilentlyContinue)
    if ($selected.Number -eq 0 -and $sysDisks) {
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
    Clear-Disk -Number $Disk.Number -RemoveData -RemoveOEM -Confirm:$false # -ErrorAction SilentlyContinue

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

    # Windows built-in format supports FAT32 only up to 32 GB.
    # For larger drives, we use the label trick with format.com
    $sizeGb = [math]::Round($Disk.Size / 1GB, 1)

    if ($sizeGb -le 32) {
        Format-Volume -DriveLetter $driveLetter -FileSystem FAT32 -NewFileSystemLabel "NAC_UPDATE" -Confirm:$false | Out-Null
    } else {
        Write-Info "Drive is $sizeGb GB. Using format.com for large FAT32..."
        # format.com can format FAT32 > 32GB on Windows 11 24H2+, older versions need workaround
        $formatResult = & cmd.exe /c "echo Y | format ${driveLetter}: /FS:FAT32 /Q /V:NAC_UPDATE" 2>&1
        # Check if it worked
        $vol = Get-Volume -DriveLetter $driveLetter -ErrorAction SilentlyContinue
        if ($vol.FileSystemType -ne 'FAT32' -and $vol.FileSystem -ne 'FAT32') {
            Write-Warn "Windows format didn't produce FAT32. Trying alternative..."
            # Use PowerShell to call diskpart as fallback
            $dpScript = @"
select disk $($Disk.Number)
clean
create partition primary size=32768
select partition 1
active
format fs=fat32 quick label=NAC_UPDATE
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

        $headers = @{}
        $currentSize = 0

        if (Test-Path $Dest) {
            $currentSize = (Get-Item $Dest).Length
            if ($currentSize -ge $ExpSize -and $ExpSize -gt 0) {
                return $true
            }
            if ($currentSize -gt 0) {
                $headers["Range"] = "bytes=$currentSize-"
                if ($attempt -gt 1) {
                    $currentMb = [math]::Round($currentSize / 1MB)
                    $totalMb   = [math]::Round($ExpSize / 1MB)
                    Write-Info "Resuming from $currentMb / $totalMb MB  (attempt $attempt/$MaxRetries)..."
                }
            }
        } elseif ($attempt -gt 1) {
            Write-Info "Retrying from scratch  (attempt $attempt/$MaxRetries)..."
        }

        try {
            $ProgressPreference = 'Continue'

            if ($currentSize -gt 0) {
                # Resume: use .NET HttpWebRequest for range support
                $request = [System.Net.HttpWebRequest]::Create($Url)
                $request.AddRange($currentSize)
                $request.Timeout = 30000
                $request.ReadWriteTimeout = 120000
                $request.AllowAutoRedirect = $true

                $response = $request.GetResponse()
                $stream = $response.GetResponseStream()
                $fileStream = [System.IO.FileStream]::new($Dest, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write)

                $buffer = New-Object byte[] 131072  # 128 KB buffer
                $totalRead = $currentSize
                $expectedTotal = $currentSize + $response.ContentLength
                $lastReport = Get-Date

                while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $fileStream.Write($buffer, 0, $read)
                    $totalRead += $read

                    # Progress every 2 seconds
                    $now = Get-Date
                    if (($now - $lastReport).TotalSeconds -ge 2) {
                        $pct = if ($expectedTotal -gt 0) { [math]::Round(($totalRead / $expectedTotal) * 100, 1) } else { 0 }
                        $dlMb = [math]::Round($totalRead / 1MB)
                        Write-Progress -Activity "Downloading firmware" -Status "$dlMb MB downloaded ($pct)%" -PercentComplete ([math]::Min($pct, 100))
                        $lastReport = $now
                    }
                }

                $fileStream.Close()
                $stream.Close()
                $response.Close()
                Write-Progress -Activity "Downloading firmware" -Completed
            } else {
                # Fresh download: use BITS for better performance and resume
                $bitsOk = $false
                try {
                    Import-Module BitsTransfer -ErrorAction Stop
                    Start-BitsTransfer -Source $Url -Destination $Dest -DisplayName "NAC Firmware" -Description "Downloading $FirmwareVersion"
                    $bitsOk = $true
                } catch {
                    Write-Warn "BITS transfer failed, falling back to .NET download..."
                }

                if (-not $bitsOk) {
                    # Fallback: .NET download with progress
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
                            Write-Progress -Activity "Downloading firmware" -Status "$dlMb MB downloaded ($pct)%" -PercentComplete ([math]::Min($pct, 100))
                            $lastReport = $now
                        }
                    }

                    $fileStream.Close()
                    $stream.Close()
                    $response.Close()
                    Write-Progress -Activity "Downloading firmware" -Completed
                }
            }

            # Verify we got something substantial
            if (Test-Path $Dest) {
                $finalSize = (Get-Item $Dest).Length
                if ($finalSize -gt 1000000000) {
                    return $true
                } else {
                    Write-Warn "File too small ($finalSize) bytes. Retrying..."
                }
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

function Save-Firmware {
    param([string]$Dest)

    Write-Header "Downloading Firmware"
    Write-Info "Version:  $FirmwareVersion"
    Write-Info "Size:     ~5.9 GB ($ExpectedSize) bytes"
    Write-Info "Download will auto-resume if the connection drops."
    Write-Host ""

    # Check for existing download
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

    Write-Info "Downloading from majestic-web.mpsa.com..."
    Write-Host "  $FirmwareUrl"
    Write-Host ""

    if (Save-WithResume -Url $FirmwareUrl -Dest $Dest -ExpSize $ExpectedSize) {
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

    Write-Err "All download URLs failed after $MaxRetries retries."
    Write-Host ""
    Write-Host "  Your partial download is kept at: $Dest"
    Write-Host "  Download manually from rui.saraiva's site:"
    Write-Host "    https://sites.google.com/view/nac-rcc/system/nac/wave-3"
    Write-Host ""
    Write-Host "  Then re-run:  .\Prepare-NacFirmwareUpdate.ps1 -TarFile `"path\to\file.tar`""
    exit 1
}

# ── Validate firmware ──────────────────────────────────────────────────────
function Test-Firmware {
    param([string]$Path)

    Write-Header "Validating Firmware File"

    $size = (Get-Item $Path).Length
    Write-Info "File size: $size bytes"

    if ($size -eq $ExpectedSize) {
        Write-Ok "Size matches the known-good version ($ExpectedSize) bytes."
    } elseif ($size -eq 6312210432) {
        Write-Host ""
        Write-Err "THIS IS THE BROKEN CLOUDFRONT FILE!"
        Write-Err "Size: 6,312,210,432 bytes (should be 6,312,212,480)"
        Write-Err "This WILL fail with 'incompatible hardware'."
        Write-Host ""
        Write-Host "  You need the correct file from the majestic-web server."
        Write-Host "  Re-run this script without -TarFile to download automatically."
        exit 1
    } else {
        Write-Warn "Size $size doesn't match expected $ExpectedSize."
        Write-Warn "Could be a newer upload. Proceeding."
    }

    # Basic tar check - Windows 10 1803+ has tar.exe built in
    Write-Info "Checking archive integrity..."
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

# ── License file ───────────────────────────────────────────────────────────
function Get-License {
    param([string]$UsbRoot)

    Write-Header "Preparing License File"

    $searchPaths = @(
        (Join-Path $PSScriptRoot $script:LicenseFilename),
        (Join-Path "." $script:LicenseFilename),
        (Join-Path $env:USERPROFILE "Downloads\$($script:LicenseFilename)"),
        (Join-Path $env:USERPROFILE "Desktop\$($script:LicenseFilename)")
    )

    $found = $null
    foreach ($p in $searchPaths) {
        if (Test-Path $p) {
            $found = $p
            break
        }
    }

    if ($found) {
        Write-Info "Found license: $found"
    } else {
        Write-Info "License not found locally. Downloading from Stellantis..."
        $tmpLicense = Join-Path $env:TEMP $script:LicenseFilename
        try {
            Invoke-WebRequest -Uri $script:LicenseUrl -OutFile $tmpLicense -ErrorAction Stop
            $content = Get-Content $tmpLicense -Raw -ErrorAction SilentlyContinue
            if ($content -match '"errorCode"' -or $content -match '"file":null') {
                Write-Warn "Server returned an error. License not available."
                Write-Warn "Proceeding WITHOUT license - car must have internet!"
                Remove-Item $tmpLicense -Force -ErrorAction SilentlyContinue
                return $false
            }
            $found = $tmpLicense
            Write-Ok "License downloaded."
        } catch {
            Write-Warn "Download failed: $($_.Exception.Message)"
            Write-Warn "Proceeding WITHOUT license - car must have internet!"
            return $false
        }
    }

    $licDir = Join-Path $UsbRoot "license"
    New-Item -ItemType Directory -Path $licDir -Force | Out-Null
    Copy-Item $found (Join-Path $licDir $script:LicenseFilename) -Force
    Write-Ok "License placed at: USB:\license\$($script:LicenseFilename)"
    return $true
}

# ── Extract firmware ───────────────────────────────────────────────────────
function Expand-ToUsb {
    param([string]$TarPath, [string]$UsbRoot)

    Write-Header "Extracting Firmware to USB"
    Write-Info "Extracting ~5.9 GB archive. This takes several minutes..."

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
    param([string]$UsbRoot, [string]$DriveLetter, [bool]$HasLicense)

    Write-Header "USB Drive Ready!"

    Write-Host "USB contents:" -ForegroundColor White
    Get-ChildItem $UsbRoot -Recurse -Depth 2 -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Write-Host "  $($_.FullName.Replace($UsbRoot, 'USB:'))" }
    Write-Host ""

    if ($HasLicense) {
        Write-Host "  [+] License file present" -ForegroundColor Green
    } else {
        Write-Host "  [!] No license file - car MUST have internet!" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host "  INSTALLATION INSTRUCTIONS" -ForegroundColor Cyan
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  1. Start the car (engine on or READY mode for hybrid)"
    if (-not $HasLicense) {
        Write-Host "  2. Connect car to WiFi or phone hotspot FIRST" -ForegroundColor Yellow
        Write-Host "     Settings > Connectivity > WiFi"
    } else {
        Write-Host "  2. Optionally connect to WiFi (recommended as backup)"
    }
    Write-Host "  3. Insert USB drive"
    Write-Host "  4. System should detect the update automatically"
    Write-Host "     If not: Settings > System info > System update"
    Write-Host "  5. Installation takes 30-45 minutes"
    Write-Host "     DO NOT turn off the engine during install!" -ForegroundColor Red
    Write-Host "  6. System reboots automatically when done"
    Write-Host ""
    Write-Host "  Safely eject the USB: right-click drive in Explorer > Eject" -ForegroundColor White
    Write-Host ""
    Write-Host "  Troubleshooting:" -ForegroundColor Yellow
    Write-Host "    - Hold NAC power/volume button 10+ sec to reset"
    Write-Host "    - Try a different USB drive"
    Write-Host "    - BSI reset: disconnect 12V battery 15 min, reconnect"
    Write-Host ""
    Write-Host "  Community: https://www.mittns.de/  |  https://www.peugeotforums.com/"
    Write-Host ""
}

# ── Main ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  NAC Wave 3 Firmware Update - USB Prep (Windows)" -ForegroundColor Cyan
Write-Host "  Target: $FirmwareVersion" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# Check tar.exe is available (Windows 10 1803+)
if (-not (Get-Command tar.exe -ErrorAction SilentlyContinue)) {
    Write-Err "tar.exe not found. This script requires Windows 10 version 1803 or later."
    Write-Err "Alternatively, install 7-Zip or bsdtar."
    exit 1
}

Get-Uin

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

# Download or use provided firmware
$tarPath = ""
if ($TarFile) {
    if (-not (Test-Path $TarFile)) {
        Write-Err "File not found: $TarFile"
        exit 1
    }
    $tarPath = $TarFile
    Write-Info "Using provided file: $tarPath"
} else {
    $tarPath = Join-Path $env:TEMP $FirmwareFilename
    Save-Firmware -Dest $tarPath
}

Test-Firmware -Path $tarPath
Expand-ToUsb -TarPath $tarPath -UsbRoot $usbRoot

$hasLicense = Get-License -UsbRoot $usbRoot

Show-Summary -UsbRoot $usbRoot -DriveLetter $usbRoot -HasLicense $hasLicense

Write-Ok "Done! Safely eject the USB drive before removing it."
Write-Host ""
