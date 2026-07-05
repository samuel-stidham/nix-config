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
