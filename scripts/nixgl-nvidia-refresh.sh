#!/usr/bin/env bash
#
# nixgl-nvidia-refresh.sh - print the nvidiaVersion + nvidiaHash to pin in
# flake.nix's legacyPackages.nixGLNvidia after an NVIDIA driver update.
#
# Why this exists: nixGLNvidia is pinned (not auto-detected) so it stays PURE
# and needs no --impure. Auto-detection is inherently impure (it reads the live
# /proc/driver/nvidia/version), so instead of paying that cost on every build,
# we pin and refresh on the rare driver bump. This script does the refresh: it
# reads the running driver version and prefetches the matching .run for its hash.
#
# It also parses the version itself rather than leaning on nixGL's parser, whose
# regex ("...Module  <ver>...") does not match the NVIDIA Open Kernel Module
# string ("...Open Kernel Module for x86_64  <ver>..."), which is what breaks
# nixGL's auto path on this machine in the first place.
#
# Prints only. It never edits flake.nix or touches git — paste the two lines in.

set -euo pipefail

version_file=/proc/driver/nvidia/version
if [[ ! -r "$version_file" ]]; then
  echo "nixgl-nvidia-refresh: $version_file not readable (NVIDIA kernel module loaded?)" >&2
  exit 1
fi

# First line is the NVRM line; the driver version is its first X.Y.Z token. The
# GCC version lives on a later line, so restrict to line 1.
version=$(sed -n '1p' "$version_file" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)
if [[ -z "$version" ]]; then
  echo "nixgl-nvidia-refresh: could not parse a version from:" >&2
  sed -n '1p' "$version_file" >&2
  exit 1
fi

url="https://download.nvidia.com/XFree86/Linux-x86_64/${version}/NVIDIA-Linux-x86_64-${version}.run"
echo "Detected NVIDIA driver: $version" >&2
echo "Prefetching $url ..." >&2

hash=$(nix store prefetch-file --json "$url" | jq -r .hash)

cat <<EOF

Paste these into flake.nix (legacyPackages.nixGLNvidia):

          nvidiaVersion = "${version}";
          nvidiaHash = "${hash}";
EOF
