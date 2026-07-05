{ pkgs, lib, ... }:

# Dev toolchains for every language folder under
# ~/code/personal-projects/language-specific. Nix owns these and they lead on
# PATH. Ubuntu's own gcc and clang stay untouched for the system layer.
#
# Attributes confirmed against github:NixOS/nixpkgs/nixos-unstable on 2026-07-04.
# See .agents/languages.md for the resolved versions and the confirm commands.

let
  # Step 6: latest gcc and clang/llvm from Nix, pinned by version. These lead on
  # PATH for dev work. Ubuntu's gcc 13 and its apt llvm stay for the system.
  # Confirmed newest on the channel: gcc16 is 16.1.0, llvmPackages_22.clang is
  # 22.1.8. You chose the latest. Drop to gcc15 (15.2.0) or llvmPackages_21
  # (clang 21.1.8) here if a newer compiler ever breaks a build.
  gccPinned = pkgs.gcc16;
  llvmPinned = pkgs.llvmPackages_22;

  # gcc and clang both ship generic `cc`, `c++`, and `cpp` names, which collide
  # in the profile. buildEnv priority did not resolve it here, so give clang its
  # own copy with those three generic names removed. gcc then owns `cc`, `c++`,
  # and `cpp`, and clang stays available as `clang` and `clang++`.
  clangNoGeneric = pkgs.symlinkJoin {
    name = "clang-${llvmPinned.clang.version}-nogeneric";
    paths = [ llvmPinned.clang ];
    postBuild = ''
      rm -f "$out/bin/cc" "$out/bin/c++" "$out/bin/cpp"
    '';
  };
in
{
  home.packages = with pkgs; [
    # C and C++ (c-projects, cpp-projects). Pinned per Step 6.
    gccPinned
    clangNoGeneric
    llvmPinned.lld
    llvmPinned.lldb

    # Go (go-projects, wails-projects). Confirmed 1.26.4. Dev tools from ~/go/bin.
    go
    gopls
    delve             # dlv debugger, confirmed 1.26.3
    golangci-lint     # confirmed 2.12.2
    gofumpt           # confirmed 0.10.0
    go-tools          # staticcheck, confirmed 2026.1
    gosec             # confirmed 2.27.1
    govulncheck       # confirmed 1.5.0
    gotests           # confirmed 1.9.0

    # Rust (rust-projects, tauri-projects). rustup usage moves to nixpkgs
    # rustc/cargo. Swap in rust-overlay later if you need pinned channels.
    rustc
    cargo
    rustfmt
    clippy
    rust-analyzer

    # Zig (zig-projects). Confirmed 0.16.0, matches the /opt/zig build.
    zig

    # Odin (odin-projects). nixpkgs tracks tagged releases, not the nightly you
    # ran from ~/odin. Pin a version here if you need the nightly.
    odin

    # Crystal (crystal-projects). Replaces the openSUSE apt repo.
    crystal
    shards

    # Elixir and Erlang. No project folder, but both are installed and used.
    # Confirmed elixir 1.18.4 on erlang OTP 28.5.0.2. The top-level attrs are
    # deprecated, so use the beamPackages set.
    beamPackages.elixir
    beamPackages.erlang

    # Clojure. sdkman managed leiningen, which means you use Clojure. Confirmed
    # clojure 1.12.5 and leiningen 2.12.0. Both ride on the default JDK from
    # jdks.nix. babashka is the fast-start scripting runtime, added as a bonus.
    clojure
    leiningen
    babashka

    # OCaml. Was opam at /usr/local plus a ~/.opam switch. Nix owns it now.
    # Confirmed ocaml 5.4.1, opam 2.5.1, dune 3.21.1. opam can still manage its
    # own switches on top if you need pinned package sets.
    ocaml
    opam
    dune_3
    ocamlPackages.utop
    ocamlPackages.ocaml-lsp
    ocamlformat

    # Haskell. Was ghcup at ~/.ghcup. No project folder, but you have it
    # installed. Confirmed ghc 9.10.3, cabal 3.16.1.0, HLS 2.13.0.0, stack 3.9.3.
    ghc
    cabal-install
    haskell-language-server
    stack

    # Julia. Was juliaup at ~/.juliaup. Confirmed julia-bin 1.12.6. julia-bin is
    # the official binary, which avoids a long source build.
    julia-bin

    # JavaScript and TypeScript runtimes.
    nodejs_24   # node-projects, electron-projects, tauri, wails. Replaces nvm.
    bun         # bun-projects. Replaces the ~/.bun installer.
    deno        # deno-projects. Replaces the ~/.deno installer.
    typescript

    # PHP (php-projects, laravel-projects, symfony-projects, nativephp-projects).
    # Replaces the ondrej/php PPA. composer for project dependencies.
    php
    php.packages.composer

    # Ruby (ruby-projects, rails-projects). Replaces apt ruby and rbenv. ruby
    # already ships bundler, so no separate bundler package. Gems install per
    # project through bundler.
    ruby

    # C# and .NET (csharp-projects). Run 8, 9, and 10 side by side, matching the
    # three SDKs the apt backports PPA installed. Confirmed 8.0.422, 9.0.315,
    # and 10.0.301. combinePackages puts all three under one dotnet root.
    (with dotnetCorePackages; combinePackages [
      sdk_8_0
      sdk_9_0
      sdk_10_0
    ])

    # Lua and LÖVE (lua-projects, love-projects). Confirmed lua5_5 is 5.5.0,
    # which matches your source build. luajit covers the apt libluajit usage.
    lua5_5
    # luajit CLI dropped. You had none installed, its headers collide with
    # lua5_5, LOVE bundles its own, and the apt libluajit for plugins stays on
    # apt. Add it back isolated if you ever need the standalone luajit.
    love

    # TeXstudio. Confirmed 4.9.5. It has no language folder. It is a GUI app, so
    # it is an explicit exception to the Flatpak-first rule in
    # .agents/install-policy.md. You chose Nix for it on purpose.
    texstudio

    # Java is handled in jdks.nix, which runs Temurin 8, 11, 17, 21, 25, and 26
    # side by side for PrismLauncher and general JVM work.
  ];
}
