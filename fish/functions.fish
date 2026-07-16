# ----------------------------------------
# Custom History Function (with timestamps)
# ----------------------------------------
function history
    builtin history --show-time='%F %T '
end

# Function: add_to_path
# Adds the given directory to PATH if it isn’t already present.
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

function cleanup
    sudo apt autoremove -y && sudo apt autoclean
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

function godot --description 'Run Godot with nohup, redirecting output to /dev/null'
    nohup $GODOT >/dev/null 2>&1 &
end

function update_ssh_auth_sock
    if not set -q SSH_AUTH_SOCK
        eval (ssh-agent -c)
    end
end

function servers --description 'Open the dev-servers zellij layout'
    # -n / --new-session-with-layout starts a NEW zellij session with a layout
    # (home/terminals.nix). Plain --layout without -n tries to add a tab to an
    # existing session instead, which is why "--session X --layout Y" failed with
    # "There is no active session". This opens a fresh session each run, so quit a
    # running one first or its stacks collide (visibly, since close_on_exit=false).
    if set -q ZELLIJ
        echo "You're inside zellij already; run this from a plain terminal."
        return 1
    end
    zellij -n servers --layout servers
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
