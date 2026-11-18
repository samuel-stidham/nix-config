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
    # Rust from upstream's own release binaries, so the toolchain can sit on
    # the newest stable. Added 2026-11-14 for 1.100.0, released 2026-11-12.
    # nixpkgs could not supply it. The lock, nixos-unstable, nixpkgs-unstable
    # and master all evaluated rustc to 1.99.0 or 1.99.1 that day, because a
    # compiler bump rebuilds the world and waits out a staging cycle. This
    # input ONLY feeds home/languages.nix. Every Rust package nixpkgs builds
    # keeps the nixpkgs compiler, so nothing falls off the binary cache.
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs@{ self, nixpkgs, nixpkgs-nvidia, flake-parts, home-manager, nixgl, catppuccin, rust-overlay, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-darwin" ];
      imports = [ inputs.process-compose-flake.flakeModule ];

      # Home-manager configs are per-user, not per-system in the flake-parts
      # sense, so they live under `flake`.
      flake =
        let
          # NOT TEMPORARY ANY MORE. This overlay was written as "DELETE when
          # nixos-unstable ships bun >= 1.4.0", the same shape as the deno
          # overlay that was deleted below. That condition is MET. The lock of
          # 2026-11-02 packages bun 1.4.2. The overlay stays for a reason the
          # delete condition never considered, in the sources block below.
          # nixpkgs points x86_64-linux at the baseline zip, the build for CPUs
          # without AVX2, and that is still true at 1.4.2:
          #
          #   nix eval nixpkgs#legacyPackages.x86_64-linux.bun.passthru.sources.x86_64-linux.url
          #   .../bun-v1.4.2/bun-linux-x64-baseline.zip
          #
          # Deleting the overlay would therefore move this box onto the baseline
          # build, a silent downgrade on a 9950X3D. So the overlay now exists to
          # pick the plain zip. While it exists it tracks the newest release,
          # because the hashes have to be refreshed on every bump either way.
          #
          # HISTORY. Bun 1.4.0 released upstream on 2026-08-20. As of 2026-08-25
          # nixpkgs still packaged 1.3.13 on master and unstable both, so the
          # overlay was born as a channel-lag bridge. Rechecked 2026-08-25
          # against bun's LATEST file, 1.4.0 was the newest release then.
          #
          # RECHECKED 2026-11-02. Upstream's releases page names 1.4.4 as the
          # latest release and nixpkgs carries 1.4.2, so the version below moves
          # to 1.4.4. Check both again before the next bump.
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
          # Verified: the rebuilt store binary prints "1.4.4" from `bun
          # --version` on x86_64-linux. Unverified on aarch64-darwin, no such
          # machine available.
          bunOverlay = final: prev: {
            bun = prev.bun.overrideAttrs (old: {
              version = "1.4.4";
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
                    url = "https://github.com/oven-sh/bun/releases/download/bun-v1.4.4/bun-linux-x64.zip";
                    hash = "sha256-v4zL+ysLgBWeD5ptFcVTF63YB3U028YTCj7bUvzLOVw=";
                  };
                  "aarch64-darwin" = prev.fetchurl {
                    url = "https://github.com/oven-sh/bun/releases/download/bun-v1.4.4/bun-darwin-aarch64.zip";
                    hash = "sha256-wkDX8My5DCY6hJ/NsJt+5iYw2SE0jtaq/ahrnVd7xRA=";
                  };
                };
              };
            });
          };

          # DENO OVERLAY REMOVED 2026-09-07, because nixpkgs caught up.
          #
          # An overlay lived here from 2026-08-25. nixpkgs packaged deno 2.9.4
          # three weeks after 2.9.5 shipped upstream, so this repo carried its
          # own. It replaced the package rather than bumping it. 2.9.5 moved v8
          # behind a deno_v8 facade pinning rusty_v8 150.4.0, and nixpkgs builds
          # librusty_v8 from source with four local patches, so a faithful bump
          # was not affordable.
          #
          # That trade cost the denort and libdenort outputs, the nixpkgs
          # patches and the test suite. nixpkgs ships 2.9.5 itself now, so the
          # cost buys nothing. Removing the overlay restores all three outputs.
          #
          # Verified 2026-09-07 after the lock bump. deno.version in the locked
          # nixpkgs reads 2.9.5, which is exactly the delete condition the old
          # comment wrote down.
          #
          # bun is in a DIFFERENT position and bunOverlay above stays. nixpkgs
          # caught up on version, 1.4.2 at the 2026-11-02 lock, but it still
          # ships the baseline zip. See the overlay's own comment.

          # PRISMLAUNCHER OVERLAY REMOVED 2026-11-02, because nixpkgs caught up.
          #
          # An overlay lived here from 2026-10-03. 11.1.1 is a SECURITY hotfix,
          # released upstream on 2026-09-28, whose only change is PR #6183,
          # "Prevent path traversal in CurseForge modpack overrides". Four of
          # the six instances on this machine are CurseForge packs, so waiting
          # for the channel was not acceptable. The overlay moved version and
          # src together, the way the nixpkgs master bump did.
          #
          # Its delete condition was "nixos-unstable ships prismlauncher >=
          # 11.1.1". Verified 2026-11-02: prismlauncher.version reads 11.1.1 at
          # the locked nixpkgs, and it already did at the previous lock
          # 02c087f3 from 2026-10-20. The overlay had been redundant for one
          # bump. Removing it also picks up the libxkbcommon wrapper change
          # master made beside the hotfix, which the overlay did not carry.
          #
          # One trap from the overlay's own comment is worth keeping. A bare
          # `version` override on this package fails SILENTLY. src is fetched
          # by tag with a fixed hash, so the old hash keeps the old store path
          # and cache.nixos.org substitutes it. The result is old code under a
          # new version string. Move version and src together, always.

          mkHome = system: home-manager.lib.homeManagerConfiguration {
            pkgs = import nixpkgs {
              inherit system;
              config.allowUnfree = true;
              # rust-overlay only ADDS pkgs.rust-bin. It does not replace
              # pkgs.rustc, so no nixpkgs package is rebuilt by its presence.
              overlays = [ bunOverlay rust-overlay.overlays.default ];
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
        #
        # MOVED TO THE 595 PRODUCTION BRANCH ON 2026-09-07, from 580.173.02.
        #
        # The driver was picked against two questions rather than against
        # novelty. Does it build for the running kernel, and does it survive the
        # move to Ubuntu 26.04? Ubuntu answers the first itself. It ships a
        # prebuilt signed linux-modules-nvidia-595-open-generic-hwe-24.04 at
        # 7.0.0-31.31, which is the ABI this box now boots.
        #
        # The second question was already answered before it was asked. Ubuntu
        # 26.04 ships kernel 7.0.0-31, the exact kernel the 24.04 HWE stack had
        # already delivered here. There is no kernel jump waiting at
        # do-release-upgrade. resolute carries nvidia-driver-595-open at 595.84,
        # the same version as noble, so the release upgrade only re-points the
        # ubuntu suffix and leaves this pin alone.
        #
        # WHY NOT 610, WHICH IS NEWER
        #
        # 610 is NVIDIA's New Feature Branch and 595 is the Production Branch,
        # read off nvidia.com/en-us/drivers/unix rather than recalled. New
        # Feature Branch gets a shorter support window. That is the wrong trade
        # for a box that sits on an LTS for years. ubuntu-drivers also marks
        # 595-open recommended for this 5090. Newer was available and was not
        # the goal.
        #
        # TRAP, ON THE APT SIDE. `apt install nvidia-driver-595-open` on its own
        # pulls in dkms and drops Ubuntu's prebuilt modules, so the module gets
        # rebuilt locally on every kernel bump for no gain. Name the module
        # metapackage alongside it to keep the signed prebuilt path.
        #
        # ORDER MATTERS AND IS THE OPPOSITE OF THE OBVIOUS ONE. This pin must
        # not be bumped before the host driver actually changes. Bumping it
        # first injects 595 userspace against a still-running 580 module and
        # reproduces the exact mismatch above, only backwards. Switch the host,
        # reboot, confirm, then edit this.
        #
        # Verified 2026-09-07 on this machine after the reboot. nvidia-smi and
        # /sys/module/nvidia/version both report 595.84. Exactly one nvidia.ko
        # exists under 7.0.0-31 and it is 595.84, so no 580 module competes at
        # boot. The pin below was built as nixGLNvidia-595.84 BEFORE the host
        # switched, which proved the 25.11 nvidia_x11 builder handles 595.84
        # and left no window where the box had a driver nix could not match.
        #
        # BUMPED TO 595.91.07 ON 2026-09-15, a point release on the same branch.
        #
        # This time the pin moved BEFORE the reboot, against the order above.
        # The order rule guards a host that still works. This host did not.
        # apt had replaced the 595.84 userspace with 595.91.07 while the 595.84
        # module still ran. Host nvidia-smi already failed with
        # "Driver/library version mismatch, NVML library version: 595.91".
        # Bumping early cost nothing that was not already lost. The only
        # nvidia.ko on disk under 7.0.0-31 was 595.91.07, so no old module
        # remained for the old pin to serve after the reboot.
        #
        # scripts/nixgl-nvidia-refresh.sh could not produce this pin. It reads
        # /proc/driver/nvidia/version, which is the RUNNING module, still
        # 595.84. The version here came from `modinfo -F version nvidia`, which
        # reads the module file on disk. The hash came from the same
        # `nix store prefetch-file` call the script makes.
        #
        # Verified 2026-09-23 on this machine after the reboot, which closes
        # the check owed above. `nixGLNvidia nvidia-smi` reports 595.91.07 with
        # no mismatch. `nixGLNvidia glxinfo -B` reports "OpenGL core profile
        # version string: 4.6.0 NVIDIA 595.91.07" with direct rendering Yes.
        #
        # THE PROFILE GOES STALE, NOT THE PIN. Between the 09-15 edit and that
        # check this file read 595.91.07 while the installed profile still
        # carried nixGLNvidia-595.84. Every nix GL app failed with "Failed to
        # initialize NVML: Driver/library version mismatch, NVML library
        # version: 595.84" against a host already running 595.91.07. Editing
        # this file fixes nothing until `home-manager switch` runs. The apt
        # upgrade and the switch are two halves of one driver bump, and the
        # half that is easy to forget is the second one.
        #
        # A KERNEL BUMP IS NOT A DRIVER BUMP. On 2026-09-22 apt installed
        # 7.0.0-34-generic and linux-modules-nvidia-595-open-7.0.0-34-generic
        # at 7.0.0-34.34~24.04.1+1. That version string looks like a driver
        # change and is not one. It is the same module rebuilt for the new
        # kernel. `modinfo -k 7.0.0-34-generic -F version nvidia` reports
        # 595.91.07, matching 7.0.0-31, so this pin needs no edit to survive
        # the reboot onto 7.0.0-34. Read the version out of the module before
        # believing the apt package version.
        #
        # THE RELEASE UPGRADE KEPT THE PIN AND DROPPED THE DRIVER. On 2026-09-29
        # do-release-upgrade moved this box to 26.04.1 (resolute). The 26.04
        # paragraph above predicted the pin would survive, and it did. What it
        # missed is that the upgrade removed the whole 595 userspace.
        # /var/log/dist-upgrade/main.log lists nvidia-utils-595, both arches of
        # libnvidia-gl-595, xserver-xorg-video-nvidia-595, nvidia-settings and
        # the rest under removal. It kept linux-modules-nvidia-595-open and
        # nvidia-kernel-common-595.
        #
        # This failure is SILENT. The desktop came up normally on the AMD iGPU
        # through modesetting, so nothing looked broken. The 5090 had no
        # userspace, host nvidia-smi did not exist, and `nixGLNvidia nvidia-smi`
        # died with "exec: nvidia-smi: not found". The obvious check passes
        # anyway. `modinfo -F version nvidia` still read 595.91.07 and matched
        # this pin, because the module is the half that survived. After a
        # release upgrade, check that host `nvidia-smi` runs, not the module.
        #
        # The fix was apt alone. resolute carries nvidia-driver-595-open at
        # 595.91.07-0ubuntu0.26.04.1, not the 595.84 predicted above, and
        # `ubuntu-drivers devices` marks it recommended. That is the same
        # version as this pin, so no edit and no `home-manager switch` followed.
        #
        # Verified 2026-09-29 after the reboot. The running module, the module
        # on disk, host nvidia-smi and `nixGLNvidia nvidia-smi` all report
        # 595.91.07. Xorg.0.log loads the nvidia driver for the 5090.
        # `nixGLNvidia glxinfo -B` reports "OpenGL core profile version string:
        # 4.6.0 NVIDIA 595.91.07" with direct rendering Yes.
        #
        # BUMPED TO 595.99.02 ON 2026-10-08, a point release on the same branch.
        #
        # `apt dist-upgrade` moved resolute's nvidia-driver-595-open from
        # 595.91.07-0ubuntu0.26.04.1 to 595.99.02-0ubuntu0.26.04.1. It was the
        # 09-15 shape again. apt replaced the userspace while the 595.91.07
        # module kept running. Host nvidia-smi failed with "Driver/library
        # version mismatch, NVML library version: 595.99". The version here
        # came from `modinfo -F version nvidia`, because the refresh script
        # still reads the running module and would print 595.91.07. The hash
        # came from `nix store prefetch-file` on NVIDIA's 595.99.02 runfile.
        #
        # The module on disk now comes from dkms, the apt TRAP above. modinfo
        # resolves to updates/dkms/nvidia.ko.zst under 7.0.0-38, and `dkms
        # status` lists 595.99.02 for both 7.0.0-34 and 7.0.0-38. The same
        # upgrade removed linux-modules-nvidia-595-open-7.0.0-34-generic.
        #
        # BUMPING EARLY IS FREE, SWITCHING EARLY IS NOT. The 09-15 paragraph
        # says bumping before the reboot cost nothing that was not already
        # lost. That holds for the edit and is wrong for the switch. Measured
        # before this reboot, host `glxinfo -B` failed with BadValue on
        # X_GLXCreateNewContext. The installed nixGLNvidia-595.91.07 still
        # reported "4.6.0 NVIDIA 595.91.07" with direct rendering Yes. nixGL
        # carries its own userspace, and that userspace still matched the
        # running module. The fresh nixGLNvidia-595.99.02 failed exactly like
        # the host. So edit and build whenever, but run `home-manager switch`
        # immediately before the reboot. Nix GL apps then lose nothing.
        #
        # NOT YET VERIFIED AFTER THE REBOOT. Verified 2026-10-08 before it:
        # the pin builds as nixGLNvidia-595.99.02 from the 25.11 nvidia_x11
        # builder. The runtime check owed is the 09-29 one. The running
        # module, host nvidia-smi and `nixGLNvidia nvidia-smi` must all read
        # 595.99.02. `nixGLNvidia glxinfo -B` must report "4.6.0 NVIDIA
        # 595.99.02" with direct rendering Yes. Replace this paragraph with
        # that result once it has run.
        legacyPackages.nixGLNvidia = (import "${nixgl}/default.nix" {
          # Built from nixpkgs-nvidia (a stable branch), NOT the unstable `pkgs`
          # above — see the nixpkgs-nvidia input comment for why (the `kernel`
          # override arg). This only affects the driver libs nixGL injects.
          pkgs = import nixpkgs-nvidia {
            inherit system;
            config.allowUnfree = true;
          };
          nvidiaVersion = "595.99.02";
          nvidiaHash = "sha256-6HR3lYv3YwcFSTJL1a1slI66btIQ5EAFs+/4SUD24ew=";
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
          # process-compose's OWN REST API, not a process. It defaults to 8080
          # and that default is what killed seaweedfs. See the long comment on
          # services.seaweedfs below for the failure and the second half of the
          # fix.
          #
          # This stack is the one that has an API at all. services-flake passes
          # --no-server, so `nix run .#services` never binds a port for itself
          # and the two stacks cannot collide with each other. That asymmetry
          # is upstream's choice and is not relied on here. Naming the port
          # explicitly means a future services-flake that drops --no-server
          # fails at a bind rather than silently stealing this one.
          #
          # 8082 is arbitrary and deliberately not adjacent to anything a dev
          # server picks by default. The point is to leave 8080 free for the
          # apps in ~/sites, which are the reason this stack exists.
          #
          # Verified 2026-08-25: `nix run .#sites` logged "start http server
          # listening localhost:8082" and bound only 8082. With the services
          # stack also up, 8080 was reported FREE by ss, which is the point.
          # `process-compose -p 8082 process list` returned php-fpm and
          # dnsmasq, so the API is reachable on the new port.
          cli.environment.PC_PORT_NUM = 8082;
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
          # Ports: s3 8333, filer 8888, master 9333, volume 8081. A Laravel
          # .env points at it with AWS_ENDPOINT=http://127.0.0.1:8333,
          # AWS_ACCESS_KEY_ID=dev, AWS_SECRET_ACCESS_KEY=devsecret, and
          # AWS_USE_PATH_STYLE_ENDPOINT=true.
          #
          # Old minio data is left at ~/.local/share/dev-services/minio and
          # is not migrated. Delete it by hand once nothing in it matters.
          # THE VOLUME SERVER IS OFF 8080 ON PURPOSE, moved 2026-08-25.
          #
          # seaweedfs defaults its volume server to 8080 and that port is the
          # busiest one on a web dev box. process-compose's own REST API also
          # defaults to 8080, so `nix run .#sites` bound it first and the
          # volume server died fifteen seconds later, after master, filer and
          # s3 had already come up:
          #
          #   F volume.go:621 Volume server listener error:listen tcp
          #   127.0.0.1:8080: bind: address already in use
          #
          # The whole `weed server` process exits 255 on that, so the working
          # master and s3 gateway went down with it. process-compose retried
          # five times, hit max_restarts, and left seaweedfs dead.
          #
          # RACE, NOT ORDER. The zellij servers layout starts this stack in the
          # pane above sites, so "start services first" looks like a fix and is
          # not one. process-compose binds its API at t=0 while the volume
          # server binds at t=16s, after the master bootstrap wait. sites wins
          # every time regardless of which pane launched first.
          #
          # Pinning the sites API elsewhere is the other half of this fix and
          # is done below, but on its own it only hands 8080 to seaweedfs. That
          # is the same trap one layer down. A `php artisan serve --port=8080`
          # or a vite dev server would take the port back and break s3 again,
          # with the same fifteen second delay and the same silence.
          #
          # 8081 is seaweedfs's own convention for a second volume server. The
          # master hands out volume URLs from live heartbeats rather than from
          # stored state, so nothing on disk records the old port and no
          # migration is needed. Laravel never talks to 8080 or 8081 directly.
          # It talks to the s3 gateway on 8333, which resolves volumes through
          # the master.
          #
          # Verified 2026-08-25, both stacks up together in the failing order,
          # sites started first. seaweedfs logged zero "Restarting" lines and
          # zero exit 255s, against six restarts and five 255s on the run
          # before. All four ports bound (9333, 8888, 8333, 8081) and
          # /cluster/status, /status and the filer root each returned 200,
          # where /cluster/status had returned 000 refused. The master
          # topology advertised "Url": "127.0.0.1:8081", and a 20 byte object
          # POSTed to the filer read back byte identical, so master to volume
          # routing follows the new port. Anonymous s3 still answers 403, so
          # the identity file above is still doing its job.
          services.seaweedfs."seaweedfs" = {
            enable = true;
            dataDir = "${runDir}/seaweedfs";
            volume.port = 8081;
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
          settings.processes.meilisearch = {
            command = ''
              ${pkgs.meilisearch}/bin/meilisearch \
                --db-path ${runDir}/meilisearch \
                --http-addr 127.0.0.1:7700 \
                --upgrade-db
            '';

            # READINESS PROBE, added 2026-08-26. This is a monitor fix, not a
            # runtime one. meilisearch was up and serving the whole time.
            #
            # Every other process here comes from services-flake, and that
            # module ships a probe with each one. meilisearch is hand written,
            # so it had none, and process-compose leaves the health column
            # empty for a process it has no way to test. In the TUI that reads
            # as the one service that never finished loading, sitting blank
            # next to five neighbours that all say Ready.
            #
            # That is a bad failure to have here specifically. The comment
            # above is about meilisearch dying quietly on a version bump, and
            # the operator's only signal is this pane. A column that looks
            # broken when the service is fine trains you to ignore the column,
            # which is exactly when the real outage gets missed.
            #
            # http_get rather than an exec probe, unlike the services-flake
            # ones that shell out to curl or redis-cli. process-compose makes
            # the request itself, so nothing has to be on PATH.
            #
            # /health, not /. Both answer 200, but / is only meaningful by
            # accident. nixpkgs builds meilisearch with no cargo features
            # ("BuildFeatures":"" in nix derivation show), so mini-dashboard is
            # absent and / returns JSON where upstream would serve the
            # dashboard HTML. If that feature is ever enabled here, / starts
            # answering from a static file handler and stops saying anything
            # about the engine. /health means the same thing either way.
            #
            # The numbers match the services-flake probes on purpose, so all
            # six processes go Ready on the same cadence. That gives the pane
            # roughly 52 seconds (2 + 5 x 10) before it gives up. A large
            # --upgrade-db migration could outrun that, and the failure mode is
            # a blank health column on a process that then comes up fine. Live
            # with it. The index here is 136K and rebuildable, so the migration
            # is a second or two, and a longer budget would delay the honest
            # signal on the failure this probe exists to catch.
            #
            # NO `availability` BLOCK, deliberately. The services-flake
            # processes all carry restart = on_failure with max_restarts = 5.
            # Copying that here would look consistent and would help nothing.
            # The failure this process actually has is the version mismatch
            # above, which is deterministic. Five more attempts produce five
            # more identical exits and five more lines of noise over the one
            # error worth reading.
            #
            # Verified 2026-08-26 by running both builds of this stack and
            # reading /processes off the process-compose API. Before, with the
            # same engine up and /health already returning 200:
            #
            #   meilisearch   Running   -
            #   redis         Running   Ready
            #
            # After, same query, same stack:
            #
            #   meilisearch   Running   Ready
            #   redis         Running   Ready
            #
            # All six long lived processes now report Ready with 0 restarts.
            readiness_probe = {
              http_get = {
                host = "127.0.0.1";
                port = 7700;
                path = "/health";
              };
              initial_delay_seconds = 2;
              period_seconds = 10;
              timeout_seconds = 4;
              success_threshold = 1;
              failure_threshold = 5;
            };
          };
        };
      };
    };
}
