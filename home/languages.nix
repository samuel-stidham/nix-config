{ pkgs, lib, ... }:

# Dev toolchains for every language folder under
# ~/Code/personal-projects/language-specific. Nix owns these and they lead on
# PATH. Ubuntu's own gcc and clang stay untouched for the system layer.
#
# Attributes confirmed against github:NixOS/nixpkgs/nixos-unstable on 2026-08-25.
# The resolved versions are stated inline below, per toolchain. There is no
# .agents/languages.md. It was cited here but never written.

let
  # Step 6: latest gcc and clang/llvm from Nix, pinned by version. These lead on
  # PATH for dev work. Ubuntu's gcc 13 and its apt llvm stay for the system.
  # Confirmed newest on the channel: gcc16 is 16.2.0, llvmPackages_22.clang is
  # 22.1.8. Drop to gcc15 (15.3.0) or llvmPackages_21 (clang 21.1.8) here if a
  # newer compiler ever breaks a build.
  #
  # llvmPackages_23 EXISTS ON THE CHANNEL AND IS DELIBERATELY NOT TAKEN. Its
  # clang reports 23.1.0-rc1, a release candidate rather than a release. Nothing
  # here needs a clang 23 feature, so taking it would only buy a compiler that
  # can still change under a working build. Move once the rc suffix is gone.
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

  # Go 1.27.4, one patch release AHEAD of nixpkgs. Pinned 2026-11-17.
  #
  # WHY. go.dev listed 1.27.4 as the newest stable that day. nixpkgs carried
  # 1.27.3 as go_1_27 on the lock, nixos-unstable, nixpkgs-unstable and master
  # alike. Its default `go` was older still, 1.26.10, and that default is what
  # stood in home.packages before this binding.
  #
  # THE OBVIOUS FIX THAT DOES NOT WORK is bumping the nixpkgs lock. Every
  # branch stops at 1.27.3, so the bump moves the whole profile and still
  # lands one release short.
  #
  # THE SECOND OBVIOUS FIX is an overlay replacing pkgs.go. Every Go package
  # in the profile would then rebuild from source, lego and yq-go included.
  # So this binding is local to the module, the same trade the Rust toolchain
  # below makes. Nothing outside the Go block sees it.
  #
  # THE TRADE. This compiler builds from source here, since no binary cache
  # has it. nixpkgs' own 1.27 recipe and patches are reused unchanged, and
  # only the version and the source tarball differ. The sha256 is the one
  # go.dev publishes for go1.27.4.src.tar.gz.
  #
  # DROP THIS once nixpkgs' go_1_27 reaches 1.27.4 or later. Put go_1_27 back
  # in its place and the tools below can return to their cached builds.
  goPinned = pkgs.go_1_27.overrideAttrs (_: rec {
    version = "1.27.4";
    src = pkgs.fetchurl {
      url = "https://go.dev/dl/go${version}.src.tar.gz";
      sha256 = "73cfb8571aec0c01177687db87163d46aa20e9779672772891aa17654d9a6099";
    };
  });

  # The builder for the four tools that parse or type-check Go source: gopls,
  # go-tools, gci and impl. Each links the go/types and go/parser of the
  # compiler that BUILT it. nixpkgs built go-tools, gci and impl with 1.26.10
  # and gopls with 1.27.3. A tool built by an older Go than the one on PATH
  # rejects newer modules, and nixpkgs' own gopls recipe records that
  # breakage. Building all four with goPinned keeps tool and compiler on one
  # release. The tool versions themselves do not move. All four were already
  # the newest upstream tags on 2026-11-17, read off proxy.golang.org.
  buildGoPinned = pkgs.buildGo127Module.override { go = goPinned; };
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
    go-task     # the `task` runner, confirmed 3.52.0
    bazel       # confirmed 7.6.0

    # C/C++ analysis. valgrind is dynamic (memcheck, helgrind, cachegrind,
    # massif); the rest are static and complement clang-tidy (which ships in
    # clang-tools above and is the module-aware one, driven by clangd). These
    # are standalone tools independent of the compiler version, so clang-analyzer
    # riding clang 21 while the toolchain is clang 22 is fine.
    #
    # LOW PRIORITY SINCE 2026-09-29. The nixpkgs bump to 7a0f122f (2026-09-28)
    # made clang-tools 22.1.8 ship its own bin/scan-view. The profile build then
    # died with "pkgs.buildEnv error: two given paths contain a conflicting
    # subpath" on clang-analyzer-21.1.8/bin/scan-view against clang-tools. The
    # obvious fix, dropping clang-analyzer, loses scan-build, which clang-tools
    # 22 still does not carry. lowPrio lets the scan-view matching the pinned
    # toolchain win and keeps scan-build from here.
    valgrind                # dynamic memory/thread analysis, confirmed 3.27.1
    (lib.lowPrio clang-analyzer)  # scan-build driver, confirmed 21.1.8
    include-what-you-use    # header hygiene (iwyu), confirmed 0.26
    flawfinder              # pattern-based C/C++ security scanner, confirmed 2.0.20

    # Go (go-projects, wails-projects). Confirmed 1.27.4 on 2026-11-17. The
    # compiler is goPinned from the let block above, which explains why it is
    # not nixpkgs' `go`. Dev tools outside nixpkgs live in ~/go/bin.
    #
    # gopls, go-tools, gci and impl are REBUILT with goPinned through
    # buildGoPinned. The other six stay on nixpkgs' cached builds, and the Go
    # that built each is stated beside it. The ones built with 1.26.10 are the
    # ones to rebuild the same way if a 1.27 module ever trips them.
    goPinned
    (gopls.override { buildGoLatestModule = buildGoPinned; })  # confirmed 0.24.0
    delve             # dlv debugger, confirmed 1.27.2, built with go 1.26.10
    golangci-lint     # confirmed 2.15.0, built with go 1.27.3
    gofumpt           # confirmed 0.12.0, built with go 1.26.10
    (go-tools.override { buildGoModule = buildGoPinned; })     # staticcheck, confirmed 2026.2.2
    gosec             # confirmed 2.30.0, built with go 1.26.10
    govulncheck       # confirmed 1.9.0, built with go 1.27.3
    gotests           # confirmed 1.9.0, built with go 1.26.10
    # gci and impl were `go install` binaries in ~/go/bin. Both are in nixpkgs, so
    # they come from the store now and stay reproducible. goplay, glyphs, meteor
    # and nishanths/license are NOT in nixpkgs, so they stay as go installs and are
    # recorded in docs/recorded-packages.txt instead.
    (gci.override { buildGoModule = buildGoPinned; })          # confirmed 0.14.0
    (impl.override { buildGoModule = buildGoPinned; })         # confirmed 1.5.0

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
    # Confirmed elixir 1.18.4 on erlang OTP 28.5.0.5. The top-level attrs are
    # deprecated, so use the beamPackages set.
    beamPackages.elixir
    beamPackages.erlang

    # Clojure. sdkman managed leiningen, which means you use Clojure. Confirmed
    # clojure 1.12.5.1664 and leiningen 2.12.0. Both ride on the default JDK
    # from jdks.nix. babashka is the fast-start scripting runtime, added as a
    # bonus.
    clojure
    leiningen
    babashka

    # Maven. Not installed anywhere before 2026-11-02. Eclipse's embedded m2e
    # was the only Maven on the box. 3.10.0 is the latest release on
    # maven.apache.org that day and the pinned nixpkgs carries the same, so
    # nothing is behind. The wrapper exports JAVA_HOME as a default onto
    # nixpkgs' openjdk-headless 21.0.12.1. That is the same version as the
    # temurin 21 leading on PATH, so mvn and java agree. An override onto
    # temurin-bin-21 would drop the second JDK from the closure. The argument
    # was already renamed once, jdk to jdk_headless, so the override is not
    # worth its breakage. A JAVA_HOME in the environment still wins.
    maven

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

    # Julia. Was juliaup at ~/.juliaup. Confirmed julia-bin 1.12.7. julia-bin is
    # the official binary, which avoids a long source build.
    julia-bin

    # JavaScript and TypeScript runtimes.

    # node-projects, electron-projects, tauri, wails. Replaces nvm. Confirmed
    # 24.19.0, which is the newest 24.x published on nodejs.org/dist.
    #
    # 24 AND NOT 26, THOUGH nodejs_26 IS ON THE CHANNEL AT 26.7.0. This line
    # tracks the Active LTS, not the newest major. The nodejs/Release
    # schedule.json puts 24 in Active LTS from 2025-10-28 until 2026-10-20.
    # 26 does not enter LTS until 2026-10-28. Until that date 26 is Current,
    # which is a weaker promise than this machine wants. Move to nodejs_26
    # after 2026-10-28 and not before.
    nodejs_24

    # bun-projects. Replaces the ~/.bun installer. 1.4.0, and 1.4.0 is the
    # newest release upstream. It arrives through the overlay in flake.nix,
    # because nixpkgs is still on 1.3.13 on master. Read the overlay comment
    # before touching this.
    bun

    # deno-projects. Replaces the ~/.deno installer. 2.9.5, which is the
    # newest release upstream. It arrives through denoOverlay in flake.nix,
    # because nixpkgs still packages 2.9.4 on master.
    #
    # That overlay does NOT bump the nixpkgs package the way the bun one does.
    # It replaces the source build with upstream's official binary, and the
    # reason is written out in full beside it. Read that before touching this,
    # because it is the one place this repo takes a binary over a nixpkgs
    # build, and it costs the denort output.
    deno

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
    # three SDKs the apt backports PPA installed. Confirmed 8.0.424, 9.0.317,
    # and 10.0.400. combinePackages puts all three under one dotnet root.
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
