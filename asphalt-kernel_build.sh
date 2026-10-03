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

wget https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-${KERNEL_VERSION}.tar.xz
tar -xvf linux-${KERNEL_VERSION}.tar.xz

git clone https://github.com/dianqk/nixos-android-devices


cd linux-${KERNEL_VERSION}
mkdir asphalt-patch
cp -r ../nixos-android-devices/pkgs/linux-kernel/sm8475/asphalt/patches/* asphalt-patch/

git apply asphalt-patch/local/0001-sm8475-core.patch
git apply asphalt-patch/local/0002-asphalt-display.patch
git apply asphalt-patch/local/0003-asphalt-touch.patch
git apply asphalt-patch/local/0004-sm8475-pcie-wifi.patch
git apply asphalt-patch/local/0005-sm8475-ufs-clocks.patch
git apply asphalt-patch/local/0006-asphalt-board-dts.patch
git apply asphalt-patch/local/0007-sm8450-iris-video.patch
git apply asphalt-patch/local/0008-asphalt-usb-audio.patch
git apply asphalt-patch/local/0009-cs35l45-dsp-part-name.patch
git apply asphalt-patch/local/0010-qmp-hardware-port-select.patch
git apply asphalt-patch/local/0011-sm8475-audio-service-setup.patch
git apply asphalt-patch/sm-x800-linux/0012-sm8450-camss.patch
git apply asphalt-patch/sm-x800-linux/0013-camcc-shared-rcg.patch
git apply asphalt-patch/local/0014-wl2864c-regulators.patch
git apply asphalt-patch/local/0015-asphalt-sensors.patch
git apply asphalt-patch/local/0016-asphalt-camera-wiring.patch
git apply asphalt-patch/sm-x800-linux/0017-camcc-retain-ff.patch
git apply asphalt-patch/local/0018-asphalt-displayport.patch
git apply asphalt-patch/local/0019-dp-debug-connector.patch
git apply asphalt-patch/upstream/0020-lucid-ole-preserve-enabled-pll.patch


cp ../sm8475.config .config

make -j$(nproc) ARCH=arm64 CC="ccache clang" LLVM=1
_kernel_version="$(make kernelrelease -s)"


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
    $PKGDIR/boot/Image

install -Dm644 arch/$ARCH/boot/dts/qcom/sm8475-lenovo-asphalt.dtb \
    $PKGDIR/boot/sm8475-lenovo-asphalt.dtb

install -Dm644 .config \
    $PKGDIR/boot/config-${_kernel_version}

install -Dm644 System.map \
    $PKGDIR/boot/System.map-${_kernel_version}
    
chmod +x ../mkbootimg

cat arch/arm64/boot/Image.gz arch/arm64/boot/dts/qcom/sm8475-lenovo-asphalt.dtb > Image.gz-dtb_asphalt

install -Dm644 Image.gz-dtb_asphalt \
    $PKGDIR/boot/Image.gz-dtb_asphalt

mv Image.gz-dtb_asphalt zImage_asphalt
../mkbootimg --kernel zImage_asphalt --cmdline "root=PARTLABEL=linux rootwait rw fsck.repair=yes" --base 0x00000000 --kernel_offset 0x00008000 --tags_offset 0x01e00000 --pagesize 4096 --id -o ../boot_asphalt_dualboot.img
../mkbootimg --kernel zImage_asphalt --cmdline "root=PARTLABEL=userdata rootwait rw fsck.repair=yes" --base 0x00000000 --kernel_offset 0x00008000 --tags_offset 0x01e00000 --pagesize 4096 --id -o ../boot_asphalt_singleboot.img


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



cd ../../../..

git clone https://github.com/linux-msm/audioreach-topology
cd audioreach-topology
git checkout 993a17dcb672357998a463a73f120064d6c74f4f
cd ..

wget https://raw.githubusercontent.com/dianqk/nixos-android-devices/refs/heads/main/pkgs/asphalt/audio/Lenovo-Y700.m4 -O Lenovo-Y700.m4
m4 -I audioreach-topology Lenovo-Y700.m4 > Lenovo-Y700-tplg.conf
alsatplg -c Lenovo-Y700-tplg.conf -o Lenovo-Y700-tplg.bin
mv Lenovo-Y700-tplg.bin firmware-lenovo-asphalt/usr/lib/firmware/qcom/sm8475/Lenovo-Y700-tplg.bin

dpkg-deb --build --root-owner-group linux-lenovo-asphalt
dpkg-deb --build --root-owner-group firmware-lenovo-asphalt
dpkg-deb --build --root-owner-group alsa-lenovo-asphalt