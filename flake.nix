{
  description = "samuelstidham home-manager configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # nixGL wraps Nix GL and Vulkan apps so they find the Ubuntu NVIDIA driver.
    # It is not in nixpkgs, so it comes as a flake input. It is exposed as a
    # runnable output below, not baked into the home config, because its NVIDIA
    # wrapper matches the running driver and so cannot be built purely.
    nixgl.url = "github:nix-community/nixGL";
    # Catppuccin theming for every supported program, set to the Frappe flavor.
    catppuccin.url = "github:catppuccin/nix";
  };

  outputs = { self, nixpkgs, home-manager, nixgl, catppuccin, ... }:
    let
      # One shared home for both platforms. x86_64-linux is the daily driver.
      # aarch64-darwin is scaffolded for a later Mac, not used yet.
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

      # nixGL wrappers for running Nix GL and Vulkan apps against the Ubuntu
      # NVIDIA driver. Run with --impure, since the NVIDIA wrapper reads the host
      # driver at build time:
      #   nix run --impure ~/nix-config#nixGL -- <app>
      packages.x86_64-linux = {
        nixGL = nixgl.packages.x86_64-linux.nixGLDefault;
        nixGLNvidia = nixgl.packages.x86_64-linux.nixGLNvidia;
      };
    };
}
