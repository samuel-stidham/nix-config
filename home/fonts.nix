{ pkgs, ... }:

# Nerd Fonts. These are the patched fonts already installed on the machine,
# brought into Nix so they are reproducible. Confirmed on nixpkgs-unstable on
# 2026-07-05. MonoLisa is not here, since it is a paid font with no nixpkgs
# package. It stays outside Nix. There is no .agents/outside-nix.md recording it,
# so this comment is the record.

{
  fonts.fontconfig.enable = true;

  home.packages = with pkgs; [
    nerd-fonts.jetbrains-mono   # the terminal default below
    nerd-fonts.fira-code
    nerd-fonts.fira-mono
    nerd-fonts.caskaydia-cove   # Cascadia Code patched
    nerd-fonts.iosevka
    nerd-fonts.blex-mono        # IBM Plex Mono patched
    nerd-fonts.gohufont
    nerd-fonts.terminess-ttf    # Terminus patched

    # Doom's nerd-icons looks up the family "Symbols Nerd Font Mono" for its
    # modeline/dashboard glyphs. Without this, icons render as empty boxes. This
    # is the Nix-native replacement for `M-x nerd-icons-install-fonts`.
    nerd-fonts.symbols-only
  ];
}
