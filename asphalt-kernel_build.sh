set -e

# 仅在未设置环境变量时配置ccache
if [ -z "$CCACHE_DIR" ]; then
    export CCACHE_DIR="/home/runner/.ccache"
    export CCACHE_MAXSIZE="10G"
    export CCACHE_SLOPPINESS="file_macro,locale,time_macros"
fi

# 确保ccache目录存在
mkdir -p "$CCACHE_DIR"

KERNEL_VERSION="$1"


# 确保ccache优先使用clang
export CC="ccache clang"
export CXX="ccache clang++"
export AR="llvm-ar"
export NM="llvm-nm"
export OBJCOPY="llvm-objcopy"
export OBJDUMP="llvm-objdump"
export READELF="llvm-readelf"
export STRIP="llvm-strip"

git clone https://github.com/alghiffaryfa19/asphalt-mainline linux
cd linux

cp ../sm8475.config .config

# Resolve any new/unknown config symbols from patches non-interactively
# echo "🔧 Running olddefconfig to sync config..."
# make ARCH=arm64 CC="ccache clang" LLVM=1 olddefconfig

# Show which critical configs were dropped by olddefconfig
echo "🔍 Checking critical configs after olddefconfig..."
for cfg in CONFIG_PINCTRL_SM8475 CONFIG_TOUCHSCREEN_NOVATEK_NT36523N_SPI CONFIG_DRM_PANEL_NOVATEK_NT36523; do
    if grep -q "^${cfg}=" .config; then
        echo "  ✅ ${cfg} = $(grep "^${cfg}=" .config | cut -d= -f2)"
    else
        echo "  ❌ ${cfg} was DROPPED — patch likely missing Kconfig entry"
    fi
done

make -j$(nproc) ARCH=arm64 CC="ccache clang" LLVM=1 Image Image.gz dtbs modules
_kernel_version="$(make kernelrelease -s)"

# Verify DTB was actually built before proceeding
if [ ! -f arch/arm64/boot/dts/qcom/sm8475-lenovo-asphalt.dtb ]; then
    echo "❌ FATAL: sm8475-lenovo-asphalt.dtb not found after build!"
    echo "   → Patch 0006-asphalt-board-dts.patch may have failed or DTS Makefile entry is missing."
    exit 1
fi

# =========================
# Validate critical kernel configs (ref: nixos-android-devices)
# =========================
echo "🔍 Validating kernel configuration..."
WARN_COUNT=0
for cfg in \
    CONFIG_BLK_DEV_INITRD=y \
    CONFIG_RD_ZSTD=y \
    CONFIG_PINCTRL_SM8475=y \
    CONFIG_SCSI_UFS_QCOM=y \
    CONFIG_USB_DWC3=y \
    CONFIG_USB_DWC3_QCOM=y \
    CONFIG_DRM_MSM=y \
    CONFIG_DRM_PANEL_NOVATEK_NT36523=y \
    CONFIG_TOUCHSCREEN_NOVATEK_NT36523N_SPI=y \
    CONFIG_ATH11K_PCI=y \
    CONFIG_PHY_QCOM_QMP_COMBO=y \
    CONFIG_MODULE_COMPRESS_ZSTD=y; do
    if ! grep -q "^${cfg}$" .config; then
        echo "⚠️  WARNING: ${cfg} not found in .config"
        WARN_COUNT=$((WARN_COUNT+1))
    fi
done
if [ $WARN_COUNT -eq 0 ]; then
    echo "✅ All critical kernel configs validated"
else
    echo "⚠️  ${WARN_COUNT} config warning(s) — build continues"
fi


sed -i "s/Version:.*/Version: ${_kernel_version}/" ../linux-lenovo-asphalt/DEBIAN/control

PKGDIR=../linux-lenovo-asphalt
ARCH=arm64

# =========================
# Systemd fast shutdown config (wait n see)
# =========================
#mkdir -p $PKGDIR/etc/systemd/system.conf.d
#cat <<EOF > $PKGDIR/etc/systemd/system.conf.d/99-fast-shutdown.conf
#[Manager]
#DefaultTimeoutStopSec=10s
#DefaultTimeoutAbortSec=10s
#EOF

# =========================
# Install kernel images
# =========================
mkdir -p $PKGDIR/boot

install -Dm644 arch/$ARCH/boot/Image.gz \
    $PKGDIR/boot/Image.gz

install -Dm644 arch/$ARCH/boot/Image \
    $PKGDIR/boot/vmlinuz-${_kernel_version}

install -Dm644 arch/$ARCH/boot/dts/qcom/sm8475-lenovo-asphalt.dtb \
    $PKGDIR/boot/sm8475-lenovo-asphalt.dtb

install -Dm644 .config \
    $PKGDIR/boot/config-${_kernel_version}

install -Dm644 System.map \
    $PKGDIR/boot/System.map-${_kernel_version}
    
chmod +x ../mkbootimg

# =========================
# Generate boot images (header v2 + DTB, adapted from nixos-android-devices)
# Uses Image (uncompressed) + separate DTB (not concatenated)
# Offsets: base=0x0, kernel=0x8000, ramdisk=0x1000000, tags=0x100, dtb=0x1f00000
# Note: tanpa --ramdisk di sini. Boot image dengan initramfs dibuat di rootfs build.
# =========================
MKBOOTIMG_COMMON="--base 0x00000000 --kernel_offset 0x00008000 --ramdisk_offset 0x01000000 --tags_offset 0x00000100 --dtb_offset 0x01f00000 --pagesize 4096 --header_version 2 --id"

../mkbootimg \
    --kernel arch/$ARCH/boot/Image \
    --dtb arch/$ARCH/boot/dts/qcom/sm8475-lenovo-asphalt.dtb \
    --cmdline "root=PARTLABEL=linux rootwait rw fsck.repair=yes" \
    $MKBOOTIMG_COMMON \
    -o ../boot_asphalt_dualboot.img

../mkbootimg \
    --kernel arch/$ARCH/boot/Image \
    --dtb arch/$ARCH/boot/dts/qcom/sm8475-lenovo-asphalt.dtb \
    --cmdline "root=PARTLABEL=userdata rootwait rw fsck.repair=yes" \
    $MKBOOTIMG_COMMON \
    -o ../boot_asphalt_singleboot.img


make -j$(nproc) ARCH=arm64 CC="ccache clang" LLVM=1 INSTALL_MOD_PATH=../linux-lenovo-asphalt modules_install
rm ../linux-lenovo-asphalt/lib/modules/**/build

cd ..
git clone https://github.com/alghiffaryfa19/firmware-lenovo-asphalt fw-asphalt
cd fw-asphalt
rm *md
rm SHA256SUMS
cd ..

cp -r fw-asphalt/* firmware-lenovo-asphalt/

git clone https://github.com/map220v/alsa-ucm-conf
mkdir -p alsa-lenovo-asphalt/usr/share/alsa
cp -r alsa-ucm-conf/ucm2 alsa-lenovo-asphalt/usr/share/alsa/

cd alsa-lenovo-asphalt/usr/share/alsa/ucm2
mkdir Lenovo-Y700
mkdir -p conf.d/sm8475
cd Lenovo-Y700
wget https://raw.githubusercontent.com/dianqk/nixos-android-devices/refs/heads/main/pkgs/asphalt/Lenovo-Y700.conf
wget https://raw.githubusercontent.com/dianqk/nixos-android-devices/refs/heads/main/pkgs/asphalt/HiFi.conf
cd ..
ln -s Lenovo-Y700/Lenovo-Y700.conf conf.d/sm8475/Lenovo-Y700.conf



cd ../../../../..

git clone https://github.com/linux-msm/audioreach-topology
cd audioreach-topology
git checkout 993a17dcb672357998a463a73f120064d6c74f4f
cd ..

wget https://raw.githubusercontent.com/dianqk/nixos-android-devices/refs/heads/main/pkgs/asphalt/audio/Lenovo-Y700.m4 -O Lenovo-Y700.m4
m4 -I audioreach-topology Lenovo-Y700.m4 > Lenovo-Y700-tplg.conf
alsatplg -c Lenovo-Y700-tplg.conf -o Lenovo-Y700-tplg.bin
install -Dm0644 Lenovo-Y700-tplg.bin firmware-lenovo-asphalt/usr/lib/firmware/qcom/sm8475/Lenovo-Y700-tplg.bin

dpkg-deb --build --root-owner-group linux-lenovo-asphalt
dpkg-deb --build --root-owner-group firmware-lenovo-asphalt
dpkg-deb --build --root-owner-group alsa-lenovo-asphalt