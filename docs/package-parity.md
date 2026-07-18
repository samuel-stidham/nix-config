# Package parity

This document records every package the system layer of `bootstrap.sh` installs,
family by family. The system layer is the non-Nix software a fresh desktop does
not ship. Nix owns the same set of user tools everywhere, so it needs no parity
table. Only this thin distro-specific layer changes per family, and this is where
a name drifts and a fresh install fails.

There is one row per package. The columns are the package and its role, then the
name on `debian`, `fedora` and `suse`, then a status. The status is one of four
values. `parity` means the package exists everywhere under the same name.
`renamed` means the name differs per family and the row gives each one. `gap`
means the package is genuinely absent on a family, and the row says what happens
instead. `unverified` means the name could not be confirmed against a package
database.

A status may carry a qualifier after a comma, naming HOW it resolved. `probed` is
a run-time name probe, `vendor repo` and `Flathub id` mark a non-distro source,
`fedora-only prerequisite` is the RPM Fusion enablers, and `resolved` is a former
gap now closed, as with Scheme, which is guile from Nix. The base word is always
one of the four above.

The gap rows are the point of this document. A gap is not a reason to skip a
package in silence. It is a reason to say what the machine does instead, so the
same software still arrives. Those sentences live under the table.

## How the names were verified

Every `fedora` name was read off `packages.fedoraproject.org` at Fedora 43, or
off the RPM Fusion release 43 mirror for the packages RPM Fusion carries. Every
`suse` name was read off the openSUSE Tumbleweed mirror index at
`mirrorcache.opensuse.org`, both the `oss` and `non-oss` repositories. The
`debian` names are confirmed on the reference Ubuntu box with `apt-cache policy`.
That is the authoritative local source for the reference family.

The suse names were checked on BOTH Tumbleweed and Leap, each in its own
container, since `detect_os` maps `opensuse-leap` to the suse family too. `detect`
returns `FAMILY=suse` on both, and every package resolves on both, with two
differences found on Leap. `steam` is absent from Leap's default repos where it
resolves in Tumbleweed's non-oss, so `_system_suse` installs steam on its own and
soft-fails to Flatpak. And Leap carries no `pythonNN-podman-compose` at all, so
the podman-compose probe finds nothing there and prints guidance rather than
fail. Everything else resolves on Leap 16.0, including the calibre X11 dep
`libxcb-cursor0`, which an earlier note wrongly called a Leap gap.

Beyond the index, every `fedora` and `suse` name here was VERIFIED to resolve in
a throwaway container of that distro, with `dnf install --assumeno` on Fedora and
`zypper install --dry-run` on Tumbleweed. `detect` returns the right family in
both. Fedora's base set resolves and RPM Fusion carries `VirtualBox`,
`akmod-VirtualBox` and `steam`. Every suse name including `kernel-default-devel`
and `virtualbox-kmp-default` resolves, with non-oss enabled by default so `steam`
needs no repo step. That is stronger than a live-index read.

The atomic path was verified as far as it can be off an ostree host. Every Flatpak
id `bootstrap.sh` installs, `com.google.Chrome`, `com.visualstudio.code`,
`org.prismlauncher.PrismLauncher`, `com.github.tchx84.Flatseal`, `org.gimp.GIMP`,
`io.ente.auth` and `com.valvesoftware.Steam`, resolves to a real app page on
Flathub. And the three rpm-ostree calls the code makes, `refresh-md`, `install
--idempotent` and `cleanup -m`, are confirmed against the rpm-ostree binary in a
Fedora container.

What is still not tested is BEHAVIOUR. Nothing was installed, booted, or run, so
"resolves" is not "produces the same machine", and no fedora or suse machine
exists here to prove that. The one row that was a real gap, suse `podman-compose`,
is resolved now by a run-time probe. Base Debian, which alone lacked a
`ubuntu-drivers`-style tool, is dropped, so the apt family's driver story is just
`ubuntu-drivers autoinstall` on Ubuntu, Mint, and Pop.

## The table

| package (role) | debian | fedora | suse | status |
| --- | --- | --- | --- | --- |
| podman | `podman` | `podman` | `podman` | parity |
| podman-docker | `podman-docker` | `podman-docker` | `podman-docker` | parity |
| podman-compose | `podman-compose` | `podman-compose` | `python31N-podman-compose`, newest probed | gap (suse), probed |
| openssh-server | `openssh-server` | `openssh-server` | `openssh-server` | parity |
| kernel headers or devel | `linux-headers-$(uname -r)` plus a probed tracker | `kernel-devel` | `kernel-${flavor}-devel`, probed | renamed |
| virtualbox base | `virtualbox` | `VirtualBox`, RPM Fusion | `virtualbox` | renamed |
| virtualbox kernel module | `virtualbox-dkms` | `akmod-VirtualBox`, RPM Fusion | `virtualbox-kmp-${flavor}`, probed | renamed |
| virtualbox GUI | in `virtualbox` | in `VirtualBox` | `virtualbox-qt`, split out | renamed |
| steam | `steam-installer`, multiverse | `steam`, RPM Fusion nonfree | `steam`, non-oss repo | renamed |
| fuse2 compat | `libfuse2t64` or `libfuse2`, probed | `fuse-libs` | `libfuse2` | renamed |
| xdg-desktop-portal-gtk | `xdg-desktop-portal-gtk` | `xdg-desktop-portal-gtk` | `xdg-desktop-portal-gtk` | parity |
| btrfs tools | `btrfs-progs` | `btrfs-progs` | `btrfsprogs`, no hyphen | renamed |
| smartmontools | `smartmontools` | `smartmontools` | `smartmontools` | parity |
| hdparm | `hdparm` | `hdparm` | `hdparm` | parity |
| exfatprogs | `exfatprogs` | `exfatprogs` | `exfatprogs` | parity |
| Scheme | from Nix | from Nix | from Nix | resolved, guile in nixpkgs |
| flatpak | `flatpak` | `flatpak` | `flatpak` | parity |
| calibre X11 dep | `libxcb-cursor0` | `xcb-util-cursor` | `libxcb-cursor0` | renamed |
| native firewall | `ufw` | `firewalld` | `firewalld` | renamed, probed |
| nvidia driver | `ubuntu-drivers-common`, autoinstall | `akmod-nvidia` plus `xorg-x11-drv-nvidia-cuda`, RPM Fusion nonfree | NVIDIA community repo, `install-new-recommends` | renamed |
| virtualbox ext-pack | `virtualbox-ext-pack` | unpackaged | unpackaged | gap (fedora, suse) |
| google-chrome-stable | `google-chrome-stable` | `google-chrome-stable` | `google-chrome-stable` | parity, vendor repo |
| VS Code | `code` | `code` | `code` | parity, vendor repo |
| RPM Fusion enablers | not applicable | `rpmfusion-free-release`, `rpmfusion-nonfree-release` | not applicable | fedora-only prerequisite |
| Flatseal | `com.github.tchx84.Flatseal` | same | same | parity, Flathub id |
| GIMP | `org.gimp.GIMP` | same | same | parity, Flathub id |
| Ente Auth | `io.ente.auth` | same | same | parity, Flathub id |

## What the gaps do instead

The gap rows are the reason this document exists. Each one names what the machine
installs when the distro package is absent, so the same software still arrives.

### podman-compose on suse

openSUSE has no unversioned `podman-compose` and, confirmed in a Tumbleweed
container, no `python3-podman-compose` either. `zypper install python3-podman-compose`
errors "not found in package names", and the capability search finds no provider.
The only real packages are version-pinned, `python313-podman-compose` and
`python314-podman-compose` today, and the python version moves. So `_system_suse`
probes at run time: `zypper se podman-compose` lists the flavors, `sort -V` picks
the newest, and it installs that. If none is found it says so rather than fail.
Verified: the probe selects `python314-podman-compose` in a current Tumbleweed
container.

### Scheme, guile instead of mit-scheme

mit-scheme was the original choice and it is a genuine gap. It is absent from the
Fedora database and from both suse oss indexes. Fedora ships `chez-scheme` and
`chibi-scheme`, and suse ships `scheme48` and `chezscheme`, none of which is a
drop-in, and on Ubuntu it came only from apt. So Scheme moved to guile, which is
in nixpkgs and packaged on every distro. One Nix package, `guile` at 3.0.11, now
gives the same Scheme on every family, and the system layer installs none.

This is the pattern for a package that is absent or renamed across families. When
a good cross-platform equivalent exists in nixpkgs, take it from Nix and drop the
per-distro juggling entirely, rather than maintain a name per distro.

### calibre X11 dependency, a rename not a gap

The calibre binary installer bundles Qt but not the X11 libraries Qt loads at
startup. Without `libxcb-cursor.so.0`, calibre installs and then dies at first
launch with "You are missing the system library libxcb-cursor.so.0". The library
is `libxcb-cursor0` on Debian and openSUSE, and `xcb-util-cursor` on Fedora, which
ships the same shared object under a different package name. VERIFIED in
containers: `libxcb-cursor0` resolves on both Tumbleweed and Leap 16.0, and
`xcb-util-cursor` resolves on Fedora. An earlier note called this a Leap 16 gap,
read off a web page, and it was wrong. There is no gap here, only a rename.

### VirtualBox extension pack on fedora and suse

The Oracle extension pack adds the USB 2.0 and 3.0 controllers, and without it
VirtualBox lists no USB devices at all. It is proprietary under the Oracle PUEL,
so neither Fedora nor openSUSE packages it, VERIFIED in containers where
`virtualbox-ext-pack` resolves on neither. Debian has `virtualbox-ext-pack`, which
fetches and license-accepts the pack through debconf. On fedora and suse the
bootstrap fetches the version-matched
`Oracle_VM_VirtualBox_Extension_Pack-*.vbox-extpack` from
`download.virtualbox.org` instead. The download reachability itself is unverified.

### nvidia on the apt family

Ubuntu, Mint, and Pop all ship `ubuntu-drivers-common`, whose `ubuntu-drivers
autoinstall` picks the right driver for the card and survives a release upgrade
better than a pinned version. That is the whole apt story now that base Debian is
dropped. Base Debian carried no such tool and would have needed the non-free
`nvidia-driver` by hand, but it is no longer a target. See the tombstone in
`detect_os`.

## Traps worth stating outright

These are the rows a naive doc gets backwards. Each one is easy to reason wrong
from memory, which is why every name above was read off a live index.

Steam on debian is `steam-installer`, never `steam-launcher`. `steam-launcher` is
Valve's own apt-repo name and resolves only where Valve's repo is added by hand.
The reference box has that repo, so `steam-launcher` resolves here and nowhere
fresh. That is exactly why it looked correct for so long.

The btrfs tools drop the hyphen on suse alone. suse spells it `btrfsprogs`, while
both fedora and debian keep `btrfs-progs`. It is tempting to "fix" fedora to match
suse, and that fix is wrong.

The fuse2 compat library makes fedora the odd one. fedora calls it `fuse-libs`,
while suse and debian both use `libfuse2`. Writing `libfuse2` for fedora fails.

The calibre X11 dependency also makes fedora the odd one. fedora calls it
`xcb-util-cursor`, while suse and debian use `libxcb-cursor0`.

VirtualBox on fedora is capital `VirtualBox`, from RPM Fusion. Package managers are
case sensitive, so the capitalization is load bearing rather than cosmetic.

Steam, VirtualBox, `akmod-VirtualBox`, `akmod-nvidia` and `xorg-x11-drv-nvidia-cuda`
are not in the Fedora database at all. They come from RPM Fusion, which
`_system_fedora` enables first through `rpmfusion-free-release` and
`rpmfusion-nonfree-release`. A search for `steam` on `packages.fedoraproject.org`
finds nothing, and that absence is expected, not a gap.

`google-chrome-stable` and `code` come from the vendor's own repository, Google's
and Microsoft's, not the distro. They are parity by construction, and the name was
read off the vendor pages rather than a distro index. Do not send a reader hunting
for `code` in the Fedora database.

## Not treated as package rows

Several installs are not distro packages. The Flatpak apps, the git-checkout
installs such as Doom Emacs and LazyVim, and the self-updating binaries such as
Claude Code, the AWS CLI, calibre and Tailscale all fall outside `pkg_install`.
They install the same way on every family by their own means, so they need no
parity row. Calibre's X11 dependency is a distro package
and does have a row above. Tailscale installs through its own distro-aware
installer rather than `pkg_install`, so it is not a parity row either.
