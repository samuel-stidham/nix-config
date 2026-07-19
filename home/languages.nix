{ pkgs, lib, ... }:

# Dev toolchains for every language folder under
# ~/Code/personal-projects/language-specific. Nix owns these and they lead on
# PATH. Ubuntu's own gcc and clang stay untouched for the system layer.
#
# Attributes confirmed against github:NixOS/nixpkgs/nixos-unstable on 2026-07-04.
# The resolved versions are stated inline below, per toolchain. There is no
# .agents/languages.md. It was cited here but never written.

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

  # PHP 8.5 with a curated extension set, shared with the php-fpm service behind
  # nginx. The full rationale lives in ../parts/php.nix.
  phpWithExt = import ../parts/php.nix pkgs;
in
{
  home.packages = with pkgs; [
    # C and C++ (c-projects, cpp-projects). Pinned per Step 6.
    gccPinned
    clangNoGeneric
    llvmPinned.lld
    llvmPinned.lldb
    llvmPinned.clang-tools   # clangd, clang-format, clang-tidy, clang-query, etc.
    llvmPinned.llvm          # opt, llc, llvm-ar, llvm-nm, llvm-objdump, llvm-config

    # GNU build and debug tools. Matches build-essential, gdb, cmake, and the
    # autotools from apt. binutils gives ar, as, ld, nm, objdump, readelf, strip.
    gdb
    gnumake
    cmake
    ninja
    autoconf
    automake
    libtool
    pkg-config
    bison
    flex
    binutils
    gperf
    ccache
    meson       # modern build system, confirmed 1.10.2
    go-task     # the `task` runner, confirmed 3.48.0
    bazel       # confirmed 7.6.0

    # C/C++ analysis. valgrind is dynamic (memcheck, helgrind, cachegrind,
    # massif); the rest are static and complement clang-tidy (which ships in
    # clang-tools above and is the module-aware one, driven by clangd). These
    # are standalone tools independent of the compiler version, so clang-analyzer
    # riding clang 21 while the toolchain is clang 22 is fine.
    valgrind                # dynamic memory/thread analysis, confirmed 3.27.1
    cppcheck                # standalone static analyzer, confirmed 2.21.1
    clang-analyzer          # scan-build / scan-view driver, confirmed 21.1.8
    include-what-you-use    # header hygiene (iwyu), confirmed 0.26
    flawfinder              # pattern-based C/C++ security scanner, confirmed 2.0.20

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
    # gci and impl were `go install` binaries in ~/go/bin. Both are in nixpkgs, so
    # they come from the store now and stay reproducible. goplay, glyphs, meteor
    # and nishanths/license are NOT in nixpkgs, so they stay as go installs and are
    # recorded in docs/recorded-packages.txt instead.
    gci               # confirmed 0.14.0
    impl              # confirmed 1.5.0

    # Rust (rust-projects, tauri-projects). rustup usage moves to nixpkgs
    # rustc/cargo. Swap in rust-overlay later if you need pinned channels.
    rustc
    cargo
    rustfmt
    clippy
    rust-analyzer
    # rustlings, the guided Rust exercise set. It was a `cargo install rustlings`
    # living in ~/.cargo/bin. Codified here so it comes from the store. ~/.cargo/bin
    # is on PATH now, but the Nix profile leads it (configure_path.fish), so this
    # copy wins. Drop the stray cargo build with `cargo uninstall rustlings`.
    rustlings         # confirmed 6.5.0

    # Scheme. guile, chosen over mit-scheme, which was a real package-parity gap.
    # mit-scheme is absent from Fedora and openSUSE and only ever came from apt on
    # Ubuntu. guile is in nixpkgs and packaged on every distro, so one Nix package
    # gives the same Scheme everywhere and the system layer installs none. See the
    # mit-scheme tombstones in bootstrap.sh for the absence evidence.
    guile             # confirmed 3.0.11

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

    # OCaml is NOT from Nix. TOMBSTONE: this list held ocaml, opam, dune_3,
    # ocamlPackages.utop, ocamlPackages.ocaml-lsp and ocamlformat. They are gone on
    # purpose. OCaml development is switch-based, and opam is the toolchain manager
    # the OCaml project itself ships, so a Nix ocaml only ever shadowed or fought
    # the opam switch the work actually used. opam owns the whole toolchain now,
    # installed the way upstream recommends rather than pinned here:
    #   bash -c "sh <(curl -fsSL https://opam.ocaml.org/install.sh)"
    #   opam init
    # dune, utop, ocaml-lsp-server and ocamlformat come from the switch. The `opam
    # env` line in fish/configure_path.fish puts the active switch on PATH, and the
    # `ocaml` section in bootstrap.sh installs the opam binary on a fresh machine.

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

    # PHP 8.5 (php-projects, laravel-projects, symfony-projects, nativephp).
    # Replaces the ondrej/php PPA and both apt php8.4 and php8.5. The extension
    # set is defined as phpWithExt in the let block above. composer rides on it.
    phpWithExt
    phpWithExt.packages.composer

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
    lua5_5.pkgs.luarocks   # rocks package manager, built against Lua 5.5
    love

    # TeXstudio. Confirmed 4.9.5. It has no language folder. It is a GUI app, so
    # it is an explicit exception to the Flatpak-first rule. That rule has no
    # separate doc, see the header of home/apps.nix. You chose Nix for it on
    # purpose.
    texstudio

    # Java is handled in jdks.nix, which runs Temurin 8, 11, 17, 21, 25, and 26
    # side by side for PrismLauncher and general JVM work.
  ];
}
