# WinModernSC

[中文](README_zh-CN.md)

## What it does

WinModernSC replaces the Windows UI font across the whole system — the shell, legacy
Win32 dialogs, UWP/WinUI apps, browsers and Office documents — using one source font
family of your choice.

It works in two stages. Two Python scripts read the fonts in `source\` and generate two
sets of font files: a 12-file `Segoe UI` family (Latin only) and 8 files that stand in for
the Windows Chinese families (Microsoft YaHei / SimSun / SimHei / DengXian). A PowerShell
script then wires those files into four registry mechanisms and backs up every value it
touches first.

**Recommended source: [SarasaGothicSC-TTF](https://github.com/be5invis/Sarasa-Gothic/releases)**
— the TTF release package, not the `-Unhinted` one. This is the combination this project
has actually been tested with and the one that looks best: Sarasa Gothic ships complete
TrueType hinting, so stems still separate cleanly at the small pixel sizes Windows UI text
runs at, and it carries Latin and Han in a single family so the two halves match.

Any Simplified Chinese font works as long as the files in `source\` follow the
`<Family>-<Style>.ttf` naming rule and cover the required weights. Only upright weights are
required — most Simplified Chinese families ship no italics at all, so when one is missing
the generator slants the matching upright itself, at a real cost described below.

## The four mechanisms

Each one covers a layer the others cannot reach. `main.ps1` parses the arguments, checks for
elevation, owns the backup file and the shared helpers, then hands off to one file per
mechanism under `src\`.

| # | What it does | Defined in |
| --- | --- | --- |
| **1** | Repoints the `Fonts` registry key at the generated files — 12 for the `Segoe UI` family (Latin) and 8 standing in for the Windows Chinese families (Microsoft YaHei / SimSun / SimHei / DengXian). GDI and DirectWrite both read the family name out of the font file itself, so this is the layer with the widest reach: shell, UWP/WinUI, browsers, Office. | [`src/main_fonts.ps1`](src/main_fonts.ps1) |
| **2** | Writes `FontSubstitutes` entries pointing `Tahoma`, `MS Shell Dlg`, `MS Sans Serif` and friends at `Segoe UI`. Only GDI reads this table; it is there to catch legacy Win32 programs still asking for family names that no longer have a good font behind them. | [`src/main_font_substitutes.ps1`](src/main_font_substitutes.ps1) |
| **3** | Writes the six `WindowMetrics` LOGFONTs (caption, small caption, menu, dialog, status bar, icon label) plus caption height and the Windows 11 border, for every user profile on the machine. Classic comctl32 controls never consult `Fonts` or `FontSubstitutes` — the system pushes the font *and its point size* to them through `SystemParametersInfo` — so this is the only layer that can change the size. | [`src/main_window_metrics.ps1`](src/main_window_metrics.ps1) |
| **4** | Prepends two lines to `FontLink\SystemLink` for the five `Segoe UI` GDI families, so their Han fallback resolves through the files mechanism 1 installed instead of the stock font in `%windir%\Fonts`. Each family gets the matching weight (`Segoe UI Light` links the Light cut, `Segoe UI Black` the Bold one); mismatch it and you get light Latin next to regular-weight Han. The inserted entry copies the `,128,96` suffix from the stock entry it shadows — that suffix is what switches on GDI's size matching between the base font and the linked one (measured on Win11 26200: with it, `Segoe UI` renders linked `Microsoft YaHei UI` at 1.05×; without it, a flat 1.00×), so dropping it would silently turn the matching off. Windows pairs every scaled entry with an unscaled duplicate of itself, so we do the same — hence two lines. The rest of each existing chain is kept as-is — its order and its `,128,96` scaling parameters are deliberate, and it carries the Japanese, Korean, Traditional Chinese and Segoe UI Symbol fallbacks. | [`src/main_font_link.ps1`](src/main_font_link.ps1) |

Undoing all four is handled by [`src/main_revert.ps1`](src/main_revert.ps1), driven from the
backup JSON that each mechanism writes before it changes anything.

### How they depend on each other

**Mechanism 1 is the foundation; 2, 3 and 4 all assume it is in place.** None of them fails
without it — each writes what it writes regardless — but the *result* changes:

- **2 and 3** only redirect font requests to the family name `Segoe UI`. Whether that name
  resolves to your font or to Microsoft's original depends entirely on mechanism 1 having
  run, in this run or an earlier one. `main.ps1` prints a warning if you combine `-no-fonts`
  with either of them.
- **4 depends on 1 twice over.** It reads the `Fonts` entry for the *matching weight* of
  Microsoft YaHei to build the first line of the fallback chain, so it has to run *after*
  mechanism 1 — `main.ps1` enforces that order. And the problem it exists to solve (Han
  stripped out of the `Segoe UI` files) is created by mechanism 1 in the first place; without
  1 the `Fonts` entries are still bare filenames like `msyh.ttc`, so mechanism 4 skips every
  family and writes nothing at all.
- **2, 3 and 4 do not depend on each other** and can be skipped in any combination.

## Highlights

Each item below names the mechanism and the file that implements it.

**Covers both rendering paths, not just one.** Mechanism 1
([`src/main_fonts.ps1`](src/main_fonts.ps1)) repoints the `Fonts` registry key at generated
files whose `name` table carries the target family name — GDI and DirectWrite both read the
family name out of the font file, so both follow. Mechanism 2
([`src/main_font_substitutes.ps1`](src/main_font_substitutes.ps1)) adds `FontSubstitutes`
entries, which only GDI reads, to catch legacy Win32 programs still asking for `Tahoma` or
`MS Shell Dlg`. Mechanism 4 ([`src/main_font_link.ps1`](src/main_font_link.ps1)) extends
`FontLink\SystemLink` so GDI's Han fallback resolves through the same files instead of
going straight to `%windir%\Fonts` and picking up the stock font. Editing `FontSubstitutes`
by hand only covers the GDI half of this.

**Han text that a web page or document asks for by name gets replaced too.**
[`src/make_cjk.py`](src/make_cjk.py) writes both the English and the localized family name
(`nameID 1`, langID `0x804`) into the generated files — `Microsoft YaHei` / 微软雅黑,
`SimSun` / 宋体, `SimHei` / 黑体, `DengXian` / 等线 — and mechanism 1 points the matching
`Fonts` entries at them. A page with `font-family: 微软雅黑` or a Word document whose body
font is 宋体 therefore resolves to the new font. `FontSubstitutes` cannot do this, because
DirectWrite ignores that table entirely.

**Latin and Han come from one source font.**
[`src/make_segoe_ui.py`](src/make_segoe_ui.py) subsets the generated `Segoe UI` family down
to the coverage of the real Segoe UI, dropping Han — which is what stock Windows does, the
real Segoe UI has no Han either — and mechanism 4 makes sure the fallback lands on the CJK
files built from the same source by `make_cjk.py`.

**Changes size and window geometry, not just family names.** Mechanism 3
([`src/main_window_metrics.ps1`](src/main_window_metrics.ps1)) writes the six `WindowMetrics`
LOGFONTs plus caption height and the Windows 11 padded border. It does this for every user
profile on the machine, plus `HKU\.DEFAULT` and the new-user template
(`C:\Users\Default\NTUSER.DAT`, temporarily `reg load`ed), so new accounts and the pre-logon
UI get it too. Each hive's `AppliedDPI` is recorded in the backup, and `lfHeight` is
rescaled on restore if display scaling changed in the meantime. noMeiryoUI covers this layer
only — it does not reach the layers that browsers, UWP apps or Office read.

**Full backup, one-command restore, and a dry run.** Every value that is about to be written
is read and saved to `winmodernsc-backup.json` before anything is modified. Values that did
not exist beforehand are recorded as null and deleted on restore, and registry keys the
install created are removed if they end up empty, so `-revert` does not leave residue.
`-DryRun` prints the complete plan for all four mechanisms and writes nothing at all — not
even the backup file.

**No process injection, no system files replaced.** Font files are copied to `C:\Fonts` and
the registry is pointed at them; nothing under `%windir%\Fonts` is modified or deleted.
Nothing runs after installation. MacType, by comparison, injects into processes to change
rasterization at run time.

**Not tied to one source font.** [`src/util.py`](src/util.py) scans `source\` for
`<Family>-<Style>.ttf` files, requires only Regular / Light plus either Bold or Black, and
uses any extra weights it finds. Every output picks the same-named style first and falls back
to the nearest available one; those fallback chains are a literal table at the top of
`make_segoe_ui.py` and `make_cjk.py`, and the resolved mapping is printed before each build
starts. Italics are not required: an output whose whole italic chain comes up empty is built
by shearing the matching upright instead, which keeps the door open to the many Simplified
Chinese families that have no italics — see the trade-off below before relying on it.

## Requirements and setup

### Requirements

- **Windows 10 or 11** with the Simplified Chinese fonts and the static Segoe UI files
  present in `%windir%\Fonts`: `msyh.ttc`, `msyhbd.ttc`, `msyhl.ttc`, `simsun.ttc`,
  `simhei.ttf`, `Deng.ttf`, `Dengb.ttf`, `Dengl.ttf`, and `segoeui.ttf` … `seguibli.ttf`.
  The generators copy identity fields (family name, style, weight class, PANOSE) from these
  and stop with a list of what is missing if any are absent.
- **Python 3.8+** with fontTools: `pip install fonttools`
- **PowerShell as Administrator** — Windows PowerShell 5.1 or PowerShell 7 both work.
  `-DryRun` is the only mode that runs without elevation.
- **About 205 MB free on `C:`** for the generated fonts (the CJK files are the bulk of it).

### 1. Put the source fonts in `source\`

Put any Simplified Chinese font family into `WinModernSC\source\` — anything works as long as
the files follow the naming rules below. The recommended pick (and the one this project is
tested with) is the SarasaGothicSC package from the
[Sarasa Gothic releases page](https://github.com/be5invis/Sarasa-Gothic/releases); if you go
with it, take the TTF release, not the `-Unhinted` variant.

Naming rules for that directory:

- Every file must be named `<Family>-<Style>.ttf`, e.g. `SarasaGothicSC-Regular.ttf`,
  `SarasaGothicSC-BoldItalic.ttf`.
- `<Family>` must be identical for every file in the directory — one family per directory.
- Required styles: `Regular`, `Light`, plus either `Bold` or `Black`. Missing any of these is
  a hard error that names the exact files it could not find.
- Italic styles are optional. Supply them and they are used as-is; leave them out and the
  six italic outputs are generated by shearing the matching upright.
- Extra styles (`ExtraLight`, `SemiBold`, `SemiLight` …) are used when present and skipped
  when not.

**What you give up when the italics are synthesized.** When an output's whole italic fallback
chain comes up empty, the generator takes the matching upright source and slants the outlines
itself: a 12° shear along the baseline, the same angle the real Segoe UI Italic uses. Outputs
built this way are tagged `(伪斜 12°)` — "synthetic oblique, 12°"; the build log is in
Chinese — in the plan the generator prints before it starts, so it never happens quietly, and
a real italic in `source\` always wins over the shear. But a sheared upright is not a drawn
italic:

- **It destroys the source font's hinting, and that is the one you will see.** TrueType
  instructions are written against the upright coordinates — they identify stems by point
  number and snap their edges onto the pixel grid — so on a sheared outline they drag the
  slanted stems back toward vertical and break up the strokes. That looks worse than no
  hinting at all, so the generator drops the instructions along with `fpgm`, `prep` and
  `cvt `. The vertical hinting goes with them, which leaves the synthesized italics blurry
  and unevenly weighted at the small pixel sizes Windows UI text runs at. Sarasa Gothic, the
  recommended source, ships real italics and is not affected.
- A shear is not a redesign: `a`, `e` and `f` keep their upright two-storey shapes instead of
  becoming the single-storey cursive forms a drawn italic uses.
- Han strokes shear badly — horizontals and verticals pick up different visual weight once
  slanted, so characters read lighter or heavier than the upright at the same weight. This
  cost is latent today: only the Latin `Segoe UI` family is ever sheared and Han is stripped
  out of it, so it would bite only if a Chinese italic output were added.
- Spacing is not recomputed: advance widths are untouched and the kerning pairs still
  describe upright shapes, so slanted pairs sit slightly loose or tight.
- Tall glyphs can overhang, because the shear pushes them sideways out of the bounding box
  the upright had.

### 2. Generate the fonts

```bash
python src\make_segoe_ui.py
```

```bash
python src\make_cjk.py
```

The first writes 12 files to `SegoeUIMod\` (about 4 MB), the second writes 8 files to
`CJKMod\` (about 200 MB). Both print which source weight each output was built from before
they start.

When a generator finishes it immediately runs [`src/verify_fonts.py`](src/verify_fonts.py)
over its own output and exits non-zero if anything is wrong. The checks are: every expected
file is present and no stale ones are left over; the identity fields (`name` IDs 1, 2, 4, 6,
16, 17, both English and Chinese) match the Windows font each file impersonates; the CJK side
has full Han and symbol coverage while the Latin side has no Han at all; every output named
`Italic` carries a non-zero `post.italicAngle`, which is what a shear that silently did not
happen would fail; and `gasp` keeps grayscale and symmetric smoothing on for every size
range. Output with no TrueType hinting is reported as a warning rather than an error — for an
upright that means the source font had none, for a synthesized italic it is the shear having
dropped them. To re-check existing output without rebuilding:

```bash
python src\verify_fonts.py
```

### 3. Preview, install, restore

Preview — prints every change and touches nothing:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File .\main.ps1 -install -DryRun
```

Install, from an **Administrator** PowerShell:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File .\main.ps1 -install
```

Then **sign out and back in**, or reboot. GDI caches `FontSubstitutes` when a session
starts, so restarting the font cache service is not enough.

Restore everything, including deleting the installed font files:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File .\main.ps1 -revert
```

### Parameters

| Parameter | Effect |
| --- | --- |
| `-install` | Install everything (mechanisms 1 through 4). |
| `-revert` | Restore everything from `winmodernsc-backup.json` and delete the installed font files. |
| `-no-fonts` | Skip mechanism 1. **Nothing actually gets replaced** — 2 and 3 still redirect requests to `Segoe UI`, but that stays Microsoft's original font — so this is only useful when an earlier run already installed the files and you just want the registry rewritten. |
| `-no-font-substitutes` | Skip mechanism 2. Legacy Win32 programs asking for `Tahoma` / `MS Shell Dlg` / `MS Sans Serif` keep their old font; nothing else is affected. |
| `-no-window-metrics` | Skip mechanism 3. Title bars, menus, dialogs and status bars keep their current font **and size**, because those controls never read the `Fonts` key that mechanism 1 changes. |
| `-no-font-link` | Skip mechanism 4. If mechanism 1 did run, GDI programs fall back to the stock Microsoft YaHei for Han while DirectWrite uses the new font, so two different Han fonts end up on screen at once (harmless if you also passed `-no-fonts`). |
| `-DryRun` | Print the plan and change nothing. Combines with `-install` or `-revert`. |

The four `-no-*` switches combine freely. `-install` and `-revert` are mutually exclusive.
Running `main.ps1` with no arguments prints this list.

### What gets changed

| Mechanism | Location |
| --- | --- |
| 1 | `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts` (20 values), font files in `C:\Fonts` |
| 2 | `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\FontSubstitutes` (8 values) |
| 3 | `<each user>\Control Panel\Desktop\WindowMetrics` (6 LOGFONTs + 2 scalars) |
| 4 | `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\FontLink\SystemLink` (up to 5 values) |

Left alone on purpose: NSimSun (monospace, used by old programs for table alignment),
KaiTi / FangSong, the SimSun-ExtB/ExtG rare-character extensions, and Microsoft JhengHei.

If you edit the `.ps1` files, keep them saved as **UTF-8 with BOM** — Windows PowerShell 5.1
reads a BOM-less `.ps1` using the system ANSI code page and will mangle the non-ASCII text.

## Credits

- [fonttools](https://github.com/fonttools/fonttools) — library used to manipulate and generate the font files.
- [noMeiryoUI](https://github.com/Tatsu-syo/noMeiryoUI) — reference for the `WindowMetrics`
  layer (mechanism 3).
- [Sarasa Gothic](https://github.com/be5invis/Sarasa-Gothic) — the recommended source font.
- Claude Code.

The generated fonts keep the source font's own copyright and license `name` records. They
are built for local system-font substitution and are not meant for redistribution; check
your source font's license before sharing them.

Licensed under the [Apache License 2.0](LICENSE).
