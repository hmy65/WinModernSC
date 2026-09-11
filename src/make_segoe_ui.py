#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
用 source\\ 里的字体造出整套 "Segoe UI"（12 个静态文件），输出到 SegoeUIMod\\。

这一族只管拉丁：汉字会被裁掉，交给字体回退落到微软雅黑，而雅黑在文件层
指向同一套源字体（见 make_cjk.py）。真正的 Segoe UI 本来也是一个汉字都没有，
所以这就是 Windows 原本的分工，顺带把每个文件从 20 多 MB 压到 1MB 上下。

Segoe UI 不是可变字体，是 12 个静态文件，按 Windows 经典的「每 4 个一组」
样式链接结构组织：

  GDI 家族 (nameID 1)   ID2           排版家族(16)  排版子族(17)
  ---------------------------------------------------------------
  Segoe UI              Regular       (无)          (无)
  Segoe UI              Bold          (无)          (无)
  Segoe UI              Italic        (无)          (无)
  Segoe UI              Bold Italic   (无)          (无)
  Segoe UI Light        Regular       Segoe UI      Light
  ... Semilight / Semibold / Black 依此类推

GDI 看到 5 个家族（每组 R/B/I/BI），DirectWrite 再靠 nameID 16/17 把它们
合并成一个排版家族 "Segoe UI"。身份字段逐个从系统里真的 segoeui*.ttf 照抄，
不手抄。

Win11 外壳用的那个 "Segoe UI Variable" 不在这一族里，是另一个注册项、另一个
文件，见 make_vf.py。

按源类型分两条路（源类型见 util.scan_source）：
    STATIC / BOTH   每个输出挑一个同名或最接近的静态字重（下面 STYLES 那张
                    并档表），并存时静态那半已经齐了，用不着动 VF
    VF              源里只有一个可变字体，各档从它实例化出来

源是单个 VF 时可以加 --regular-weight N（400–500）：Regular 和 Italic 这一档
改在 wght N 上切，身份仍是 400，别的档不动，见 util.outline_weight。
make_vf.py / make_cjk.py 要给同一个值。
"""

import os
import time
from collections import namedtuple

from fontTools.ttLib import TTFont

import patch_glyphs
import util
import verify_fonts
from util import log

OUTDIR = os.path.join(util.ROOT, "SegoeUIMod")

# 输出文件, 照抄身份的真 Segoe UI 文件, 源字重的优先顺序, Fonts 注册表值名。
#
# 源字重那一列就是「并档表」：第一个是同名样式，找不到就往后退到最接近的
# 一档，几个输出复用同一个源文件。Semilight 一般没有同名样式，直接并到
# Light；Black 并到 Bold。身份字段仍然逐个照抄真 Segoe UI，所以系统眼里
# 的字重档位一个不少。
#
# 斜体那 6 个输出的链要是整条都落空（源字体压根没有真斜体，简中字体里很
# 常见），就退到对应的正体源，轮廓由 util.oblique() 剪出来。这是下策，见
# README 里那一段代价 —— 有真斜体就一定用真斜体。
STYLES = [
    ("SegoeUI-Regular.ttf",         "segoeui.ttf",   ("Regular",),
     "Segoe UI (TrueType)"),
    ("SegoeUI-Bold.ttf",            "segoeuib.ttf",  ("Bold", "Black", "SemiBold"),
     "Segoe UI Bold (TrueType)"),
    ("SegoeUI-Italic.ttf",          "segoeuii.ttf",  ("Italic",),
     "Segoe UI Italic (TrueType)"),
    ("SegoeUI-BoldItalic.ttf",      "segoeuiz.ttf",  ("BoldItalic", "BlackItalic", "SemiBoldItalic"),
     "Segoe UI Bold Italic (TrueType)"),
    ("SegoeUI-Light.ttf",           "segoeuil.ttf",  ("Light", "ExtraLight"),
     "Segoe UI Light (TrueType)"),
    ("SegoeUI-LightItalic.ttf",     "seguili.ttf",   ("LightItalic", "ExtraLightItalic"),
     "Segoe UI Light Italic (TrueType)"),
    ("SegoeUI-Semilight.ttf",       "segoeuisl.ttf", ("SemiLight", "Light", "ExtraLight"),
     "Segoe UI Semilight (TrueType)"),
    ("SegoeUI-SemilightItalic.ttf", "seguisli.ttf",  ("SemiLightItalic", "LightItalic", "ExtraLightItalic"),
     "Segoe UI Semilight Italic (TrueType)"),
    ("SegoeUI-Semibold.ttf",        "seguisb.ttf",   ("SemiBold", "Bold", "Black"),
     "Segoe UI Semibold (TrueType)"),
    ("SegoeUI-SemiboldItalic.ttf",  "seguisbi.ttf",  ("SemiBoldItalic", "BoldItalic", "BlackItalic"),
     "Segoe UI Semibold Italic (TrueType)"),
    ("SegoeUI-Black.ttf",           "seguibl.ttf",   ("Black", "Bold", "SemiBold"),
     "Segoe UI Black (TrueType)"),
    ("SegoeUI-BlackItalic.ttf",     "seguibli.ttf",  ("BlackItalic", "BoldItalic", "SemiBoldItalic"),
     "Segoe UI Black Italic (TrueType)"),
]


def plan_note(merged, fake, thick=False):
    """计划表和汇总表末尾那一列：这个输出是并档来的、伪斜出来的，还是被
    --regular-weight 调粗的。

    伪斜和调粗都必须在日志里看得见 —— 它们和正常的产物在文件名、身份字段上
    一模一样，不标出来就只能靠肉眼看字形才发现。
    """
    tags = (([] if not merged else ["并档"])
            + ([] if not fake else ["伪斜 %g°" % util.ITALIC_ANGLE])
            + ([] if not thick else ["调粗"]))
    return "(%s)" % ", ".join(tags) if tags else ""


# 一个输出的施工单。path 和 inst 恰好有一个是 None：静态源给路径，VF 源给
# (字重, 要不要斜体) 这一对坐标，到时候现切。thick = 这一档被 --regular-weight
# 调粗了（轮廓字重 != 身份字重）。
Row = namedtuple("Row", "outname realname label path inst merged fake thick reg")


def plan_static(src):
    """STATIC / BOTH：每个输出挑一个同名或最接近的静态字重。"""
    plan = []
    for outname, realname, chain, reg in STYLES:
        hit = util.pick_source(src.styles, chain, outname, required=False)
        # 只有斜体链整条落空才伪斜。正体链落空是硬错误 —— upright_chain()
        # 对正体链是恒等变换，下面那次 required=True 会照样把它报出来。
        fake = hit is None and util.is_italic(chain[0])
        if hit is None:
            hit = util.pick_source(src.styles, util.upright_chain(chain), outname)
        sname, spath, merged = hit
        plan.append(Row(outname, realname, sname, spath, None, merged, fake,
                        False, reg))
    return plan


def plan_vf(vfi, regular_weight=None):
    """VF：每个输出去 VF 上切哪一档。

    切哪一档不看文件名里的样式词，看【被冒充的那个真 Segoe UI 文件】的
    usWeightClass —— clone_identity() 本来就把这个值原样抄进产物，轮廓跟着
    身份走，两边永远对得上。Semilight 是 350、Semibold 600、Black 900，一档
    不少，也就不必再为 VF 另立一张「输出 -> 字重」对照表。

    例外只有 Regular（400）那一档：给了 --regular-weight 就改切在它上面，
    Regular 和 Italic 一起，见 util.outline_weight。

    斜体：源 VF 带 ital / slnt 轴就切真斜体，不带就照静态那条路的规矩伪斜。
    并档在这条路上不存在 —— 轴是连续的，要哪一档就有哪一档。
    """
    plan = []
    for outname, realname, chain, reg in STYLES:
        ident = util.system_font_weight(realname)
        weight = util.outline_weight(ident, regular_weight)
        want_italic = util.is_italic(chain[0])
        fake = want_italic and not vfi.has_italic_axis
        label = "VF wght %d%s" % (weight,
                                  " 斜" if want_italic and not fake else "")
        plan.append(Row(outname, realname, label, None, (weight, want_italic),
                        False, fake, weight != ident, reg))
    return plan


def open_source(row, vfi):
    """按施工单开出这一档的源字体。

    静态那条路直接开成品文件，不实例化 —— 它自带的 prep/fpgm/cvt 和逐字形
    指令原样留着，那是小字号能看清的关键。VF 那条路先切出静态实例（同一档
    只切一次，见 util.VFInstances）。两条路开出来之后走的是同一条流水线，
    补字也一样要补。
    """
    if row.path:
        return TTFont(row.path)
    return TTFont(vfi.instance(*row.inst)[0])


def main():
    args = util.parse_args("用 source\\ 里的字体造出 12 个静态 Segoe UI，"
                           "输出到 SegoeUIMod\\。")
    src = util.scan_source()
    rw = util.resolve_regular_weight(src, args.regular_weight)
    util.require_system_fonts([s[1] for s in STYLES])
    os.makedirs(OUTDIR, exist_ok=True)

    log("源字体 : %s" % src.describe())
    log("目录   : %s" % util.SOURCE_DIR)
    log("输出到 : %s" % OUTDIR)
    if rw:
        log("Regular: 轮廓切在 wght %d（身份仍是 %d）" % (rw, util.REGULAR))
    log("")

    vfi = util.VFInstances(src.vf) if src.kind == util.VF else None
    try:
        plan = plan_vf(vfi, rw) if vfi else plan_static(src)
        _build(plan, vfi, rw)
    finally:
        if vfi:
            vfi.close()

    # 生成完当场自检，不通过就非零退出。SegoeUI-Variable.ttf 是 make_vf.py 的
    # 产物，同住这个目录，报给 also 免得被当成旧文件。
    verify_fonts.report_after_build(*verify_fonts.verify_segoe(
        STYLES, OUTDIR, also=[util.VF_OUTNAME]))


def _build(plan, vfi, regular_weight=None):
    # 先把 12 个输出各自用哪个源定下来，打一张表出来再动手
    log("%-28s %-16s %-14s %s" % ("输出", "身份照抄", "源字重", "备注"))
    for r in plan:
        log("  %-28s %-16s %-14s %s"
            % (r.outname, r.realname, r.label,
               plan_note(r.merged, r.fake, r.thick)))
    log("")

    t0 = time.time()
    rows = []
    for r in plan:
        outname, realname, sname, merged, fake = (
            r.outname, r.realname, r.label, r.merged, r.fake)
        t = time.time()
        font = open_source(r, vfi)
        real = util.open_system_font(realname, lazy=True)
        out = os.path.join(OUTDIR, outname)
        try:
            util.clone_identity(font, real, "WinModernSC-%s"
                                % os.path.splitext(outname)[0],
                                regular_weight=regular_weight)
            util.clone_metrics(font, real, caret=True)
            util.set_gasp(font)
            if "meta" in font:
                font["meta"].data["dlng"] = "Latn, Grek, Cyrl"
                font["meta"].data["slng"] = "Latn, Grek, Cyrl"
            # 裁到「真 Segoe UI 覆盖什么我们就覆盖什么」，汉字交给回退
            util.subset_to_coverage(font, real.getBestCmap().keys())
            if fake:
                # 排在裁剪之后：剪切要遍历每个字形并重算包围盒，裁完只剩两千
                # 来个，比对着源字体那四万多个字形做便宜一个数量级。
                #
                # 也必须排在补字【之前】。补字的第一顺位捐赠源就是 real ——
                # 斜体那 6 个输出的 real 是真的 segoeui*i.ttf，搬过来的字形
                # 本身就已经是斜的。放在补字之后剪，等于把它们再斜一遍：实测
                # 逐点比对，搬进来的 97 个字形全都比捐赠源多斜了一个 tan12°，
                # 12° 变成 24°，和周围的字明显不是一套。
                util.oblique(font)
            # 补上源字体缺、而真 Segoe UI 有的那些（西欧重音字母、标点、符号）。
            # 排在裁剪之后：裁完只剩两千来个字形，比对着源字体那四万多个做便宜
            # 一个数量级，而且补进来的本来就都在裁剪目标里，不会被裁掉。
            # 后备捐赠源按【轮廓】的字重排：VF 那条路切在哪档就是哪档（Regular
            # 调粗过就是 --regular-weight），静态那条路照旧按身份。
            rep = patch_glyphs.patch(font, real, realname,
                                     r.inst[0] if r.inst
                                     else util.system_font_weight(realname),
                                     must=util.MUST_LATIN)
            if rep.wanted:
                log("      " + rep.line("[补字]"))
            n_glyph = len(font.getGlyphOrder())
            font.save(out)
            # 必须放在 save 之后：head 的包围盒是编译时由 maxp.recalc 重算的，
            # 裁之前、甚至裁完还没保存时读到的都还是源字体那一整套字形的框。
            util.check_metrics(font, outname)
        finally:
            real.close()
        id1 = font["name"].getDebugName(1)
        id2 = font["name"].getDebugName(2)
        font.close()
        note = plan_note(merged, fake, r.thick)
        rows.append((outname, id1, id2, sname, n_glyph, util.mb(out), note))
        log("  -> %-28s %6.2f MB  %5d 字形  <- %-16s %s(%.0fs)"
            % (outname, util.mb(out), n_glyph, sname,
               note + " " if note else "", time.time() - t))

    log("")
    log("%-28s %-20s %-12s %-16s %7s %7s  %s"
        % ("文件", "ID1 (GDI 家族)", "ID2", "源字重", "字形", "MB", "备注"))
    log("-" * 100)
    total = 0
    for outname, id1, id2, sname, n, size, note in rows:
        total += size
        log("%-28s %-20s %-12s %-16s %7d %7.2f  %s"
            % (outname, id1, id2, sname, n, size, note))
    log("-" * 100)
    log("%d 个文件, 合计 %.1f MB, 用时 %.0fs" % (len(rows), total, time.time() - t0))


if __name__ == "__main__":
    main()
