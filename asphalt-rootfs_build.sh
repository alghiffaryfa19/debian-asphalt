set -e

IMAGE_SIZE="8G"
FILESYSTEM_UUID="ee8d3593-59b1-480e-a3b6-4fefb17ee7d8"

if [ $# -lt 2 ]; then
    echo "Usage: $0 <distro-variant> <kernel>"
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root"
    exit 1
fi

DISTRO=$1
KERNEL=$2
USERNAME=$3
PASSWORD=$4

distro_type=$(echo "$DISTRO" | cut -d'-' -f1)
distro_variant=$(echo "$DISTRO" | cut -d'-' -f2)

if [ "$distro_type" != "debian" ]; then
    echo "Only debian supported"
    exit 1
fi

distro_version="trixie"

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# 🔥 MULTI FLAVOUR
FLAVOURS=("gnome-shell-mobile")
BOOTMODES=("dual")

for FLAVOUR in "${FLAVOURS[@]}"; do
for MODE in "${BOOTMODES[@]}"; do

echo ""
echo "======================================"
echo "🚀 BUILD: $FLAVOUR - $MODE"
echo "======================================"

ROOTFS_IMG="${distro_type}_${distro_version}_${FLAVOUR}_${MODE}_${TIMESTAMP}.img"

rm -rf rootdir || true

truncate -s $IMAGE_SIZE "$ROOTFS_IMG"
mkfs.ext4 "$ROOTFS_IMG"

mkdir rootdir
mount -o loop "$ROOTFS_IMG" rootdir

# bootstrap
debootstrap --arch=arm64 "$distro_version" rootdir http://deb.debian.org/debian/

# mount
mount --bind /dev rootdir/dev
mount --bind /dev/pts rootdir/dev/pts
mount -t proc proc rootdir/proc
mount -t sysfs sys rootdir/sys

# base packages
chroot rootdir apt update
chroot rootdir apt install -y \
    systemd sudo vim wget curl \
    network-manager openssh-server \
    wpasupplicant dbus \
    initramfs-tools zstd systemd-boot-efi

# Configure initramfs to use zstd (required by NixOS reference config)
sed -i 's/^COMPRESS=.*/COMPRESS=zstd/' rootdir/etc/initramfs-tools/initramfs.conf

echo "📦 Installing device-specific .deb packages..."

# Copy semua .deb ke rootfs
cp *.deb rootdir/tmp/

# Install dependency dulu (biar aman)
chroot rootdir apt install -y \
    libglib2.0-0 \
    libprotobuf-c1 \
    libqmi-glib5 \
    libmbim-glib4 || true

# Install satu per satu (biar gampang debug kalau gagal)
# debug
ls -lah rootdir/tmp/

chroot rootdir bash -c 'apt update && apt install -y --allow-downgrades -o Dpkg::Options::="--force-overwrite" /tmp/*.deb' || exit 1

# Force initramfs generation for installed kernel modules
echo "🛠️ Forcing initramfs generation..."
chroot rootdir bash -c 'for k in /lib/modules/*; do if [ -d "$k" ]; then update-initramfs -c -k $(basename $k) || true; fi; done'

echo "✅ All custom .deb installed"

# root password
chroot rootdir bash -c "echo -e '1234\n1234' | passwd root"

echo "lenovo-$FLAVOUR-$MODE" > rootdir/etc/hostname

# =========================
# 🖥️ DESKTOP
# =========================
if [ "$distro_variant" = "desktop" ]; then

    if [ "$FLAVOUR" = "plasma-mobile" ]; then
        chroot rootdir apt install -y \
            plasma-mobile konsole sddm firefox-esr

        chroot rootdir systemctl disable gdm3 2>/dev/null || true
        chroot rootdir systemctl enable sddm

    elif [ "$FLAVOUR" = "gnome-shell-mobile" ]; then
    
        cat > rootdir/etc/apt/sources.list.d/debian.sources <<EOF
Types: deb deb-src
URIs: http://deb.debian.org/debian
Suites: trixie trixie-updates
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb deb-src
URIs: http://security.debian.org/debian-security
Suites: trixie-security
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF

    : > rootdir/etc/apt/sources.list

        chroot rootdir apt update

        chroot rootdir apt-get build-dep -y gnome-shell mutter gnome-settings-daemon
        chroot rootdir apt install -y \
            gnome-shell gnome-session gnome-terminal gdm3 firefox-esr gnome-console

        wget https://github.com/alghiffaryfa19/gnome-shell-mobile-builder/releases/download/gnome-shell-48/gnome-shell-mobile.deb
        wget https://github.com/alghiffaryfa19/gnome-shell-mobile-builder/releases/download/mutter-48/mutter-mobile.deb
        wget https://github.com/alghiffaryfa19/gnome-shell-mobile-builder/releases/download/gsd-48/gsd-mobile.deb

        

        cp ./*.deb rootdir/tmp/
        chroot rootdir bash -c 'apt-get install -y --allow-downgrades -o Dpkg::Options::="--force-overwrite" /tmp/*.deb'
        
        chroot rootdir apt-mark hold gnome-shell mutter gnome-settings-daemon

        chroot rootdir systemctl enable gdm3

        git clone https://github.com/phildevprog/force-phone-mode.git rootdir/.local/share/gnome-shell/extensions/force-phone-mode@phildevprog.com
        chroot rootdir gnome-extensions enable force-phone-mode@phildevprog.com
        
    fi

    # user
    chroot rootdir useradd -m -s /bin/bash $USERNAME
    echo "$USERNAME:$PASSWORD" | chroot rootdir chpasswd
    chroot rootdir usermod -aG sudo $USERNAME

    # autologin
    if [ "$FLAVOUR" = "lomiri" ]; then
        mkdir -p rootdir/etc/lightdm/lightdm.conf.d
        cat > rootdir/etc/lightdm/lightdm.conf.d/50-autologin.conf <<EOF
[Seat:*]
autologin-user=$USERNAME
autologin-user-timeout=0
user-session=lomiri
greeter-session=lightdm-gtk-greeter
EOF

    else
        mkdir -p rootdir/etc/gdm3
        cat > rootdir/etc/gdm3/daemon.conf <<EOF
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=$USERNAME
EOF
    fi

    chroot rootdir systemctl enable NetworkManager
    chroot rootdir systemctl set-default graphical.target
fi

# =========================
# 💽 FSTAB (INI KUNCI)
# =========================

if [ "$MODE" = "dual" ]; then
    echo "PARTLABEL=linux / ext4 defaults,x-systemd.growfs 0 1" > rootdir/etc/fstab
else
    echo "PARTLABEL=userdata / ext4 defaults,x-systemd.growfs 0 1" > rootdir/etc/fstab
fi

# clean
chroot rootdir apt clean

# =========================
# 🐧 INITRAMFS & BOOT IMAGE
# =========================
# The kernel .deb installation should have triggered update-initramfs.
# Let's extract it and build the final boot image.
echo "🛠️ Extracting initramfs and generating final boot image..."
mkdir -p boot_out
cp rootdir/boot/initrd.img-* boot_out/initrd.img || echo "⚠️ initrd.img not found!"
cp rootdir/boot/vmlinuz-* boot_out/vmlinuz || echo "⚠️ vmlinuz not found!"
cp rootdir/boot/sm8475-lenovo-asphalt.dtb boot_out/sm8475-lenovo-asphalt.dtb || echo "⚠️ DTB not found!"

# We assume the DTB is available in the current directory or boot_out from the kernel build
if [ -f boot_out/initrd.img ] && [ -f boot_out/vmlinuz ] && [ -f boot_out/sm8475-lenovo-asphalt.dtb ]; then
    chmod +x ./mkbootimg
    MKBOOTIMG_COMMON="--base 0x00000000 --kernel_offset 0x00008000 --ramdisk_offset 0x01000000 --tags_offset 0x00000100 --dtb_offset 0x01f00000 --pagesize 4096 --header_version 2 --id"
    
    CMDLINE_SUFFIX="rootwait rw fsck.repair=yes"
    if [ "$MODE" = "dual" ]; then
        CMDLINE="root=PARTLABEL=linux $CMDLINE_SUFFIX"
        IMG_NAME="boot_asphalt_dualboot_initramfs.img"
    else
        CMDLINE="root=PARTLABEL=userdata $CMDLINE_SUFFIX"
        IMG_NAME="boot_asphalt_singleboot_initramfs.img"
    fi

    ./mkbootimg \
        --kernel boot_out/vmlinuz \
        --ramdisk boot_out/initrd.img \
        --dtb boot_out/sm8475-lenovo-asphalt.dtb \
        --cmdline "$CMDLINE" \
        $MKBOOTIMG_COMMON \
        -o "$IMG_NAME"
    echo "✅ Boot image created: $IMG_NAME"
else
    echo "⚠️ Skipping boot image generation (missing initrd, vmlinuz, or dtb)"
fi

# =========================
# 🥾 U-Boot EFI system partition
# =========================
if ! command -v mkfs.fat >/dev/null 2>&1; then
    echo "mkfs.fat not found; install dosfstools on the build host" >&2
    exit 1
fi

ESP_IMG="${distro_type}_${distro_version}_${FLAVOUR}_${MODE}_${TIMESTAMP}_linux-boot.img"
ESP_SIZE="1G"
if [ "$MODE" = "dual" ]; then
    ROOT_PARTLABEL="linux"
else
    ROOT_PARTLABEL="userdata"
fi

EFI_LOADER=$(find rootdir/usr/lib/systemd/boot/efi -type f \
    -iname 'systemd-bootaa64.efi*' -print -quit)
if [ -z "$EFI_LOADER" ]; then
    echo "ARM64 systemd-boot EFI binary not found in rootfs" >&2
    exit 1
fi
if [ ! -s boot_out/vmlinuz ] || [ ! -s boot_out/initrd.img ]; then
    echo "Kernel or initramfs missing; cannot make the U-Boot EFI boot partition" >&2
    exit 1
fi

truncate -s "$ESP_SIZE" "$ESP_IMG"
mkfs.fat -F 32 -n LINUX_BOOT "$ESP_IMG"
mount -o loop "$ESP_IMG" rootdir/boot
mkdir -p rootdir/boot/EFI/BOOT rootdir/boot/loader/entries
install -m 0644 "$EFI_LOADER" rootdir/boot/EFI/BOOT/BOOTAA64.EFI
install -m 0644 boot_out/vmlinuz rootdir/boot/vmlinuz
install -m 0644 boot_out/initrd.img rootdir/boot/initrd.img
cat > rootdir/boot/loader/loader.conf <<EOF
default debian.conf
timeout 3
editor no
EOF
cat > rootdir/boot/loader/entries/debian.conf <<EOF
title Debian GNU/Linux (Lenovo Asphalt)
linux /vmlinuz
initrd /initrd.img
options root=PARTLABEL=${ROOT_PARTLABEL} rootwait rw fsck.repair=yes
EOF
sync
umount rootdir/boot
fsck.fat -n "$ESP_IMG"
echo "✅ U-Boot EFI partition created: $ESP_IMG"

# unmount
umount rootdir/dev/pts || true
umount rootdir/dev || true
umount rootdir/proc || true
umount rootdir/sys || true
umount rootdir || true

rm -rf rootdir

# uuid
tune2fs -U $FILESYSTEM_UUID "$ROOTFS_IMG"

echo "✅ DONE: $ROOTFS_IMG"

# compress
echo "🗜️ compressing..."
7z a "${ROOTFS_IMG}.7z" "$ROOTFS_IMG"

done
done