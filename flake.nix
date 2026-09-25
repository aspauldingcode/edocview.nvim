{
  description = "Rendered document previews inside a NixVim split";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    # Mermaid's Puppeteer runtime currently fails with the newer Chromium in
    # unstable on Darwin. Keep its browser/runtime pair independently pinned.
    diagramNixpkgs.url = "github:NixOS/nixpkgs/ef34387ddd751e1ab8857adf4676492d32eb24ec";
    nixvim.url = "github:nix-community/nixvim";
  };

  outputs =
    inputs@{
      self,
      diagramNixpkgs,
      nixpkgs,
      nixvim,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      pluginFor = pkgs: pkgs.vimUtils.buildVimPlugin {
        pname = "edocview.nvim";
        version = "0.1.0";
        src = self;
        doCheck = false;
      };
      configurationFor = system: nixvim.lib.evalNixvim {
        inherit system;
        modules = [ self.nixvimModules.default ];
      };
    in
    {
      nixvimModules.default = import ./nixvim.nix { inherit self nixpkgs diagramNixpkgs; };

      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          configuration = configurationFor system;
        in
        {
          default = configuration.config.build.package;
          plugin = pluginFor pkgs;
        }
      );

      checks = forAllSystems (system: {
        nixvim = (configurationFor system).config.build.test;
      });
    };
}
