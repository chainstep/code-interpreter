#!/bin/bash

echo "Starting Sandbox (direct NsJail, no microVM) on port 2000..."

ROOTFS="${SANDBOX_ROOTFS:-/sandbox-rootfs}"

if [ ! -x "$ROOTFS/sandbox_api/entrypoint.sh" ]; then
    echo "FATAL: no sandbox rootfs at $ROOTFS - the directory-root image target is required when KVM_ENABLED=false"
    exit 1
fi

if mount -o remount,rw /sys/fs/cgroup 2>/dev/null; then
    echo "[sandbox] Remounted cgroupfs as rw"
else
    echo "[sandbox] WARNING: could not remount cgroupfs rw - NsJail cgroup isolation may fail"
fi

mkdir -p /sys/fs/cgroup/init
echo "[sandbox] Draining root cgroup ($(wc -w < /sys/fs/cgroup/cgroup.procs 2>/dev/null || echo '?') procs) into init/..."
_root_procs=$(cat /sys/fs/cgroup/cgroup.procs 2>/dev/null || true)
for _pid in $_root_procs; do
    echo "$_pid" > /sys/fs/cgroup/init/cgroup.procs 2>/dev/null || true
done
_remaining=$(wc -w < /sys/fs/cgroup/cgroup.procs 2>/dev/null || echo "?")
echo "[sandbox] Root cgroup procs after drain: $_remaining"

if echo "+memory +pids" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null; then
    echo "[sandbox] Enabled +memory +pids on root cgroup.subtree_control"
else
    echo "[sandbox] WARNING: could not enable controllers on root ($_remaining procs remain)"
fi

export SANDBOX_ROOTFS="$ROOTFS"

exec unshare --mount bash -c '
    ROOTFS="${SANDBOX_ROOTFS:-/sandbox-rootfs}"

    mount --bind "$ROOTFS" "$ROOTFS" || { echo "FATAL: cannot bind $ROOTFS onto itself"; exit 1; }

    mkdir -p "$ROOTFS/proc" "$ROOTFS/sys" "$ROOTFS/dev" "$ROOTFS/pkgs" "$ROOTFS/tmp" "$ROOTFS/.oldroot"

    if mount -t proc proc "$ROOTFS/proc" 2>/dev/null; then
        echo "[sandbox] Mounted fresh procfs"
    else
        echo "[sandbox] WARNING: fresh procfs unavailable, reusing the container /proc"
        mount --rbind /proc "$ROOTFS/proc" || { echo "FATAL: cannot bind /proc"; exit 1; }
    fi

    mount --rbind /sys "$ROOTFS/sys" || { echo "FATAL: cannot bind /sys"; exit 1; }
    mount --rbind /dev "$ROOTFS/dev" || { echo "FATAL: cannot bind /dev"; exit 1; }

    for host_file in /etc/resolv.conf /etc/hosts /etc/hostname; do
        [ -f "$host_file" ] || continue
        [ -e "$ROOTFS$host_file" ] || : > "$ROOTFS$host_file" 2>/dev/null || continue
        mount --bind "$host_file" "$ROOTFS$host_file" 2>/dev/null || \
            echo "[sandbox] WARNING: could not bind $host_file"
    done

    if [ -d /host-packages ] && [ -n "$(ls -A /host-packages 2>/dev/null)" ]; then
        mount --bind /host-packages "$ROOTFS/pkgs" || \
            echo "[sandbox] WARNING: could not bind /host-packages - sandbox will run without packages"
    elif [ -z "$(ls -A "$ROOTFS/pkgs" 2>/dev/null)" ]; then
        echo "[sandbox] WARNING: no packages found - populate the host package directory or no runtime will be available"
    fi

    chmod 1777 "$ROOTFS/tmp" 2>/dev/null || true

    cd "$ROOTFS" || { echo "FATAL: cannot enter $ROOTFS"; exit 1; }
    pivot_root . .oldroot || { echo "FATAL: pivot_root into $ROOTFS failed"; exit 1; }
    cd /

    if command -v umount >/dev/null 2>&1; then
        umount -l /.oldroot 2>/dev/null || echo "[sandbox] WARNING: could not detach the previous root"
        rmdir /.oldroot 2>/dev/null || true
    else
        echo "[sandbox] WARNING: umount is unavailable, the previous root stays mounted at /.oldroot"
    fi

    echo "[sandbox] Running on the sandbox rootfs"

    exec /sandbox_api/entrypoint.sh
'
