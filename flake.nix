{
  description = "samuelstidham home-manager configuration and local dev services";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # nixGL wraps Nix GL and Vulkan apps so they find the Ubuntu NVIDIA driver.
    # Exposed as a runnable output, run with --impure.
    nixgl.url = "github:nix-community/nixGL";
    # Catppuccin theming, Frappe flavor.
    catppuccin.url = "github:catppuccin/nix";
    # Local dev services (databases, cache, search, S3) as a process-compose
    # stack. Run with `nix run .#services`. Root-free, data under ~/.local/share.
    process-compose-flake.url = "github:Platonic-Systems/process-compose-flake";
    services-flake.url = "github:juspay/services-flake";
  };

  outputs = inputs@{ self, nixpkgs, flake-parts, home-manager, nixgl, catppuccin, ... }:
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
          siteRoot = "/home/samuelstidham/sites";
          runDir = "/home/samuelstidham/.local/share/dev-services";
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

        # nixGL runnable outputs. Run with:
        #   nix run --impure ~/nix-config#nixGL -- <app>
        packages.nixGL = nixgl.packages.${system}.nixGLDefault;
        packages.nixGLNvidia = nixgl.packages.${system}.nixGLNvidia;

        # Web layer for ~/sites/<name>. php-fpm and the .test resolver. Run with
        # `nix run .#sites`. See MIGRATION notes for the one-time system config.
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
            dataDir = "/home/samuelstidham/.local/share/dev-services/mariadb";
          };
          services.postgres."postgres" = {
            enable = true;
            package = pkgs.postgresql_18;
            dataDir = "/home/samuelstidham/.local/share/dev-services/postgres";
          };
          services.redis."redis" = {
            enable = true;
            dataDir = "/home/samuelstidham/.local/share/dev-services/redis";
          };
          services.mongodb."mongodb" = {
            enable = true;
            dataDir = "/home/samuelstidham/.local/share/dev-services/mongodb";
          };
          services.minio."minio" = {
            enable = true;
            dataDir = "/home/samuelstidham/.local/share/dev-services/minio";
          };

          # meilisearch is not a services-flake service, so run it as a plain
          # process-compose process with its data under ~/.local/share.
          settings.processes.meilisearch.command = ''
            ${pkgs.meilisearch}/bin/meilisearch \
              --db-path /home/samuelstidham/.local/share/dev-services/meilisearch \
              --http-addr 127.0.0.1:7700
          '';
        };
      };
    };
}
