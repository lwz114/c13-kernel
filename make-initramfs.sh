#!/bin/bash
# Build a minimal Linux initramfs for the Readboy C13.
# Loads display modules (msm + deps) and switch_root to the real rootfs.
# Usage: make-initramfs.sh <modules-dir> <out-initramfs.gz>
#   modules-dir: lib/modules/<release>/ tree from modules_install
set -e

SRC_MODS="${1:?modules dir (contains lib/modules/<rel>)}"
OUT_GZ="${2:?output initramfs.gz}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

RELEASE="$(ls "$SRC_MODS/lib/modules/" | head -1)"
MODDIR="$TMP/lib/modules/$RELEASE"
echo "==> kernel release: $RELEASE"

# --- 1. static busybox ---
echo "==> fetching static aarch64 busybox"
# resolve latest busybox-static version from Alpine index (avoid hardcoded 404s)
BBX_URL=""
for i in 1 2 3; do
    BBX_URL="$(curl -sL "https://dl-cdn.alpinelinux.org/alpine/v3.20/main/aarch64/APKINDEX.tar.gz" \
        | tar -xzO APKINDEX 2>/dev/null \
        | awk '/^P:busybox-static$/{f=1;next} f&&/^V:/{v=substr($0,3); print "https://dl-cdn.alpinelinux.org/alpine/v3.20/main/aarch64/busybox-static-"v".apk"; exit}')"
    [ -n "$BBX_URL" ] && break
    sleep 2
done
[ -n "$BBX_URL" ] || BBX_URL="https://dl-cdn.alpinelinux.org/alpine/v3.20/main/aarch64/busybox-static-1.36.1-r31.apk"
echo "    busybox URL: $BBX_URL"
curl -sL "$BBX_URL" -o "$TMP/bbx.apk"
mkdir -p "$TMP/bbx"
tar xzf "$TMP/bbx.apk" -C "$TMP/bbx"
mkdir -p "$TMP/bin"
cp "$TMP/bbx/bin/busybox.static" "$TMP/bin/busybox"
chmod 755 "$TMP/bin/busybox"
# applet symlinks (network tools included so USB gadget + telnet work)
for a in sh mount umount switch_root insmod modprobe depmod ls cat \
         echo mkdir sleep poweroff reboot mv cp rm mknod dmesg \
         ip ifconfig telnetd nc udhcpc hostname grep sed awk cut tr \
         find df free ps kill sync zcat gzip ln blkid chroot head tail; do
    ln -s busybox "$TMP/bin/$a"
done

# --- 2. full module tree (display closure + input/usb/hid for keyboard) ---
echo "==> copying module tree (display + input + usb/hid)"
mkdir -p "$MODDIR"
cp -r "$SRC_MODS/lib/modules/$RELEASE/modules."* "$MODDIR/" 2>/dev/null || true
cp "$SRC_MODS/lib/modules/$RELEASE/modules.dep" "$MODDIR/" 2>/dev/null || true

# closure: everything msm.ko depends on (recursively), plus drm core/panel/backlight,
# plus input (touchscreen/keys), hid, usb (host/storage/gadget)
python3 - "$MODDIR" "$SRC_MODS/lib/modules/$RELEASE" << 'PYEOF'
import os, re, sys, shutil

moddir = sys.argv[1]          # target lib/modules/<rel>
srcmod = sys.argv[2]          # source lib/modules/<rel>
os.makedirs(moddir, exist_ok=True)

def parse_dep(fn):
    deps = {}
    with open(fn) as f:
        for line in f:
            line = line.rstrip('\n')
            if not line:
                continue
            parts = line.split(':')
            mod = parts[0].strip()
            deps[mod] = [d.strip() for d in parts[1].split() if d.strip()]
    return deps

dep = parse_dep(os.path.join(srcmod, 'modules.dep'))
kept = set()

def add_closure(root):
    stack = [root]
    while stack:
        m = stack.pop()
        if m in kept:
            continue
        kept.add(m)
        for d in dep.get(m, []):
            stack.append(d)

# seed list: msm + drm core + panels + backlight (display ONLY - adding
# input/usb/hid modules here caused display blackscreen after switch_root)
seeds = [m for m in dep if '/msm/msm.ko' in m or m.startswith('kernel/drivers/gpu/drm/')]
seeds += [m for m in dep if '/video/backlight/' in m]
for m in dep:
    if '/drm/panel/' in m:
        seeds.append(m)
for s in seeds:
    add_closure(s)

for m in sorted(kept):
    src = os.path.join(srcmod, m)
    if not os.path.exists(src):
        continue  # trimmed away; skip (module is builtin or unnecessary)
    dst = os.path.join(moddir, m)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy2(src, dst)
print(f"    {len(kept)} module files in closure, copied those that exist")
PYEOF

# --- 3. init script ---
# create mount points inside the cpio (they are not in the archive)
mkdir -p "$TMP/proc" "$TMP/sys" "$TMP/dev" "$TMP/mnt" "$TMP/etc"
cat > "$TMP/init" << 'INITEOF'
#!/bin/sh
# C13 minimal initramfs init: mount /proc /sys /dev, load display
# modules, then switch_root to the real rootfs.
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

echo "[init] C13 initramfs starting"
mkdir -p /proc /sys /dev /mnt
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null
mdev -s 2>/dev/null || true

# --- USB gadget ECM network + telnetd: remote access without keyboard ---
echo "[init] bringing up USB gadget (ECM)"
mount -t configfs configfs /sys/kernel/config 2>/dev/null
UDC="$(ls /sys/class/udc/ 2>/dev/null | head -1)"
if [ -n "$UDC" ] && [ -d /sys/kernel/config/usb_gadget ]; then
    mkdir -p /sys/kernel/config/usb_gadget/c13
    echo 0x1d6b > /sys/kernel/config/usb_gadget/c13/idVendor
    echo 0x0104 > /sys/kernel/config/usb_gadget/c13/idProduct
    mkdir -p /sys/kernel/config/usb_gadget/c13/strings/0x409
    echo "C13" > /sys/kernel/config/usb_gadget/c13/strings/0x409/serialnumber
    echo "C13 initramfs" > /sys/kernel/config/usb_gadget/c13/strings/0x409/product
    mkdir -p /sys/kernel/config/usb_gadget/c13/configs/c.1/strings/0x409
    echo "ECM" > /sys/kernel/config/usb_gadget/c13/configs/c.1/strings/0x409/configuration
    mkdir -p /sys/kernel/config/usb_gadget/c13/functions/ecm.usb0
    ln -sf /sys/kernel/config/usb_gadget/c13/functions/ecm.usb0 /sys/kernel/config/usb_gadget/c13/configs/c.1/
    echo "$UDC" > /sys/kernel/config/usb_gadget/c13/UDC 2>/dev/null
    sleep 1
    ifconfig usb0 10.15.19.2 netmask 255.255.255.0 up 2>/dev/null || \
        ip addr add 10.15.19.2/24 dev usb0 2>/dev/null
    echo "[init] USB gadget up: usb0 10.15.19.2"
    # netcat-based root shell on :23 (no keyboard needed)
    (nc -l -p 23 -e /bin/sh -k 2>/dev/null &)
    (nc -l -p 23 -e /bin/sh 2>/dev/null &)
    echo "[init] nc shell on :23 (usb0 10.15.19.2)"
else
    echo "[init] WARN: no UDC found, USB gadget unavailable"
fi

# Try to load the msm display stack (needed for DRM console / fbcon)
if ls /lib/modules/*/kernel/drivers/gpu/drm/msm/msm.ko* >/dev/null 2>&1; then
    echo "[init] loading msm display stack"
    # modprobe first (needs modules.dep); fall back to insmod in dep order
    # (insmod cannot load .ko.zst -> decompress with zcat first)
    if ! modprobe msm 2>/dev/null; then
        echo "[init] modprobe failed, manual insmod (zcat .ko.zst)"
        mkdir -p /tmp/mod
        for m in drm drm_kms_helper drm_shmem_helper gpu-sched \
                 drm_display_helper drm_dp_aux_bus drm_exec drm_client_lib \
                 aux-bridge drm_gpuvm drm_panel_orientation_quirks \
                 mdt_loader ubwc_config cec msm; do
            for f in /lib/modules/*/kernel/drivers/gpu/drm/$m.ko* \
                     /lib/modules/*/kernel/drivers/gpu/drm/msm/$m.ko* \
                     /lib/modules/*/kernel/drivers/soc/qcom/$m.ko* \
                     /lib/modules/*/kernel/drivers/media/cec/core/$m.ko*; do
                [ -f "$f" ] || continue
                case "$f" in
                    *.zst) zcat "$f" > /tmp/mod/$m.ko 2>/dev/null && insmod /tmp/mod/$m.ko 2>/dev/null ;;
                    *) insmod "$f" 2>/dev/null ;;
                esac
            done
        done
    fi
    echo "[init] DRM devices: $(ls /sys/class/drm/ 2>/dev/null | tr '\n' ' ')"
fi

# Locate the real rootfs: scan block devices for a partition that looks
# like a Linux rootfs (has /etc and an init).
echo "[init] scanning for rootfs"
ROOTFS_DEV=""

# userdata partition (LABEL=rootfs) is /dev/sda9 on the C13
for try in /dev/sda9 /dev/sdb9 /dev/sdc9 /dev/mmcblk0p9; do
    [ -b "$try" ] || continue
    mkdir -p /mnt
    if mount -t ext4 "$try" /mnt 2>/dev/null || \
       mount -t f2fs "$try" /mnt 2>/dev/null || \
       mount -t auto "$try" /mnt 2>/dev/null; then
        if [ -d /mnt/etc ] && { [ -x /mnt/sbin/init ] || [ -x /mnt/usr/lib/systemd/systemd ] || [ -x /mnt/lib/systemd/systemd ]; }; then
            echo "[init] rootfs found on $try"
            ROOTFS_DEV="$try"
            break
        fi
        umount /mnt 2>/dev/null
    fi
done

if [ -z "$ROOTFS_DEV" ]; then
    for dev in /dev/sd?[0-9] /dev/sd[a-z]*[0-9]* /dev/mmcblk?p[0-9]; do
        [ -b "$dev" ] || continue
        case "$dev" in
            /dev/sd[a-z]) continue;;
        esac
        [ "$dev" = "$ROOTFS_DEV" ] && continue
        mkdir -p /mnt
        if mount -t ext4 "$dev" /mnt 2>/dev/null || \
           mount -t f2fs "$dev" /mnt 2>/dev/null || \
           mount -t auto "$dev" /mnt 2>/dev/null; then
            if [ -d /mnt/etc ] && { [ -x /mnt/sbin/init ] || [ -x /mnt/usr/lib/systemd/systemd ] || [ -x /mnt/lib/systemd/systemd ]; }; then
                echo "[init] rootfs found on $dev"
                ROOTFS_DEV="$dev"
                break
            fi
            umount /mnt 2>/dev/null
        fi
    done
fi

if [ -n "$ROOTFS_DEV" ]; then
    echo "[init] installing modules into rootfs"
    if [ -d /lib/modules ] && [ -d /mnt/lib ]; then
        mkdir -p /mnt/lib/modules
        cp -a /lib/modules/* /mnt/lib/modules/ 2>/dev/null || true
    fi
    # --- boot fixes on the rootfs (idempotent) ---
    echo "[init] applying boot fixes to rootfs"
    rm -f /mnt/etc/systemd/system/network-online.target.wants/NetworkManager-wait-online.service
    rm -f /mnt/etc/systemd/system/network-online.target.wants/systemd-networkd-wait-online.service
    ln -sf /dev/null /mnt/etc/systemd/system/NetworkManager-wait-online.service 2>/dev/null
    ln -sf /dev/null /mnt/etc/systemd/system/systemd-networkd-wait-online.service 2>/dev/null
    rm -f /mnt/etc/systemd/system/graphical.target.wants/gnome-remote-desktop.service
    rm -f /mnt/etc/systemd/system/graphical.target.wants/gnome-remote-desktop-configuration.service
    ln -sf /lib/systemd/system/graphical.target /mnt/etc/systemd/system/default.target 2>/dev/null
    sync
    echo "[init] boot fixes applied, switching root"
    exec switch_root /mnt /sbin/init
fi

echo "[init] FATAL: no rootfs found"
echo "[init] block devices:"
ls -l /dev/sd* /dev/mmcblk* 2>/dev/null
echo "[init] keeping shell alive for nc access (usb0 10.15.19.2:23)"
while true; do nc -l -p 23 -e /bin/sh 2>/dev/null; done
INITEOF
chmod 755 "$TMP/init"

# --- 4. pack ---
echo "==> packing initramfs"
rm -rf "$TMP/bbx" "$TMP/bbx.apk"
OUT_GZ_ABS="$(realpath -m "$OUT_GZ")"
( cd "$TMP" && find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -9 > "$OUT_GZ_ABS" )

echo "==> done: $OUT_GZ ($(stat -c%s "$OUT_GZ_ABS") bytes)"
