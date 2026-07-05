{ pkgs, ... }:

# Extra editors to goof off with, all from Nix. The daily drivers live elsewhere:
# neovim is in cli.nix (with LazyVim as its config, cloned to ~/.config/nvim) and
# emacs has its own module. These are the "just to have them" editors. Any apt or
# vendor copies are removed in favour of these, see the removal notes in chat.

{
  home.packages = with pkgs; [
    vim         # regular vim (not neovim). Replaces the apt vim. Binary: vim
    kakoune     # modal editor. Binary: kak
    helix       # modal editor. Binary: hx
    zed-editor  # GUI editor. Binary: zeditor
  ];
}
