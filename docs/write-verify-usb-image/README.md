# write-verify-usb-image

`write-verify-usb-image.sh` creates bootable USB installation media from a raw disk image and verifies the result byte-for-byte.

The tool is intended primarily for creating JetPack installation media directly on an NVIDIA Jetson system. It writes the image to a whole USB storage device, flushes pending writes, reads the image-sized region back from the device, and compares it with the source image.

> **Warning**
>
> Writing an image destroys all existing data on the selected USB drive. Always verify the target device before continuing.

## Supported Environment

- NVIDIA Jetson platform
- Ubuntu 22.04 or later
- Bash
- util-linux 2.37 or later
- APT package management
- USB mass-storage devices reported by Linux with `TRAN=usb`

The script may work on other Linux systems, but those environments are outside the supported scope.

## Features

- Lists available whole-disk USB devices
- Rejects partitions and non-USB targets
- Protects the root disk
- Protects the disk containing the source image
- Confirms that the target is large enough
- Requires explicit destructive confirmation by default
- Detects target replacement or identity changes during the operation
- Shows write and verification progress
- Verifies the written media byte-for-byte
- Places the target in read-only mode during verification
- Restores the target's original read-only state when the script exits
- Reports write, verification, and total elapsed times
- Appends pass or fail results to `/var/log/write-verify-usb.log`

## Installation

Clone the repository and make the script executable:

```bash
git clone <repository-url>
cd <repository-directory>
chmod +x tools/write-verify-usb-image.sh
```

The script uses standard Ubuntu command-line tools and `pv`. If `pv` is not installed, the script installs it with APT before a real write or verification operation.

## Usage

```text
write-verify-usb-image.sh --list
write-verify-usb-image.sh [--yes] [--dry-run] /dev/sdX /path/to/image.iso
write-verify-usb-image.sh --verify-only /dev/sdX /path/to/image.iso
```

Run the script from the repository root as:

```bash
./tools/write-verify-usb-image.sh [options] /dev/sdX /path/to/image.iso
```

The script invokes `sudo` for operations that require elevated privileges. It is normally run as the current user rather than by placing `sudo` before the entire command.

## List USB Drives

Before writing an image, list the whole-disk USB devices detected by Linux:

```bash
./tools/write-verify-usb-image.sh --list
```

Example:

```text
DEVICE         SIZE       TRAN   RM   MODEL
-------------- ---------- ------ ---- -----
/dev/sda       231.1G     usb    1    USB Flash Disk
```

Only whole USB disks are shown. Partitions such as `/dev/sda1` are not valid targets.

## Write and Verify an Image

```bash
./tools/write-verify-usb-image.sh \
    /dev/sda \
    ~/Downloads/jetsoninstaller.iso
```

Before writing, the script displays the target device, source image, image size, source disk, and captured target identity.

The confirmation prompt requires the complete target path:

```text
WARNING: This will erase all data on /dev/sda.
Type the full device path (/dev/sda) to continue:
```

Type the displayed path exactly to begin the operation.

During normal operation, the script:

1. Validates the platform, image, and target device.
2. Rejects protected or unsuitable disks.
3. Unmounts filesystems on the target.
4. Revalidates the target identity.
5. Writes the source image to the target device.
6. Flushes pending writes and target buffers.
7. Revalidates the target identity again.
8. Sets the target read-only.
9. Reads back and compares the image-sized region.
10. Reports timing and appends the result to the log.

After a successful operation, remove the USB drive safely and reconnect it before use.

## Dry Run

Use `--dry-run` to validate the command and display the actions that would be taken without modifying the target:

```bash
./tools/write-verify-usb-image.sh --dry-run \
    /dev/sda \
    ~/Downloads/jetsoninstaller.iso
```

Dry-run mode does not:

- unmount the target;
- write the image;
- verify the media;
- install `pv`;
- append a log entry.

It still performs read-only validation and device inspection.

## Verify Existing Media

Use `--verify-only` to compare an existing USB device with an image without rewriting it:

```bash
./tools/write-verify-usb-image.sh --verify-only \
    /dev/sda \
    ~/Downloads/jetsoninstaller.iso
```

The target is unmounted, flushed, placed in read-only mode for the comparison, and restored to its original read-only state when the script exits.

Verification compares only the first number of bytes equal to the source image size. Unused space after the written image is ignored.

## Skip the Confirmation Prompt

Use `--yes` to skip the script's destructive confirmation prompt:

```bash
./tools/write-verify-usb-image.sh --yes \
    /dev/sda \
    ~/Downloads/jetsoninstaller.iso
```

Use this option only in a controlled environment. It does not suppress password prompts or other interactions produced by `sudo` or APT.

## Options

| Option | Description |
|---|---|
| `-l`, `--list` | List available whole-disk USB devices. |
| `-y`, `--yes` | Skip the destructive confirmation prompt. |
| `-n`, `--dry-run` | Validate and describe the operation without modifying anything. |
| `--verify-only` | Verify existing media without writing it first. |
| `--version` | Display the script version. |
| `-h`, `--help` | Display command help. |

## Verification Results

A successful comparison reports:

```text
VERIFICATION PASSED
```

This means that the image-sized portion of the USB device matched the source image during the readback pass.

It does not guarantee:

- future reliability of the USB drive;
- absence of counterfeit capacity outside the compared region;
- successful operation of the installer;
- compatibility between the image and the target Jetson system.

A mismatch reports:

```text
VERIFICATION FAILED
```

The script exits with a nonzero status when verification fails.

## Logging

Results are appended to:

```text
/var/log/write-verify-usb.log
```

Each record includes:

- timestamp;
- pass or fail result;
- source image path and size;
- target device;
- captured target identity;
- operation mode;
- write time, when applicable;
- verification time.

A logging failure produces a warning. It does not change a successful imaging result into a failed one.

## Troubleshooting

### Target is rejected as a partition

Supply the whole disk rather than one of its partitions:

```text
Correct:   /dev/sda
Incorrect: /dev/sda1
```

### Target is not reported as USB

The tool requires `lsblk` to report the target with `TRAN=usb`. Some unusual adapters or enclosures may not expose transport information correctly and will be rejected.

Inspect the device with:

```bash
lsblk -dnpo NAME,SIZE,MODEL,TRAN,RM,SERIAL
```

### A target filesystem cannot be unmounted

Close file managers, terminals, and applications using files on the USB drive, then retry.

Useful commands include:

```bash
findmnt
lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS
```

### Verification fails or the USB device disconnects

Inspect recent kernel messages for USB resets, disconnects, or I/O errors:

```bash
sudo dmesg --ctime | grep -iE 'usb|uas|reset|disconnect|I/O error|buffer error|medium error'
```

A verification failure may indicate:

- a failing USB drive;
- a poor USB connection;
- an unstable adapter or hub;
- a source image that changed after writing;
- media that does not contain the expected image.

### `pv` installation fails

Install it manually and rerun the command:

```bash
sudo apt-get update
sudo apt-get install pv
```

## Known Limitations

- The target must be reported as a whole USB disk.
- Complex multidisk RAID, LVM, and device-mapper graphs are outside the supported scope.
- Active swap on the target is not explicitly detected.
- The script does not prove that no process has opened the block device directly.
- Only the disk backing `/` is explicitly protected as a system disk.
- The script does not validate the downloaded source image against a published checksum.
- A genuine hardware read error may sometimes be reported as a comparison mismatch.

See [DESIGN.md](DESIGN.md) for the safety model, implementation decisions, testing strategy, and additional limitations.

## License

This tool is distributed under the license provided at the repository root, MIT.
