#!/usr/bin/env bash
# Форматирует флэшку в ext4, создает /install и кладет туда Entware-инсталлятор.
# Использование: sudo ./prepare-entware-usb.sh /dev/sdX [метка]
# ВНИМАНИЕ: все данные на устройстве будут уничтожены.

set -euo pipefail

URL="https://bin.entware.net/aarch64-k3.10/installer/aarch64-installer.tar.gz"
DEV="${1:-}"
LABEL="${2:-ENTWARE}"

die() { echo "Ошибка: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "нужен root (sudo)"
[[ -n "$DEV" ]] || die "использование: $0 /dev/sdX [метка]"
[[ -b "$DEV" ]] || die "$DEV не блочное устройство"
for c in lsblk parted mkfs.ext4 wipefs partprobe; do
    command -v "$c" >/dev/null || die "не найден $c"
done
if command -v curl >/dev/null; then DL=(curl -fL -o)
elif command -v wget >/dev/null; then DL=(wget -O)
else die "нужен curl или wget"; fi

[[ "$(lsblk -dno TYPE "$DEV")" == "disk" ]] || die "$DEV должен быть диском целиком, не разделом"

# защита от форматирования системного диска
if lsblk -nlo MOUNTPOINT "$DEV" | grep -qxE '/|/boot|/boot/efi|/home'; then
    die "$DEV содержит системные разделы"
fi

TMP="$(mktemp -d)"
MNT="$TMP/mnt"; mkdir "$MNT"
cleanup() {
    mountpoint -q "$MNT" 2>/dev/null && umount "$MNT" || true
    rm -rf "$TMP"
}
trap cleanup EXIT

# Скачиваем до форматирования, чтобы не стереть флэшку зря
echo "==> Скачивание инсталлятора"
"${DL[@]}" "$TMP/installer.tar.gz" "$URL"
tar -tzf "$TMP/installer.tar.gz" >/dev/null || die "архив поврежден"

echo
lsblk -o NAME,SIZE,TRAN,MODEL,LABEL,MOUNTPOINT "$DEV"
echo
read -r -p "Все данные на $DEV будут стерты. Для подтверждения введи имя устройства ($DEV): " ans
[[ "$ans" == "$DEV" ]] || die "отмена"

echo "==> Размонтирование"
while read -r p; do
    [[ -n "$p" ]] && umount "$p" 2>/dev/null || true
done < <(lsblk -nlpo NAME "$DEV" | tail -n +2)

echo "==> Разметка (msdos, один раздел)"
wipefs -a "$DEV" >/dev/null
parted -s "$DEV" mklabel msdos mkpart primary ext4 1MiB 100%
partprobe "$DEV"
udevadm settle 2>/dev/null || sleep 2
PART="$(lsblk -nlpo NAME,TYPE "$DEV" | awk '$2=="part"{print $1; exit}')"
[[ -b "$PART" ]] || die "раздел не найден"

echo "==> mkfs.ext4 на $PART (метка: $LABEL)"
# отключаем новые фичи ext4, которые может не поддерживать ядро роутера
OPTS="^metadata_csum,^64bit"
mkfs.ext4 -F -L "$LABEL" -O "$OPTS,^orphan_file" "$PART" 2>/dev/null \
    || mkfs.ext4 -F -L "$LABEL" -O "$OPTS" "$PART"

echo "==> Копирование инсталлятора"
mount "$PART" "$MNT"
mkdir -p "$MNT/install"
cp "$TMP/installer.tar.gz" "$MNT/install/aarch64-installer.tar.gz"
sync
umount "$MNT"

echo "==> Готово: $PART, /install/aarch64-installer.tar.gz"