# Theme inventory

Researched on November 20, 2026. This inventory lists candidate color themes from Linux distribution terminals and the most installed Visual Studio Code themes. It records where each palette comes from and how reliable the values are.

**Bundled so far:** seven Linux presets in `ThemeGallery.swift` (`linuxPresets`): Ubuntu, Kali Dark, GNOME Dark, GNOME Light, Breeze, Tango, and Linux Console. Kali-Dark was cross-checked against a second independent copy of the colorscheme file, and Linux Console matches the default palette in the kernel's `drivers/tty/vt/vt.c`. Window chrome colors are derived. Text on every chrome and selection color has at least 4.5:1 contrast.

**Visual Studio Code themes:** 48 more themes are bundled in `vscode-themes.json`, for 58 in total. Nine come from the built-in theme extensions of Visual Studio Code 1.144.1 (Abyss, Kimbie Dark, Monokai, Monokai Dimmed, Quiet Light, Red, Solarized Dark, Solarized Light, Tomorrow Night Blue). Thirty-nine come from the 19 MIT-licensed Marketplace extensions in the ranking below. Bearded Theme is excluded because it is GPL licensed, and Monokai Pro is excluded because it is commercial. Variants that differ only in italics or borders are skipped. `scripts/build-vscode-themes.py` regenerates the blueprint, its checksum, and `vscode-community-themes-licenses.txt` from a local Visual Studio Code app and downloaded `.vsix` packages. Only workbench colors are used; token colors are not bundled. The theme list in the app is a single list with a search field. The former MShell theme was removed, and Midnight is the default.

## Current state

The app bundles `vscode-themes.json`, which contains the 10 built-in themes from Visual Studio Code's `theme-defaults` extension: Light 2026, Dark 2026, Dark+, Dark Modern, Light+, Light Modern, Dark (Visual Studio), Light (Visual Studio), Dark High Contrast, and Light High Contrast. The loader checks a SHA-256 checksum, accepts at most 64 `color-palette` assets, and reads Visual Studio Code color keys. Terminal colors come from `terminal.ansi*` keys, with a fallback palette when a theme omits them.

Distribution palettes define only the terminal: foreground, background, cursor, and 16 ANSI colors. To use one as a full workspace preset, MShell must derive the toolbar, sidebar, tab, and accent colors.

## Linux distribution terminal palettes

**Verified** means the values were read from the terminal's own source or from a maintained collection that names the source. **Port** means a third-party conversion that has not been compared with the upstream file.

| Distribution | Default terminal and palette | Background / foreground | ANSI 0–15 | Status |
|---|---|---|---|---|
| **Ubuntu** (up to 25.04) | GNOME Terminal, Ubuntu profile: Tango colors on aubergine | `#300A24` / `#EEEEEC` | `#2E3436 #CC0000 #4E9A06 #C4A000 #3465A4 #75507B #06989A #D3D7CF` · `#555753 #EF2929 #8AE234 #FCE94F #729FCF #AD7FA8 #34E2E2 #EEEEEC` | Verified · [iTerm2-Color-Schemes "Ubuntu"](https://github.com/mbadolato/iTerm2-Color-Schemes) · [Gogh "Clone Of Ubuntu"](https://github.com/Gogh-Co/Gogh) |
| **Ubuntu** (25.10 and later) | Ptyxis replaced GNOME Terminal | Not confirmed | Not confirmed | Check the Ubuntu Ptyxis package for an Ubuntu palette. Upstream Ptyxis has no palette named Ubuntu. [Phoronix](https://phoronix.com/news/Ubuntu-Ptyxis-Recommended) |
| **Kali Linux** | QTerminal, Kali-Dark | `#23252E` / `#FFFFFF`, cursor `#B4D5FF` | `#1F2229 #D41919 #5EBDAD #FEA44C #367BF0 #9755B3 #49AEE6 #E6E6E6` · `#198388 #EC0101 #47D4B9 #FF8A18 #277FFF #962AC3 #05A1F7 #FFFFFF` | Cross-checked · [Alacritty gist](https://gist.github.com/scmanjarrez/3a069c3db3af2411118ad162cfb88e88) and a separate copy of `Kali-Dark.colorscheme` in [toxicwebdev/toxicblue](https://github.com/toxicwebdev/toxicblue) match. The Kali GitLab copy of qtermwidget blocked automated access. |
| **Fedora Workstation**, GNOME desktops | Ptyxis, GNOME palette, dark variant | `#1C1C1F` / `#FFFFFF` | `#241F31 #C01C28 #2EC27E #F5C211 #1E78E4 #9841BB #0AB9DC #C0BFBC` · `#5E5C64 #ED333B #57E389 #F8E45C #51A1FF #C061CB #4FD2FD #F6F5F4` | Verified · [Ptyxis `gnome.palette`](https://gitlab.gnome.org/chergert/ptyxis/-/tree/main/src/palettes) |
| Same, light variant | Ptyxis, GNOME palette, light variant | `#FFFFFF` / `#1D1D20` | `#1D1D20 #C01C28 #26A269 #A2734C #12488B #A347BA #2AA1B3 #CFCFCF` · `#5D5D5D #F66151 #33D17A #E9AD0C #2A7BDE #C061CB #33C7DE #FFFFFF` | Verified · same source |
| **RHEL, CentOS Stream, Rocky, AlmaLinux** | GNOME desktop. The terminal depends on the release (GNOME Terminal or Ptyxis). | Uses the GNOME palette above | — | No distribution-specific palette was found. Confirm the default terminal for RHEL 9 and 10. |
| **Older GNOME distributions** (CentOS 7, Debian, older Fedora) | GNOME Terminal, Tango | Black or system colors | Same ANSI values as the Ubuntu row | Verified · Gogh "Builtin Tango Dark" and "Builtin Tango Light" |
| **KDE distributions** (Kubuntu, Fedora KDE, openSUSE, Manjaro KDE) | Konsole, Breeze | `#232627` / `#FCFCFC` | `#232627 #ED1515 #11D116 #F67400 #1D99F3 #9B59B6 #1ABC9C #FCFCFC` · `#7F8C8D #C0392B #1CDC9A #FDBC4B #3DAEE9 #8E44AD #16A085 #FFFFFF` | Verified · Ptyxis `Breeze.palette`, generated from Gogh |
| **Linux console** (all distributions, servers without a desktop) | VGA text-mode palette | `#000000` / `#AAAAAA` | `#000000 #AA0000 #00AA00 #AA5500 #0000AA #AA00AA #00AAAA #AAAAAA` · `#555555 #FF5555 #55FF55 #FFFF55 #5555FF #FF55FF #55FFFF #FFFFFF` | Standard VGA values · Gogh "Linux Vt" |
| **elementary OS**, **Pop!_OS**, **Peppermint** | Their own terminal defaults | See source | See source | Available as Gogh "Elementary", "Pop", and "Peppermint". Not compared with the distributions' current releases. |

### Brand-inspired themes

Debian, Red Hat, CentOS, Arch, and most server distributions do not ship their own terminal palette. A theme named after them would be a new design based on brand colors. Brand colors from aggregator sites often disagree, so take values from each project's own brand page before designing.

| Brand | Colors found | Reliability |
|---|---|---|
| Ubuntu | Orange `#E95420`, aubergine `#300A24` (terminal) | Terminal value verified. Check the orange against [Ubuntu's brand update](https://ubuntu.com/blog/ubuntu-orange-update). |
| CentOS | Green `#9CCD2A`, orange `#EFA724`, blue `#262577`, purple `#A14F8C` | From the [archived CentOS wiki](https://wiki.centos.org/ArtWork(2f)Brand(2f)Logo.html). This logo is deprecated in favor of CentOS Stream. |
| Arch Linux | Blue `#1793D1`, gray `#333333` | Third-party source ([designpieces](https://www.designpieces.com/palette/arch-linux-color-palette-hex-and-rgb/)). |
| Kali Linux | Blue `#367BF0` | Taken from the Kali-Dark ANSI blue. |
| Red Hat, Fedora, Debian | Conflicting values | Not verified. Use [AlmaLinux branding](https://almalinux.org/branding/) and similar official pages as the model for each project. |

## Most installed Visual Studio Code themes

Queried from the Visual Studio Marketplace API on November 20, 2026, in the Themes category, sorted by installs. Install counts are cumulative. Icon themes, extension packs, and deprecated listings are excluded.

| Rank | Theme | Extension ID | Installs | Rating |
|---|---|---|---|---|
| 1 | GitHub Theme | `GitHub.github-vscode-theme` | 20.7M | 4.6 |
| 2 | One Dark Pro | `zhuangtongfa.Material-theme` | 12.9M | 4.7 |
| 3 | Dracula Theme Official | `dracula-theme.theme-dracula` | 11.2M | 4.8 |
| 4 | Atom One Dark | `akamud.vscode-theme-onedark` | 7.4M | 4.8 |
| 5 | Ayu | `teabyii.ayu` | 4.3M | 4.8 |
| 6 | Monokai Pro | `monokai.theme-monokai-pro-vscode` | 4.2M | 3.6 |
| 7 | Winter is Coming | `johnpapa.winteriscoming` | 3.8M | 4.6 |
| 8 | Night Owl | `sdras.night-owl` | 3.6M | 4.9 |
| 9 | Tokyo Night | `enkia.tokyo-night` | 3.0M | 5.0 |
| 10 | One Monokai | `azemoh.one-monokai` | 3.0M | 4.9 |
| 11 | Palenight | `whizkydee.material-palenight-theme` | 2.7M | 4.9 |
| 12 | SynthWave '84 | `RobbOwen.synthwave-vscode` | 2.6M | 4.8 |
| 13 | Shades of Purple | `ahmadawais.shades-of-purple` | 2.4M | 4.9 |
| 14 | Cobalt2 | `wesbos.theme-cobalt2` | 1.9M | 4.8 |
| 15 | Andromeda | `EliverLara.andromeda` | 1.7M | 5.0 |
| 16 | Bearded Theme | `BeardedBear.beardedtheme` | 1.5M | 4.9 |
| 17 | Catppuccin | `Catppuccin.catppuccin-vsc` | 1.5M | 5.0 |
| 18 | Atom One Light | `akamud.vscode-theme-onelight` | 1.5M | 4.9 |
| 19 | Noctis | `liviuschera.noctis` | 1.4M | 4.9 |
| 20 | Nord | `arcticicestudio.nord-visual-studio-code` | 1.3M | 4.9 |
| 21 | Panda | `tinkertrain.theme-panda` | 1.3M | 4.7 |
| 22 | Gruvbox | `jdinhlife.gruvbox` | 1.1M | 5.0 |
| 23 | Omni | `rocketseat.theme-omni` | 1.0M | 4.9 |
| 24 | Darcula | `rokoroku.vscode-theme-darcula` | 0.9M | 4.8 |
| 25 | Eva | `fisheva.eva-theme` | 0.8M | 4.9 |
| 26 | Linux Themes for VS Code | `SolarLiner.linux-themes` | 0.8M | 4.8 |
| 27 | Doki Theme | `unthrottled.doki-theme` | 0.7M | 4.9 |
| 28 | Min Theme | `miguelsolorio.min-theme` | 0.6M | 4.9 |
| 29 | Aura | `DaltonMenezes.aura-theme` | 0.6M | 5.0 |

Notes:

- Microsoft's C/C++ Themes (`ms-vscode.cpptools-themes`, 61.8M) has the most installs, but most come from automatic installation with the C/C++ extension. It is not a measure of user choice.
- Monokai Pro is a commercial theme. Do not bundle it without a license.
- Linux Themes for VS Code adapts Linux desktop styles. Review its theme list as a source for the distribution presets above.
- Visual Studio Code also ships other built-in theme extensions under the same MIT license as `theme-defaults`: Abyss, Kimbie Dark, Monokai, Monokai Dimmed, Quiet Light, Red, Solarized Dark, Solarized Light, and Tomorrow Night Blue. They can be added with the existing adapter.

## Recommended first set

| Group | Themes |
|---|---|
| Distribution terminals | Ubuntu (classic aubergine), Kali Dark, GNOME dark and light (Fedora, RHEL), Breeze (KDE), Tango, Linux console |
| Visual Studio Code built-ins | Solarized Dark, Solarized Light, Monokai, Abyss, Quiet Light, Tomorrow Night Blue |
| Popular community themes | GitHub Dark and Light, One Dark Pro, Dracula, Tokyo Night, Night Owl, Catppuccin, Nord, Gruvbox, Ayu |

The current loader accepts at most 64 assets. The bundled 10 plus this set are about 34 presets, because several extensions provide more than one variant.

## Before bundling

- Check each theme's license and keep its notice next to `vscode-themes-license.txt`.
- Pin each source to a release or commit and record its SHA-256 in the bundle manifest.
- Verify the Kali-Dark port against the upstream file. Confirm the default terminals for Ubuntu 25.10 and later and for RHEL 9 and 10.
- For terminal-only palettes, define the derived workspace colors and check text contrast in the toolbar, sidebar, and tabs.
