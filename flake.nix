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

      perSystem = { pkgs, system, lib, ... }: {
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
