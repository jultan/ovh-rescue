#!/usr/bin/env bash
set -euo pipefail

DISK="/dev/nvme0n1"
HOSTNAME_ARCH="arch01"
BOOTSTRAP=/run/arch-ovh-bootstrap
TARGET=/mnt/arch-ovh-target
MIRROR=${MIRROR:-https://geo.mirror.pkgbuild.com}

# Un espace de noms privé empêche la propagation des montages au rescue.
if [[ ${1:-} != --isolated ]]; then
    exec unshare --mount --propagation private -- bash "$(readlink -f "$0")" --isolated
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl ca-certificates zstd gdisk dosfstools e2fsprogs util-linux parted

IPV6_ADDR=$(awk '$1 == "address" {print $2; exit}' /etc/network/interfaces.d/60-rescue-ipv6)
IPV6_GW=$(awk '$1 == "gateway" {print $2; exit}' /etc/network/interfaces.d/60-rescue-ipv6)
MAC=$(cat /sys/class/net/eth0/address)

# Le rescue utilise parfois une partition swap sur le disque d'installation.
swapoff -a || true
umount "${DISK}p1" "${DISK}p3" 2>/dev/null || true
wipefs -af "$DISK"
sgdisk --zap-all "$DISK"
sgdisk -n 1:0:+1G -t 1:ef00 -c 1:EFI "$DISK"
sgdisk -n 2:0:+8G -t 2:8200 -c 2:SWAP "$DISK"
sgdisk -n 3:0:0 -t 3:8300 -c 3:ARCH "$DISK"
partprobe "$DISK"
udevadm settle
mkfs.fat -F 32 -n EFI "${DISK}p1"
mkswap -L SWAP "${DISK}p2"
mkfs.ext4 -F -L ARCH "${DISK}p3"

mkdir -p "$TARGET" "$BOOTSTRAP"
# Le bootstrap et son cache pacman résident en RAM, hors du rootfs limité du rescue.
mount -t tmpfs -o size=3G,mode=0755 tmpfs "$BOOTSTRAP"
mount "${DISK}p3" "$TARGET"
mkdir -p "$TARGET/boot"
mount "${DISK}p1" "$TARGET/boot"

curl -fL "$MIRROR/iso/latest/archlinux-bootstrap-x86_64.tar.zst" -o /run/arch-bootstrap.tar.zst
tar --zstd -xf /run/arch-bootstrap.tar.zst -C "$BOOTSTRAP" --strip-components=1
# L'archive contient root.x86_64/ ; --strip-components=1 place son contenu directement dans BOOTSTRAP.

cp /etc/resolv.conf "$BOOTSTRAP/etc/resolv.conf"
mount --bind /dev "$BOOTSTRAP/dev"
mount -t devpts devpts "$BOOTSTRAP/dev/pts"
mount -t proc proc "$BOOTSTRAP/proc"
mount --bind /sys "$BOOTSTRAP/sys"
mkdir -p "$BOOTSTRAP/mnt/boot"
mount --bind "$TARGET" "$BOOTSTRAP/mnt"
mount --bind "$TARGET/boot" "$BOOTSTRAP/mnt/boot"

# Évite Landlock et les erreurs du sandbox pacman sous le noyau Debian Rescue.
sed -i '/^\[options\]/a DisableSandbox' "$BOOTSTRAP/etc/pacman.conf"
printf 'Server = %s/$repo/os/$arch\n' "$MIRROR" > "$BOOTSTRAP/etc/pacman.d/mirrorlist"
chroot "$BOOTSTRAP" pacman-key --init
chroot "$BOOTSTRAP" pacman-key --populate archlinux
chroot "$BOOTSTRAP" pacman -Sy --noconfirm archlinux-keyring arch-install-scripts
chroot "$BOOTSTRAP" pacstrap -K /mnt base linux-lts linux-firmware mkinitcpio grub efibootmgr \
    openssh vim

ROOT_UUID=$(blkid -s UUID -o value "${DISK}p3")
EFI_UUID=$(blkid -s UUID -o value "${DISK}p1")
SWAP_UUID=$(blkid -s UUID -o value "${DISK}p2")
cat > "$TARGET/etc/fstab" <<EOF
UUID=$ROOT_UUID / ext4 defaults 0 1
UUID=$EFI_UUID /boot vfat umask=0077 0 2
UUID=$SWAP_UUID none swap defaults 0 0
EOF

printf '%s\n' "$HOSTNAME_ARCH" > "$TARGET/etc/hostname"
cat > "$TARGET/etc/hosts" <<EOF
127.0.0.1 localhost
::1 localhost
127.0.1.1 $HOSTNAME_ARCH
EOF

mkdir -p "$TARGET/etc/systemd/network"
cat > "$TARGET/etc/systemd/network/20-ovh.network" <<EOF
[Match]
MACAddress=$MAC

[Network]
DHCP=ipv4
Address=$IPV6_ADDR
IPv6AcceptRA=no
LinkLocalAddressing=ipv6
DNS=1.1.1.1
DNS=2606:4700:4700::1111

[Route]
Gateway=$IPV6_GW
GatewayOnLink=yes
EOF
ln -sfn /run/systemd/resolve/stub-resolv.conf "$TARGET/etc/resolv.conf"

install -d -m 700 "$TARGET/root/.ssh"
cp /root/.ssh/authorized_keys "$TARGET/root/.ssh/authorized_keys"
chmod 600 "$TARGET/root/.ssh/authorized_keys" 2>/dev/null || true

# Le noyau du rescue n'est pas celui qui démarrera : ne pas filtrer les modules autodétectés.
sed -i 's/ autodetect / /' "$TARGET/etc/mkinitcpio.conf"
# Préparer le système cible dans l'espace de noms privé existant.
mount --bind /dev "$TARGET/dev"
mount -t devpts devpts "$TARGET/dev/pts"
mount -t proc proc "$TARGET/proc"
mount --bind /sys "$TARGET/sys"
mount -t tmpfs tmpfs "$TARGET/run"
chroot "$TARGET" /bin/bash -e <<'EOF'
ssh-keygen -A
systemctl enable sshd systemd-networkd systemd-resolved
mkinitcpio -P
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Arch
grub-mkconfig -o /boot/grub/grub.cfg
EOF

printf '\nInstallation terminée : %s, IPv6 %s. Redémarrage manuel.\n' "$DISK" "$IPV6_ADDR"

