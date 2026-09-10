#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
用 source\\ 里的字体造出 Windows 中文族的替身：微软雅黑 / 宋体 / 黑体 / 等线，
输出到 CJKMod\\。

为什么需要这一步：FontSubstitutes 只有 GDI 认，DirectWrite 完全无视，所以
浏览器网页里的 font-family: 微软雅黑 / 宋体、Office 文档正文指定的中文字体，
靠替换表是改不掉的。但 GDI 和 DirectWrite 都从字体文件的 name 表读族名 ——
把 name 表改写成「微软雅黑」的副本注册过去，两条渲染路径就都跟着变了。

不动的：新宋体（等宽，老程序拿它对齐表格）、楷体 / 仿宋（书法体）、
SimSun-ExtB/ExtG（生僻字扩展）、微軟正黑體（繁体）。新宋体和宋体挤在同一个
注册项下，所以 WinModernSC-SimSun.ttc 里 face0 是替身、face1 把原版新宋体
原样搬进来。

按源类型分两条路（源类型见 util.scan_source）：
    STATIC / BOTH   每个输出挑一个同名或最接近的静态字重（下面 TARGETS 那张
                    并档表），并存时静态那半已经齐了，用不着动 VF
    VF              源里只有一个可变字体，各档从它实例化出来
"""

import os
import time
from collections import namedtuple

from fontTools.ttLib import TTFont, TTCollection

import patch_glyphs
import util
import verify_fonts
from util import log

OUTDIR = os.path.join(util.ROOT, "CJKMod")

# 纵向度量统一从这里抄（按 upem 缩放）。不按各自被顶替的字体抄：宋体是
# upem 256 的老字体、等线的框又和雅黑差一截，逐个照抄会让同一屏上不同中文族
# 的行距各不相同。统一用雅黑的，整套中文行高就和原版 Windows 一致。
METRICS_FROM = ("msyh.ttc", 0)

# 源字重的优先顺序，也就是「并档表」：第一个是同名样式，没有就退到最接近
# 的一档，几个输出复用同一个源文件。
REG = ("Regular",)
BOLD = ("Bold", "Black", "SemiBold")
LIGHT = ("Light", "ExtraLight")

# 输出文件, 源字重, [(要冒充的系统字体, ttc 索引, 是否原样搬运)], Fonts 注册表值名
TARGETS = [
    ("WinModernSC-YaHei.ttc",         REG,
     [("msyh.ttc", 0, False), ("msyh.ttc", 1, False)],
     "Microsoft YaHei & Microsoft YaHei UI (TrueType)"),
    ("WinModernSC-YaHei-Bold.ttc",    BOLD,
     [("msyhbd.ttc", 0, False), ("msyhbd.ttc", 1, False)],
     "Microsoft YaHei Bold & Microsoft YaHei UI Bold (TrueType)"),
    ("WinModernSC-YaHei-Light.ttc",   LIGHT,
     [("msyhl.ttc", 0, False), ("msyhl.ttc", 1, False)],
     "Microsoft YaHei Light & Microsoft YaHei UI Light (TrueType)"),
    # face1 = 新宋体，等宽，原样保留
    ("WinModernSC-SimSun.ttc",        REG,
     [("simsun.ttc", 0, False), ("simsun.ttc", 1, True)],
     "SimSun & NSimSun (TrueType)"),
    ("WinModernSC-SimHei.ttf",        REG,
     [("simhei.ttf", None, False)],
     "SimHei (TrueType)"),
    ("WinModernSC-DengXian.ttf",      REG,
     [("Deng.ttf", None, False)],
     "DengXian (TrueType)"),
    ("WinModernSC-DengXian-Bold.ttf", BOLD,
     [("Dengb.ttf", None, False)],
     "DengXian Bold (TrueType)"),
    ("WinModernSC-DengXian-Light.ttf", LIGHT,
     [("Dengl.ttf", None, False)],
     "DengXian Light (TrueType)"),
]


# 一个输出的施工单。path 和 inst 恰好有一个是 None：静态源给路径，VF 源给
# 一个字重，到时候现切。
Row = namedtuple("Row", "outname faces label path inst merged reg")


def plan_static(src):
    """STATIC / BOTH：每个输出挑一个同名或最接近的静态字重。"""
    plan = []
    for outname, chain, faces, reg in TARGETS:
        sname, spath, merged = util.pick_source(src.styles, chain, outname)
        plan.append(Row(outname, faces, sname, spath, None, merged, reg))
    return plan


def plan_vf():
    """VF：每个输出去 VF 上切哪一档。

    切哪一档看【被冒充的那个系统中文字体】的 usWeightClass —— 微软雅黑
    Light/Regular/Bold 是 300/400/700，等线三档同理，宋体黑体都是 400。
    clone_identity() 本来就把这个值原样抄进产物，轮廓跟着身份走，所以这条
    路不需要 TARGETS 那张并档表，也不需要另立一张字重对照表。
    """
    plan = []
    for outname, _chain, faces, reg in TARGETS:
        # faces[0] 是这个输出的主 face；keep=True 的那种（新宋体）原样搬运，
        # 根本不换轮廓，轮不到它决定字重。
        weight = util.system_font_weight(faces[0][0], faces[0][1])
        plan.append(Row(outname, faces, "VF wght %d" % weight, None,
                        (weight,), False, reg))
    return plan


def open_source(row, vfi):
    """按施工单开出这一档的源字体。VF 那条路同一档只切一次。"""
    if row.path:
        return TTFont(row.path)
    return TTFont(vfi.instance(*row.inst)[0])


def main():
    src = util.scan_source()
    util.require_system_fonts([f[0] for t in TARGETS for f in t[2]]
                              + [METRICS_FROM[0]])
    os.makedirs(OUTDIR, exist_ok=True)

    log("源字体 : %s" % src.describe())
    log("目录   : %s" % util.SOURCE_DIR)
    log("输出到 : %s" % OUTDIR)
    log("纵向度量统一抄 %s face%d" % METRICS_FROM)
    log("")

    vfi = util.VFInstances(src.vf) if src.kind == util.VF else None
    try:
        _build(plan_vf() if vfi else plan_static(src), vfi)
    finally:
        if vfi:
            vfi.close()

    # 生成完当场自检，不通过就非零退出
    verify_fonts.report(*verify_fonts.verify_cjk(TARGETS, OUTDIR))


def _build(plan, vfi):
    # 先把每个输出用哪个源定下来，打一张表出来再动手
    log("%-32s %-14s %s" % ("输出", "源字重", "冒充"))
    for r in plan:
        who = ", ".join("%s%s" % (f[0], "" if f[1] is None else "#%d" % f[1])
                        + ("(原样)" if f[2] else "") for f in r.faces)
        log("  %-32s %-14s %-24s %s"
            % (r.outname, r.label, who, "(并档)" if r.merged else ""))
    log("")

    metrics = util.open_system_font(METRICS_FROM[0], METRICS_FROM[1], lazy=True)
    t0 = time.time()
    rows = []
    try:
        for r in plan:
            outname, faces = r.outname, r.faces
            t = time.time()
            fonts = []
            for i, (realname, idx, keep) in enumerate(faces):
                real = util.open_system_font(realname, idx)
                if keep:
                    # 真字体，原样搬进 TTC，不换轮廓也不改任何字段
                    fonts.append(real)
                    continue
                font = open_source(r, vfi)
                util.clone_identity(font, real, "WinModernSC-%s-%d"
                                    % (os.path.splitext(outname)[0], i))
                util.clone_metrics(font, metrics)
                util.check_metrics(font, outname)
                util.set_gasp(font)
                # 补上源字体缺、而被冒充的那个中文字体有的符号（← ■ ● ℃ 〇 ※
                # 之类）。中文族【不裁剪】，所以这里补的是整个字体的覆盖面。
                rep = patch_glyphs.patch(font, real, realname,
                                         real["OS/2"].usWeightClass,
                                         must=util.MUST_CJK)
                if rep.wanted:
                    log("      " + rep.line("[补字] %s face%d" % (outname, i)))
                fonts.append(font)
                real.close()

            out = os.path.join(OUTDIR, outname)
            if len(fonts) > 1:
                col = TTCollection()
                col.fonts = fonts
                col.save(out)          # shareTables=True 是默认值，同一份轮廓只存一次
            else:
                fonts[0].save(out)
            for f in fonts:
                f.close()

            names = util.family_names(out)
            rows.append((outname, util.mb(out), names))
            log("  -> %-32s %6.1f MB  (%.0fs)  %s"
                % (outname, util.mb(out), time.time() - t, "; ".join(names)))
    finally:
        metrics.close()

    log("")
    log("%-32s %7s  %s" % ("文件", "MB", "族名 (英文 / 中文)"))
    log("-" * 96)
    total = 0
    for outname, size, names in rows:
        total += size
        log("%-32s %7.1f  %s" % (outname, size, "; ".join(names)))
    log("-" * 96)
    log("%d 个文件, 合计 %.1f MB, 用时 %.0fs" % (len(rows), total, time.time() - t0))


if __name__ == "__main__":
    main()
