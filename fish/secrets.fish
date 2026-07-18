# Global secrets, loaded from the safetybox vault into the shell environment.
#
# Every secret stored as global/<name> with an --env-name is exported here, so
# tools like aws and restic find their credentials without a plaintext file such
# as ~/.aws/credentials ever existing on disk.
#
# The whole set decrypts in one call. That is the point of reveal --env: a single
# passphrase read and one identity unlock for the entire batch, instead of one
# per secret. The passphrase itself comes from passage, handed to safetybox
# through `psub -F`. The -F is load bearing: plain psub writes a REGULAR temp
# file under /tmp, which on this box is ext4 on the NVMe, so the passphrase would
# land on persistent disk on every shell start. -F makes it a named fifo instead,
# so the secret only ever crosses a pipe and never a file on disk.
#
# Store a new global secret like this, and it appears here on the next shell:
#   printf '%s' "$VALUE" | safetybox set global/some-token --env-name SOME_TOKEN

function load-secrets --description 'Load every global/* secret from safetybox into this shell'
    if not command -q safetybox
        echo "load-secrets: safetybox is not on PATH" >&2
        return 1
    end
    if not command -q passage
        echo "load-secrets: passage is not on PATH" >&2
        return 1
    end
    safetybox reveal --env --prefix global --format fish \
        --passphrase-file (passage show safetybox/passphrase | psub -F) 2>/dev/null | source
    # Gate the marker on safetybox's own status, not the pipeline's. `and` here
    # would chain on `source`, which succeeds even when it sources nothing, so a
    # locked or failed vault would still export the marker and every child shell
    # would skip the retry, turning a vault outage into a silent session-wide
    # credential blackout. $pipestatus[1] is safetybox's exit, read before any
    # other command runs.
    if test $pipestatus[1] -eq 0
        set -gx SAFETYBOX_SECRETS_LOADED 1
    end
end

function unload-secrets --description 'Erase the global/* secrets from this shell'
    if not command -q safetybox
        return 1
    end
    for name in (safetybox list global --json 2>/dev/null | jq -r '.[].name')
        set -l var (safetybox show $name --json 2>/dev/null | jq -r '.envName // empty')
        test -n "$var"; and set -e $var
    end
    set -e SAFETYBOX_SECRETS_LOADED
end

# Load once per session, in every shell. The exported marker means subshells
# inherit the secrets and never pay for a second decrypt.
if not set -q SAFETYBOX_SECRETS_LOADED
    load-secrets
end
