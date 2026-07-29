#!/usr/bin/env bash
#
# samba-mdns.sh - advertise the Time Machine share so the Mac can find it.
#
# WHY THIS IS A SEPARATE PROCESS AT ALL
#
# vfs_fruit(8) says fruit:time machine = yes "also registers the share with mDNS
# in case Samba is built with mDNS support". nixpkgs does not build it that way.
# Checked on samba 4.23.8:
#
#   $ ldd .../bin/smbd | grep -ciE 'avahi|dns_sd|mdns'
#   0
#   $ strings .../bin/smbd | grep -iE 'DNSServiceRegister|avahi_client'
#   (no output)
#
# So the advertisement has to come from somewhere else. This is that somewhere.
#
# WHY avahi-publish AND NOT /etc/avahi/services
#
# The usual answer is an XML service file dropped in /etc/avahi/services. That
# path is root owned, and this repo does not take root to configure a user's
# backup target. avahi-publish asks the running system daemon over D-Bus as an
# ordinary user, which needs no privilege and no file outside the home.
#
# The cost is that the records live only as long as this process. That is what
# the systemd unit is for, and it is arguably better: when smbd stops, the
# advertisement stops with it, so the Mac stops being told about a share that is
# not being served.
#
# WHAT macOS ACTUALLY NEEDS
#
# Three records, and all three matter for different reasons.
#
# _smb._tcp is what puts the machine in Finder's sidebar under Network.
#
# _device-info._tcp carries the model string. It only changes which icon Finder
# draws, but TimeCapsule8,119 is what makes it read as a backup appliance rather
# than a generic server.
#
# _adisk._tcp is the one Time Machine reads. sys=adVF=0x100 announces that the
# server supports the volume flags. dk0=adVN=<share>,adVF=0x82 names disk zero,
# gives its volume name, and 0x82 marks it usable as a Time Machine destination.
# The name in adVN must match the smb.conf share name exactly, or the Mac offers
# a destination that then fails to mount.
#
# Port 9 on the two informational records is the convention. Nothing connects to
# them, they exist to carry TXT records, and 9 is discard.
#
# Without _adisk._tcp the share is not gone, it is merely not offered. It can
# still be mounted by hand in Finder and Time Machine will accept it, because
# vfs_fruit advertises the capability over SMB itself. This service is what makes
# it appear without anyone mounting anything.

shareName="${1:?samba-mdns: no share name given}"
model="${2:-TimeCapsule8,119}"
port="${3:-445}"

# The short hostname. avahi-publish takes a literal name, unlike an avahi service
# FILE, where %h is a wildcard the daemon expands. Passing %h here would publish a
# service literally called "%h".
host="$(uname -n)"
host="${host%%.*}"

pids=()

# Kill the siblings when any one of them goes. Three half-published records are
# worse than none: Finder would show the machine while Time Machine silently had
# nowhere to write.
cleanup() {
  trap - EXIT INT TERM
  for p in "${pids[@]}"; do
    kill "$p" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM

avahi-publish-service "$host" _smb._tcp "$port" &
pids+=("$!")

avahi-publish-service "$host" _device-info._tcp 9 "model=$model" &
pids+=("$!")

avahi-publish-service "$host" _adisk._tcp 9 \
  "sys=adVF=0x100" \
  "dk0=adVN=$shareName,adVF=0x82" &
pids+=("$!")

# Return as soon as ANY publisher exits, rather than waiting for all three. A
# publisher that dies has dropped its record, and systemd should restart the set
# rather than leave a partial advertisement standing.
wait -n
