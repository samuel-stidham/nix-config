{
  description = "samuelstidham home-manager configuration and local dev services";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # nixGL wraps Nix GL and Vulkan apps so they find the host NVIDIA driver.
    # Said "Ubuntu" until 2026-07. nixGL probes whatever driver the host has, so
    # naming one distro invited a per-distro branch that must not exist here.
    # Exposed as a runnable output, run with --impure.
    nixgl.url = "github:nix-community/nixGL";
    # nixGL builds its NVIDIA userspace driver from THIS nixpkgs, pinned to a
    # release branch on purpose. nixGL calls nvidia_x11 with the older `kernel`
    # override argument, which nixpkgs-unstable has since dropped — building
    # nixGLNvidia against unstable fails with "unexpected argument 'kernel'". A
    # stable branch keeps the compatible API. This input ONLY builds the nixGL
    # driver libs; the rest of the system stays on unstable. Not `.follows`
    # nixpkgs for exactly that reason.
    nixpkgs-nvidia.url = "github:NixOS/nixpkgs/nixos-25.11";
    # Catppuccin theming, Frappe flavor.
    catppuccin.url = "github:catppuccin/nix";
    # Local dev services (databases, cache, search, S3) as a process-compose
    # stack. Run with `nix run .#services`. Root-free, data under ~/.local/share.
    process-compose-flake.url = "github:Platonic-Systems/process-compose-flake";
    services-flake.url = "github:juspay/services-flake";
  };

  outputs = inputs@{ self, nixpkgs, nixpkgs-nvidia, flake-parts, home-manager, nixgl, catppuccin, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-darwin" ];
      imports = [ inputs.process-compose-flake.flakeModule ];

      # Home-manager configs are per-user, not per-system in the flake-parts
      # sense, so they live under `flake`.
      flake =
        let
          # TEMPORARY, DELETE when nixos-unstable ships bun >= 1.4.0. Check
          # after a flake update with:
          #
          #   nix eval nixpkgs#legacyPackages.x86_64-linux.bun.version
          #
          # Bun 1.4.0 released upstream on 2026-08-20. As of 2026-08-25 nixpkgs
          # still packages 1.3.13 on master and unstable both. The bump PR
          # "bun: 1.3.13 -> 1.4.0" is open and unmerged, so the channel is days
          # away at best.
          #
          # RECHECKED 2026-08-25. The LATEST file on bun's main branch reads
          # 1.4.0 and its releases feed lists no newer tag, so this overlay is
          # at the newest release rather than merely ahead of the channel. Check
          # both again before bumping the version below.
          #
          # The obvious fix is `bun upgrade`, and it cannot work here. This bun
          # lives in the read-only nix store, so the upgrader cannot replace its
          # own binary. Its fallback installs to ~/.bun, the exact installer
          # home/languages.nix:161 exists to REPLACE. That path drifts outside
          # the machine definition and wins the PATH race silently.
          #
          # So this overlay bumps the same package instead. nixpkgs' bun reads
          # its src from passthru.sources, a per-system fetchurl set over the
          # official release zips. Swapping version plus sources is the whole
          # bump, because the finalAttrs fixpoint recomputes src from them. The
          # nixpkgs bump PR performs the identical edit.
          #
          # Only the two systems this flake declares are listed. Any other
          # system hits the package's own "Unsupported system" throw, loud on
          # purpose. Hashes came from `nix store prefetch-file` on each zip.
          #
          # Verified: the rebuilt store binary prints "1.4.0" from `bun
          # --version` on x86_64-linux. Unverified on aarch64-darwin, no such
          # machine available.
          bunOverlay = final: prev: {
            bun = prev.bun.overrideAttrs (old: {
              version = "1.4.0";
              # THE WARNING THIS FLAG SILENCES IS A FALSE POSITIVE. Since the
              # nixpkgs bump on 2026-08-23 every eval of this flake printed:
              #
              #   evaluation warning: bun-1.3.13 was overridden with `version`
              #   but not `src` at .../flake.nix:72:15.
              #
              # The check lives in pkgs/stdenv/generic/make-derivation.nix:268
              # and is purely syntactic. It fires when the override set has a
              # `version` key and no `src` key. It never inspects what the
              # override actually did.
              #
              # This overlay does move the source. It moves it one level down,
              # through passthru.sources, which is exactly where bun's own `src`
              # attribute reads from. The check cannot see through that.
              #
              # Adding a literal `src` here is the obvious fix and it is worse.
              # An explicit `src` beats bun's per-system passthru.sources lookup
              # for EVERY system at once, so aarch64-darwin would then unpack the
              # linux zip. This flag is nixpkgs' own documented opt-out and
              # pkgs/stdenv/darwin/default.nix:396 uses it for the same reason.
              __intentionallyOverridingVersion = true;
              passthru = old.passthru // {
                sources = {
                  # NOT the zip nixpkgs itself uses. nixpkgs points x86_64-linux
                  # at bun-linux-x64-baseline.zip, the build bun ships for CPUs
                  # without AVX2. This box is a Ryzen 9 9950X3D and /proc/cpuinfo
                  # lists avx2 and avx512f, so the plain build runs and is the one
                  # bun intends for this hardware. Keep the difference in mind if
                  # this overlay is ever copied to an older machine.
                  "x86_64-linux" = prev.fetchurl {
                    url = "https://github.com/oven-sh/bun/releases/download/bun-v1.4.0/bun-linux-x64.zip";
                    hash = "sha256-LQP7X7g6yLVnrKCigbLOGhoZ1Ij1bClo2Iw/Jekv5FI=";
                  };
                  "aarch64-darwin" = prev.fetchurl {
                    url = "https://github.com/oven-sh/bun/releases/download/bun-v1.4.0/bun-darwin-aarch64.zip";
                    hash = "sha256-xmnpf2Fk4cluBwF0jbmN+ndJKQjL2DlMdVcTSnNd44E=";
                  };
                };
              };
            });
          };

          # TEMPORARY, DELETE when nixos-unstable ships deno >= 2.9.5. Check
          # after a flake update with:
          #
          #   nix eval nixpkgs#legacyPackages.x86_64-linux.deno.version
          #
          # deno 2.9.5 released upstream on 2026-08-06. nixpkgs still packages
          # 2.9.4 on master on 2026-08-25, three weeks later, so this is not a
          # channel that is merely a few days behind.
          #
          # THIS OVERLAY REPLACES THE PACKAGE RATHER THAN BUMPING IT, and that
          # is the whole difference from bunOverlay above. bun's nixpkgs
          # package IS the official zip, so bumping version plus sources is a
          # faithful bump. deno's is a rustPlatform.buildRustPackage from git,
          # standing on librusty_v8, which nixpkgs builds from SOURCE under
          # V8_FROM_SOURCE=1 with gn and ninja and four nixpkgs-local patches.
          #
          # The faithful bump is the obvious fix and it is not affordable here.
          # 2.9.5 moved v8 behind a new deno_v8 facade crate, and that facade
          # pins rusty_v8 150.4.0 where 2.9.4 pinned 150.2.0. So it needs
          # librusty_v8 rebuilt at a new version, those four patches
          # re-verified against a tree they were never written for, and a full
          # V8 compile with no cache hit. That is exactly the work nixpkgs has
          # not finished, which is why the bump has sat for three weeks.
          #
          # WHAT THE TRADE COSTS. nixpkgs' deno has three outputs: out, denort
          # and libdenort. This has only the binary. `deno compile` needs
          # denort, so with this overlay it fetches denort into ~/.cache/deno
          # at first use, the way deno behaves for everyone off Nix. That is a
          # network fetch where nixpkgs gave a store path. Nothing else in this
          # repo touches denort. The nixpkgs test suite and its patches are
          # also gone, so this is upstream's binary, unpatched. Shell
          # completions are NOT lost. They are regenerated from the binary
          # below, because dropping them was this overlay's first bug.
          #
          # Only the two systems this flake declares are listed, and anything
          # else throws rather than silently falling back to 2.9.4. A silent
          # fallback is the failure this repo keeps writing tombstones about.
          #
          # Verified 2026-08-25: the built binary prints "deno 2.9.5 (stable,
          # release, x86_64-unknown-linux-gnu)" and `deno eval` reports v8
          # 15.0.245.2-rusty. dl.deno.land/release-latest.txt returns v2.9.5.
          # Unverified on aarch64-darwin, no such machine available.
          denoOverlay = final: prev: {
            deno = prev.stdenvNoCC.mkDerivation (finalAttrs: {
              pname = "deno";
              version = "2.9.5";

              src =
                finalAttrs.passthru.sources.${prev.stdenvNoCC.hostPlatform.system}
                  or (throw "deno overlay: unsupported system ${prev.stdenvNoCC.hostPlatform.system}");

              # autoPatchelfHook is Linux only, and the darwin binary needs no
              # interpreter rewrite, so the hook is guarded rather than the
              # whole overlay. cc.cc.lib supplies libgcc_s, the one shared
              # object the linux binary wants that is not libc.
              nativeBuildInputs = [
                prev.unzip
                prev.installShellFiles
              ]
              ++ prev.lib.optionals prev.stdenvNoCC.hostPlatform.isLinux [
                prev.autoPatchelfHook
              ];
              buildInputs =
                prev.lib.optionals prev.stdenvNoCC.hostPlatform.isLinux [
                  prev.stdenv.cc.cc.lib
                ];

              dontConfigure = true;
              dontBuild = true;

              # The zip holds a bare `deno` at its root, so the default
              # unpacker's srcRoot guessing has nothing to descend into.
              unpackPhase = ''
                runHook preUnpack
                unzip "$src"
                runHook postUnpack
              '';

              installPhase = ''
                runHook preInstall
                install -Dm755 ./deno "$out/bin/deno"
                runHook postInstall
              '';

              # COMPLETIONS IN postPatchelf, NOT installPhase. nixpkgs' deno
              # ships bash, zsh and fish completions, and the first draft of
              # this overlay silently dropped all three. The empty output was
              # visible only as a zero-byte deno-2.9.5-fish-completions in the
              # closure, which is the quiet kind of regression.
              #
              # Regenerating them means RUNNING the binary, and on linux the
              # binary cannot run until autoPatchelfHook has rewritten its
              # interpreter. That hook lands in fixup, after installPhase, so
              # generating there fails. postPhases puts this after it instead.
              # nixpkgs' own bun package solves the identical problem the
              # identical way, see pkgs/by-name/bu/bun/package.nix.
              #
              # The canExecute guard matters for a cross build, where the host
              # binary cannot run on the builder. This flake never crosses, but
              # a silent wrong answer there is worth one conditional.
              postPhases = [ "postPatchelf" ];
              postPatchelf = prev.lib.optionalString
                (prev.stdenvNoCC.buildPlatform.canExecute prev.stdenvNoCC.hostPlatform) ''
                  installShellCompletion --cmd deno \
                    --bash <("$out/bin/deno" completions bash) \
                    --zsh <("$out/bin/deno" completions zsh) \
                    --fish <("$out/bin/deno" completions fish)
                '';

              passthru.sources = {
                "x86_64-linux" = prev.fetchurl {
                  url = "https://github.com/denoland/deno/releases/download/v2.9.5/deno-x86_64-unknown-linux-gnu.zip";
                  hash = "sha256-iwEKOxpKAYimfNuKeic0iypQGveK7H/HTyrOFnNo1TA=";
                };
                "aarch64-darwin" = prev.fetchurl {
                  url = "https://github.com/denoland/deno/releases/download/v2.9.5/deno-aarch64-apple-darwin.zip";
                  hash = "sha256-t5aq3RMfaTBWDB7gQM8Nb1OTP7uYdGTp/0a9fqSDBhU=";
                };
              };

              meta = prev.deno.meta // {
                mainProgram = "deno";
              };
            });
          };

          mkHome = system: home-manager.lib.homeManagerConfiguration {
            pkgs = import nixpkgs {
              inherit system;
              config.allowUnfree = true;
              overlays = [ bunOverlay denoOverlay ];
            };
            # `self` + `system` let home modules reach the flake's own outputs
            # (home/graphics.nix installs self.legacyPackages.${system}.nixGLNvidia,
            # so the pinned wrapper is defined once, above).
            extraSpecialArgs = { inherit self system; };
            modules = [
              ./home/home.nix
              catppuccin.homeModules.catppuccin
            ];
          };
        in
        {
          homeConfigurations = {
            "samuelstidham@x86_64-linux" = mkHome "x86_64-linux";
            "samuelstidham@aarch64-darwin" = mkHome "aarch64-darwin";
          };
        };

      perSystem = { pkgs, system, ... }:
        let
          # HOME ROOT. The single hardcoded home path in this repo, and the
          # hardcode is structural rather than lazy.
          #
          # The repo rule is `${config.home.homeDirectory}` and never a literal.
          # `perSystem` cannot obey it. This is a flake-parts module, so there is
          # no `config.home` in scope to read.
          #
          # The obvious fix is `builtins.getEnv "HOME"`, and it is worth writing
          # down exactly how it fails. Pure evaluation does not reject it. It
          # returns the empty string and exits 0:
          #
          #   $ nix eval --expr 'builtins.getEnv "HOME"' --raw   ->  (empty), exit 0
          #   $ nix eval --impure --expr 'builtins.getEnv "HOME"' --raw
          #                                                      ->  /home/samuelstidham
          #
          # So getEnv does not fail loudly here. It silently yields runDir as
          # "/.local/share/dev-services", an unwritable path at the filesystem
          # root, and the flake still evaluates. Forcing `--impure` on every
          # consumer to dodge that is a worse trade than one honest literal.
          #
          # Branching on `pkgs.stdenv.hostPlatform.isDarwin` beats hardcoding the
          # linux path, because `systems` above declares aarch64-darwin and macOS
          # homes live under /Users. This is asking the platform instead of
          # maintaining a list. The same expression already lives at
          # home/home.nix:29.
          #
          # It hardcodes ONCE. Six dataDirs below used to re-spell this prefix by
          # hand while runDir sat here unused. That drifts silently: change this
          # line and the php-fpm socket moves while the databases stay behind.
          homeDir =
            if pkgs.stdenv.hostPlatform.isDarwin
            then "/Users/samuelstidham"
            else "/home/samuelstidham";
          # KEEP IN SYNC with home/web.nix's runDir. These are two independent
          # bindings for one path, in different eval contexts (perSystem here, a
          # home module there) that cannot share a `let`. php-fpm's listen socket
          # here and nginx's fastcgi_pass there both derive from it, so a change
          # here not mirrored there silently breaks the php-fpm connection.
          runDir = "${homeDir}/.local/share/dev-services";

          # siteRoot lived here and is deliberately gone. It was nginx's document
          # root. When nginx moved to home/web.nix (see the comment below), the
          # consumer went with it and the binding stayed, referenced by nothing.
          # Nix does not warn on an unused `let` binding, so it read as live
          # config for as long as it survived. The live definition is
          # home/web.nix:42, and it already uses ${config.home.homeDirectory}.
          # Do not reintroduce it here. A second copy would look authoritative
          # and serve nothing.

          phpPkg = import ./parts/php.nix pkgs;

          # nginx's config moved to home/web.nix, where nginx now runs as a
          # systemd user service. It fronts Forgejo as well as the dev sites, so
          # it must outlive `nix run .#sites`. Keeping a second copy here would
          # be a config that looks authoritative and serves nothing.

          # S3 credentials for the seaweedfs gateway below. NOT SECRETS. This
          # pair is a loopback-only dev default in the same class as mariadb's
          # passwordless root, published on purpose so every Laravel .env on
          # this machine can copy it. Anything real comes from safetybox.
          #
          # It exists because the gateway denies anonymous callers. See the
          # comment on services.seaweedfs below for the verification.
          seaweedfsS3Config = pkgs.writeText "seaweedfs-s3-identities.json" (builtins.toJSON {
            identities = [{
              name = "dev";
              credentials = [{ accessKey = "dev"; secretKey = "devsecret"; }];
              actions = [ "Admin" "Read" "List" "Tagging" "Write" ];
            }];
          });

          phpFpmConf = pkgs.writeText "php-fpm-dev.conf" ''
            [global]
            pid = ${runDir}/php-fpm/php-fpm.pid
            error_log = ${runDir}/php-fpm/error.log
            daemonize = no
            [www]
            listen = ${runDir}/php-fpm/php-fpm.sock
            pm = dynamic
            pm.max_children = 8
            pm.start_servers = 2
            pm.min_spare_servers = 1
            pm.max_spare_servers = 4
          '';
        in
        {
        # mongodb is unfree. An allowInsecurePredicate for minio sat here too
        # and left with minio itself, replaced by seaweedfs below.
        _module.args.pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };

        # nixGL runnable outputs. In legacyPackages, NOT packages, on purpose.
        # nixGL's derivations use the impure builtins.currentTime, so exposing them
        # under `packages` made `nix flake check` fail with "attribute 'currentTime'
        # missing" unless run with --impure, which took the one cheap gate that
        # catches eval errors, including darwin ones, off the table. `nix flake
        # check` deliberately skips legacyPackages, the same escape hatch nixpkgs
        # itself uses for impure or huge package sets, so this keeps the check clean.
        # You still need --impure to RUN nixGL, because it probes the host driver,
        # which is impure by nature. The attribute path is longer as a result:
        #   nix run --impure .#legacyPackages.x86_64-linux.nixGL -- <app>
        legacyPackages.nixGL = nixgl.packages.${system}.nixGLDefault;
        # nixGLNvidia with the driver version pinned. nixGL's auto-detection
        # cannot parse the "Open Kernel Module for x86_64  <ver>" version string
        # (its regex, nixGL.nix:237, expects the classic "Kernel Module  <ver>"
        # form), so version must be supplied. Pinning version + hash also makes
        # this PURE: no --impure to build or run, unlike the auto path, so it can
        # go on PATH via home.packages. On a driver bump, run
        # `scripts/nixgl-nvidia-refresh` for the new version + hash.
        #
        # THE PIN GOES STALE BY ITSELF, AND QUIETLY. A routine `apt upgrade` on
        # 2026-07-23 moved the host driver from 580.159.03 to 580.173.02 and
        # nothing here changed. NVIDIA userspace must match the running kernel
        # module exactly, so GL context creation failed:
        #
        #   $ nixGLNvidia nvidia-smi
        #   Failed to initialize NVML: Driver/library version mismatch
        #   NVML library version: 580.159
        #   $ nixGLNvidia glxinfo -B
        #   X Error of failed request:  BadValue
        #     Minor opcode of failed request:  24 (X_GLXCreateNewContext)
        #
        # The host itself was never broken. Unwrapped `glxinfo -B` reported
        # 4.6.0 NVIDIA 580.173.02 the whole time, so nothing on the desktop
        # misbehaved and only nix-built GL apps failed. That asymmetry is why it
        # sat unnoticed for a day. Re-check this pin against
        # `nvidia-smi --query-gpu=driver_version` after any apt run that touches
        # libnvidia-*, and treat it as mandatory after a release upgrade.
        legacyPackages.nixGLNvidia = (import "${nixgl}/default.nix" {
          # Built from nixpkgs-nvidia (a stable branch), NOT the unstable `pkgs`
          # above — see the nixpkgs-nvidia input comment for why (the `kernel`
          # override arg). This only affects the driver libs nixGL injects.
          pkgs = import nixpkgs-nvidia {
            inherit system;
            config.allowUnfree = true;
          };
          nvidiaVersion = "580.173.02";
          nvidiaHash = "sha256-jY65AB4FqaimY9PV0wT+tk7yhE7hhczf2VJ4aCD0bhs=";
        }).nixGLNvidia;

        # Web layer for ~/sites/<name>. php-fpm and the .test resolver. Run with
        # `nix run .#sites`. The one-time system config is in SITES.md under
        # "One-time system setup". There is no MIGRATION.md.
        #
        # nginx is NOT here any more. It moved to a systemd user service in
        # home/web.nix, because it now fronts Forgejo as well as the dev sites,
        # and HTTPS to the git server cannot depend on this stack being started
        # by hand. Two nginxes would also fight: a listener on 0.0.0.0:443 blocks
        # every other bind on the box (verified, EADDRINUSE), so port 443 has
        # exactly one owner.
        #
        # php-fpm stays. When this stack is down, nginx is still up and a dev
        # site returns 502, which is the honest answer rather than a refused
        # connection. Forgejo is unaffected.
        process-compose."sites" = {
          settings.processes = {
            php-fpm.command = ''
              mkdir -p ${runDir}/php-fpm
              exec ${phpPkg}/bin/php-fpm -F -y ${phpFpmConf}
            '';
            # Port 5333 avoids mDNS/avahi on 5353. systemd-resolved routes .test
            # here, see the one-time system setup in the repo notes.
            dnsmasq.command = ''
              exec ${pkgs.dnsmasq}/bin/dnsmasq --keep-in-foreground --no-resolv \
                --no-hosts --address=/test/127.0.0.1 --listen-address=127.0.0.1 \
                --port=5333
            '';
          };
        };

        # Local dev services stack. `nix run .#services` starts them all.
        process-compose."services" = {
          imports = [ inputs.services-flake.processComposeModules.default ];

          services.mysql."mariadb" = {
            enable = true;
            package = pkgs.mariadb;
            dataDir = "${runDir}/mariadb";
          };
          services.postgres."postgres" = {
            enable = true;
            package = pkgs.postgresql_18;
            dataDir = "${runDir}/postgres";
          };
          services.redis."redis" = {
            enable = true;
            dataDir = "${runDir}/redis";
          };
          services.mongodb."mongodb" = {
            enable = true;
            dataDir = "${runDir}/mongodb";
          };
          # SeaweedFS REPLACES minio as the local S3, decided 2026-08-04.
          #
          # minio was not broken here, which is worth stating, because the
          # motive was upstream. nixpkgs marks minio abandoned, with six
          # unpatched CVEs on the locked rev, two of them unauthenticated
          # object writes. Laravel 13's docs also dropped MinIO from their
          # S3-compatible examples. The endpoint swap is config alone, so
          # nothing app-side depended on minio staying.
          #
          # Garage was the obvious alternative and fails one real need.
          # Laravel's Flysystem adapter drives file visibility through
          # GetObjectAcl and PutObjectAcl. Garage's compatibility page lists
          # both as Missing, answered with 501 Not Implemented. SeaweedFS
          # implements both, and presigned URLs for temporaryUrl(). It also
          # has a services-flake module, garage does not.
          #
          # filer.enable is REQUIRED for the s3 gateway, the module throws
          # at eval time without it.
          #
          # s3.config is set because the obvious default is a trap. The
          # services-flake option text says a null config runs the gateway
          # without authentication. On seaweedfs 4.40 the opposite happens,
          # and it fails closed. healthz answers 200 while every anonymous
          # request gets 403 AccessDenied (curl, 2026-08-04). Laravel needs
          # credentials that work, so the dev identity above is wired in.
          # Ports: s3 8333, filer 8888, master 9333, volume 8080. A Laravel
          # .env points at it with AWS_ENDPOINT=http://127.0.0.1:8333,
          # AWS_ACCESS_KEY_ID=dev, AWS_SECRET_ACCESS_KEY=devsecret, and
          # AWS_USE_PATH_STYLE_ENDPOINT=true.
          #
          # Old minio data is left at ~/.local/share/dev-services/minio and
          # is not migrated. Delete it by hand once nothing in it matters.
          services.seaweedfs."seaweedfs" = {
            enable = true;
            dataDir = "${runDir}/seaweedfs";
            filer.enable = true;
            s3.enable = true;
            s3.config = seaweedfsS3Config;
          };

          # meilisearch is not a services-flake service, so run it as a plain
          # process-compose process with its data under ~/.local/share.
          #
          # --upgrade-db IS LOAD BEARING. Without it a nixpkgs bump takes
          # meilisearch down. The engine refuses a database written by an older
          # build, and exits 1 before it binds a port:
          #
          #   Your database version (1.49.0) is incompatible with your current
          #   engine version (1.53.1).
          #
          # This happened on 2026-07-18 at 1.48.2 and again on 2026-08-25 at
          # 1.49.0. Treat it as certain on every bump rather than as bad luck.
          #
          # IT FAILS SILENTLY, which is why it earns this much comment. The
          # symptom is that meilisearch is simply not there. process-compose
          # restarts it, it exits 1 each time, and the reason never reaches the
          # operator. Both stacks also default to the same log file,
          # /tmp/process-compose-$USER.log, so `nix run .#sites` and
          # `nix run .#services` overwrite each other's lines. The meilisearch
          # error was absent from that file the whole time the loop ran.
          #
          # Pinning meilisearch to whatever version wrote the database is the
          # obvious fix and it is worse. It freezes one package against the rest
          # of the flake, and someone has to notice and undo it later. The data
          # here is a dev index that any app can rebuild, 136K on 2026-08-25.
          #
          # THE TRADE: the upgrade is one way. There is no downgrade, so a bad
          # migration costs the index. Copy the directory before a large jump.
          # The convention already in ~/.local/share/dev-services is
          # meilisearch.v<version>.bak.<timestamp>.
          #
          # Verified: 1.53.1 with this flag migrated the 1.49.0 database, and
          # /health then returned {"status":"available"} on 127.0.0.1:7700.
          settings.processes.meilisearch.command = ''
            ${pkgs.meilisearch}/bin/meilisearch \
              --db-path ${runDir}/meilisearch \
              --http-addr 127.0.0.1:7700 \
              --upgrade-db
          '';
        };
      };
    };
}
