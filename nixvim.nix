{ self, nixpkgs, diagramNixpkgs }:
{ pkgs, ... }:
let
  diagramPkgs = diagramNixpkgs.legacyPackages.${pkgs.stdenv.hostPlatform.system};
  chromium = diagramPkgs.playwright-driver.selectBrowsers {
    withChromium = false;
    withChromiumHeadlessShell = true;
    withFfmpeg = false;
    withFirefox = false;
    withWebkit = false;
  };
  mermaidCli = pkgs.writeShellScriptBin "mmdc" ''
    browser="$(${pkgs.findutils}/bin/find -L ${chromium} -type f \
      -name chrome-headless-shell -print -quit)"
    if [ -z "$browser" ]; then
      echo "edocview: bundled Chromium executable not found" >&2
      exit 1
    fi
    export PUPPETEER_EXECUTABLE_PATH="$browser"
    exec ${diagramPkgs.mermaid-cli}/bin/mmdc "$@"
  '';
in
{
  # The flake intentionally exposes a standalone NixVim build. Make its
  # package source explicit so NixVim does not warn about flake input wiring.
  nixpkgs.source = nixpkgs;

  extraPlugins = [
    pkgs.vimPlugins.image-nvim
    (pkgs.vimUtils.buildVimPlugin {
      pname = "edocview.nvim";
      version = "0.1.0";
      src = self;
      doCheck = false;
    })
  ];

  extraPackages = [
    pkgs.imagemagick
    pkgs.graphviz
    mermaidCli
    pkgs.pandoc
    pkgs.typst
    (pkgs.python3.withPackages (pythonPackages: [
      pythonPackages.pymupdf
      (if pkgs.stdenv.hostPlatform.isDarwin then
        pythonPackages.weasyprint.overridePythonAttrs (_: { doCheck = false; })
      else
        pythonPackages.weasyprint)
    ]))
    (pkgs.texliveMedium.withPackages (texPackages: [ texPackages.latexmk ]))
  ];

  extraConfigLua = ''
    local function setup_edocview_image()
      require("image").setup({
        backend = "kitty",
        processor = "magick_cli",
        integrations = {
          markdown = { enabled = false },
          typst = { enabled = false },
          html = { enabled = false },
        },
      })
    end

    -- image.nvim's Kitty backend must query an attached terminal. NixVim's
    -- headless check has no UI, so initialize immediately only for real UIs.
    if #vim.api.nvim_list_uis() > 0 then
      setup_edocview_image()
    else
      vim.api.nvim_create_autocmd("UIEnter", {
        once = true,
        callback = setup_edocview_image,
      })
    end
    require("edocview").setup({ auto_open = true })
  '';
}
