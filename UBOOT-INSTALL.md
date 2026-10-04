# U-Boot dan Debian di Lenovo Asphalt (TB320FC)

Build lama menghasilkan Android `boot.img` berisi kernel Linux. Image itu bukan
U-Boot, sehingga memasangnya lewat ABL tidak otomatis menyediakan firmware UFS,
perangkat EFI, atau boot chain yang dibutuhkan Debian. Alur baru mengikuti
`pkgs/u-boot/sm8475/asphalt` dari repo referensi:

```text
ABL (slot B) -> U-Boot Android boot image pada boot_b
             -> GPT linux-boot (FAT32)
             -> EFI/BOOT/BOOTAA64.EFI (systemd-boot)
             -> kernel EFI-stub + initrd -> PARTLABEL=linux
```

U-Boot mencari partisi GPT `linux-boot` pada UFS dan memuat fallback EFI path
`/EFI/BOOT/BOOTAA64.EFI`. Layout yang didukung adalah ESP FAT32 terpisah 1 GiB
dengan label GPT `linux-boot`, serta partisi ext4 berlabel GPT `linux` sebagai
root Debian. Firmware hanya ditulis ke `boot_b`; jangan menulis ke `boot_a`,
`recovery_b`, `super`, atau partisi ESP.

## Build

Di host Debian/x86_64 diperlukan Nix dengan flakes, Python 3, `fdtget` dari
`device-tree-compiler`, `dpkg-deb`, dan `dosfstools`. Clone repo referensi
`https://github.com/dianqk/nixos-android-devices` sebagai direktori sibling di
workspace; workflow GitHub Actions melakukan checkout ini otomatis:

```sh
git clone https://github.com/dianqk/nixos-android-devices nixos-android-devices
./asphalt-uboot_build.sh
```

Untuk lokasi lain, set `NIXOS_ANDROID_DEVICES=/path/to/nixos-android-devices`.

Script membangun `devices.asphalt.u-boot` dan firmware dari U-Boot v2026.10-rc5
yang dipin di flake referensi, menjalankan `tests/asphalt-uboot.py`, lalu
membangun image DTBO nonaktif yang disediakan referensi, lalu membuat:

- `build/uboot/boot_asphalt_uboot.img`: image yang akan di-flash ke `boot_b`.
- `build/uboot/asphalt-disabled-dtbo.img`: DTBO nol 24 MiB untuk `dtbo_b`.
- `build/uboot/uboot-lenovo-asphalt_2026.10~rc5_arm64.deb`: salinan image di
  `/usr/share/uboot-lenovo-asphalt/`; instalasi paket tidak mem-flash perangkat.

Build kernel seperti biasa dengan `./asphalt-kernel_build.sh`. Build rootfs
sebagai root dan pastikan paket kernel/firmware/ALSA `.deb` tersedia di direktori
kerja seperti yang dibutuhkan script saat ini. Selain image root ext4 dan image
Android lama, `./asphalt-rootfs_build.sh debian-desktop <kernel> <user> <password>`
sekarang menghasilkan image ESP `*_linux-boot.img` FAT32 berukuran 1 GiB. ESP itu
berisi systemd-boot ARM64 fallback, kernel, initrd, dan loader entry. Kernel
harus mempertahankan `CONFIG_EFI_STUB=y` (sudah aktif di `sm8475.config`).

Image `boot_asphalt_*_initramfs.img` yang masih dibuat oleh build rootfs adalah
artefak Android/Linux lama; **jangan flash image tersebut sebagai pengganti
U-Boot**.

## Instalasi

Persiapkan UFS dari recovery yang berfungsi. Pembuatan/penyusutan partisi dapat
menghapus data Android userdata. Pertahankan slot A dan `super`; detail layout,
verifikasi GPT, dan langkah pemulihan perangkat ada di [panduan storage Asphalt
referensi](https://github.com/dianqk/nixos-android-devices/blob/main/docs/asphalt/manual-storage.md).
Sebelum lanjut, `lsblk`/`blkid` harus menunjukkan partisi `linux-boot` FAT32
ukuran 1 GiB, `linux` ext4, dan firmware target `boot_b`.

1. Tulis image root ext4 yang dihasilkan ke partisi GPT `linux` yang sudah
   disiapkan dan cukup besar. Jangan menulis image root ke ESP.
2. Salin image ESP ke partisi FAT `linux-boot`. Pastikan label GPT tidak ambigu,
   dan cocokkan perangkat hasil `readlink -f` dengan output `lsblk` sebelum
   menjalankan perintah tulis berikut:

   ```sh
   ESP=/dev/disk/by-partlabel/linux-boot
   readlink -f "$ESP"
   lsblk -o NAME,SIZE,TYPE,PARTLABEL,FSTYPE,MOUNTPOINTS "$(readlink -f "$ESP")"
   sudo dd if=debian_trixie_gnome-shell-mobile_dual_<timestamp>_linux-boot.img \
     of="$ESP" bs=4M conv=fsync status=progress
   sudo fsck.fat -n "$ESP"
   ```

   Ganti nama file dengan image ESP yang benar-benar dihasilkan. Pastikan ukuran
   partisi tujuan tepat 1 GiB sebelum `dd`.
3. Boot perangkat ke **ABL Fastboot** (bukan Fastboot dari U-Boot), lalu gunakan
   CLI pemeriksa dari repo referensi. Ganti `FASTBOOT_SERIAL` dengan serial yang
   ditampilkan `fastboot devices`. Perintah pertama hanya memeriksa image,
   produk, slot aktif B, dan kapasitas partisi:

   ```sh
   REF=/path/to/nixos-android-devices
   nix run "$REF#mobile-device" -- --serial FASTBOOT_SERIAL fastboot flash \
     build/uboot/boot_asphalt_uboot.img --partition boot_b
   ```

   Periksa ringkasan hasil validasi, lalu ulangi perintah yang sama dengan
   `--execute` untuk menulis image. Jangan gunakan perintah flash saat sudah
   berada di U-Boot; backend U-Boot Fastboot pada perangkat ini bukan backend
   UFS. CLI juga menolak target selain `boot_b` atau jika slot B tidak aktif.
4. Flash DTBO nonaktif referensi ke slot B. **Jangan gunakan `fastboot erase
   dtbo_b`**; gunakan image 24 MiB hasil build agar isi partisi dalam format
   yang disediakan untuk konfigurasi Asphalt:

   ```sh
   fastboot flash dtbo_b build/uboot/asphalt-disabled-dtbo.img
   ```

5. Setelah kedua flash berhasil, pastikan slot B masih aktif lalu reboot. ABL
   akan menjalankan U-Boot dari `boot_b`;
   U-Boot kemudian memuat systemd-boot dari `linux-boot`, yang memilih kernel dan
   initrd Debian. Simpan recovery RAM yang berfungsi untuk pemulihan.

## Catatan pemulihan

Jika U-Boot mulai tetapi gagal menemukan EFI loader, periksa label GPT `linux-boot`,
format FAT32, serta keberadaan `EFI/BOOT/BOOTAA64.EFI` dan `loader/entries/debian.conf`.
Jika kernel mulai tetapi tidak menemukan root, pastikan entry EFI memakai label
yang cocok dengan mode build (`linux` untuk dual, `userdata` untuk single).

U-Boot Asphalt di referensi mengharapkan DT/PLL handoff panel yang sepadan dengan
patch kernel Asphalt di sana. Jika boot berhasil tetapi layar padam atau touch
gagal, jangan menganggap image firmware rusak; uji pasangan kernel yang mencakup
reserved-memory splash dan perbaikan Lucid OLE PLL dari source referensi.