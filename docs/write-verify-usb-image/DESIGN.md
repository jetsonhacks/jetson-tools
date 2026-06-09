# Design

## Purpose

`write-verify-usb-image.sh` creates bootable USB installation media from a disk image and verifies the result byte-for-byte.

The immediate use case is creating JetPack installation media directly on an NVIDIA Jetson system without relying on another computer or on Balena Etcher, which is not currently available as a native ARM64 application for this workflow.

The tool combines image writing and verification into one operation so that users do not need to write the image with one application and verify it separately from the command line.

## Supported Platform

The supported environment is:

- NVIDIA Jetson platform
- Ubuntu 22.04 or later
- Bash
- util-linux 2.37 or later
- APT package management
- USB mass-storage target devices reported by Linux with `TRAN=usb`

The implementation may work on other Linux systems, but those environments are outside the supported scope.

## Design Goals

The tool is designed to:

1. Write a raw disk image to a USB storage device.
2. Verify the written media by reading it back and comparing it byte-for-byte with the source image.
3. Provide useful progress information during both writing and verification.
4. Protect the root disk, the image source disk, and non-USB block devices.
5. Make destructive actions explicit and difficult to trigger accidentally.
6. Detect target-device replacement or renaming during the operation.
7. Restore the target device's original read-only state when the script exits.
8. Provide clear results, timings, and a persistent log entry.
9. Work entirely on the Jetson without requiring a second host computer.

## Non-Goals

The tool is not intended to:

- Format a USB drive before writing.
- Copy an ISO file into an existing filesystem.
- Manage arbitrary RAID, multidisk LVM, or complex device-mapper configurations.
- Support all Linux distributions.
- Replace a general-purpose disk-management application.
- Repair failing or counterfeit flash media.
- Verify files inside the image individually.
- Resize the image or expand filesystems after writing.
- Select a USB drive automatically without explicit user input.

## Why the Drive Is Not Formatted First

The source image is written as a raw whole-disk image.

A bootable ISO or disk image may already contain:

- a partition table;
- boot records;
- an EFI system partition;
- one or more filesystems;
- installer files and metadata.

The operation copies the image byte-for-byte starting at the beginning of the target disk. Any existing partition table or filesystem metadata on the USB drive is overwritten by the image.

Formatting the drive before writing would add work without changing the final result.

## Command-Line Interface

The primary interface is:

```text
write-verify-usb-image.sh [--yes] [--dry-run] /dev/sdX /path/to/image.iso
```

Additional modes are:

```text
write-verify-usb-image.sh --list
write-verify-usb-image.sh --verify-only /dev/sdX /path/to/image.iso
write-verify-usb-image.sh --version
write-verify-usb-image.sh --help
```

### Default Mode

Default mode writes the image and then verifies it.

### List Mode

`--list` shows whole-disk USB devices detected by `lsblk`.

The listing is informational. The user must still explicitly supply a target device.

### Verify-Only Mode

`--verify-only` skips the write phase and compares an existing USB device with the supplied image.

The target is still unmounted, flushed, placed in read-only mode during verification, and restored to its original read-only state at exit.

### Dry-Run Mode

`--dry-run` performs validation and reports the actions that would be taken without:

- unmounting the target;
- writing the image;
- verifying the media;
- installing `pv`;
- appending a log entry.

### Noninteractive Confirmation

`--yes` skips the destructive confirmation prompt.

It is intended for controlled automation. The default behavior remains interactive.

## Operation Flow

The normal write-and-verify flow is:

1. Parse command-line options.
2. Confirm the supported Ubuntu and util-linux versions.
3. Validate required commands.
4. Canonicalize and validate the source image and target path.
5. Confirm that the target is a whole USB disk.
6. Protect the root disk.
7. Protect the disk containing the source image.
8. Confirm that the target is large enough.
9. Display source and target information.
10. Capture the target identity.
11. Unmount target filesystems.
12. Capture and preserve the target's original read-only state.
13. Require destructive confirmation.
14. Revalidate target identity.
15. Write the image with progress.
16. Flush pending writes and target buffers.
17. Revalidate target identity.
18. Set the target read-only.
19. Read back and compare the image-sized region.
20. Restore the target's original read-only state on exit.
21. Report phase and total timings.
22. Append a result to the log.
23. Instruct the user to remove and reconnect the completed media.

## Safety Model

Writing a raw image is destructive. Safety checks are therefore a primary design concern rather than an optional convenience.

### Whole-Disk Requirement

The target must have block type `disk`.

Partitions such as `/dev/sda1` are rejected. The image must be written to the whole device, such as `/dev/sda`.

### USB-Only Requirement

The target must be reported by `lsblk` with:

```text
TRAN=usb
```

This prevents accidental selection of normal NVMe, SATA, eMMC, or other non-USB storage.

The restriction is deliberate. The current tool is intended for USB installation media, not arbitrary disk imaging.

### Root-Disk Protection

The script identifies the block device backing `/`, follows its parent device chain, and rejects the target if it resolves to the same disk.

This is intended to prevent overwriting the running Jetson system.

### Source-Disk Protection

The script identifies the disk containing the source image and rejects the operation if the source image resides on the target disk.

The source disk remains mounted because the image must remain readable throughout the operation.

### Capacity Check

The source image size must be greater than zero and no larger than the target device.

### Destructive Confirmation

Before writing, the script displays the target and requires the user to type the full device path exactly.

For example:

```text
Type the full device path (/dev/sda) to continue:
```

A generic `y` confirmation is intentionally not used because it provides less protection against acting on the wrong disk.

### Device Identity Revalidation

Linux device names such as `/dev/sda` can be reused after disconnects.

The script captures a target identity composed of:

- major and minor device number;
- serial number;
- model;
- size.

It revalidates this identity immediately before writing and again immediately before verification.

If the identity changes, the script stops rather than continuing against a potentially different device.

### Read-Only Verification

Before verification, the target is placed into kernel-enforced read-only mode with `blockdev --setro`.

This prevents accidental writes during the comparison phase, including writes introduced by future script changes or unrelated processes.

The original read-only state is captured once and restored by an `EXIT` trap.

### Signal Handling

`INT` and `TERM` are converted to explicit exit codes. Cleanup occurs through the `EXIT` trap so the target's access state is restored consistently.

## Dependency Handling

The script uses standard Ubuntu utilities and `pv`.

`pv` provides progress, elapsed time, transfer rate, percentage, and ETA.

If `pv` is not installed, the script installs it using APT before beginning a real write or verification operation.

Dry-run mode reports that installation would occur but does not modify the system.

## Write Path

The image is streamed through `pv` into `dd`:

```text
image file -> pv -> dd -> USB block device
```

`pv` provides the user-visible progress display.

`dd` performs the raw block-device write.

### Direct I/O

When the image size is aligned to the target's logical sector size, the write uses:

```text
iflag=fullblock
oflag=direct
conv=fsync
```

`oflag=direct` reduces the misleading effect of the Linux page cache. Progress therefore more closely tracks data being accepted by the storage device rather than data merely copied into system memory.

`iflag=fullblock` is used because `dd` reads from a pipe. Pipe reads may be shorter than the requested block size, and direct I/O has alignment requirements.

`conv=fsync` requests that output data be synchronized before `dd` reports completion.

### Unaligned Images

If the image size is not a multiple of the target's logical sector size, direct I/O may fail on the final partial block.

In that case, the script falls back to:

```text
iflag=fullblock
oflag=dsync
conv=fsync
```

This favors correctness and compatibility over maximum write speed.

## Flush and Cache Handling

After writing, the script performs:

1. `sync`
2. `blockdev --flushbufs` on the target
3. `udevadm settle`

The source disk is not separately flushed because it is only being read.

The flush sequence ensures that pending host-side writes have been committed before verification begins. It does not assume that a completed high-level write automatically proves that the flash media contains the expected data.

## Verification Path

Verification reads exactly the number of bytes contained in the source image:

```text
USB block device -> dd -> pv -> cmp <- image file
```

The comparison ignores unused space after the image-sized region.

A successful verification means every compared byte matches.

### Comparison Result Handling

`cmp` exits immediately when it finds a mismatch. That closes the pipeline and may cause upstream `pv` and `dd` processes to receive `SIGPIPE`.

For this reason, the script interprets the `cmp` status first:

- `0`: compared data matches;
- `1`: verification mismatch;
- other: comparison error.

Only after a clean match does the script require successful `dd` and `pv` statuses.

This ordering prevents an ordinary mismatch from being incorrectly reported as a USB read failure.

### Verification Guarantees

A passing result establishes that the image-sized portion of the USB device matched the source image during the readback pass.

It does not guarantee:

- future reliability of the flash drive;
- absence of counterfeit capacity beyond the image region;
- correct operation of the Jetson installer;
- firmware compatibility;
- stable USB operation under all hardware conditions.

## Progress and Timing

Both phases show:

- bytes transferred;
- percentage complete;
- elapsed phase time;
- transfer rate;
- estimated time remaining.

The script records:

- write time;
- verification time;
- total imaging time.

Operational timing begins after destructive confirmation so user decision time is not included.

The imaging total includes write, flush, state changes, and verification.

## Error Handling

The script uses:

```bash
set -Eeuo pipefail
```

Pipeline exit statuses are captured explicitly where multiple processes participate in an operation.

Failures are distinguished where practical:

- invalid or unsupported platform;
- missing command;
- invalid target;
- protected root or source disk;
- insufficient target capacity;
- target identity change;
- unmount failure;
- write-pipeline failure;
- comparison mismatch;
- comparison error;
- incomplete read;
- progress-pipeline failure;
- log-write failure.

A verification mismatch returns a nonzero result and is logged as failed.

A logging failure is secondary. It produces a warning but does not change a successful imaging result into a failed one.

## Logging

The script appends a timestamped result to:

```text
/var/log/write-verify-usb.log
```

Each record includes:

- pass or fail result;
- image path and size;
- target device path;
- captured target identity;
- operation mode;
- write time when applicable;
- verification time.

Logging uses `sudo` because the destination is under `/var/log`.

Failure to append the log is reported as a warning.

## Known Limitations

### Complex Storage Topologies

Root- and source-disk protection follows a single parent-device chain.

This covers common Jetson configurations, including ordinary partitions and simple encrypted or LVM layouts. It is not intended to fully model:

- multidisk RAID;
- LVM volumes spanning several physical disks;
- complex device-mapper graphs.

### Active Swap

The current design does not explicitly reject a USB target containing active swap.

A future hardening pass may inspect `swapon --show` before writing.

### Direct Block-Device Users

Unmounting filesystems does not prove that no process has the block device open directly.

A future version may use `fuser`, `lsof`, or `/proc` inspection to detect direct users, provided false positives can be handled clearly.

### Additional System Mounts

The script explicitly protects the disk backing `/`.

Future hardening may also protect independently backed system paths such as `/boot` and `/boot/efi`.

### Diagnostic Precision During Read Failure

A genuine target read error may appear to `cmp` as an early mismatch or early end-of-file condition.

The operation still fails safely, but the message may describe a mismatch rather than identify the lower-level USB read error.

Kernel logs should be consulted when hardware failure is suspected:

```bash
sudo dmesg --ctime | grep -iE   'usb|uas|reset|disconnect|I/O error|buffer error|medium error'
```

### USB Enumeration

The USB transport check depends on `lsblk` reporting `TRAN=usb`.

Some unusual bridges or enclosures may not report transport information as expected and will be rejected.

## Testing Strategy

The script should be tested at two levels.

### Physical Media Tests

Physical USB tests validate:

- realistic write and read rates;
- direct-I/O behavior;
- USB-controller compatibility;
- device flush behavior;
- disconnect and reset handling;
- readback verification.

At least one known-good and one intentionally corrupted image should be tested.

### Automated Tests

Loop devices and command mocks can cover:

- aligned direct-I/O flag selection;
- unaligned synchronous-I/O fallback;
- successful comparison;
- mismatch with upstream `SIGPIPE`;
- genuine read failure;
- write failure;
- target identity change;
- verify-only access-state restoration;
- logging failure;
- dry-run behavior;
- missing dependency behavior;
- capacity rejection;
- protected-disk rejection.

Automated tests are increasingly important because the script contains multiple modes, cleanup paths, and pipeline-status interactions.

## Future Considerations

Potential future improvements include:

- active-swap detection;
- direct block-device usage checks;
- protection for `/boot` and `/boot/efi`;
- more precise distinction between mismatch and hardware read failure;
- optional dependency-install confirmation;
- log-path configuration;
- checksum validation of the downloaded source image;
- shell test coverage using Bats or an equivalent framework;
- a graphical front end that preserves the same safety model.

The current design should remain focused on the Jetson USB-image workflow. Generalizing the utility to arbitrary Linux storage environments should not take priority over clarity, safety, and reliable behavior on supported Jetson systems.
