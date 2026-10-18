#!/usr/bin/env bash
set -euo pipefail

# Debian 13 Trixie depuis Debian Rescue OVH (UEFI).
# ATTENTION : efface le disque sans confirmation.
DISK=/dev/nvme0n1
HOSTNAME_DEBIAN=trixie01
TARGET=/mnt/ovh-trixie

if [[ \${1:-} != --isolated ]]; then
    exec unshare --mount --propagation private -- bash "$(readlink -f "$0")" --isolated
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y debootstrap debian-archive-keyring gdisk dosfstools e2fsprogs parted

IPV6_ADDR=$(awk '$1 == "address" {print $2; exit}' /etc/network/interfaces.d/60-rescue-ipv6)
IPV6_GW=$(awk '$1 == "gateway" {print $2; exit}' /etc/network/interfaces.d/60-rescue-ipv6)
MAC=$(cat /sys/class/net/eth0/address)

swapoff -a || true
umount "\${DISK}p1" "\${DISK}p3" 2>/dev/null || true
wipefs -af "$DISK"
sgdisk --zap-all "$DISK"
sgdisk -n 1:0:+1G -t 1:ef00 -c 1:EFI "$DISK"
sgdisk -n 2:0:+8G -t 2:8200 -c 2:SWAP "$DISK"
sgdisk -n 3:0:0 -t 3:8300 -c 3:DEBIAN "$DISK"
partprobe "$DISK"
udevadm settle
mkfs.fat -F 32 -n EFI "\${DISK}p1"
mkswap -L SWAP "\${DISK}p2"
mkfs.ext4 -F -L DEBIAN "\${DISK}p3"

mkdir -p "$TARGET"
mount "\${DISK}p3" "$TARGET"
mkdir -p "$TARGET/boot"
mount "\${DISK}p1" "$TARGET/boot"

debootstrap --arch=amd64 --variant=minbase trixie "$TARGET" https://deb.debian.org/debian

cat > "$TARGET/etc/apt/sources.list" <<'EOF'
deb https://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb https://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
deb https://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
EOF

ROOT_UUID=$(blkid -s UUID -o value "\${DISK}p3")
EFI_UUID=$(blkid -s UUID -o value "\${DISK}p1")
SWAP_UUID=$(blkid -s UUID -o value "\${DISK}p2")
cat > "$TARGET/etc/fstab" <<EOF
UUID=$ROOT_UUID / ext4 defaults 0 1
UUID=$EFI_UUID /boot vfat umask=0077 0 2
UUID=$SWAP_UUID none swap defaults 0 0
EOF

printf '%s\n' "$HOSTNAME_DEBIAN" > "$TARGET/etc/hostname"
cat > "$TARGET/etc/hosts" <<EOF
127.0.0.1 localhost
::1 localhost
127.0.1.1 $HOSTNAME_DEBIAN
EOF

mount --bind /dev "$TARGET/dev"
mount -t devpts devpts "$TARGET/dev/pts"
mount -t proc proc "$TARGET/proc"
mount --bind /sys "$TARGET/sys"
mkdir -p "$TARGET/sys/firmware/efi/efivars"
mount -t efivarfs efivarfs "$TARGET/sys/firmware/efi/efivars"
mount -t tmpfs tmpfs "$TARGET/run"
cp -L /etc/resolv.conf "$TARGET/etc/resolv.conf"

chroot "$TARGET" apt-get update
chroot "$TARGET" apt-get install -y --no-install-recommends \
    linux-image-amd64 initramfs-tools grub-efi-amd64 efibootmgr \
    systemd-sysv systemd-networkd systemd-resolved \
    openssh-server ca-certificates vim

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

install -d -m 700 "$TARGET/root/.ssh"
cp /root/.ssh/authorized_keys "$TARGET/root/.ssh/authorized_keys"
chmod 600 "$TARGET/root/.ssh/authorized_keys"
mkdir -p "$TARGET/etc/ssh/sshd_config.d"
cat > "$TARGET/etc/ssh/sshd_config.d/10-ovh-root.conf" <<'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
EOF

chroot "$TARGET" /bin/bash -e <<'EOF'
ssh-keygen -A
systemctl enable ssh systemd-networkd systemd-resolved
update-initramfs -u -k all
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Debian
update-grub
EOF

printf '\nDebian Trixie installée sur %s (IPv6 %s). Redémarrage manuel.\n' "$DISK" "$IPV6_ADDR"
