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
curl -sL "https://dl-cdn.alpinelinux.org/alpine/v3.20/main/aarch64/busybox-static-1.36.1-r31.apk" \
    -o "$TMP/bbx.apk"
mkdir -p "$TMP/bbx"
tar xzf "$TMP/bbx.apk" -C "$TMP/bbx"
mkdir -p "$TMP/bin"
cp "$TMP/bbx/bin/busybox.static" "$TMP/bin/busybox"
chmod 755 "$TMP/bin/busybox"
# applet symlinks
for a in sh mount umount switch_root insmod modprobe depmod ls cat \
         echo mkdir sleep poweroff reboot mv cp rm mknod; do
    ln -s busybox "$TMP/bin/$a"
done

# --- 2. display modules (msm + dependency closure from modules.dep) ---
echo "==> copying display modules (msm dependency closure)"
mkdir -p "$MODDIR"
cp -r "$SRC_MODS/lib/modules/$RELEASE/modules."* "$MODDIR/" 2>/dev/null || true
cp "$SRC_MODS/lib/modules/$RELEASE/modules.dep" "$MODDIR/" 2>/dev/null || true

# closure: everything msm.ko depends on (recursively), plus drm core/panel/backlight
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

# seed list: msm + drm core + panels + backlight
seeds = [m for m in dep if '/msm/msm.ko' in m or m.startswith('kernel/drivers/gpu/drm/')]
seeds += [m for m in dep if '/video/backlight/' in m]
for m in dep:
    if '/drm/panel/' in m:
        seeds.append(m)
for s in seeds:
    add_closure(s)

for m in sorted(kept):
    src = os.path.join(srcmod, m)
    dst = os.path.join(moddir, m)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy2(src, dst)
print(f"    {len(kept)} module files copied")
PYEOF

# --- 3. init script ---
cat > "$TMP/init" << 'INITEOF'
#!/bin/sh
# C13 minimal initramfs init: mount /proc /sys /dev, load display
# modules, then switch_root to the real rootfs.
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

echo "[init] C13 initramfs starting"
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null
mdev -s 2>/dev/null || true

# Try to load the msm display stack (needed for DRM console / fbcon)
if ls /lib/modules/*/kernel/drivers/gpu/drm/msm/msm.ko* >/dev/null 2>&1; then
    echo "[init] loading msm display stack"
    modprobe msm 2>/dev/null || {
        # fallback: load deps in order then msm
        for m in drm drm_kms_helper drm_shmem_helper gpu-sched \
                 drm_display_helper drm_dp_aux_bus drm_exec drm_client_lib \
                 aux-bridge drm_gpuvm; do
            insmod /lib/modules/*/kernel/drivers/gpu/drm/$m.ko* 2>/dev/null || true
        done
        insmod /lib/modules/*/kernel/drivers/gpu/drm/msm/msm.ko* 2>/dev/null || true
    }
fi

# Locate the real rootfs: scan block devices for a partition that looks
# like a Linux rootfs (has /etc and an init).
echo "[init] scanning for rootfs"
for dev in /dev/sd?[0-9] /dev/mmcblk?p[0-9] /dev/block/platform/*/by-name/*; do
    [ -b "$dev" ] || continue
    case "$dev" in
        *boot*|*recovery*|*persist*|*modem*|*dsp*) continue;;
    esac
    mkdir -p /mnt
    if mount -t ext4 "$dev" /mnt 2>/dev/null || \
       mount -t f2fs "$dev" /mnt 2>/dev/null || \
       mount -t auto "$dev" /mnt 2>/dev/null; then
        if [ -d /mnt/etc ] && { [ -x /mnt/sbin/init ] || [ -x /mnt/usr/lib/systemd/systemd ] || [ -x /mnt/lib/systemd/systemd ]; }; then
            echo "[init] rootfs found on $dev"
            exec switch_root /mnt /sbin/init
        fi
        umount /mnt 2>/dev/null
    fi
done

echo "[init] FATAL: no rootfs found"
echo "[init] block devices:"
ls -l /dev/sd* /dev/mmcblk* 2>/dev/null
exec /bin/sh
INITEOF
chmod 755 "$TMP/init"

# --- 4. pack ---
echo "==> packing initramfs"
( cd "$TMP" && find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -9 > "$OUT_GZ" )

echo "==> done: $OUT_GZ ($(stat -c%s "$OUT_GZ") bytes)"
