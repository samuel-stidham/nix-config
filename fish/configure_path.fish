# add_to_path is defined in functions.fish, its home. env.fish sources
# functions.fish before home/fish.nix sources this file, so the function is
# already defined when the calls below run.

# An EXPORTED SET_PATH_SOURCED is always stale, so erase it before the guard. The
# marker below is set -g and never -x, so a value that is EXPORTED here can only
# have come from an OLDER version of this file that set it -gx. That exported value
# is inherited by every child of the shell that ran it, a fresh login included, and
# it makes this shell skip its own PATH build and the opam integration below, the
# exact trap the -g choice warns about, and a new generation alone does not undo
# it. Erasing it lets this shell rebuild. A legitimate same-shell marker is -g, not
# exported, so `set -qx` leaves it untouched. This was a real bug: an inherited
# exported marker skipped the block and opam never integrated in any shell.
if set -qx SET_PATH_SOURCED
    set -e SET_PATH_SOURCED
end

if not set -q SET_PATH_SOURCED
    # -g, NOT -x. The marker must not be exported. A child that inherits the
    # environment but resets PATH, which is exactly what `nix develop` and
    # systemd units do, would see the inherited marker, skip this whole block,
    # and run with a PATH that was never built. Measured:
    #   env SET_PATH_SOURCED=1 PATH=/usr/bin:/bin fish -c '...'
    #   -> PATH stays /usr/bin:/bin, nix bin missing, block skipped, no message.
    # Compare env.fish's __NIX_ENV_SOURCED, where -gx is deliberate because that
    # marker genuinely must cross a process boundary. This one must not.
    set -g SET_PATH_SOURCED 1

    # Zig and ZLS
    add_to_path "$ZLS_HOME/zig-out/bin"

    # Texlive. The arch directory was hardcoded to "x86_64-linux", the only one
    # this machine has. add_to_path never tests -d, so on aarch64 (aarch64-linux)
    # or darwin (universal-darwin) a nonexistent directory was added silently and
    # every texlive binary was simply missing, with nothing on PATH to say why.
    # The glob is the probe and needs no arch list. It also matches nothing when
    # TEXLIVE_HOME is unset, so no /bin/* accident. Unverified on non-x86_64, no
    # such machine available.
    for dir in $TEXLIVE_HOME/bin/*
        test -d "$dir"; and add_to_path "$dir"
    end

    # Savvy
    add_to_path "$SAVVY_HOME/bin"

    # PHP (Composer global)
    add_to_path "$HOME/.config/composer/vendor/bin"

    # JetBrains Toolbox
    add_to_path "$HOME/.local/share/JetBrains/Toolbox/scripts"

    # Golang (GOPATH bin and go install SDKs). go itself is from Nix.
    add_to_path "$GOPATH/bin"
    add_to_path "$HOME/sdk"

    # .NET global tools. The dotnet SDK itself is from Nix and already on PATH;
    # this only adds ~/.dotnet/tools (godotenv, etc.).
    add_to_path "$DOTNET_INSTALL"

    # local binaries
    add_to_path "$HOME/.local/bin"
    add_to_path "$HOME/bin"

    # Per-language package-manager bins. The toolchains come from Nix, but their
    # package managers install USER packages into these dirs, and a dev machine has
    # to run them. Added BEFORE the Nix profile below, so anything ALSO codified in
    # Nix resolves to the reproducible Nix copy. Not every language needs a line
    # here: npm's prefix is ~/.local so its globals land in ~/.local/bin above, go
    # uses ~/go/bin above, composer uses ~/.config/composer/vendor/bin above, and
    # opam is switch-based, handled by `opam env` below.
    add_to_path "$HOME/.cargo/bin"    # cargo install
    add_to_path "$HOME/.bun/bin"      # bun add --global
    add_to_path "$HOME/.deno/bin"     # deno install
    # PNPM_HOME itself, with no /bin suffix, which is the odd one out on this list.
    # pnpm puts the pnpm binary and every `pnpm add --global` shim directly in that
    # directory rather than in a bin subdirectory under it. Appending /bin here
    # would add a path that does not exist and pnpm would simply be missing.
    #
    # This line is what puts pnpm on PATH AT ALL, not a shadow of a Nix copy. pnpm
    # is deliberately not in the flake so it can self-update, so nothing else adds
    # it. env.fish sets PNPM_HOME and bootstrap.sh passes the same value to the
    # installer. Guarded, because a machine that has not run pnpm_cli yet has the
    # variable set and the directory absent, and add_to_path never tests -d.
    test -d "$PNPM_HOME"; and add_to_path "$PNPM_HOME"

    # Nix home-manager profile.
    #
    # This comment used to claim that adding it last leaves it FIRST on PATH, so
    # the Nix tooling leads over apt, cargo, conda, and the manual installs. That
    # is false, and was false when it was written. Measured in `fish -l`:
    # ~/.nix-profile/bin sits at positions 10 and 14 of 26, behind nine
    # manual-install directories.
    #
    # Two causes, neither fixable from this file. hm-session-vars.fish already
    # put ~/.nix-profile/bin on PATH before this file runs, so the `contains`
    # guard in add_to_path makes the call below a no-op. An entry already on PATH
    # never moves to the front, which is the part the old comment missed.
    # Separately, `fish_user_paths` is a UNIVERSAL variable holding ~/.fzf/bin,
    # and fish prepends it after every line here has run. It appears in no file in
    # this repo, so it is unmanaged machine state and it wins PATH[1].
    #
    # The measured cost: this shell runs fzf 0.67.0 out of ~/.fzf while the flake
    # pins 0.74.0. Clearing it is a system change and Sam's call, not this file's:
    #   set -U fish_user_paths        # empty it
    #   rm -rf ~/.fzf                 # remove the Nov 2025 manual install
    #
    # The call stays, because it is still what puts Nix on PATH when
    # hm-session-vars has not run. It does not, and cannot, set priority.
    add_to_path "$NIX_HOME/bin"

    # Force the Nix profile to the FRONT of PATH. hm-session-vars.fish already put
    # ~/.nix-profile/bin on PATH before this file runs, so the add_to_path above is
    # a no-op and the freshly-prepended ~/go/bin, ~/.cargo/bin and friends land
    # AHEAD of it. Sam wants the codified Nix copy to win over an ad-hoc cargo or go
    # install of the same name. Measured before this fix: `which gofumpt` resolved
    # to ~/go/bin, shadowing the flake's copy. Remove nix bin, then re-prepend it.
    if set -q NIX_HOME
        set -x PATH "$NIX_HOME/bin" (string match -v "$NIX_HOME/bin" $PATH)
    end

    # OCaml/opam. OCaml is NOT from Nix (see the tombstone in home/languages.nix),
    # so opam owns the whole toolchain and this is how it reaches PATH at all, not a
    # shadow of anything. A tool from `opam install` lives in the active switch
    # under ~/.opam/<switch>/bin, not a fixed dir, so add_to_path cannot find it.
    #
    # `eval (opam env)`, NOT `opam env --shell=fish | source`, and NOT opam's
    # init.fish. The pipe form works on its own but SILENTLY fails here, after this
    # file has rebuilt PATH: opam env's output carries a `builtin -n | /bin/sh -c ...`
    # MANPATH probe that fights `source` over stdin in that context, so nothing gets
    # set. init.fish fails for a related reason, and with `opam init` answered "no
    # hooks" its env_hook.fish is empty anyway. `eval` captures opam env's output as
    # a string and runs it, so there is no pipe and no stdin to fight, and it applies
    # in every shell. This was masked while ocaml came from Nix (its binaries sat on
    # PATH directly) and surfaced the moment opam became the only source. Measured:
    # the pipe form leaves OPAM_SWITCH_PREFIX unset in a full login shell and ocaml
    # resolves to nothing, while eval sets it and ocaml resolves to
    # ~/.opam/default/bin/ocaml. Guarded, so a host without opam or before `opam
    # init` neither errors nor prints.
    if command -q opam; and test -d "$HOME/.opam"
        eval (opam env --shell=fish 2>/dev/null)
    end
end
