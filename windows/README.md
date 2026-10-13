# NAC Wave 4 Update Scripts for Windows

Two PowerShell scripts to prepare USB drives for updating the infotainment system (Continental NAC Wave 4) found in Peugeot, Citroën, DS, Opel/Vauxhall vehicles from ~2017 onwards.

These scripts exist because the official Citroën/Peugeot/DS/Opel Update apps frequently fail with a **"Version not compatible with hardware"** error — often caused by broken files on Stellantis's CDN servers, expired certificates, or missing license files. These scripts bypass those issues by downloading from known-good sources, automatically resuming interrupted downloads, and correctly structuring the USB drive.

---

## What's Included

| Script | What it does |
|---|---|
| `Prepare-NacFirmwareUpdate.ps1` | Downloads and prepares firmware **44.07.33.32_NAC-r0** (latest NAC Wave 4 firmware, ~5.9 GB) |
| `Prepare-NacMapUpdate.ps1` | Downloads and prepares European map **17.0.0-r0** (latest cartography, ~19 GB) |

**Always install firmware first, then maps.** The map update requires Wave 4 firmware.

---

## Compatible Vehicles

Any PSA/Stellantis vehicle with a Continental NAC Wave 4 infotainment system, including but not limited to:

- Citroën C5 Aircross, C4, C3 Aircross, Berlingo, C5 X
- Peugeot 208, 2008, 308, 3008, 508, 5008, Rifter, Partner
- DS 3, DS 4, DS 7, DS 9
- Opel/Vauxhall Corsa, Mokka, Grandland, Combo
- Toyota Proace (PSA-based models)

To confirm you have a NAC Wave 4, check the firmware version on your screen (Settings → System info). If it starts with **42.xx** or **44.xx**, you have Wave 4. Versions starting with **31.xx** are Wave 3 (some can be upgraded), and **21.xx** are Wave 2 (not compatible with these scripts).

---

## Prerequisites

### What you need

- **Windows 10 version 1803 or later** (or Windows 11) — for the built-in `tar.exe`
- **PowerShell 5.1 or later** — pre-installed on all Windows 10/11 systems
- **Administrator access** — needed to format the USB drive

No additional software needs to be installed. Everything these scripts use ships with Windows.

### How to check your Windows version

Press `Win + R`, type `winver`, press Enter. You need version **1803** or higher (released April 2018). If you're on Windows 11, you're fine.

### If you have an older Windows version

If your Windows is older than version 1803, you'll need to install **7-Zip** to extract `.tar` files:

1. Go to [7-zip.org](https://www.7-zip.org/)
2. Download the 64-bit Windows version
3. Install it
4. You can then right-click the `.tar` file → 7-Zip → Extract Here

In this case you would use the scripts with `--TarFile` pointing to the already-extracted folder, or extract manually to the USB.

---

## Before You Start

You will need:

- A **USB drive** — any size for firmware (8 GB+), at least **32 GB for maps**
- Your **NAC UIN** (for firmware only) — a 20-character code that identifies your head unit

### How to Find Your UIN

1. Format any USB drive as FAT32 (right-click in File Explorer → Format → File system: FAT32)
2. Insert it into the car's USB port
3. On the NAC touchscreen: **Settings → System info → System version**
4. Choose **"Export to USB"** (sometimes called "Export configuration")
5. Remove the USB and plug it into your PC
6. Two files will be on the drive:
   - `instkey_XXXXXXXXXXXXXXXXXXXX.xml`
   - `packageslist_XXXXXXXXXXXXXXXXXXXX.txt`
7. The `XXXXXXXXXXXXXXXXXXXX` part (20 characters) is your UIN

Example UIN: `0D01071F79D4D1E3643C`

---

## Usage

### How to run the scripts

There are two ways to run the scripts, depending on your comfort level.

#### Option A — For technical users (PowerShell directly)

1. Right-click the **Start button** → **Terminal (Admin)** or **PowerShell (Admin)**
2. If you see a command prompt instead of PowerShell, type `powershell` and press Enter
3. Navigate to the folder containing the scripts:
   ```powershell
   cd "$env:USERPROFILE\Downloads"
   ```
4. You may need to allow script execution (one-time):
   ```powershell
   Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
   ```
5. Run the script:
   ```powershell
   .\Prepare-NacFirmwareUpdate.ps1
   ```

#### Option B — For everyone else

1. Find the `.ps1` file in File Explorer
2. Right-click it → **Run with PowerShell**
3. If Windows asks about execution policy, choose **Yes** or **Allow**
4. **Important:** If the script says it needs Administrator rights, close it and:
   - Press the **Start button**
   - Type **PowerShell**
   - Right-click **Windows PowerShell** → **Run as administrator**
   - Type: `cd "$env:USERPROFILE\Downloads"` (or wherever you saved the scripts)
   - Type: `.\Prepare-NacFirmwareUpdate.ps1`

### Firmware Update

```powershell
.\Prepare-NacFirmwareUpdate.ps1
```

The script will:
1. Ask for your UIN
2. Show available USB drives and let you pick one
3. Format it as FAT32 with MBR partition table
4. Download the firmware (~5.9 GB) with automatic resume
5. Verify the file is the correct version (not the broken CloudFront one)
6. Extract it to the USB drive
7. Download and place your license file
8. Show installation instructions

**Options:**

```powershell
.\Prepare-NacFirmwareUpdate.ps1 -Uin "0D01071F79D4D1E3643C"       # skip UIN prompt
.\Prepare-NacFirmwareUpdate.ps1 -TarFile "C:\Downloads\fw.tar"     # use pre-downloaded file
.\Prepare-NacFirmwareUpdate.ps1 -SkipFormat                         # don't reformat USB
```

### Map Update

```powershell
.\Prepare-NacMapUpdate.ps1
```

Same flow, but for the European cartography (~19 GB). No UIN or license needed for maps.

**Options:**

```powershell
.\Prepare-NacMapUpdate.ps1 -TarFile "C:\Downloads\maps.tar"       # use pre-downloaded file
.\Prepare-NacMapUpdate.ps1 -SkipFormat                              # don't reformat USB
```

---

## Installing in the Car

### Firmware

1. Start the car — engine on, or press Start twice for READY mode (hybrid/EV)
2. **Recommended:** connect the car to WiFi or your phone's hotspot first (Settings → Connectivity → WiFi). This provides a backup path for license verification
3. Insert the USB drive
4. The system should detect the update automatically. If not: Settings → System info → System update
5. Installation takes **30–45 minutes**. **Do not turn off the engine**
6. The system reboots automatically when done

### Maps (after firmware is updated)

1. Start the car
2. Insert the USB drive
3. Choose which countries to install (all existing maps are deleted first)
4. Installation takes **45–90 minutes** (19 GB over USB 2.0). A long drive is ideal
5. There is no visible progress bar — this is normal

---

## Troubleshooting

### "Version not compatible with hardware"

| Cause | Fix |
|---|---|
| You used the official Update app | The CloudFront file is broken since Feb 2026. Use this script instead |
| License file missing or invalid | The script handles this, but connect the car to WiFi as backup |
| NAC needs a reset | Hold the power/volume button on the NAC for 10+ seconds |
| USB drive issues | Try a different drive. Some NAC units are picky about brands |

### "No media content on the USB memory stick"

- The USB must be **FAT32** with an **MBR** partition table (the script handles this)
- The `SWL` folder and `UpdateInfo.xml` must be in the root of the USB
- If you formatted the drive yourself, Windows may have used GPT instead of MBR — let the script handle formatting

### FAT32 formatting issues on large drives

Windows has historically limited the built-in GUI formatter to 32 GB for FAT32. The scripts handle this automatically using `format.com` or `diskpart`. If you're formatting manually, use the command line:

```cmd
format E: /FS:FAT32 /Q /V:NAC_UPDATE
```

(Replace `E:` with your USB drive letter. Windows 11 24H2 and later removed the 32 GB limit in the GUI as well.)

### Script won't run — "execution policy" error

Run this once in an Administrator PowerShell:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

Then try the script again.

### Download keeps failing

The scripts automatically resume from where they left off (up to 50 retries with exponential backoff). The partial download is stored in your `%TEMP%` folder. Re-running the script picks up where it stopped.

To download manually, open PowerShell and run:

```powershell
# Firmware (use this URL, NOT the CloudFront one):
Start-BitsTransfer -Source "https://majestic-web.mpsa.com/nas/eu/mjb00/PSA/mjbsu/PSA_ovip-int-firmware-version_44-07-33-32_NAC-r0_NAC_EUR_WAVE4.tar" -Destination "$env:USERPROFILE\Downloads\firmware.tar"

# Maps:
Start-BitsTransfer -Source "https://download-cde.tomtom.com/OEM/PSA/MAP/PSA_map-eur_17.0.0-r0-NAC_EUR_WAVE4.tar" -Destination "$env:USERPROFILE\Downloads\maps.tar"
```

Then pass them to the scripts with `-TarFile "path\to\file.tar"`.

### BSI Reset (last resort)

If nothing works:

1. Turn the car off
2. Disconnect the 12V battery for 15 minutes
3. Reconnect the battery
4. Start the car and try again

### Windows 11 / PowerShell 5.1 gotchas

The `windows/` scripts were previously **untested** on real hardware. The following issues were hit during an end-to-end run on Windows 11 with PowerShell 5.1 and are now handled by `Prepare-NacFirmwareUpdate.ps1`:

| Symptom | What was happening | Status |
|---|---|---|
| Script blocked from running | Windows' execution policy prevents unsigned `.ps1` scripts from running by default | Launch with `powershell -ExecutionPolicy Bypass -File .\Prepare-NacFirmwareUpdate.ps1`, or run `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser` once |
| Single USB drive rejected every input | With exactly one USB drive attached, the drive list was a single object instead of an array, so selection failed and no drive could be chosen | Fixed — the drive list is always treated as an array, so a lone USB drive is offered/auto-selected correctly |
| "The disk has already been initialized" during format | The disk wasn't reliably wiped before `Initialize-Disk`, so initialization threw on an already-initialized disk | Fixed — the disk is now reliably cleaned first and initialization is idempotent (only initializes a RAW disk, otherwise resets the partition style) |
| Download fails immediately on `majestic-web.mpsa.com` | The fresh download used BITS, which requires HTTP Range support; that server doesn't provide it, so BITS threw a COMException | Fixed — the fresh download no longer depends on BITS; it streams directly (interrupted downloads still auto-resume) |
| False "archive corrupted — re-download it" report | The `tar` integrity check truncated its own pipe after a few entries, making `tar` exit non-zero on a perfectly intact file (an exact size match is strong evidence the file is fine) | Fixed — the check now reads the full `tar` output and bases the corrupted/OK decision on `tar`'s real exit code |

---

## How It Works (Technical Details)

The NAC firmware update process requires:

1. **The firmware archive** — a `.tar` file containing an `SWL` folder with signed firmware packages. The same archive works for all NAC Wave 4 units
2. **A license file** — a PKCS#7 encrypted file specific to your unit (UIN) and firmware version (UpdateID). Downloaded from Stellantis's Majestic API. Map updates do not require a license
3. **A FAT32 USB drive** with an MBR partition table. The NAC does not support exFAT, NTFS, or GPT

### Why the official app fails

Since February 4, 2026, Stellantis uploaded a new firmware to their CloudFront CDN (6,312,210,432 bytes) that is improperly signed. The official Update apps download from this CDN. The previous valid version (6,312,212,480 bytes) remains available on their majestic-web.mpsa.com server. These scripts download from the working server.

---

## Community Resources

- [rui.saraiva's NAC & RCC Updates](https://sites.google.com/view/nac-rcc/system/nac/wave-4) — definitive version tracker
- [Mittns Peugeot Forum](https://www.mittns.de/) — toolbox and support
- [Peugeot Forums](https://www.peugeotforums.com/) — active discussions
- [French Car Forum](https://frenchcarforum.co.uk/forum/viewtopic.php?t=81068) — long-running update thread
- [ludwig-v's firmware reverse engineering](https://github.com/ludwig-v/psa-nac-firmware-reverse-engineering) — technical reference

---

## License

These scripts are provided as-is for personal use. The firmware and map files are copyrighted by Stellantis/Continental/TomTom and downloaded from their official servers. Use at your own risk.
