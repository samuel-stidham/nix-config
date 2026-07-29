#!/usr/bin/env bash
#
# samba-timemachine.sh - a rootless smbd serving one Time Machine share.
#
# The MacBook backs up here over SMB. Everything below exists because samba
# assumes it is root and assumes it owns /etc and /var, and none of that is true
# on this machine.
#
# WHY A USER SERVICE AND NOT A SYSTEM DAEMON
#
# smbd wants port 445, which is privileged. This box already lowered the floor
# for nginx, which holds 443 as a systemd USER service. See SITES.md:101:
#
#   net.ipv4.ip_unprivileged_port_start = 80
#
# 445 is above 80, so an unprivileged smbd binds it with no capability and no
# root. That sysctl is the single load-bearing system dependency here. If it ever
# returns to the kernel default of 1024, this unit dies at bind with EACCES,
# which is loud and legible rather than silent.
#
# Rootless smbd cannot setuid to a connecting user. That is fine, because the
# share has exactly one valid user and it is the user smbd already runs as. A
# second user would need a system daemon and this design would not stretch.
#
# WHY THE MOUNT GUARD IS THE MOST IMPORTANT LINE IN THIS FILE
#
# The share lives on a drive that udisks mounts. If the drive is absent, a plain
# `mkdir -p` would happily create the share directory on the ROOT filesystem,
# underneath an empty mountpoint. smbd would start, the Mac would connect, and
# Time Machine would quietly fill the NVMe system disk with backups nobody asked
# for. Nothing would report an error until / ran out of space.
#
# So the label is resolved with drive-mount and a failure aborts. An unmounted
# backup target must stop the service, not degrade it.
#
# The path is resolved at RUNTIME rather than frozen into the unit at Nix eval
# time. udisks mounts at /media/$USER on Ubuntu, /run/media/$USER on Fedora and
# openSUSE, and this repo pins /mnt/LABEL on a fresh machine. See
# scripts/drive-mount.sh, which exists because nine sites once hardcoded the
# Ubuntu form.
#
# WHY nodatacow, AND THE chattr TRAP
#
# Time Machine over SMB writes a sparsebundle: thousands of fixed-size band files
# rewritten in place, forever. That is the worst case for copy on write. Every
# rewrite allocates a new extent, the file fragments without bound, and a
# multi-TB spinner spends its life seeking.
#
# So the share directory gets nodatacow, and new files inherit it. The obvious
# one-liner does not work, and the failure is worth recording because it looks
# like a broken filesystem rather than a rule:
#
#   $ chattr +C /media/samuelstidham/StoragePrime/TimeMachine
#   chattr: Invalid argument while setting flags on ...
#   $ chattr -c +C /media/samuelstidham/StoragePrime/TimeMachine
#   chattr: Invalid argument while setting flags on ...
#
# The drive is mounted `compress=zstd:3`, so every directory already carries the
# `c` flag. btrfs treats `c` and `C` as mutually exclusive and rejects any single
# ioctl that would leave both set. Clearing and setting in one chattr call fails
# for the same reason. Two calls, in order, succeed:
#
#   $ chattr -c DIR && chattr +C DIR && lsattr -d DIR
#   ---------------C------ DIR
#
# Verified on this machine on 2026-07-28, including that a file created inside
# afterwards inherits `C`.
#
# The trade is real and deliberate. nodatacow also disables checksums for these
# files, so btrfs scrub can no longer detect bit rot inside the sparsebundle.
# That is acceptable here and nowhere else: this is the backup copy, the Mac
# holds the original, and Time Machine verifies its own backups. Fragmentation
# was the failure that actually happens.
#
# The flag only affects files created after it is set, so it is applied while the
# directory is still empty. On a directory that already holds bands, this warns
# instead of pretending.

label="${1:?samba-timemachine: no drive label given}"
shareName="${2:?samba-timemachine: no share name given}"
maxSize="${3:?samba-timemachine: no max size given}"
stateDir="${SAMBA_STATE_DIR:?samba-timemachine: SAMBA_STATE_DIR is unset}"

user="$(id -un)"

# NetBIOS caps a name at 15 characters, and this machine is called
# samuelstidham-X870-Pro-RS-WiFi. Left to itself smbd derives the NetBIOS name
# from the hostname and warns on every start:
#
#   WARNING: The 'netbios name' is too long (max. 15 chars).
#
# Truncating here rather than letting samba do it silently. The value barely
# matters, because this server is SMB2 and above on port 445 only, nmbd never
# runs, and the Mac finds the share over mDNS. It exists to stop samba guessing.
netbios="$(uname -n)"
netbios="${netbios%%.*}"
netbios="${netbios:0:15}"

# Resolve the label to wherever the kernel has it mounted right now.
#
# rc is captured rather than tested inline. drive_mount distinguishes 1 (not
# mounted, a normal answer) from 2 (findmnt missing, a broken machine), and both
# must stop this service. A backup target that is not there is not a reason to
# start anyway. See the exit status contract in scripts/drive-mount.sh.
mount=""
rc=0
mount="$(drive-mount "$label")" || rc=$?
if [ "$rc" -ne 0 ] || [ -z "$mount" ]; then
  printf 'samba-timemachine: %s is not mounted (drive-mount rc=%s), refusing to start\n' \
    "$label" "$rc" >&2
  printf 'samba-timemachine: starting anyway would back the Mac up onto the system disk\n' >&2
  exit 1
fi

share="$mount/$shareName"
mkdir -p "$share"

# nodatacow, in two steps, for the reason in the header comment.
attrs="$(lsattr -d "$share" 2>/dev/null | awk '{print $1}')" || attrs=""
case "$attrs" in
  *C*)
    : # already nodatacow, nothing to do
    ;;
  *)
    # Only meaningful on an empty directory, since the flag is inherited at
    # creation and never applied retroactively.
    shopt -s nullglob dotglob
    existing=("$share"/*)
    shopt -u nullglob dotglob
    if [ "${#existing[@]}" -gt 0 ]; then
      printf 'samba-timemachine: %s already holds %d entries and is not nodatacow\n' \
        "$share" "${#existing[@]}" >&2
      printf 'samba-timemachine: existing bands stay copy-on-write and will fragment\n' >&2
    else
      chattr -c "$share"
      chattr +C "$share"
    fi
    ;;
esac

# Everything samba would put under /var/lib/samba and /run/samba, relocated.
# Without every one of these, smbd tries to write into the store or into /var and
# dies at startup.
mkdir -p \
  "$stateDir/private" \
  "$stateDir/lock" \
  "$stateDir/state" \
  "$stateDir/cache" \
  "$stateDir/run" \
  "$stateDir/ncalrpc" \
  "$stateDir/log"
# private holds the password database, so it is the one that must be tight.
#
# The other three are set explicitly rather than left to the umask. Under a
# restrictive umask they come out 0700 and smbd warns on every start:
#
#   WARNING: lock directory ... should have permissions 0755 for browsing to work
#
# These directories hold no secrets, only tdb state, so 0755 costs nothing.
chmod 700 "$stateDir/private"
chmod 755 "$stateDir/lock" "$stateDir/state" "$stateDir/cache"

conf="$stateDir/smb.conf"

# Generated here rather than written by Nix, because `path` needs the mountpoint
# that was only resolved a moment ago. A store-resident smb.conf would have to
# freeze the Ubuntu path and would be wrong on every other family.
#
# fruit:time machine = yes implies durable handles, and disables kernel oplocks,
# kernel share modes and posix locking for the share. Those are not set by hand
# below because samba enforces them itself, and writing them out again would
# invite someone to "fix" one. See vfs_fruit(8).
cat > "$conf" <<EOF
[global]
   workgroup = WORKGROUP
   server string = %h
   netbios name = $netbios
   server role = standalone server
   security = user
   # NTLMv1 off. NTLMv2 is unaffected and is what macOS uses.
   ntlm auth = no
   # A floor, not a pin. macOS negotiates SMB3.1.1 against this.
   server min protocol = SMB2
   smb ports = 445
   # No printing. Without these smbd probes for CUPS on every connection.
   load printers = no
   printcap name = /dev/null
   disable spoolss = yes

   # Rootless paths. See the header comment.
   private dir = $stateDir/private
   lock directory = $stateDir/lock
   state directory = $stateDir/state
   cache directory = $stateDir/cache
   pid directory = $stateDir/run
   ncalrpc dir = $stateDir/ncalrpc
   passdb backend = tdbsam:$stateDir/private/passdb.tdb

   logging = file
   log file = $stateDir/log/smbd.log
   max log size = 1000

   # Apple interoperability. vfs_fruit(8) requires fruit to be stacked with
   # streams_xattr, and gives catia fruit streams_xattr as its example stack.
   # Order matters and this is that order.
   #
   # catia is inert until fruit:encoding = native is set, which it is not. It is
   # listed anyway so the stack matches the documented one, and so enabling
   # native encoding later is a one-line change rather than one that also has to
   # remember to add catia. A character mapper asked to map nothing does nothing.
   vfs objects = catia fruit streams_xattr
   fruit:aapl = yes
   fruit:nfs_aces = no
   fruit:model = TimeCapsule8,119
   fruit:metadata = stream
   fruit:veto_appledouble = no
   fruit:posix_rename = yes
   fruit:zero_file_id = yes
   fruit:wipe_intentionally_left_blank_rfork = yes
   fruit:delete_empty_adfiles = yes

[$shareName]
   path = $share
   read only = no
   guest ok = no
   valid users = $user
   vfs objects = catia fruit streams_xattr
   fruit:time machine = yes
   # Caps what Time Machine believes the volume holds, so it does not expand to
   # fill an 11TB drive. vfs_fruit(8) is explicit that this number is derived by
   # counting sparsebundle band files, so NOTHING ELSE may live in this share or
   # the accounting silently drifts. That is why the share is its own directory
   # rather than the drive root.
   fruit:time machine max size = $maxSize
EOF

# A samba password is separate from the Unix one and lives in its own passdb.
# Without it the Mac gets NT_STATUS_LOGON_FAILURE, which reads like a wrong
# password rather than an absent account. Fail here instead, with the fix.
#
# The password itself is never in this repo and never in this script. See
# SECRETS.md and .agents/rules.md.
if ! pdbedit -L -s "$conf" 2>/dev/null | grep -q "^$user:"; then
  printf 'samba-timemachine: no samba password set for %s\n' "$user" >&2
  printf 'samba-timemachine: set one, without printing it, with:\n' >&2
  printf '  smbpasswd -s -a %s -c %s\n' "$user" "$conf" >&2
  exit 1
fi

exec smbd --foreground --no-process-group --configfile "$conf"
