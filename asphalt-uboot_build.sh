#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REFERENCE=${NIXOS_ANDROID_DEVICES:-"$SCRIPT_DIR/nixos-android-devices"}
OUTPUT_DIR=${UBOOT_OUTPUT_DIR:-"$SCRIPT_DIR/build/uboot"}

for tool in nix python3 dpkg-deb sha256sum fdtget; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "Missing required tool: $tool" >&2
        exit 1
    }
done

if [[ ! -f "$REFERENCE/flake.nix" || ! -f "$REFERENCE/tests/asphalt-uboot.py" ]]; then
    echo "Reference checkout not found or incomplete: $REFERENCE" >&2
    echo "Set NIXOS_ANDROID_DEVICES to the nixos-android-devices checkout." >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
IMAGE_LINK="$OUTPUT_DIR/result-image"
FIRMWARE_LINK="$OUTPUT_DIR/result-firmware"

nix build "$REFERENCE#devices.asphalt.u-boot" --builders '' --out-link "$IMAGE_LINK"
nix build "$REFERENCE#devices.asphalt.u-boot.firmware" --builders '' --out-link "$FIRMWARE_LINK"

IMAGE=$(readlink -f "$IMAGE_LINK")
FIRMWARE=$(readlink -f "$FIRMWARE_LINK")
python3 "$REFERENCE/tests/asphalt-uboot.py" "$FIRMWARE" "$IMAGE"

PACKAGE_ROOT=$(mktemp -d "$OUTPUT_DIR/package.XXXXXXXX")
trap 'rm -rf "$PACKAGE_ROOT"' EXIT
install -Dm0644 "$SCRIPT_DIR/uboot-lenovo-asphalt/DEBIAN/control" \
    "$PACKAGE_ROOT/DEBIAN/control"
install -Dm0644 "$IMAGE" \
    "$PACKAGE_ROOT/usr/share/uboot-lenovo-asphalt/boot_asphalt_uboot.img"

dpkg-deb --build --root-owner-group \
    "$PACKAGE_ROOT" \
    "$OUTPUT_DIR/uboot-lenovo-asphalt_2026.10~rc5_arm64.deb"

install -Dm0644 "$IMAGE" "$OUTPUT_DIR/boot_asphalt_uboot.img"
sha256sum "$OUTPUT_DIR/boot_asphalt_uboot.img" \
    "$OUTPUT_DIR/uboot-lenovo-asphalt_2026.10~rc5_arm64.deb" \
    | tee "$OUTPUT_DIR/SHA256SUMS"
echo "U-Boot image and Debian package are in: $OUTPUT_DIR"