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
"""

import os
import time

from fontTools.ttLib import TTFont

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


def plan_note(merged, fake):
    """计划表和汇总表末尾那一列：这个输出是并档来的、还是伪斜出来的。

    伪斜必须在日志里看得见 —— 它和真斜体的产物在文件名、身份字段上一模一样，
    不标出来就只能靠肉眼看字形才发现走的是下策那条路。
    """
    tags = ([] if not merged else ["并档"]) + ([] if not fake else
                                              ["伪斜 %g°" % util.ITALIC_ANGLE])
    return "(%s)" % ", ".join(tags) if tags else ""


def main():
    family, styles = util.scan_source()
    util.require_system_fonts([s[1] for s in STYLES])
    os.makedirs(OUTDIR, exist_ok=True)

    log("源字体 : %s（%s，%d 个样式）" % (family, util.SOURCE_DIR, len(styles)))
    log("输出到 : %s" % OUTDIR)
    log("")

    # 先把 12 个输出各自用哪个源文件定下来，打一张表出来再动手
    plan = []
    for outname, realname, chain, reg in STYLES:
        hit = util.pick_source(styles, chain, outname, required=False)
        # 只有斜体链整条落空才伪斜。正体链落空是硬错误 —— upright_chain()
        # 对正体链是恒等变换，下面那次 required=True 会照样把它报出来。
        fake = hit is None and util.is_italic(chain[0])
        if hit is None:
            hit = util.pick_source(styles, util.upright_chain(chain), outname)
        sname, spath, merged = hit
        plan.append((outname, realname, sname, spath, merged, fake, reg))
    log("%-28s %-16s %-14s %s" % ("输出", "身份照抄", "源字重", "备注"))
    for outname, realname, sname, _p, merged, fake, _r in plan:
        log("  %-28s %-16s %-14s %s"
            % (outname, realname, sname, plan_note(merged, fake)))
    log("")

    t0 = time.time()
    rows = []
    for outname, realname, sname, spath, merged, fake, _reg in plan:
        t = time.time()
        # 直接开源字体的成品文件 —— 不实例化、不补字，它自带的
        # prep/fpgm/cvt 和逐字形指令原样留着，那是小字号能看清的关键。
        font = TTFont(spath)
        real = util.open_system_font(realname, lazy=True)
        out = os.path.join(OUTDIR, outname)
        try:
            util.clone_identity(font, real, "WinModernSC-%s"
                                % os.path.splitext(outname)[0])
            util.clone_metrics(font, real, caret=True)
            util.set_gasp(font)
            if "meta" in font:
                font["meta"].data["dlng"] = "Latn, Grek, Cyrl"
                font["meta"].data["slng"] = "Latn, Grek, Cyrl"
            # 裁到「真 Segoe UI 覆盖什么我们就覆盖什么」，汉字交给回退
            n_glyph = util.subset_to_coverage(font, real.getBestCmap().keys())[1]
            if fake:
                # 排在裁剪之后：剪切要遍历每个字形并重算包围盒，裁完只剩两千
                # 来个，比对着源字体那四万多个字形做便宜一个数量级。
                util.oblique(font)
            font.save(out)
            # 必须放在 save 之后：head 的包围盒是编译时由 maxp.recalc 重算的，
            # 裁之前、甚至裁完还没保存时读到的都还是源字体那一整套字形的框。
            util.check_metrics(font, outname)
        finally:
            real.close()
        id1 = font["name"].getDebugName(1)
        id2 = font["name"].getDebugName(2)
        font.close()
        note = plan_note(merged, fake)
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

    # 生成完当场自检，不通过就非零退出
    verify_fonts.report(*verify_fonts.verify_segoe(STYLES, OUTDIR))


if __name__ == "__main__":
    main()
