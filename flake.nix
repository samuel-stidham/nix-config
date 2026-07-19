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
          mkHome = system: home-manager.lib.homeManagerConfiguration {
            pkgs = import nixpkgs {
              inherit system;
              config.allowUnfree = true;
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

      perSystem = { pkgs, system, lib, ... }:
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
          # Branching on `pkgs.stdenv.isDarwin` beats hardcoding the linux path,
          # because `systems` above declares aarch64-darwin and macOS homes live
          # under /Users. This is asking the platform instead of maintaining a
          # list. The same expression already lives at home/home.nix:29.
          #
          # It hardcodes ONCE. Six dataDirs below used to re-spell this prefix by
          # hand while runDir sat here unused. That drifts silently: change this
          # line and the php-fpm socket moves while the databases stay behind.
          homeDir =
            if pkgs.stdenv.isDarwin then "/Users/samuelstidham" else "/home/samuelstidham";
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
        # mongodb is unfree and the pinned minio is flagged insecure. minio here
        # only ever binds localhost for dev, so allowing it is acceptable.
        _module.args.pkgs = import nixpkgs {
          inherit system;
          config = {
            allowUnfree = true;
            allowInsecurePredicate = pkg: lib.getName pkg == "minio";
          };
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
        legacyPackages.nixGLNvidia = (import "${nixgl}/default.nix" {
          # Built from nixpkgs-nvidia (a stable branch), NOT the unstable `pkgs`
          # above — see the nixpkgs-nvidia input comment for why (the `kernel`
          # override arg). This only affects the driver libs nixGL injects.
          pkgs = import nixpkgs-nvidia {
            inherit system;
            config.allowUnfree = true;
          };
          nvidiaVersion = "580.159.03";
          nvidiaHash = "sha256-MshdmbD2QMlQH2GzndrSCP0CiNAVxPvF/QQ1wHeD+nc=";
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
          services.minio."minio" = {
            enable = true;
            dataDir = "${runDir}/minio";
          };

          # meilisearch is not a services-flake service, so run it as a plain
          # process-compose process with its data under ~/.local/share.
          settings.processes.meilisearch.command = ''
            ${pkgs.meilisearch}/bin/meilisearch \
              --db-path ${runDir}/meilisearch \
              --http-addr 127.0.0.1:7700
          '';
        };
      };
    };
}
