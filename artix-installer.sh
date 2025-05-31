#!/bin/bash

# Проверка root-доступа
if [[ $EUID -ne 0 ]]; then
  echo "Этот скрипт должен быть запущен от root"
  exit 1
fi

# Выбор схемы разметки
clear
echo "Выберите схему разметки:"
echo "1) MBR"
echo "2) GPT"
echo -n "Введите число: "
read PART_SCHEME

case $PART_SCHEME in
  1) 
    echo "Выбрана схема разметки: MBR"
    SCHEME="mbr"
    ;;
  2) 
    echo "Выбрана схема разметки: GPT"
    SCHEME="gpt"
    ;;
  *)
    echo "Неверный выбор. Выход."
    exit 1
    ;;
esac

# Выбор системы инициализации
clear
echo "Выберите систему инициализации:"
echo "1) openrc      2) runit      3) s6"
echo "4) dinit       5) baselayout 6) Выход"
echo -n "Введите число: "
read INIT_CHOICE

case $INIT_CHOICE in
  1) INIT_SYSTEM=openrc;;
  2) INIT_SYSTEM=runit;;
  3) INIT_SYSTEM=s6;;
  4) INIT_SYSTEM=dinit;;
  5) INIT_SYSTEM=baselayout;;
  6) exit 0;;
  *) echo "Неверный выбор."; exit 1;;
esac

echo "Выбрана система инициализации: $INIT_SYSTEM"

# Ввод целевого диска
echo -n "Введите диск (например /dev/sda): "
read DISK

if [ ! -b "$DISK" ]; then
  echo "Указанный диск не существует"
  exit 1
fi

# Подтверждение удаления данных
echo "Все данные на $DISK будут удалены! Продолжить? (yes/no)"
read confirm
if [ "$confirm" != "yes" ]; then
  echo "Отмена"
  exit 1
fi

# Разметка диска
echo "Разметка диска $DISK с $SCHEME схемой"

if [ "$SCHEME" == "mbr" ]; then
  parted --script "$DISK" mklabel msdos
  parted --script "$DISK" mkpart primary ext4 1MiB 100%
  parted --script "$DISK" set 1 boot on
  PARTITION="${DISK}1"
else
  parted --script "$DISK" mklabel gpt
  parted --script "$DISK" mkpart primary ext4 1MiB 100%
  parted --script "$DISK" set 1 esp on
  PARTITION="${DISK}1"
fi

# Форматирование и монтирование
echo "Форматирую и монтирую разделы..."
mkfs.ext4 -F "$PARTITION"
MOUNTPOINT="/mnt/artix"
mkdir -p "$MOUNTPOINT"
mount "$PARTITION" "$MOUNTPOINT"

# Пакеты для установки
COMMON_PACKAGES="base linux linux-firmware grub linux-headers git base-devel \
xf86-input-libinput mesa vulkan-intel vulkan-radeon \
xf86-video-amdgpu xf86-video-ati xf86-video-intel xf86-video-nouveau xf86-video-vesa xf86-video-fbdev \
intel-ucode amd-ucode"

NET_PACKAGES="dhcpcd wpa_supplicant dialog networkmanager"

# Установка базовой системы
echo "Устанавливаю базовую систему Artix с $INIT_SYSTEM..."
basestrap "$MOUNTPOINT" $COMMON_PACKAGES $NET_PACKAGES $INIT_SYSTEM

# Генерация fstab
fstabgen -U "$MOUNTPOINT" >> "$MOUNTPOINT/etc/fstab"

# Настройка окружения в chroot
cp /etc/pacman.d/mirrorlist "$MOUNTPOINT/etc/pacman.d/mirrorlist"
artix-chroot "$MOUNTPOINT" ln -sf /usr/share/zoneinfo/Europe/Kiev /etc/localtime
artix-chroot "$MOUNTPOINT" hwclock --systohc
artix-chroot "$MOUNTPOINT" echo artix > /etc/hostname

# Настройка hosts
cat <<EOF > "$MOUNTPOINT/etc/hosts"
127.0.0.1   localhost
::1         localhost
127.0.1.1   artix.localdomain artix
EOF

# Активация сетевых служб
echo "Активирую NetworkManager..."
case $INIT_SYSTEM in
  openrc)
    artix-chroot "$MOUNTPOINT" rc-update add NetworkManager default
    ;;
  runit)
    artix-chroot "$MOUNTPOINT" ln -s /etc/runit/sv/NetworkManager /etc/runit/runsvdir/default
    ;;
  s6)
    artix-chroot "$MOUNTPOINT" s6-rc-bundle add default NetworkManager
    ;;
  dinit)
    artix-chroot "$MOUNTPOINT" ln -s /etc/dinit.d/NetworkManager /etc/dinit.d/boot.d/
    ;;
  baselayout)
    echo "⚠️ baselayout не использует менеджер служб по умолчанию. Настройка NetworkManager вручную."
    ;;
esac

# Установка загрузчика
if [ "$SCHEME" == "mbr" ]; then
  artix-chroot "$MOUNTPOINT" grub-install --target=i386-pc "$DISK"
else
  artix-chroot "$MOUNTPOINT" grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Artix
fi
artix-chroot "$MOUNTPOINT" grub-mkconfig -o /boot/grub/grub.cfg

# Установка пароля root
artix-chroot "$MOUNTPOINT" passwd

echo -e "\n✅ Установка завершена! Перезагрузите и выньте установочный носитель."

