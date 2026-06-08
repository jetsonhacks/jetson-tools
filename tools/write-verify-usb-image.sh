#!/usr/bin/env bash
set -Eeuo pipefail

PROGRAM_NAME=${0##*/}
VERSION="0.4.3"

LOG_FILE="/var/log/write-verify-usb.log"
MIN_UBUNTU_VERSION="22.04"
MIN_UTIL_LINUX_VERSION="2.37"

READ_ONLY_DRIVE=
ORIGINAL_READ_ONLY=
WRITE_SECONDS=0
VERIFY_SECONDS=0

# Captured at validation time; rechecked before write and before verify.
DRIVE_IDENTITY=

# Populated by set_dd_write_flags(); consumed by write_image().
DD_WRITE_FLAGS=()

usage() {
    cat <<EOF
Usage:
  $PROGRAM_NAME --list
  $PROGRAM_NAME [--yes] [--dry-run] /dev/sdX /path/to/image.iso
  $PROGRAM_NAME --verify-only /dev/sdX /path/to/image.iso

Options:
  -l, --list          List available whole-disk USB drives.
  -y, --yes           Skip the destructive confirmation prompt.
  -n, --dry-run       Show what would happen without writing anything.
      --verify-only   Verify an existing USB image without writing it.
      --version       Show program version.
  -h, --help          Show this help.

Default operation:
  1.  Validate Ubuntu >= $MIN_UBUNTU_VERSION and util-linux >= $MIN_UTIL_LINUX_VERSION.
  2.  Validate that the target is a whole USB disk.
  3.  Refuse the root disk and the disk containing the image.
  4.  Capture target device identity (MAJ:MIN, serial, model, size).
  5.  Unmount target filesystems.
  6.  Revalidate target identity immediately before writing.
  7.  Write the image with dd and show write progress.
  8.  Flush pending writes.
  9.  Revalidate target identity immediately before verification.
  10. Set the target disk read-only.
  11. Read back and compare the image-sized portion with progress.
  12. Report write, verification, and imaging elapsed times.
  13. Append a timestamped result entry to $LOG_FILE.
  14. Prompt to safely remove and reconnect the USB drive.

WARNING: The default operation destroys all existing data on the target disk.
EOF
}

die() {
    printf '\nERROR: %s\n' "$*" >&2
    exit 1
}

info() {
    printf '%s\n' "$*"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 ||
        die "Required command not found: $1"
}

format_duration() {
    local seconds=$1
    printf '%02d:%02d:%02d' \
        $((seconds / 3600)) \
        $(((seconds % 3600) / 60)) \
        $((seconds % 60))
}

canonical_block_device() {
    readlink -f -- "$1"
}

check_platform() {
    local os_id os_version_id util_linux_version
    local os_major os_minor min_major min_minor
    local ul_major ul_minor ul_patch min_ul_major min_ul_minor

    if [[ ! -f /etc/os-release ]]; then
        die "Cannot read /etc/os-release. This script requires Ubuntu $MIN_UBUNTU_VERSION or later."
    fi

    # shellcheck source=/dev/null
    source /etc/os-release
    os_id=${ID:-}
    os_version_id=${VERSION_ID:-}

    [[ "$os_id" == "ubuntu" ]] ||
        die "This script requires Ubuntu. Detected: ${os_id:-unknown}"

    IFS='.' read -r os_major os_minor _ <<< "$os_version_id"
    IFS='.' read -r min_major min_minor _ <<< "$MIN_UBUNTU_VERSION"

    if (( os_major < min_major )) ||
       { (( os_major == min_major )) && (( os_minor < min_minor )); }; then
        die "Ubuntu $MIN_UBUNTU_VERSION or later is required. Detected: $os_version_id"
    fi

    util_linux_version=$(lsblk --version 2>/dev/null | awk '{print $NF}') ||
        die "Could not determine util-linux version."

    IFS='.' read -r ul_major ul_minor ul_patch <<< "$util_linux_version"
    IFS='.' read -r min_ul_major min_ul_minor _ <<< "$MIN_UTIL_LINUX_VERSION"
    ul_patch=${ul_patch:-0}

    if (( ul_major < min_ul_major )) ||
       { (( ul_major == min_ul_major )) && (( ul_minor < min_ul_minor )); }; then
        die "util-linux $MIN_UTIL_LINUX_VERSION or later is required. Detected: $util_linux_version"
    fi
}

capture_drive_identity() {
    local drive=$1
    # Collect MAJ:MIN, serial, model, and size into a single string.
    # MAJ:MIN is stable within a kernel session; serial+model+size
    # provide physical identity across reconnects.
    DRIVE_IDENTITY=$(lsblk -dnro MAJ:MIN,SERIAL,MODEL,SIZE "$drive" 2>/dev/null) ||
        die "Could not capture identity of $drive."
    [[ -n "$DRIVE_IDENTITY" ]] ||
        die "Identity of $drive is empty; the device may have disappeared."
}

assert_drive_identity() {
    local drive=$1
    local context=$2   # "before write" or "before verification"
    local current_identity

    current_identity=$(lsblk -dnro MAJ:MIN,SERIAL,MODEL,SIZE "$drive" 2>/dev/null) ||
        die "Could not read identity of $drive $context. The device may have been removed."

    [[ "$current_identity" == "$DRIVE_IDENTITY" ]] ||
        die "Target device identity changed $context.
  Expected: $DRIVE_IDENTITY
  Found:    $current_identity
  Refusing to continue. Check that the correct drive is still connected."
}

parent_disk_for_device() {
    local device=$1
    local type pkname

    device=$(canonical_block_device "$device")
    type=$(lsblk -ndo TYPE "$device" 2>/dev/null || true)

    case "$type" in
        disk)
            printf '%s\n' "$device"
            ;;
        part)
            pkname=$(lsblk -ndo PKNAME "$device" 2>/dev/null || true)
            [[ -n "$pkname" ]] || return 1
            printf '/dev/%s\n' "$pkname"
            ;;
        crypt|lvm|raid*|md)
            pkname=$(lsblk -ndo PKNAME "$device" 2>/dev/null || true)
            [[ -n "$pkname" ]] || return 1
            parent_disk_for_device "/dev/$pkname"
            ;;
        *)
            return 1
            ;;
    esac
}

backing_disk_for_path() {
    local path=$1
    local source

    source=$(findmnt -T "$path" -n -o SOURCE 2>/dev/null || true)
    [[ -n "$source" && -b "$source" ]] || return 1

    parent_disk_for_device "$source"
}

install_pv_if_needed() {
    if command -v pv >/dev/null 2>&1; then
        return
    fi

    require_command apt-get
    info "'pv' is required for progress display."
    info "Installing pv..."
    sudo apt-get update -qq
    sudo apt-get install -y pv
}

list_usb_drives() {
    local found=0
    printf '%-14s %-10s %-6s %-4s %s\n' \
        "DEVICE" "SIZE" "TRAN" "RM" "MODEL"
    printf '%-14s %-10s %-6s %-4s %s\n' \
        "--------------" "----------" "------" "----" "-----"

    while IFS= read -r device; do
        local type tran size rm model

        type=$(lsblk -ndo TYPE "$device" 2>/dev/null || true)
        tran=$(lsblk -ndo TRAN "$device" 2>/dev/null || true)
        [[ "$type" == "disk" && "$tran" == "usb" ]] || continue

        size=$(lsblk -ndo SIZE "$device")
        rm=$(lsblk -ndo RM "$device")
        model=$(lsblk -ndo MODEL "$device" | sed 's/[[:space:]]*$//')

        printf '%-14s %-10s %-6s %-4s %s\n' \
            "$device" "$size" "$tran" "$rm" "$model"
        found=1
    done < <(lsblk -dpno NAME)

    if (( found == 0 )); then
        info "No whole-disk USB drives were found."
    fi
}

unmount_target_filesystems() {
    local drive=$1
    local mountpoint
    local -a mountpoints=()

    mapfile -t mountpoints < <(
        lsblk -lnpo MOUNTPOINTS "$drive" |
            awk 'NF' |
            sort -r
    )

    if (( ${#mountpoints[@]} == 0 )); then
        return
    fi

    info "Unmounting filesystems on $drive..."
    for mountpoint in "${mountpoints[@]}"; do
        sudo umount -- "$mountpoint" ||
            die "Could not unmount $mountpoint"
    done

    # Settle udev and give udisks2 a moment to observe the unmounts,
    # reducing the window in which it might automount a partition.
    sudo udevadm settle
}

restore_target_access() {
    if [[ -z "${READ_ONLY_DRIVE:-}" || -z "${ORIGINAL_READ_ONLY:-}" ]]; then
        return
    fi

    if [[ "$ORIGINAL_READ_ONLY" == "1" ]]; then
        sudo blockdev --setro "$READ_ONLY_DRIVE" 2>/dev/null || true
    else
        sudo blockdev --setrw "$READ_ONLY_DRIVE" 2>/dev/null || true
    fi
}

# Route signals through explicit exits so the EXIT trap fires exactly once
# and the process exits with a meaningful code.
trap restore_target_access EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

capture_target_access_state() {
    local drive=$1

    # Record the drive's original read-only state exactly once, regardless
    # of whether we are writing or only verifying. This guarantees the EXIT
    # trap can restore the drive in both --verify-only and normal modes.
    if [[ -z "$READ_ONLY_DRIVE" ]]; then
        READ_ONLY_DRIVE=$drive
        ORIGINAL_READ_ONLY=$(sudo blockdev --getro "$drive")
    fi
}

set_target_writable() {
    local drive=$1

    capture_target_access_state "$drive"

    if [[ "$(sudo blockdev --getro "$drive")" == "1" ]]; then
        info "Setting target disk writable for image creation..."
        sudo blockdev --setrw "$drive"
    fi

    [[ "$(sudo blockdev --getro "$drive")" == "0" ]] ||
        die "Target disk is read-only and could not be made writable."
}

set_target_read_only() {
    local drive=$1

    capture_target_access_state "$drive"

    info "Setting target disk read-only for verification..."
    sudo blockdev --setro "$drive"

    [[ "$(sudo blockdev --getro "$drive")" == "1" ]] ||
        die "Could not place the target disk in read-only mode."
}

confirm_destructive_write() {
    local drive=$1
    local answer

    printf '\n'
    printf 'WARNING: This will erase all data on %s.\n' "$drive"
    printf 'Type the full device path (%s) to continue: ' "$drive"
    read -r answer

    [[ "$answer" == "$drive" ]] ||
        die "Confirmation did not match. No data was written."
}

set_dd_write_flags() {
    local drive=$1
    local image_size=$2
    local sector_size

    sector_size=$(sudo blockdev --getss "$drive") ||
        die "Could not determine logical sector size of $drive."

    if (( image_size % sector_size == 0 )); then
        DD_WRITE_FLAGS=(iflag=fullblock oflag=direct conv=fsync)
    else
        # Image size is not a multiple of the sector size; direct I/O
        # would fail on the final partial block. Fall back to dsync.
        info "Note: image size is not aligned to sector size ($sector_size bytes)."
        info "Using synchronous I/O instead of direct I/O for the write."
        DD_WRITE_FLAGS=(iflag=fullblock oflag=dsync conv=fsync)
    fi
}

write_image() {
    local drive=$1
    local image=$2
    local image_size=$3
    local write_start write_end
    local pv_status dd_status
    local -a pipeline_status

    set_dd_write_flags "$drive" "$image_size"

    info
    info "Writing $(basename "$image") to $drive..."
    info "Progress reflects data written to disk."
    info

    write_start=$(date +%s)

    set +e
    pv \
        --size "$image_size" \
        --progress \
        --timer \
        --eta \
        --rate \
        --bytes \
        "$image" |
        sudo dd \
            of="$drive" \
            bs=4M \
            "${DD_WRITE_FLAGS[@]}" \
            status=none
    pipeline_status=("${PIPESTATUS[@]}")
    set -e

    write_end=$(date +%s)
    WRITE_SECONDS=$((write_end - write_start))

    pv_status=${pipeline_status[0]}
    dd_status=${pipeline_status[1]}

    (( pv_status == 0 )) ||
        die "Image read/progress pipeline failed after $(format_duration "$WRITE_SECONDS")."

    (( dd_status == 0 )) ||
        die "Image write failed after $(format_duration "$WRITE_SECONDS")."

    info
    info "Write completed in $(format_duration "$WRITE_SECONDS")."
}

flush_before_verification() {
    local drive=$1

    info
    info "Flushing pending writes..."
    sync

    info "Flushing target disk buffers: $drive"
    sudo blockdev --flushbufs "$drive"
    sudo udevadm settle
}

verify_image() {
    local drive=$1
    local image=$2
    local image_size=$3
    local verify_start verify_end
    local dd_status pv_status cmp_status
    local -a pipeline_status

    set_target_read_only "$drive"

    info "Verifying $(basename "$image") against $drive..."
    info

    verify_start=$(date +%s)

    set +e
    sudo dd \
        if="$drive" \
        bs=4M \
        count="$image_size" \
        iflag=count_bytes,fullblock \
        status=none |
        pv \
            --size "$image_size" \
            --progress \
            --timer \
            --eta \
            --rate \
            --bytes |
        cmp -- - "$image"
    pipeline_status=("${PIPESTATUS[@]}")
    set -e

    verify_end=$(date +%s)
    VERIFY_SECONDS=$((verify_end - verify_start))

    dd_status=${pipeline_status[0]}
    pv_status=${pipeline_status[1]}
    cmp_status=${pipeline_status[2]}

    info

    # Interpret cmp first. When cmp finds a mismatch it exits immediately,
    # which sends SIGPIPE to pv and dd. Their nonzero statuses in that case
    # reflect the broken pipe, not a read failure — so dd_status and
    # pv_status are only meaningful after confirming cmp saw a clean match.
    case "$cmp_status" in
        0)
            ;;
        1)
            printf '\nVERIFICATION FAILED\n' >&2
            printf 'The USB drive does not exactly match the image file.\n' >&2
            printf 'Verification elapsed time: %s\n' \
                "$(format_duration "$VERIFY_SECONDS")" >&2
            return 1
            ;;
        *)
            die "Comparison could not be completed."
            ;;
    esac

    # cmp reported a clean match; now confirm the upstream pipeline delivered
    # a complete read. A truncated stream where cmp happened to match would
    # show up here as a nonzero dd_status.
    (( dd_status == 0 )) ||
        die "The USB drive could not be read completely."

    (( pv_status == 0 )) ||
        die "The verification progress pipeline failed."

    printf '\nVERIFICATION PASSED\n'
    printf 'The first %s bytes of %s exactly match %s.\n' \
        "$image_size" "$drive" "$image"
    printf 'Verification completed in %s.\n' \
        "$(format_duration "$VERIFY_SECONDS")"
}

append_log() {
    local result=$1
    local drive=$2
    local image=$3
    local image_size=$4
    local verify_only=$5

    local timestamp mode
    timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
    if (( verify_only == 1 )); then
        mode="verify-only"
    else
        mode="write+verify"
    fi

    local log_status

    set +e
    {
        printf '[%s] %s\n' "$timestamp" "$result"
        printf '  image:        %s (%s bytes)\n' "$image" "$image_size"
        printf '  device:       %s\n' "$drive"
        printf '  identity:     %s\n' "$DRIVE_IDENTITY"
        printf '  mode:         %s\n' "$mode"
        if (( verify_only == 0 )); then
            printf '  write time:   %s\n' "$(format_duration "$WRITE_SECONDS")"
        fi
        printf '  verify time:  %s\n' "$(format_duration "$VERIFY_SECONDS")"
    } | sudo tee -a "$LOG_FILE" >/dev/null
    log_status=${PIPESTATUS[1]}
    set -e

    (( log_status == 0 )) || return 1

    info
    info "Result appended to $LOG_FILE"
}

main() {
    local assume_yes=0
    local verify_only=0
    local dry_run=0
    local drive image drive_type drive_tran
    local root_source root_disk image_disk=
    local image_size device_size
    local imaging_start imaging_end imaging_seconds
    local verification_passed=0

    while (( $# > 0 )); do
        case "$1" in
            -l|--list)
                require_command lsblk
                list_usb_drives
                exit 0
                ;;
            -y|--yes)
                assume_yes=1
                shift
                ;;
            -n|--dry-run)
                dry_run=1
                shift
                ;;
            --verify-only)
                verify_only=1
                shift
                ;;
            --version)
                printf '%s %s\n' "$PROGRAM_NAME" "$VERSION"
                exit 0
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift
                break
                ;;
            -*)
                die "Unknown option: $1"
                ;;
            *)
                break
                ;;
        esac
    done

    (( $# == 2 )) || {
        usage >&2
        exit 2
    }

    drive=$(canonical_block_device "$1")
    image=$(readlink -f -- "$2")

    for cmd in \
        lsblk findmnt stat readlink awk sort sed sync dd cmp \
        blockdev udevadm date tee; do
        require_command "$cmd"
    done

    check_platform

    [[ -b "$drive" ]] || die "Not a block device: $drive"
    [[ -f "$image" ]] || die "Image file not found: $image"
    [[ -r "$image" ]] || die "Image file is not readable: $image"

    drive_type=$(lsblk -ndo TYPE "$drive" 2>/dev/null || true)
    [[ "$drive_type" == "disk" ]] ||
        die "Target must be a whole disk such as /dev/sdb, not a partition."

    drive_tran=$(lsblk -ndo TRAN "$drive" 2>/dev/null || true)
    [[ "$drive_tran" == "usb" ]] ||
        die "Target is not reported by Linux as a USB disk."

    root_source=$(findmnt / -n -o SOURCE)
    [[ -b "$root_source" ]] ||
        die "Could not determine the block device containing the root filesystem."

    root_disk=$(parent_disk_for_device "$root_source") ||
        die "Could not determine the disk containing the root filesystem."

    [[ "$drive" != "$(canonical_block_device "$root_disk")" ]] ||
        die "Refusing to use the disk containing the root filesystem."

    image_disk=$(backing_disk_for_path "$image" || true)
    if [[ -n "$image_disk" ]]; then
        [[ "$drive" != "$(canonical_block_device "$image_disk")" ]] ||
            die "Refusing to use the disk containing the image file."
    fi

    image_size=$(stat -Lc '%s' "$image")
    device_size=$(sudo blockdev --getsize64 "$drive")

    (( image_size > 0 )) || die "Image file is empty."
    (( device_size >= image_size )) ||
        die "USB drive is smaller than the image file."

    info "Target USB disk:"
    lsblk -dnpo NAME,SIZE,MODEL,TRAN,RM,SERIAL "$drive"

    info
    info "Image file: $image"
    info "Image size: $image_size bytes"

    if [[ -n "$image_disk" ]]; then
        info
        info "Image source disk (left mounted):"
        lsblk -dnpo NAME,SIZE,MODEL,TRAN,RM "$image_disk"
    else
        info
        info "Image source disk: not a local block device"
    fi

    # Capture device identity after all validations pass.
    capture_drive_identity "$drive"
    info
    info "Target identity: $DRIVE_IDENTITY"

    if (( dry_run == 1 )); then
        info
        info "DRY RUN — no data will be written or verified."
        if (( verify_only == 0 )); then
            info "Would write: $image → $drive"
        fi
        info "Would verify: first $image_size bytes of $drive against $image"
        info "Would append result to: $LOG_FILE"
        if ! command -v pv >/dev/null 2>&1; then
            info "Note: pv is not installed and would be installed before imaging."
        fi
        exit 0
    fi

    install_pv_if_needed

    unmount_target_filesystems "$drive"

    if (( verify_only == 0 )); then
        set_target_writable "$drive"

        if (( assume_yes == 0 )); then
            confirm_destructive_write "$drive"
        fi

        # Operational timing starts after confirmation.
        imaging_start=$(date +%s)

        assert_drive_identity "$drive" "before write"
        write_image "$drive" "$image" "$image_size"
    else
        imaging_start=$(date +%s)
        info
        info "Verify-only mode: no data will be written."
    fi

    flush_before_verification "$drive"

    assert_drive_identity "$drive" "before verification"
    if verify_image "$drive" "$image" "$image_size"; then
        verification_passed=1
    fi

    imaging_end=$(date +%s)
    imaging_seconds=$((imaging_end - imaging_start))

    info
    info "Timing summary:"
    if (( verify_only == 0 )); then
        printf '  Write:         %s\n' "$(format_duration "$WRITE_SECONDS")"
    fi
    printf '  Verification:  %s\n' "$(format_duration "$VERIFY_SECONDS")"
    printf '  Imaging total: %s\n' "$(format_duration "$imaging_seconds")"

    if (( verification_passed == 1 )); then
        if ! append_log "PASSED" "$drive" "$image" "$image_size" "$verify_only"; then
            printf 'WARNING: Imaging succeeded but the result could not be logged to %s.\n' \
                "$LOG_FILE" >&2
        fi
        printf '\nSafely remove the USB drive now, then reconnect it before use.\n'
    else
        if ! append_log "FAILED" "$drive" "$image" "$image_size" "$verify_only"; then
            printf 'WARNING: Verification failed and the result could not be logged to %s.\n' \
                "$LOG_FILE" >&2
        fi
        exit 1
    fi
}

main "$@"
