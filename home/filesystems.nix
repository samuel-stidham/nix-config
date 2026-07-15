{ ... }:

# Deliberately empty.
#
# This module used to install btrfs-progs, compsize, exfatprogs, and
# smartmontools into the user profile. That was a mistake, and the reason is
# worth keeping written down.
#
# Every one of those tools requires root. sudo resets PATH to its secure_path,
# which contains /usr/sbin:/usr/bin:/sbin:/bin and nothing else. The nix profile
# is not in it and should not be. So:
#
#   smartctl        -> /home/samuelstidham/.nix-profile/bin/smartctl
#   sudo smartctl   -> command not found
#
# The tools were on PATH and simultaneously unusable for the only thing they are
# for. `sudo btrfs` appeared to work only because btrfs-progs had also been
# installed from apt, so sudo was silently running a different binary than the
# one this file provided. That is worse than not having it.
#
# The rule this settles: a tool that always needs root belongs in the SYSTEM
# layer, installed by bootstrap.sh through the distro's package manager, where
# secure_path can find it. Nix owns the user's tools. The distro owns root's.
#
# See _system_debian and _system_fedora in bootstrap.sh for where these live now.
{ }
