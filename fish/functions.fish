# ----------------------------------------
# Custom History Function (with timestamps)
# ----------------------------------------
function history
    builtin history --show-time='%F %T '
end

# Function: add_to_path
# Adds the given directory to the front of PATH if it is not already there.
#
# DELIBERATELY NO `test -d` GUARD, and this is a conscious design choice, not an
# oversight. It adds language-manager bin dirs that may not exist yet: ~/.bun/bin,
# ~/.deno/bin, ~/.cargo/bin, ~/sdk, the composer vendor dir. Keeping a not-yet
# existent dir on PATH is the POINT. `bun add -g foo` then makes foo runnable in
# the shell you are already in, because the PATH slot is already waiting and fish
# rehashes on the first miss. A `-d` guard would skip the dir until it existed, so
# the first-ever global install into a fresh manager dir would not appear until a
# new shell. On a dev machine built around first-class language managers, that
# immediacy beats a tidy PATH, and the phantom entries resolve nothing and cost
# nothing.
#
# REVIEWERS: do not "fix" this with a `test -d`. It was flagged once (round 2, L10)
# and reverted on purpose. The one case that DOES want a -d is a wrong-arch dir
# that will never be populated, e.g. texlive's arch path, and that is handled at
# the call site with a glob in configure_path.fish, not here.
function add_to_path
    if not contains $argv[1] $PATH
        set -x PATH $argv[1] $PATH
    end
end

function backup --argument filename
    cp $filename $filename.bak
end

function copy
    set count (count $argv)
    if test "$count" -eq 2 -a -d "$argv[1]"
        set from (echo $argv[1] | string trim --right --chars=/)
        set to $argv[2]
        command cp -r $from $to
    else
        command cp $argv
    end
end

# __pkg_manager names the system package manager for the running distro. It is
# the fish-side answer to what bootstrap.sh's detect_os computes as PKG, and it
# exists because that value never reaches an interactive shell: detect_os sets a
# shell script local, and fish never runs the bootstrap. `command -q` answers the
# only question these aliases need, which tool installs a package, on the machine
# you are standing on, with no os-release table to keep in sync.
#
# ORDER is deliberate. rpm-ostree is probed first, because an atomic base
# (Bazzite, Silverblue) can also carry a layered dnf, and on such a host the
# system verb is rpm-ostree, never dnf. On plain Fedora rpm-ostree is absent, so
# dnf wins next. Prints the manager on stdout, or nothing when none matches, and
# every caller gates on that empty case and refuses loudly.
#
# This lives here in functions.fish because it is a helper function and this is
# where functions belong. grubup, rmpkg, upd, and cleanup below all call it. A
# fish function body is not resolved until the function is called, so definition
# order within the file does not matter. Unverified on fedora, suse, and atomic,
# no such machine available.
function __pkg_manager
    if command -q rpm-ostree
        echo rpm-ostree
    else if command -q apt
        echo apt
    else if command -q dnf
        echo dnf
    else if command -q zypper
        echo zypper
    end
end

# cleanup was `sudo apt autoremove -y && sudo apt autoclean`, both Debian-only
# verbs. On Fedora and openSUSE it was command-not-found and no cache was ever
# cleared. dnf carries the same two verbs. The atomic and suse arms are partial
# by necessity, explained inline. Verbs read off dnf5 and openSUSE docs, not run:
# no fedora, suse, or atomic machine available.
function cleanup --description 'Remove orphaned packages and clear the package cache'
    switch (__pkg_manager)
        case apt
            sudo apt autoremove -y && sudo apt autoclean
        case dnf
            sudo dnf autoremove -y && sudo dnf clean all
        case rpm-ostree
            # No orphan concept on an atomic base: layered packages are explicit
            # and nothing is auto-pulled, so there is nothing to autoremove.
            # `cleanup -m` drops cached rpm-md metadata, the only cache this verb
            # owns here.
            rpm-ostree cleanup -m
        case zypper
            # zypper has no autoremove verb, so the orphan half of cleanup has no
            # equivalent. `zypper clean --all` clears the package cache, the
            # autoclean half. Orphans on suse need `zypper packages --unneeded`
            # reviewed by hand, never an unattended rm.
            sudo zypper clean --all
        case '*'
            echo "cleanup: no supported package manager found" >&2
            return 1
    end
end

# grubup regenerates the bootloader config. It used to be the alias
# `sudo update-grub`, a Debian-only wrapper that hardcodes /boot/grub/grub.cfg.
# On Fedora and openSUSE that command does not exist, so the alias died with
# command-not-found and the config was never rebuilt. Both ship grub2-mkconfig
# and write /boot/grub2/grub.cfg, a path Fedora unified across BIOS and UEFI in
# F34 (Changes/UnifyGrubConfig). An atomic base owns its own boot through ostree,
# so a manual grub regen is wrong there and this refuses rather than run the
# wrong tool. Probe the tool, not $FAMILY. Verified paths against Fedora and
# openSUSE docs, not run: no fedora, suse, or atomic machine available.
function grubup --description 'Regenerate the bootloader configuration'
    if command -q rpm-ostree
        echo "grubup: atomic host, ostree owns the bootloader, nothing to do" >&2
        return 1
    else if command -q update-grub
        sudo update-grub
    else if command -q grub2-mkconfig
        sudo grub2-mkconfig -o /boot/grub2/grub.cfg
    else
        echo "grubup: no grub config generator found" >&2
        return 1
    end
end

# rmpkg and upd were the aliases `sudo apt remove` and `sudo apt update &&
# upgrade`. apt is Debian-only, so on Fedora and openSUSE they were
# command-not-found and the machine never had a package removed or an update
# applied. __pkg_manager above probes the system package manager once, and each
# verb dispatches on it. The verbs were read off dnf5, openSUSE, and rpm-ostree
# docs, not run: no fedora, suse, or atomic machine available.
function rmpkg --description 'Remove one or more packages'
    switch (__pkg_manager)
        case apt
            sudo apt remove $argv
        case dnf
            sudo dnf remove $argv
        case rpm-ostree
            # uninstall drops a layered package. A base package needs
            # `rpm-ostree override remove`, deliberately not wired here because
            # removing a base package is not the everyday case this serves.
            rpm-ostree uninstall $argv
        case zypper
            sudo zypper remove $argv
        case '*'
            echo "rmpkg: no supported package manager found" >&2
            return 1
    end
end

function upd --description 'Update and upgrade all system packages'
    switch (__pkg_manager)
        case apt
            sudo apt update && sudo apt upgrade -y
        case dnf
            sudo dnf upgrade -y
        case rpm-ostree
            # Atomic base: rpm-ostree stages a new deployment, no sudo, polkit
            # authenticates. The change lands on the next boot by design.
            rpm-ostree upgrade
        case zypper
            # Tumbleweed is rolling and has no update/upgrade split. `zypper dup`
            # is the one correct verb there, and `zypper up` is explicitly wrong
            # per openSUSE docs. Leap does split them and wants `zypper up`. The
            # os-release ID is the only local signal that separates the two.
            sudo zypper ref
            # string match, a fish builtin, not grep: it reads os-release straight
            # off stdin with no subprocess and no dependency on which grep is on
            # PATH. grep is no longer aliased, but this is still the cleaner idiom.
            # The `"?` is load bearing: real Tumbleweed ships ID="opensuse-tumbleweed"
            # WITH quotes, so an unquoted `^ID=opensuse-tumbleweed` never matched and
            # upd silently ran `zypper up`, the verb the comment above calls wrong for
            # a rolling release. bootstrap sources os-release so its quotes are gone,
            # which is why the two differ. The optional quote matches both forms and
            # still rejects opensuse-leap.
            if string match -qr '^ID="?opensuse-tumbleweed' </etc/os-release
                sudo zypper dup
            else
                sudo zypper up
            end
        case '*'
            echo "upd: no supported package manager found" >&2
            return 1
    end
end

function generatetoken --description "Generates a secure 64-character hex key using the first available method."
    set token ""

    if type -q python3
        echo "(using Python 3 secrets module)"
        set token (python3 -c 'import secrets; print(secrets.token_hex(32))')
    else if type -q openssl
        echo "(using OpenSSL)"
        set token (openssl rand -hex 32)
    else if type -q xxd
        echo "(using /dev/urandom + xxd)"
        set token (head -c 32 /dev/urandom | xxd -p | tr -d '\n')
    else if type -q hexdump
        echo "(using /dev/urandom + hexdump)"
        set token (hexdump -n 32 -v -e '1/1 "%02x"' /dev/urandom)
    else
        echo "Error: No suitable method found. Install python3, openssl, xxd, or hexdump."
        return 1
    end

    echo $token
end

# gd, not godot: a function named `godot` would shadow the real godot binary, and
# worse, the old body dropped every argument passed to it. The launcher keeps its
# own short name and forwards $argv, and `godot` stays the real command per the
# no-shadow rule.
function gd --description 'Run Godot in the background, detached, forwarding args'
    nohup $GODOT $argv >/dev/null 2>&1 &
end

# foundry is a function, not an alias, for the same reason gd is. A trailing-`&`
# alias breaks in fish: `alias foundry '... &'` expands to `... & $argv`, and the
# empty $argv makes fish error on an empty command every call. The function
# backgrounds cleanly with nothing trailing.
function foundry --description 'Launch FoundryVTT in the background, detached'
    nohup $HOME/foundryvtt/foundryvtt >/dev/null 2>&1 &
end

function update_ssh_auth_sock
    if not set -q SSH_AUTH_SOCK
        eval (ssh-agent -c)
    end
end

function servers --description 'Open the dev-servers zellij layout'
    # Thin wrapper now. The logic lives in scripts/dev-session.sh, in the store as
    # `dev-session` (home/terminals.nix), because Ghostty opens into that same
    # command via initial-command. Two copies of "attach or create" would drift,
    # and the drift would show up as two sessions fighting over the same ports.
    #
    # The body used to be `zellij -n servers --layout servers`, which named no
    # session, so every run built a new randomly-named one rather than returning
    # to the existing session. Six dead ones had accumulated by the time this was
    # replaced. dev-session names the session, which is what makes the second
    # launch attach instead of duplicate. The ZELLIJ nesting guard moved in there
    # too, so calling it from a pane still refuses.
    dev-session
end

# ----------------------------------------
# Exercism
# ----------------------------------------
#
# These are fish functions and not a script in scripts/, for one reason: a script
# runs in a subshell, so its `cd` dies when it exits and your shell never moves.
# Landing you in the exercise directory is the whole point, so it has to be a
# function.
#
# The workspace layout is $workspace/$track/$exercise, and `exercism configure`
# knows the workspace. So the path is computed rather than scraped out of
# `exercism download` output. One less thing to break when the CLI reformats.

function ex-workspace --description 'Path of the exercism workspace'
    jq -r '.workspace' $HOME/.config/exercism/user.json 2>/dev/null
end

function ex-get --description 'Download an exercism exercise and cd into it: ex-get rust clock'
    if test (count $argv) -lt 2
        echo "usage: ex-get <track> <exercise>"
        return 1
    end
    set -l track $argv[1]
    set -l exercise $argv[2]

    # download exits 255 on failure, including "You have not joined this track",
    # so the status is worth trusting. Without this check a failed download would
    # cd you into a directory that does not exist.
    set -l out (exercism download --track=$track --exercise=$exercise $argv[3..-1] 2>&1)
    if test $status -ne 0
        printf '%s\n' $out
        return 1
    end

    set -l dir (ex-workspace)/$track/$exercise
    if not test -d $dir
        printf '%s\n' $out
        echo "downloaded, but $dir is not there. Has the workspace layout changed?"
        return 1
    end
    cd $dir
end

function ex-cd --description 'cd to an already-downloaded exercise: ex-cd rust clock'
    if test (count $argv) -lt 2
        echo "usage: ex-cd <track> <exercise>"
        return 1
    end
    set -l dir (ex-workspace)/$argv[1]/$argv[2]
    if not test -d $dir
        echo "not downloaded: $dir"
        return 1
    end
    cd $dir
end

function ex-test --description 'Run the current exercise tests, detecting the track from the files'
    # The marker file names the toolchain, so there is nothing to configure and
    # nothing to pass. Walks up, so this works from src/ as well as the root.
    set -l dir (pwd)
    while test "$dir" != /
        if test -f $dir/Cargo.toml
            pushd $dir; cargo test $argv; set -l r $status; popd; return $r
        else if test -f $dir/go.mod
            pushd $dir; go test ./... $argv; set -l r $status; popd; return $r
        else if test -f $dir/build.zig
            pushd $dir; zig build test $argv; set -l r $status; popd; return $r
        else if test -f $dir/package.json
            pushd $dir; npm test $argv; set -l r $status; popd; return $r
        end
        set dir (path dirname $dir)
    end
    echo "no Cargo.toml, go.mod, build.zig or package.json above "(pwd)
    return 1
end

function ex-submit --description 'Submit the current exercise'
    # Files are optional: the CLI works out what to send from the exercise dir.
    exercism submit $argv
end

# ----------------------------------------
# nixGL — run Nix-built GL/Vulkan apps on this non-NixOS host
# ----------------------------------------
#
# This box is Ubuntu, not NixOS, so a Nix-built binary links Nix's libglvnd and
# cannot see the host's GLX vendor drivers (libGLX_nvidia / libGLX_mesa live in
# /usr/lib, off the Nix search path). The symptom is "GLX: No GLXFBConfigs
# returned" and a dead window. nixGL bridges that. The wrapper derivations live
# in this repo's flake as legacyPackages (flake.nix), kept out of `packages` so
# `nix flake check` stays pure; running them still needs --impure because nixGL
# probes the live driver.
#
# A function, not an alias, for the gd/foundry reason: it forwards $argv, and a
# trailing-token alias breaks on empty $argv in fish. The flake is referenced by
# absolute path so this works from any project dir, not just the nix-config repo.
#
# `nixgl` uses the auto-detected default; `nixgl-nvidia` forces the NVIDIA path,
# needed when the default lands on the wrong GPU on this hybrid NVIDIA+AMD
# machine. Usage: `nixgl make run`, or `nixgl ./build-clang++/ascii-abyss`.
function nixgl --description 'Run a command under nixGL (host GPU driver bridge)'
    if test (count $argv) -eq 0
        echo "usage: nixgl <command> [args...]" >&2
        return 1
    end
    nix run --impure \
        "$HOME/Code/samuel-stidham/nix-config#legacyPackages.x86_64-linux.nixGL" \
        -- $argv
end

function nixgl-nvidia --description 'Run a command under nixGL, forcing the NVIDIA driver'
    if test (count $argv) -eq 0
        echo "usage: nixgl-nvidia <command> [args...]" >&2
        return 1
    end
    nix run --impure \
        "$HOME/Code/samuel-stidham/nix-config#legacyPackages.x86_64-linux.nixGLNvidia" \
        -- $argv
end
