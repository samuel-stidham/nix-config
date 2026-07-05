{ pkgs, ... }:

# Command-line tooling that used to come from apt or from cargo installs. Nix
# owns it now, so the apt and cargo copies are retired during purge-lang-layers.
# Confirmed on nixpkgs-unstable.
#
# Note. bat, eza, zoxide, starship, atuin, direnv, fzf, and btop are NOT here.
# They are enabled through their home-manager modules in theme.nix, so they can
# be themed Catppuccin Frappe. Their module provides the binary, so listing them
# here too would collide.

{
  home.packages = with pkgs; [
    # Editor and multiplexer.
    neovim      # your NEOVIM_HOME build moves to Nix
    tmux

    # GitHub CLI. Nix owns it; no apt, snap, or vendor-repo copy was installed.
    gh

    # Search tools.
    ripgrep     # rg
    fd

    # System and shell helpers.
    htop
    fastfetch   # neofetch is dead upstream and gone from nixpkgs, this replaces it
    figlet
    xclip
    jq          # JSON processor
    yq-go       # mikefarah's yq: YAML/JSON/XML processor, standalone Go binary
    wget
    unzip
    rsync
    openssl     # used by the secure_sites fish function, and generally handy

    # HTTP clients. httpie is the classic (http/https), xh is its fast Rust
    # rewrite, curlie wraps curl with httpie-style UX.
    httpie      # http, https
    xh          # xh
    curlie      # curlie

    # Cargo installs brought into Nix so nothing lives in ~/.cargo/bin.
    websocat    # websocket cli, confirmed 1.14.0
    pay-respects # command correction, already initialized in fish, confirmed 0.8.8

    # Databases. sqlite provides sqlite3. turso-cli is the Turso db client.
    sqlite      # confirmed 3.51.2, provides sqlite3
    turso-cli   # confirmed 1.0.29
    duckdb      # was the ~/.duckdb install, confirmed 1.5.2

    # Charm.land tools you use. All confirmed on the channel.
    gum         # 0.17.0, shell script UI
    glow        # 2.1.2, markdown reader
    vhs         # 0.11.0, terminal gif recorder
    freeze      # 1.3, code screenshotter

    # Plotting used by octave and quick scripts.
    gnuplot
  ];
}
