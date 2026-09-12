# WinModernSC

[中文](README_zh-CN.md)

## What it does

WinModernSC replaces the Windows UI font across the whole system — the shell, legacy
Win32 dialogs, UWP/WinUI apps, browsers and Office documents — using one source font
family of your choice.

It works in two stages. Three Python scripts read the fonts in `source\` and generate three
sets of font files: a 12-file static `Segoe UI` family (Latin only), the single variable
font `Segoe UI Variable` that the Windows 11 shell actually uses, and 9 Chinese family files
(standing in for Microsoft YaHei / SimSun / SimHei / DengXian, plus a Microsoft YaHei
Semibold that Windows itself does not ship) — 22 files in all. A PowerShell script then
wires those files into four registry mechanisms and backs up every value it touches first.

**Recommended source: [SarasaGothicSC-TTF](https://github.com/be5invis/Sarasa-Gothic/releases)**
— the TTF release package, not the `-Unhinted` one. This is the combination this project
has actually been tested with and the one that looks best: Sarasa Gothic ships complete
TrueType hinting, so stems still separate cleanly at the small pixel sizes Windows UI text
runs at, and it carries Latin and Han in a single family so the two halves match.

Any Simplified Chinese font works as long as the files in `source\` follow the
`<Family>-<Style>.ttf` naming rule and form one of the
[three legal layouts](#1-put-the-source-fonts-in-source): a set of static weights, a single
variable font, or both together. Only upright weights are required — most Simplified Chinese
families ship no italics at all, so when one is missing the generator slants the matching
upright itself.

## The four mechanisms

Each one covers a layer the others cannot reach. `main.ps1` parses the arguments, checks for
elevation, owns the backup file and the shared helpers, then hands off to one file per
mechanism under `src\`.

| # | What it does | Defined in |
| --- | --- | --- |
| **1** | Repoints the `Fonts` registry key at the 22 generated files (12 static `Segoe UI`, 1 `Segoe UI Variable`, 9 Chinese families); GDI and DirectWrite both read the family name out of the font file itself, so the shell, UWP/WinUI, browsers and Office all follow. | [`src/main_fonts.ps1`](src/main_fonts.ps1) |
| **2** | Writes `FontSubstitutes` entries pointing the old family names `Tahoma`, `MS Shell Dlg` and `MS Sans Serif` at `Segoe UI`, to catch legacy Win32 programs still asking for them. | [`src/main_font_substitutes.ps1`](src/main_font_substitutes.ps1) |
| **3** | Writes the six `WindowMetrics` LOGFONTs (caption, small caption, menu, dialog, status bar, icon label) plus caption height and border width — this is the only layer that can change the point size. Size and weight are set with the two `-window-metrics-*` options, and a sign-in check writes them back whenever Windows resets them. | [`src/main_window_metrics.ps1`](src/main_window_metrics.ps1), [`src/logon_window_metrics.ps1`](src/logon_window_metrics.ps1) |
| **4** | Prepends two lines to `FontLink\SystemLink` for every `Segoe UI` family, so GDI's Han fallback resolves through the files mechanism 1 installed instead of the stock font in `%windir%\Fonts`. Each family gets the matching weight, and the rest of the existing chain is kept as-is. | [`src/main_font_link.ps1`](src/main_font_link.ps1) |

Undoing all four is handled by [`src/main_revert.ps1`](src/main_revert.ps1), driven from the
backup JSON that each mechanism writes before it changes anything.

### How they depend on each other

**Mechanism 1 is the foundation; 2, 3 and 4 all assume it is in place.** None of them fails
without it — each writes what it writes regardless — but the *result* changes:

- **2 and 3** only redirect font requests to a family name — 2 to `Segoe UI`, 3 to
  `Microsoft YaHei UI` (the family Windows gives the classic UI, at the matching weight for
  a non-Regular one). Whether that name resolves to your font or to Microsoft's original
  depends entirely on mechanism 1 having run, in this run or an earlier one. `main.ps1`
  prints a warning if you combine `-no-fonts` with either of them.
- **4 depends on 1 twice over.** It reads the `Fonts` entry for the *matching weight* of
  Microsoft YaHei to build the first line of the fallback chain, so it has to run *after*
  mechanism 1 — `main.ps1` enforces that order. And the problem it exists to solve (Han
  stripped out of the `Segoe UI` files) is created by mechanism 1 in the first place; without
  1 the `Fonts` entries are still bare filenames like `msyh.ttc`, so mechanism 4 skips every
  family and writes nothing at all.
- **2, 3 and 4 do not depend on each other** and can be skipped in any combination.

## Highlights

Each item below names the mechanism and the file that implements it.

**1. Covers both rendering paths.** The files mechanism 1
([`src/main_fonts.ps1`](src/main_fonts.ps1)) points at carry the target family name
themselves, and GDI and DirectWrite both read the family name out of the font file, so both
follow. Mechanism 2 ([`src/main_font_substitutes.ps1`](src/main_font_substitutes.ps1)) then
catches legacy Win32 programs that only read `FontSubstitutes`, and mechanism 4
([`src/main_font_link.ps1`](src/main_font_link.ps1)) sends GDI's Han fallback through the
same files. Editing `FontSubstitutes` by hand only covers the GDI half of this.

**2. Han text a web page or document asks for by name gets replaced too.**
[`src/make_cjk.py`](src/make_cjk.py) writes both the English and the localized family name
(`Microsoft YaHei` / 微软雅黑, `SimSun` / 宋体, `SimHei` / 黑体, `DengXian` / 等线) into the
generated files, and mechanism 1 points the matching `Fonts` entries at them. A page with
`font-family: 微软雅黑` or a Word document whose body font is 宋体 therefore resolves to the
new font. `FontSubstitutes` cannot do this, because DirectWrite ignores that table entirely.

**3. Latin and Han come from one source font.**
[`src/make_segoe_ui.py`](src/make_segoe_ui.py) subsets the generated `Segoe UI` family down
to the coverage of the real Segoe UI, dropping Han — the real Segoe UI has no Han either.
What drops out is picked up by mechanism 4, which routes it to the CJK files `make_cjk.py`
built from the same source.

**4. Whatever the source lacks gets filled in — composed rather than imported where
possible.** [`src/patch_glyphs.py`](src/patch_glyphs.py) patches in the accented letters and
symbols that the Windows font being replaced has and the source does not. Characters that
decompose (`À = A + ̀ `) become composite glyphs whose base references the source's own
letter, so style and advance width stay the source's; only what does not decompose is
imported whole. See "[Generate the fonts](#2-generate-the-fonts)".

**5. The Windows 11 shell layer gets replaced too.** Win11's Settings, Start menu and every
WinUI 3 app do not use those 12 static files — they use the variable font `Segoe UI
Variable`, which is its own entry in the `Fonts` key. [`src/make_vf.py`](src/make_vf.py)
builds that one file, copying `name` / `fvar` / `STAT` field by field from the real
`SegUIVar.ttf` on the system, so if Microsoft reshuffles them in a future build we follow
along.

**6. Changes size and window geometry, not just family names.** Mechanism 3
([`src/main_window_metrics.ps1`](src/main_window_metrics.ps1)) writes the six LOGFONTs plus
caption height and border width, for every user profile on the machine as well as
`HKU\.DEFAULT` and the new-user template, so new accounts and the pre-logon UI get it too.
Each hive's `AppliedDPI` goes into the backup, and `lfHeight` is rescaled on restore if
display scaling changed in the meantime. noMeiryoUI covers this layer only — not the ones
browsers, UWP apps and Office read.

**7. A non-default size or weight survives a display-scaling change.** Changing the scaling
makes Windows reset the classic UI fonts at the next sign-in; noMeiryoUI loses its settings
the same way. Mechanism 3 writes the very family Windows falls back to (`Microsoft YaHei UI`),
so with the defaults (9pt Regular) the reset writes exactly what was installed and nothing is
needed. Only when you pick a non-default `-window-metrics-*` does mechanism 3
register a short sign-in script ([`src/logon_window_metrics.ps1`](src/logon_window_metrics.ps1))
that rewrites your size and weight at the new scaling; `-revert` removes it.

**8. Full backup, one-command restore, and a dry run.** Every value about to be written is
saved to `winmodernsc-backup.json` first; values that did not exist beforehand are recorded
as null and deleted on restore. Registry keys the install created are removed if they end up
empty, so `-revert` leaves no residue. `-DryRun` prints the complete plan for all four
mechanisms and writes nothing at all.

**9. No process injection, no system files replaced.** Font files are copied to `C:\Fonts`
and the registry is pointed at them; nothing under `%windir%\Fonts` is modified or deleted.
Apart from the brief sign-in check in highlight 7, nothing runs after installation — MacType,
by comparison, injects into processes to change rasterization at run time.

**10. Not tied to one source font.** [`src/util.py`](src/util.py) scans `source\` and
classifies it as `STATIC`, `VF` or `BOTH`; all three generators branch on that. The static
path requires only Regular / Light plus either Bold or Black, and uses any extra weights it
finds; on the variable path the weight each output is cut at is read straight off the Windows
font it impersonates. Italics are not required — a missing one is built by shearing the
matching upright.

## Requirements and setup

### Requirements

- **Windows 10 or 11** with the Simplified Chinese fonts, the static Segoe UI files and the
  variable `SegUIVar.ttf` present in `%windir%\Fonts`: `msyh.ttc`, `msyhbd.ttc`, `msyhl.ttc`,
  `simsun.ttc`, `simhei.ttf`, `Deng.ttf`, `Dengb.ttf`, `Dengl.ttf`,
  `segoeui.ttf` … `seguibli.ttf`, and `SegUIVar.ttf`.
- **Python 3.8+** with fontTools: `pip install fonttools`
- **PowerShell as Administrator** — Windows PowerShell 5.1 or PowerShell 7 both work.
  `-DryRun` is the only mode that runs without elevation.
- **About 230 MB free on `C:`** for the generated fonts (the CJK files are the bulk of it).
  With a variable source, `SegoeUI-Variable.ttf` carries the whole source font, so add tens
  of MB on top.

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
  Mixing families is rejected outright rather than guessed at.
- `VF` is a reserved style name meaning "variable font": `<Family>-VF.ttf`, at most one per
  directory. Name and content have to agree — a file called `-VF.ttf` with no `fvar` table,
  or a file *with* an `fvar` table using a static weight name, is a hard error. (The second
  one especially: it would carry `fvar` / `STAT` into the `Segoe UI` family, and DirectWrite
  would then derive the family names from STAT and scramble every weight in it.)

**Three legal layouts; anything else is rejected.** The validator prints the source kind it
decided on, and all three generators branch on it:

| Kind | What is in `source\` | How the three scripts run |
| --- | --- | --- |
| `STATIC` | A set of static weights: at least `Regular` + `Light`, plus `Bold` or `Black` | The 12 `Segoe UI` files and the 9 Chinese ones each pick a static weight; `Segoe UI Variable` is synthesized from the static weights |
| `VF` | A single `<Family>-VF.ttf` | All three sets are instantiated from that variable font; `Segoe UI Variable` is converted from it directly, not synthesized |
| `BOTH` | `<Family>-VF.ttf` plus static files satisfying the `STATIC` rule | The 12 `Segoe UI` files and the 9 Chinese ones still take the static path (the designer's own static cuts beat interpolated ones); `Segoe UI Variable` uses the supplied VF |

- For `STATIC` and `BOTH`, missing any required weight is a hard error that names the exact
  files it could not find.
- Italic styles are optional. Supply them and they are used as-is; leave them out and the
  six italic outputs are generated by shearing the matching upright. With a variable source,
  an `ital` or `slnt` axis gives real italics and only its absence falls back to shearing.
- Extra styles (`ExtraLight`, `SemiBold`, `SemiLight` …) are used when present and skipped
  when not.

To give the Win11 shell genuinely distinct weights, add a `<Family>-VF.ttf` to `source\`
(the `BOTH` layout): a `Segoe UI Variable` synthesized from a `STATIC` source usually ends up
with no `wght` axis, leaving the weights to Windows' own synthetic bolding. The 12 static
`Segoe UI` files are unaffected either way — they have always used one real static weight
each.

### 2. Generate the fonts

```bash
python src\make_vf.py
```

```bash
python src\make_segoe_ui.py
```

```bash
python src\make_cjk.py
```

The first writes `SegoeUI-Variable.ttf` to `SegoeUIMod\` (about 0.4 MB from a static source;
from a variable source the whole source comes along, so tens of MB), the second writes the 12
static files to the same directory (about 4 MB), the third writes 9 files to `CJKMod\` (about
225 MB). All three print which source weight each output was built from before they start;
`make_vf.py` also prints the source kind, whether it synthesized or converted, and the
measured interpolation compatibility.

The three are order-independent and write their own outputs (`make_vf.py` and
`make_segoe_ui.py` share `SegoeUIMod\`, but the filenames do not overlap and each side's
self-check knows the other's output is not a stale leftover).

**A thin Regular can be made a little heavier.** Some fonts look thin at Regular at Windows
UI sizes. When the source is a single variable font, add the same `--regular-weight`
(400–500, default 400) to all three scripts: the Regular weight is built at that weight
instead, Windows still treats it as Regular, and the other weights stay as they are. If the
three scripts get different values, the self-check reports it.

**Missing glyphs are filled in automatically.** Accented letters, punctuation and symbols
that the replaced Windows font has but the source lacks get added to the output, so they
don't fall back to some other font that clashes with the surrounding text. Where possible
they are built from the source's own letter plus an accent; otherwise the whole glyph is
copied from a system font. Any output that got patched prints a
`[补字] 补 N 个码位，拼 X，搬 Y，组合符号 Z；来源 …` line. For what gets patched and how, see
the header comment in [`src/patch_glyphs.py`](src/patch_glyphs.py).

When a generator finishes it immediately runs [`src/verify_fonts.py`](src/verify_fonts.py)
over its own output and exits non-zero if anything is wrong. To re-check existing output
without rebuilding:

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

If you chose a non-default size or weight, a console window may flash briefly at each sign-in
from then on. That is the sign-in check from highlight 7, and it is normal.

Restore everything, including deleting the installed font files:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File .\main.ps1 -revert
```

### Parameters

| Parameter | Effect |
| --- | --- |
| `-install` | Install everything (mechanisms 1 through 4). |
| `-revert` | Restore everything from `winmodernsc-backup.json` and delete the installed font files. |
| `-no-fonts` | Skip mechanism 1. **Nothing actually gets replaced** — 2 and 3 still redirect requests to `Segoe UI` and `Microsoft YaHei UI`, but those stay Microsoft's original fonts — so this is only useful when an earlier run already installed the files and you just want the registry rewritten. |
| `-no-font-substitutes` | Skip mechanism 2. Legacy Win32 programs asking for `Tahoma` / `MS Shell Dlg` / `MS Sans Serif` keep their old font; nothing else is affected. |
| `-no-window-metrics` | Skip mechanism 3, including its sign-in check. Title bars, menus, dialogs and status bars keep their current font **and size**, because those controls never read the `Fonts` key that mechanism 1 changes. |
| `-no-font-link` | Skip mechanism 4. If mechanism 1 did run, GDI programs fall back to the stock Microsoft YaHei for Han while DirectWrite uses the new font, so two different Han fonts end up on screen at once (harmless if you also passed `-no-fonts`). |
| `-window-metrics-size` | Point size for the classic UI (mechanism 3). Default 9. |
| `-window-metrics-weight` | Weight for the classic UI: `Light` / `Semilight` / `Regular` / `Semibold` / `Bold` / `Black`. Default `Regular`. |
| `-DryRun` | Print the plan and change nothing. Combines with `-install` or `-revert`. |

The four `-no-*` switches combine freely. `-install` and `-revert` are mutually exclusive.
The two `-window-metrics-*` options only go with `-install` and cannot be combined with
`-no-window-metrics`.
Running `main.ps1` with no arguments prints this list.

### What gets changed

| Mechanism | Location |
| --- | --- |
| 1 | `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts` (22 values), font files in `C:\Fonts` |
| 2 | `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\FontSubstitutes` (8 values) |
| 3 | `<each user>\Control Panel\Desktop\WindowMetrics` (6 LOGFONTs + 2 scalars); with a non-default size or weight, the sign-in check also adds the `WinModernSC` value under `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run` and 2 scripts in `C:\Program Files\WinModernSC` |
| 4 | `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\FontLink\SystemLink` (up to 20 values) |

Left alone on purpose: NSimSun (monospace, used by old programs for table alignment),
KaiTi / FangSong, the SimSun-ExtB/ExtG rare-character extensions, and Microsoft JhengHei.

If you edit the `.ps1` files, keep them saved as **UTF-8 with BOM** — Windows PowerShell 5.1
reads a BOM-less `.ps1` using the system ANSI code page and will mangle the non-ASCII text.

## Credits

- [fonttools](https://github.com/fonttools/fonttools) — library used to manipulate, generate and verify the font files.
- [noMeiryoUI](https://github.com/Tatsu-syo/noMeiryoUI) — reference for the `WindowMetrics`
  layer (mechanism 3).
- [Sarasa Gothic](https://github.com/be5invis/Sarasa-Gothic) — the recommended source font.
- [OpenType specification](https://learn.microsoft.com/typography/opentype/spec/) — the
  basis for how the font tables are written.
- Claude Code.

The generated fonts keep the source font's own copyright and license `name` records. Glyphs
patched in come from the Windows fonts on your machine and are copyrighted by Microsoft. The
generated fonts are built for local system-font substitution and are not meant for
redistribution; check your source font's license before sharing them.

Licensed under the [Apache License 2.0](LICENSE).
