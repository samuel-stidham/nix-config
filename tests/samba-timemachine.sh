#!/usr/bin/env bash
#
# samba-timemachine.sh - assert the Time Machine share cannot fail quietly.
#
# WHY A GOLDEN CANNOT CATCH THESE. hm-output.sh already captures both generated
# units verbatim, so it sees any change to an ExecStart. What it cannot see is
# whether the change is WRONG. Rename the share in home/samba.nix, recapture the
# golden, and the golden now states that smbd serves "timemachine" while the mDNS
# record advertises a volume called something else. Both units changed, the
# capture blessed both, and the diff is clean forever after.
#
# The Mac's symptom is not an error either. Time Machine lists a destination,
# accepts it, and fails to mount it. That reads as a broken drive.
#
# So this file records what MUST BE TRUE rather than what is.
#
# IT RUNS THE SHIPPED SCRIPT, NOT A COPY OF ITS LOGIC. The ExecStart is read out
# of the generated unit and executed, so what is under test is the store path
# that systemd would actually run, with the same arguments. Reimplementing the
# checks here would test this file's idea of the config instead of the config.
#
# THE UNMOUNTED CASE IS THE IMPORTANT ONE. If the drive is absent and the script
# creates the share directory anyway, it lands on the root filesystem under an
# empty mountpoint, and Time Machine fills the NVMe system disk. Nothing reports
# an error until / is full. That case is exercised with a label no drive has,
# through the real resolver rather than a stub.
#
# It builds the activation package, so it gates the REPO and not the switched
# machine, the same split as git-identity.sh.
#
#   ./samba-timemachine.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
ATTR='.#homeConfigurations."samuelstidham@x86_64-linux".activationPackage'
# shellcheck source=lib-build.sh
. "$HERE/lib-build.sh"

fail=0
ok()  { printf 'ok    %-34s %s\n' "$1" "${2:-}"; }
bad() { printf 'FAIL  %-34s %s\n' "$1" "$2"; fail=1; }

out="$(build_out)"
if [ -z "$out" ] || [ ! -e "$out" ]; then
  echo "samba-timemachine: nix build produced no path" >&2
  exit 1
fi
UNITS="$out/home-files/.config/systemd/user"

# testparm comes out of the BUILT closure, not off PATH. Off PATH it would be
# whatever was last switched in, so the test would grade this tree using last
# night's samba, and on a machine that has never switched it would not exist.
testparm="$out/home-path/bin/testparm"
if [ ! -x "$testparm" ]; then
  echo "samba-timemachine: no testparm in the built closure at $testparm" >&2
  echo "samba-timemachine: is pkgs.samba still in home.packages?" >&2
  exit 1
fi

smbd_unit="$UNITS/smbd.service"
mdns_unit="$UNITS/samba-mdns.service"
for u in "$smbd_unit" "$mdns_unit"; do
  if [ ! -f "$u" ]; then
    echo "samba-timemachine: no generated unit at $u" >&2
    exit 1
  fi
done

execstart() { sed -n 's/^ExecStart=//p' "$1" | head -1; }

smbd_cmd="$(execstart "$smbd_unit")"
mdns_cmd="$(execstart "$mdns_unit")"

# ExecStart is: <store>/bin/samba-timemachine LABEL SHARE MAXSIZE
read -r smbd_bin smbd_label smbd_share smbd_size _ <<< "$smbd_cmd"
# ExecStart is: <store>/bin/samba-mdns SHARE MODEL PORT
read -r _ mdns_share _ mdns_port _ <<< "$mdns_cmd"

TMP="$(mktemp -d)"
STRAY=""
cleanup() {
  rm -rf "$TMP"
  # The happy-path case creates a real directory on the real drive. Remove it,
  # and never with a bare rm -rf on an empty variable.
  if [ -n "$STRAY" ] && [ -d "$STRAY" ]; then
    rm -rf "$STRAY"
  fi
}
trap cleanup EXIT

# ---- the cross-unit invariant -----------------------------------------------
#
# The share name smbd serves and the adVN the mDNS record advertises are two
# spellings of one value in two different units. They are compared here because
# nothing else compares them.
if [ -z "$smbd_share" ]; then
  bad "share name parsed" "could not read a share name from smbd ExecStart"
elif [ "$smbd_share" = "$mdns_share" ]; then
  ok "share name matches mDNS adVN" "$smbd_share"
else
  bad "share name matches mDNS adVN" "smbd serves [$smbd_share], mDNS advertises [$mdns_share]"
fi

# ---- the port is bindable without root --------------------------------------
#
# smbd runs as a user service. It can only hold 445 because this box lowered the
# floor, see SITES.md. If that sysctl is ever reset to the kernel default of
# 1024, the unit dies at bind and this says so first.
floor="$(sysctl -n net.ipv4.ip_unprivileged_port_start 2>/dev/null || echo 1024)"
if [ "${mdns_port:-0}" -ge "$floor" ] 2>/dev/null; then
  ok "smb port bindable unprivileged" "port $mdns_port >= floor $floor"
else
  bad "smb port bindable unprivileged" "port ${mdns_port:-?} < floor $floor, smbd cannot bind as a user"
fi

# ---- an absent drive must STOP the service ----------------------------------
#
# The real resolver, with a label no drive carries. Nothing is stubbed, so this
# exercises the same code path a missing drive takes.
missing_label="samba-test-no-such-drive-$$"
guard_state="$TMP/guard-state"
guard_out="$TMP/guard.out"
SAMBA_STATE_DIR="$guard_state" \
  "$smbd_bin" "$missing_label" "$smbd_share" "$smbd_size" > "$guard_out" 2>&1
guard_rc=$?

if [ "$guard_rc" -ne 0 ]; then
  ok "absent drive aborts" "exit $guard_rc"
else
  bad "absent drive aborts" "exited 0, it would have served a share off the system disk"
fi
if grep -q 'is not mounted' "$guard_out"; then
  ok "absent drive says why" "$(grep -m1 'is not mounted' "$guard_out" | cut -c1-60)..."
else
  bad "absent drive says why" "no 'is not mounted' message, see $guard_out"
fi
# The guard must abort BEFORE anything is created.
if [ -e "/mnt/$missing_label" ] || [ -e "/media/$USER/$missing_label" ]; then
  bad "absent drive creates nothing" "a directory was created for an unmounted drive"
else
  ok "absent drive creates nothing" ""
fi

# ---- the happy path, against the real drive ---------------------------------
#
# Everything except smbd itself. The script resolves the drive, creates the
# share, applies nodatacow, writes smb.conf, and then stops at the password
# check because no samba password is set in this throwaway state directory.
mount="$(findmnt -rn -o TARGET -S "LABEL=$smbd_label" 2>/dev/null | head -1)"
if [ -z "$mount" ]; then
  bad "drive $smbd_label mounted" "not mounted, the remaining cases cannot run"
else
  ok "drive $smbd_label mounted" "$mount"

  test_share="samba-selftest-$$"
  STRAY="$mount/$test_share"
  run_state="$TMP/run-state"
  run_out="$TMP/run.out"
  SAMBA_STATE_DIR="$run_state" \
    "$smbd_bin" "$smbd_label" "$test_share" "$smbd_size" > "$run_out" 2>&1
  run_rc=$?

  conf="$run_state/smb.conf"

  # It must stop at the password check rather than starting a file server. A
  # zero exit here would mean smbd was launched by a test.
  if [ "$run_rc" -ne 0 ] && grep -q 'no samba password set' "$run_out"; then
    ok "stops without a samba password" "exit $run_rc, names smbpasswd"
  elif [ "$run_rc" -eq 0 ]; then
    bad "stops without a samba password" "exited 0, smbd may have been started"
  else
    bad "stops without a samba password" "exit $run_rc but no password message, see $run_out"
  fi

  if [ ! -f "$conf" ]; then
    bad "smb.conf generated" "no file at $conf"
  else
    ok "smb.conf generated" "$(wc -l < "$conf") lines"

    # testparm is samba's own parser. Anything it warns about is something smbd
    # will complain about on every start.
    tp_out="$TMP/testparm.out"
    if "$testparm" -s --debuglevel=0 "$conf" > "$tp_out" 2>&1; then
      ok "testparm parses smb.conf" ""
    else
      bad "testparm parses smb.conf" "testparm returned nonzero, see $tp_out"
    fi
    if grep -q 'WARNING' "$tp_out"; then
      bad "testparm is warning free" "$(grep -m1 'WARNING' "$tp_out")"
    else
      ok "testparm is warning free" ""
    fi

    # Every share assertion goes through testparm's own resolution rather than
    # scraping its dump, and the difference already caught a bug in THIS file.
    #
    # `testparm -s` prints a parameter once under [global] and omits it from any
    # share that resolves to the same value. Scraping the [share] section
    # therefore reported "vfs objects missing" against a share that resolves the
    # stack correctly. A test that fails on a correct config is worse than no
    # test, because the fix is to weaken the test and the next one gets weakened
    # too. --section-name asks samba what the share actually resolves, inherited
    # globals and built-in defaults included.
    param() {
      "$testparm" -s --debuglevel=0 --section-name="$test_share" \
        --parameter-name="$1" "$conf" 2>/dev/null | tail -1
    }
    want_param() {
      local got
      got="$(param "$1")"
      if printf '%s' "$got" | grep -qiE "$2"; then
        ok "share: $3" "$got"
      else
        bad "share: $3" "resolved [$1] to [$got]"
      fi
    }
    # Without this the share is an ordinary SMB share and Time Machine never
    # offers it as a destination at all.
    want_param "fruit:time machine" '^yes$' 'time machine enabled'
    # Without a cap Time Machine expands until the drive is full, and this drive
    # also holds the Calibre library and Documents.
    want_param "fruit:time machine max size" '^[0-9]+[KMGTP]?$' 'max size is capped'
    # fruit REQUIRES streams_xattr beneath it, see vfs_fruit(8). Order matters,
    # so this asserts the sequence and not merely that both are present.
    want_param "vfs objects" 'fruit.*streams_xattr' 'fruit above streams_xattr'
    # A backup share answering to anyone on the LAN would be worse than none.
    want_param "valid users" "^$USER\$" "valid users = $USER"
    want_param "guest ok" '^no$' 'guest access refused'
  fi

  # ---- nodatacow, the thing that decides whether backups stay fast ----------
  #
  # A sparsebundle is thousands of band files rewritten in place. Under copy on
  # write each rewrite allocates a new extent and the file fragments without
  # bound. The flag is inherited at creation, so it is the directory that has to
  # carry it before any band exists.
  if [ ! -d "$STRAY" ]; then
    bad "share directory created" "no directory at $STRAY"
  else
    ok "share directory created" "$STRAY"
    attrs="$(lsattr -d "$STRAY" 2>/dev/null | awk '{print $1}')"
    case "$attrs" in
      *C*) ok "share is nodatacow" "$attrs" ;;
      *)   bad "share is nodatacow" "flags [$attrs], sparsebundle bands will fragment" ;;
    esac
    # Inheritance is the part that matters. A flag on the directory that new
    # files do not pick up buys nothing.
    probe="$STRAY/.inherit-probe"
    if touch "$probe" 2>/dev/null; then
      pattrs="$(lsattr "$probe" 2>/dev/null | awk '{print $1}')"
      case "$pattrs" in
        *C*) ok "new files inherit nodatacow" "$pattrs" ;;
        *)   bad "new files inherit nodatacow" "flags [$pattrs] on a file created inside" ;;
      esac
      rm -f "$probe"
    else
      bad "new files inherit nodatacow" "could not create a probe file in $STRAY"
    fi
  fi
fi

printf '\n'
if [ "$fail" = 0 ]; then
  echo "samba-timemachine: all cases passed"
else
  echo "samba-timemachine: FAILURES above"
fi
exit $fail
