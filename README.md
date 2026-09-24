# edocview.nvim

`edocview.nvim` renders complete documents in a right-hand Neovim split using
the Kitty graphics protocol. It is designed for Ghostty and other compatible
terminals: no browser, web server, or external preview window is involved.

The preview opens automatically for saved Markdown, LaTeX, Typst, and PDF
files. Markdown supports TeX math through Pandoc. Editing triggers a debounced
rebuild. Pages are rasterized once per rebuild and retained by Kitty; cursor and
scroll events only move the preview viewport instead of rerasterizing it.

## Features

- Markdown (`.md`, `.markdown`), including TeX math
- LaTeX (`.tex`)
- Typst (`.typ`)
- PDF (`.pdf`)
- Automatic right-side preview
- Hot reload after buffer edits
- Bidirectional source/preview scroll synchronization
- Preview-side scrolling with `j`, `k`, `Ctrl-D`, `Ctrl-U`, or the mouse wheel
- Saving from either split always writes the source document; the preview is an
  unlisted, read-only synthetic buffer
- XeLaTeX compilation for complete documents and automatically wrapped LaTeX
  fragments
- A reproducible Nix flake with a standalone NixVim package and check

## Requirements

- Neovim 0.10 or newer
- A terminal implementing the Kitty graphics protocol, such as Ghostty
- [`image.nvim`](https://github.com/3rd/image.nvim)
- Python with PyMuPDF
- ImageMagick
- Pandoc and Typst for fast Markdown rendering (with an XeLaTeX fallback)
- Typst for `.typ` sources
- `latexmk` and a TeX distribution for LaTeX

The included Nix configuration provides every command and Python package above.

## Try it with Nix

```sh
nix run .# -- notes.md
nix flake check
```

The default package is a complete NixVim configuration. The `plugin` package is
the standalone Neovim plugin.

## NixVim integration

Add the flake as an input:

```nix
inputs.edocview.url = "github:aspauldingcode/edocview.nvim";
```

Then import its module from your NixVim module list:

```nix
imports = [ inputs.edocview.nixvimModules.default ];
```

For local development, replace the GitHub URL with an absolute path URL:

```nix
inputs.edocview.url = "path:/path/to/edocview.nvim";
```

## Manual setup

Install `edocview.nvim`, `image.nvim`, and the runtime programs listed above,
then initialize both plugins:

```lua
require("image").setup({
  backend = "kitty",
  processor = "magick_cli",
})

require("edocview").setup({
  auto_open = true,
  debounce = 500,
  pixels_per_column = 9,
  pixels_per_row = 18,
  page_gap = 1,
})
```

## Commands

- `:EdocviewOpen` opens or replaces the preview for the current document.
- `:EdocviewStop` closes the preview.
- `:EdocviewToggle` toggles the preview for the current document.

## Current limitations

Scroll synchronization maps the source line's relative position to the rendered
document's relative position. It can therefore drift from the exact output
paragraph, especially when figures, equations, or page breaks change the layout.
The preview is rasterized, so rendered text cannot be selected and links are not
interactive. Transient errors while typing keep the last successful preview
without interrupting editing; errors are reported after an explicit save.

## License

MIT
