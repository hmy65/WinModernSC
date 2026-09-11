#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
用 source\\ 里的字体造出 Windows 认可的 "Segoe UI Variable"，
输出到 SegoeUIMod\\SegoeUI-Variable.ttf。

为什么要单独一个：Windows 11 的外壳（设置、开始菜单、通知中心，以及所有
WinUI 3 程序）用的不是 12 个静态文件那一族 "Segoe UI"，而是可变字体
"Segoe UI Variable"。它在 Fonts 键里是【另一个】注册项，指向另一个文件，
make_segoe_ui.py 那 12 个文件一个都盖不到它 —— 不做这一步，Win11 外壳那一层
文字就一直是微软原版。

DirectWrite 怎么看这个文件（老版本用 WPF 做过对照实验）：它不是靠解析
fvar 命名实例的名字，而是靠 **STAT 表** 把一个可变字体拆成若干个 WSS
(weight-stretch-style) 家族 ——
    非 WSS 轴（opsz）的 AxisValue 名字  -> 追加到排版家族名后面
                                          => Segoe UI Variable Small / Text / Display
    WSS 轴（wght）的 AxisValue 名字     -> 家族【内】的字重档
                                          => Light / Semilight / Regular / Semibold / Bold
fvar 提供可实例化的坐标，STAT 提供命名和拆分规则，两者缺一不可。删掉 STAT
只保留 fvar 实例名，实测会塌缩成一个家族、只剩 Regular 和 Bold。

这些名字、轴范围、分档区间【全部从系统里真的 SegUIVar.ttf 读出来】，一个字
都不手抄 —— 和 make_segoe_ui.py / make_cjk.py 照抄身份字段是同一个路子。

按源类型分两条路（源类型见 util.scan_source）：
    VF / BOTH   直接拿 source\\ 里的 <Family>-VF.ttf 改造，不合成
    STATIC      先从静态字重合成一个 VF，再改造

合成那条路只做真 SegUIVar.ttf 覆盖的那 2400 来个码位（拉丁 / 希腊 / 西里尔 /
标点符号，一个汉字都没有）。这正是原版的分工：真 Segoe UI Variable 本来也不带
汉字，中文由回退落到中文族 —— GDI 那边靠机制 4 的 FontLink 链，DirectWrite
那边靠它自己的回退。

源是单个 VF 时可以加 --regular-weight N（400–500），和 make_segoe_ui.py /
make_cjk.py 给同一个值：外壳要 Regular（wght 400）时拿到的是源字体 wght N 的
轮廓，其余各档不动，见 relabel_regular()。

用法:
    python src\\make_vf.py
    python src\\make_vf.py --regular-weight 450      # 仅 VF 源
"""

import copy
import os
import time

from fontTools import varLib
from fontTools.designspaceLib import (AxisDescriptor, DesignSpaceDocument,
                                      SourceDescriptor)
from fontTools.misc.fixedTools import floatToFixedToFloat
from fontTools.otlLib.builder import buildStatTable
from fontTools.ttLib import TTFont, newTable
from fontTools.ttLib.tables import otTables as ot
from fontTools.ttLib.tables._f_v_a_r import Axis, NamedInstance
from fontTools.varLib import instancer
from fontTools.varLib.models import piecewiseLinearMap

import patch_glyphs
import util
import verify_fonts
from util import log

OUTDIR = os.path.join(util.ROOT, "SegoeUIMod")
OUTNAME = util.VF_OUTNAME

# 身份、轴、命名实例、STAT 全从这个文件照抄。它是 Fonts 键里
# 'Segoe UI Variable (TrueType)' 指向的那个文件。
REAL = "SegUIVar.ttf"

# 合成 VF 的准入线，见 pick_masters()。
#
# varLib 要求各 master 的轮廓【逐点对应】：同样的轮廓数、同样的点数、同样的
# 曲线/直线标志。对不上的字形只能钉死成默认 master 的轮廓 —— 那个字就不随
# 字重变了。钉少了无所谓（都是些生僻字形），钉多了会出现「同一行里一半字母
# 加粗了、一半没有」，比整体不加粗难看得多。
#
# 实测两套常见简中字体的静态字重之间根本不能插值：
#     HarmonyOS Sans SC  (300/400/500/700)  兼容 48%
#     Sarasa Gothic SC   (300/400/600/700)  兼容 80%
# 而且不兼容的那一半里就有 B C D G M N O Q R S a b c d e f g 这些核心字母 ——
# 它们各自单独编译，本来就没打算互相插值。所以这条线卡得很紧：真正从同一个
# 可变字体切出来的静态字重过得去，各自编译的过不去，也不该过。
MAX_PIN_RATIO = 0.02
# 除了比例，核心拉丁还必须一个都不钉 —— 2% 摊到几千个字形上也够盖住半个
# 字母表，只看比例挡不住。
CORE_CHARS = "".join(chr(c) for c in range(0x20, 0x7F))


# ============================================================ 读真 SegUIVar
class RealShape(object):
    """真 SegUIVar.ttf 的轴 / 命名实例 / STAT，读成纯 Python 数据。

    读出来而不是写死：微软换版本调了分档区间、加了一档字重，我们跟着变，
    不用改代码。名字也一样 —— "Small" / "Text" / "Display" / "Semilight"
    这些串一个都不在本文件里出现。
    """

    def __init__(self, real):
        name = real["name"]

        def s(nid):
            r = name.getName(nid, *util.WIN) or name.getName(nid, *util.MAC)
            return r.toUnicode() if r else None

        fvar = real["fvar"]
        # [(tag, min, default, max, 轴名)]
        self.axes = [(a.axisTag, a.minValue, a.defaultValue, a.maxValue,
                      s(a.axisNameID)) for a in fvar.axes]
        # [(坐标, 子族名, PostScript 名)]。PostScript 名存的是【字符串】而不是
        # nameID：nameID 只在它自己那张 name 表里有意义，而我们的 name 表是
        # clone_identity 清过再重建的，256+ 那一段由 Names 从头分配。照抄一个
        # 数字过来，指到的会是我们自己刚分出去的别的串（256 = 轴名 …）。
        # 真 SegUIVar.ttf 这几条都是 0xFFFF（没有 PostScript 名），s() 返回
        # None，rebuild_instances 照样写回 0xFFFF。
        self.instances = [(dict(i.coordinates), s(i.subfamilyNameID),
                           s(i.postscriptNameID)
                           if i.postscriptNameID != 0xFFFF else None)
                          for i in fvar.instances]

        stat = real["STAT"].table
        tags = [a.AxisTag for a in stat.DesignAxisRecord.Axis]
        self.stat_axes = [(a.AxisTag, a.AxisOrdering, s(a.AxisNameID))
                          for a in stat.DesignAxisRecord.Axis]
        self.stat_values = {}       # tag -> [buildStatTable 用的 dict]
        self.dropped_formats = set()
        for v in (stat.AxisValueArray.AxisValue if stat.AxisValueArray else []):
            if v.Format == 4:
                # 多轴联合的 AxisValue。真 SegUIVar.ttf 里一条都没有；真出现了
                # 也照抄不过来（buildStatTable 走的是另一个参数），如实报告。
                self.dropped_formats.add(4)
                continue
            d = {"name": s(v.ValueNameID), "flags": v.Flags}
            if v.Format == 1:
                d["value"] = v.Value
            elif v.Format == 2:
                d["nominalValue"] = v.NominalValue
                d["rangeMinValue"] = v.RangeMinValue
                d["rangeMaxValue"] = v.RangeMaxValue
            elif v.Format == 3:
                d["value"] = v.Value
                d["linkedValue"] = v.LinkedValue
            self.stat_values.setdefault(tags[v.AxisIndex], []).append(d)
        self.elided_fallback = stat.ElidedFallbackNameID

    def axis(self, tag):
        for a in self.axes:
            if a[0] == tag:
                return a
        return None

    @property
    def wss_tag(self):
        """字重那根轴的 tag。真 SegUIVar.ttf 是 wght。"""
        return "wght"


class Names(object):
    """256 以上那一段名字的分配器：同一个字符串只占一个 nameID。

    Mac 和 Windows 两个平台都写 —— 真 SegUIVar.ttf 的每条 256+ 记录都是这两条
    （只有 en-US，没有本地化），照它的样子来。
    """

    def __init__(self, name_table, start=256):
        self.name = name_table
        self.next = start
        self.byname = {}

    def id_for(self, s):
        if s in self.byname:
            return self.byname[s]
        nid = self.next
        self.next += 1
        self.name.setName(s, nid, *util.MAC)
        self.name.setName(s, nid, *util.WIN)
        self.byname[s] = nid
        return nid


# ============================================================ 合成（STATIC）
def glyph_sig(glyf, gname):
    """一个字形的「插值签名」。两个 master 的签名相同 = 这个字形能插值。

    简单字形看轮廓断点和曲线/直线标志（点数一样但曲线点排布不同照样不能插）；
    复合字形看引用了谁、怎么定位。
    """
    g = glyf[gname]
    if g.isComposite():
        return ("c", tuple((c.glyphName, hasattr(c, "firstPt"))
                           for c in g.components))
    if g.numberOfContours <= 0:
        return ("e",)
    return ("s", tuple(g.endPtsOfContours), tuple(b & 1 for b in g.flags))


def pick_masters(src, lo, hi):
    """挑出参与合成的静态 master，返回 {字重: (样式名, 路径)}。

    只要正体 —— 斜体不参与，Segoe UI Variable 本来就没有斜体轴（真
    SegUIVar.ttf 的 fvar 只有 wght 和 opsz）。
    字重取各文件自己的 usWeightClass，不看文件名里的样式词：样式词是
    人写的，usWeightClass 是系统实际拿来匹配的那个数。
    """
    cand = {}
    for _norm, (style, path) in sorted(src.styles.items()):
        if util.is_italic(style):
            continue
        with TTFont(path, lazy=True) as f:
            w = f["OS/2"].usWeightClass
        if not lo <= w <= hi:
            continue
        if w in cand:
            # 两个文件报同一个 usWeightClass（比如 Thin 和 ExtraLight 都写 250）。
            # 留先来的那个，把这件事说出来 —— 否则「某一档没被用上」很难看出来。
            log("      note: %s 和 %s 的 usWeightClass 都是 %d，只用前者"
                % (cand[w][0], style, w))
            continue
        cand[w] = (style, path)
    return cand


def load_master(path, unicodes):
    """开一个 master 并裁到目标覆盖。

    先裁后合成，不是先合成后裁：真 SegUIVar.ttf 只有 2400 来个码位，而源字体
    动辄四五万个字形，裁完再逐字形比对/插值便宜两个数量级。
    """
    font = TTFont(path)
    util.subset_to_coverage(font, unicodes & set(font.getBestCmap().keys()))
    return font


def compat_report(fonts, dflt):
    """逐字形比对各 master，返回 (共有字形, 要钉死的字形集合)。

    字形集合本身对不上就直接返回 None —— varLib 是按【默认 master 的字形
    表】逐个去别的 master 里取的，取不到就崩。真会走到多 master 那条路的源
    （同一个可变字体切出来的静态实例）字形集合必然一致，所以这里不去费劲
    对齐，报出来退回单 master 就好。
    """
    sets = {w: frozenset(f.getGlyphOrder()) for w, f in fonts.items()}
    if len(set(sets.values())) > 1:
        return None, None
    common = set(sets[dflt])
    base = fonts[dflt]["glyf"]
    pinned = set()
    for gname in common:
        s0 = glyph_sig(base, gname)
        for w, f in fonts.items():
            if w != dflt and glyph_sig(f["glyf"], gname) != s0:
                pinned.add(gname)
                break
    return common, pinned


def core_glyphs(font):
    """CORE_CHARS 在这个字体里对应的字形名。"""
    cm = font.getBestCmap()
    return {cm[ord(c)] for c in CORE_CHARS if ord(c) in cm}


def pin_glyphs(fonts, dflt, pinned):
    """把钉死的字形换成默认 master 的那一份。

    钉死之后所有 master 在这个字形上逐字节相同 -> varLib 算出来的 delta 全是
    0 -> 这个字形不随字重变。这是「能合成」和「合不成」之间唯一的中间地带。

    用 deepcopy 而不是直接引用同一个 Glyph 对象：几个 master 共用一份可变对象，
    哪一步顺手改了坐标（重算包围盒之类）就会串到别的 master 上。钉死的本来就
    不到 2%，复制这点开销可以忽略。
    """
    base = fonts[dflt]
    for w, f in fonts.items():
        if w == dflt:
            continue
        for gname in pinned:
            f["glyf"][gname] = copy.deepcopy(base["glyf"][gname])
            f["hmtx"][gname] = base["hmtx"][gname]


def build_vf(fonts, dflt, lo, hi, axis_name):
    """varLib 合成。返回 (font, 失败原因)，失败时 font 是 None。

    【不重试】。varLib 是把别的 master 合并【进默认 master】的，中途抛异常时
    默认 master 已经是半合并状态 —— 换个参数再跑一遍，喂进去的就是被搅过的
    字体，产物看着能存、其实是坏的。上面那道逐字形兼容性检查已经把真正常见
    的失败挡在外面了（能过那道线的 master 本来就是同一个可变字体切出来的，
    GSUB/GPOS 也必然一致），所以这里剩下的异常一律当成「这套源合不了」，
    退回单 master 那条路。
    """
    ds = DesignSpaceDocument()
    ax = AxisDescriptor()
    ax.name, ax.tag = axis_name, "wght"
    ax.minimum, ax.default, ax.maximum = lo, dflt, hi
    ds.addAxis(ax)
    for w in sorted(fonts):
        s = SourceDescriptor()
        s.font = fonts[w]
        s.name = "wght-%d" % w
        s.location = {axis_name: float(w)}
        ds.addSource(s)
    try:
        return varLib.build(ds, optimize=False)[0], ""
    except Exception as e:
        return None, "%s: %s" % (type(e).__name__, e)


def synthesize(src, real, shape):
    """STATIC 源：从静态字重合成一个可变字体。返回 (font, 说明)。

    合不成就退回单 master —— 见 MAX_PIN_RATIO 那一段。退回不是失败：产物照样
    是个带 fvar/STAT 的可变字体，照样拆成 Small / Text / Display 三个家族，
    只是没有 wght 轴，字重档交给 Windows 自己合成加粗。
    """
    wax = shape.axis(shape.wss_tag)
    lo, dflt, hi = wax[1], wax[2], wax[3]
    unicodes = set(real.getBestCmap().keys())
    log("[合成] 目标覆盖 %d 个码位（真 %s 的覆盖面，一个汉字都没有）"
        % (len(unicodes), REAL))

    cand = pick_masters(src, lo, hi)
    log("[合成] %s 轴 %g..%g（默认 %g），候选 master: %s"
        % (shape.wss_tag, lo, hi, dflt,
           "、".join("%d %s" % (w, cand[w][0]) for w in sorted(cand)) or "（无）"))

    # 默认 master 必须【正好】落在轴的默认值上，varLib 的要求。
    if dflt not in cand:
        raise SystemExit(
            "source\\ 里没有 usWeightClass 正好是 %g 的正体静态字重，合成不了 "
            "%s。\n候选: %s\n"
            "补一个 %g 档的正体，或者直接放一个 <Family>-%s.ttf 进来。"
            % (dflt, OUTNAME,
               "、".join("%d %s" % (w, cand[w][0]) for w in sorted(cand)) or "（无）",
               dflt, util.VF_STYLE))

    t = time.time()
    fonts = {w: load_master(p, unicodes) for w, (s, p) in sorted(cand.items())}
    log("[合成] 裁剪完成 (%.0fs)，各 master 字形数 %s"
        % (time.time() - t, {w: len(f.getGlyphOrder()) for w, f in sorted(fonts.items())}))

    upems = {f["head"].unitsPerEm for f in fonts.values()}
    if len(upems) > 1:
        raise SystemExit("各静态字重的 unitsPerEm 不一致 %s，没法插值。" % sorted(upems))

    if len(fonts) > 1:
        common, pinned = compat_report(fonts, dflt)
        if common is None:
            log("[合成] 各 master 的字形集合对不上，没法插值。")
            ok = False
        else:
            core_pinned = sorted(core_glyphs(fonts[dflt]) & common & pinned)
            ratio = len(pinned) / float(len(common) or 1)
            log("[合成] 插值兼容性：%d 个共有字形里 %d 个对不上（%.1f%%），"
                "其中核心拉丁 %d 个%s"
                % (len(common), len(pinned), 100.0 * ratio, len(core_pinned),
                   "：" + " ".join(core_pinned[:16]) + ("…" if len(core_pinned) > 16 else "")
                   if core_pinned else ""))
            ok = ratio <= MAX_PIN_RATIO and not core_pinned
        if ok:
            pin_glyphs(fonts, dflt, pinned)
            span = (min(fonts), max(fonts))
            t = time.time()
            font, why = build_vf(fonts, dflt, span[0], span[1], wax[4])
            if font is not None:
                log("[合成] varLib 合成完成 (%.0fs)，%s 轴 %g..%g"
                    % (time.time() - t, shape.wss_tag, span[0], span[1]))
                if span != (lo, hi):
                    # master 盖不住真 SegUIVar 的整个范围，轴就只能停在 span 上：
                    # instancer 只会收窄轴、不会拓宽，范围外的限值会被它悄悄夹回
                    # fvar 原来的范围。轴外那几档的命名实例和 STAT 值由
                    # rebuild_instances / rebuild_stat 丢掉。
                    log("[合成] master 只覆盖 %s %g..%g（真 %s 是 %g..%g），"
                        "轴外的那几档不建"
                        % (shape.wss_tag, span[0], span[1], REAL, lo, hi))
                for f in fonts.values():
                    if f is not font:
                        f.close()
                return font, ("合成自 %d 档静态字重，钉死 %d 个字形"
                              % (len(cand), len(pinned)))
            # 合并失败。半合并的 master 一个都不能再用，重新裁一份干净的。
            log("")
            log("!! varLib 合成失败：%s" % why)
            log("!! 逐字形兼容性是过了的，说明卡在别的地方（多半是 GSUB/GPOS）。"
                "退回单 master。")
            log("")
            for f in fonts.values():
                f.close()
            fonts = {dflt: load_master(cand[dflt][1], unicodes)}
        else:
            log("")
            log("!! 这套源字体的静态字重之间【不能插值】—— 各档是分别编译的，")
            log("!! 轮廓的点数和排布对不上。硬合成会出现「同一行里一半字母加粗了、")
            log("!! 一半没有」，比整体不加粗难看得多。退回单 master。")
            log("")

    # --- 退回单 master
    base = fonts[dflt]
    for w, f in fonts.items():
        if w != dflt:
            f.close()
    log("[合成] 退回单 master：只用 %d %s，不建 %s 轴。"
        % (dflt, cand[dflt][0], shape.wss_tag))
    log("       产物仍然是可变字体（opsz 轴 + STAT），仍然拆成 3 个家族；")
    log("       字重那一维交给 Windows 合成加粗。真正的多字重在机制 1 装的")
    log("       12 个静态 Segoe UI 文件里，那一族不受影响。")
    return base, "单 master（源字重之间不能插值）"


# ============================================================ 改造
def limit_source_vf(font, shape, regular_weight=None):
    """VF / BOTH 源：把源可变字体的轴收成真 SegUIVar 的那一套。

    真 SegUIVar 也有的轴（wght，理论上还有 opsz）按它的范围收；它没有的轴
    （苹方的 wdth 就是一个）一律钉在源字体自己的默认值上 —— 宽度这种我们没有
    立场替源字体选，而且多留一根轴就多一套 DirectWrite 要拆的家族。

    给了 regular_weight（--regular-weight）时，wght 的默认实例切在它上面，
    标签由 relabel_regular() 再改回 400。
    """
    real_tags = {a[0]: a for a in shape.axes}
    if util.fvar_axis(font, shape.wss_tag) is None:
        raise SystemExit(
            "源可变字体没有 %s 轴（只有 %s），造不出 Segoe UI Variable 的字重档。\n"
            "换一个带字重轴的可变字体，或者改放静态字重。"
            % (shape.wss_tag,
               "、".join(a.axisTag for a in font["fvar"].axes)))

    limits = {}
    shown = []
    for a in font["fvar"].axes:
        ra = real_tags.get(a.axisTag)
        if ra is None:
            limits[a.axisTag] = a.defaultValue
            shown.append("%s=%g（钉死）" % (a.axisTag, a.defaultValue))
            continue
        lo = max(ra[1], a.minValue)
        hi = min(ra[3], a.maxValue)
        if lo > hi:
            # 两边的范围完全不重叠（源只有 800..900 之类）。给不出这根轴，
            # 钉在源字体离真 SegUIVar 默认值最近的那一端上。
            v = min(max(ra[2], a.minValue), a.maxValue)
            limits[a.axisTag] = v
            shown.append("%s=%g（钉死）" % (a.axisTag, v))
            log("      note: 源字体的 %s 是 %g..%g，和真 %s 的 %g..%g 完全不重叠，"
                "这根轴给不出来，钉在 %g"
                % (a.axisTag, a.minValue, a.maxValue, REAL, ra[1], ra[3], v))
            continue
        dflt = min(max(ra[2], lo), hi)
        if (lo, dflt, hi) != (ra[1], ra[2], ra[3]):
            log("      note: 源字体的 %s 只有 %g..%g，轴收成 %g/%g/%g —— "
                "真 %s 是 %g/%g/%g"
                % (a.axisTag, a.minValue, a.maxValue, lo, dflt, hi,
                   REAL, ra[1], ra[2], ra[3]))
        if a.axisTag == shape.wss_tag and regular_weight:
            # 两端都得留出空间：N 顶到上端，Semibold / Bold 就没有更粗的可给了。
            # 下端还得盖住真 SegUIVar 的默认值（400）：relabel_regular() 要把
            # 默认值改回它，下端高过它就成了「默认值在轴外」的坏 fvar，而
            # verify_vf 只比默认值和 usWeightClass，拦不住
            if not lo <= ra[2] < regular_weight < hi:
                raise SystemExit(
                    "源字体的 %s 收到真 %s 的范围之后是 %g..%g，"
                    "--regular-weight %d 得落在两端之间，下端还不能高过 %g。"
                    % (a.axisTag, REAL, lo, hi, regular_weight, ra[2]))
            dflt = regular_weight
        limits[a.axisTag] = (lo, dflt, hi)
        shown.append("%s %g/%g/%g" % (a.axisTag, lo, dflt, hi))

    log("[改造] instancer %s ..." % "，".join(shown))
    t = time.time()
    font = instancer.instantiateVariableFont(
        font, limits, inplace=True, optimize=False, updateFontNames=False)
    log("      %.0fs" % (time.time() - t))
    return font


def relabel_regular(font, shape, regular_weight):
    """--regular-weight：外壳要 wght 400 时给它源字体 wght N 的轮廓，其余各档不动。

    Win11 外壳要 Regular 时给的就是 wght 400，也就是【默认实例】。而 avar 规定
    默认点只能映射到默认点（每条映射都必须带 0→0），光靠 avar 把 400 挪到 N
    是做不到的。所以分两步：
      1  limit_source_vf() 已经把默认实例切在 N 上，这时轴是 lo/N/hi
      2  这里把 fvar 的默认值改回真 SegUIVar 的 400，再写一条 avar：用户空间的
         400 -> N，真 SegUIVar 其余命名实例的字重（300 / 350 / 600 / 700）原地
         不动，中间按折线插
    默认值不能停在 N：OS/2.usWeightClass 照抄的是 400，verify_vf 那条「默认值
    == usWeightClass」会拦下来 —— 那条检查说的正是系统眼里的 Regular 和默认实例
    得是同一档。

    源字体自己带 avar 的（苹方就有），新映射叠在它上面，不能覆盖：它描述的是源
    字体自己的设计空间，覆盖掉等于把各档的轮廓全换了。
    """
    tag = shape.wss_tag
    axis = util.fvar_axis(font, tag)
    lo, hi = axis.minValue, axis.maxValue
    rw = regular_weight
    label = shape.axis(tag)[2]              # 真 SegUIVar 的默认值，400

    # 新标签 -> 源字体的 wght，两边都是用户空间。钉在真 SegUIVar 命名实例的
    # 各档和轴的两端上；夹在 400 和 N 之间的档（现在的 SegUIVar 没有）钉不住，
    # 让它跟着插值。
    anchors = {c[tag] for c, _sub, _ps in shape.instances if tag in c} | {lo, hi}
    fwd = {v: v for v in anchors if lo <= v <= hi and not label <= v <= rw}
    fwd[label] = rw
    back = {b: a for a, b in fwd.items()}

    def norm(v, dflt):
        """用户值 -> 归一化坐标：默认点是 0，两侧各自线性。"""
        if v < dflt:
            return (v - dflt) / float(dflt - lo)
        if v > dflt:
            return (v - dflt) / float(hi - dflt)
        return 0.0

    def denorm(n, dflt):
        return dflt + n * ((dflt - lo) if n < 0 else (hi - dflt))

    old = {}
    if "avar" in font:
        old = dict(font["avar"].segments.get(tag) or {})

    # 两条折线叠起来，拐点是两边的并集：fwd 的各个锚点，加上源字体 avar 的
    # 各个拐点换到新标签下的位置。少一个就不是原样叠加了。
    users = set(fwd)
    for k in old:
        u = piecewiseLinearMap(denorm(k, rw), back)
        # 离已有拐点不到半个字重单位的是同一个点：源 avar 在 instancer 那一步
        # 已经按 F2Dot14 取过整，反推回来会差零点几（苹方 600 那个拐点实测
        # 差 0.03），照收就多出一段零长度的折线
        if lo <= u <= hi and all(abs(u - x) >= 0.5 for x in users):
            users.add(u)
    seg = {}
    for u in sorted(users):
        n = floatToFixedToFloat(norm(u, label), 14)
        v = piecewiseLinearMap(norm(piecewiseLinearMap(u, fwd), rw), old)
        seg.setdefault(n, floatToFixedToFloat(v, 14))
    seg.update({-1.0: -1.0, 0.0: 0.0, 1.0: 1.0})
    # 两条单调的折线叠出来必然单调；不单调就是上面哪一步算错了，存下去就是
    # 一个字重越要越细的字体，宁可停在这里
    vals = [seg[k] for k in sorted(seg)]
    if any(b < a for a, b in zip(vals, vals[1:])):
        raise SystemExit("算出来的 avar 不单调，不能写: %r" % sorted(seg.items()))

    if "avar" not in font:
        font["avar"] = newTable("avar")
    segments = font["avar"].segments
    # avar 的映射条数必须和 fvar 的轴数一样，别的轴补恒等映射
    for a in font["fvar"].axes:
        segments.setdefault(a.axisTag, {-1.0: -1.0, 0.0: 0.0, 1.0: 1.0})
    segments[tag] = dict(sorted(seg.items()))
    axis.defaultValue = label
    log("[改造] --regular-weight：默认实例切在 %s %g，轴标签改回 %g；各档 %s"
        % (tag, rw, label,
           "、".join("%g→%g" % kv for kv in sorted(fwd.items()))))


def varstores(font):
    """字体里所有的 ItemVariationStore。加轴时每一条 region 都要跟着补一维。"""
    out = []
    for tag in ("HVAR", "VVAR", "MVAR", "GDEF"):
        if tag not in font:
            continue
        t = getattr(font[tag], "table", None)
        vs = getattr(t, "VarStore", None)
        if vs is not None:
            out.append(vs)
    return out


def add_dummy_axis(font, tag, lo, dflt, hi, name_id):
    """加一根没有任何增量的轴。字形一个点都不动，纯粹是给 STAT 用的坐标系。

    opsz 就是这么来的：源字体没有光学尺寸设计，但 Segoe UI Variable 的
    Small / Text / Display 三个家族是 DirectWrite 按 opsz 的 STAT 分档拆出来
    的 —— 没有这根轴就没有那三个家族。
    """
    fvar = font["fvar"]
    axis = Axis()
    axis.axisTag = tag
    axis.minValue, axis.defaultValue, axis.maxValue = lo, dflt, hi
    axis.axisNameID = name_id
    axis.flags = 0
    fvar.axes.append(axis)
    n = len(fvar.axes)

    # avar 必须给新轴补一条恒等映射。不是可选的：avar 的 axisSegmentMaps 条数
    # 必须和 fvar 的轴数一样，fontTools 编译时按 fvar 的轴 tag 逐个去 segments
    # 里取，少一条直接 KeyError。
    if "avar" in font:
        font["avar"].segments.setdefault(tag, {-1.0: -1.0, 0.0: 0.0, 1.0: 1.0})
    # 各 VarStore 的 region 补一维中性记录 (0,0,0)
    for vs in varstores(font):
        rl = vs.VarRegionList
        for region in rl.Region:
            while len(region.VarRegionAxis) < n:
                a = ot.VarRegionAxis()
                a.StartCoord = a.PeakCoord = a.EndCoord = 0.0
                region.VarRegionAxis.append(a)
        rl.RegionAxisCount = n
    # gvar / cvar 的 TupleVariation 不含这个 tag，fontTools 编译时按 (0,0,0)
    # 写入，不用管。


def rebuild_axes(font, shape, names):
    """把 fvar 补齐成真 SegUIVar 的轴集合。返回实际有的轴 tag 集合。"""
    have = {a.axisTag for a in font["fvar"].axes} if "fvar" in font else set()
    if "fvar" not in font:
        # 单 master 那条路：整张 fvar 都得现建
        font["fvar"] = newTable("fvar")
        font["fvar"].axes = []
        font["fvar"].instances = []
    fvar = font["fvar"]

    # 已有的轴（wght）：名字换成真 SegUIVar 的轴名
    for a in fvar.axes:
        real_axis = shape.axis(a.axisTag)
        if real_axis:
            a.axisNameID = names.id_for(real_axis[4])
    # 缺的轴（opsz，可能还有 wght 没有的情况）补成哑轴
    for tag, lo, dflt, hi, axis_name in shape.axes:
        if tag in have:
            continue
        if tag == shape.wss_tag:
            continue        # 没有字重轴就是没有，不假装有
        add_dummy_axis(font, tag, lo, dflt, hi, names.id_for(axis_name))
    return {a.axisTag for a in fvar.axes}


def rebuild_instances(font, shape, names, tags):
    """照真 SegUIVar 的命名实例重建，落在我们没有的轴上、或者轴外的那些丢掉。

    没有 wght 轴时 15 个实例只剩 3 个（Regular Small / Regular / Regular
    Display）—— 那才是实情：这个文件只有一档字重。多报几档出来，
    DirectWrite 会以为 Semibold 有实体文件，于是【不】合成加粗，
    结果是所有字重长得一模一样。
    """
    fvar = font["fvar"]
    fvar.instances = []
    kept = []
    defaults = {a[0]: a[2] for a in shape.axes}
    ranges = {a.axisTag: (a.minValue, a.maxValue) for a in fvar.axes}
    for coords, subfamily, ps_name in shape.instances:
        # 落在我们没有的那根轴上、坐标又不是它默认值的实例，给不出这一档
        if any(t not in tags and v != defaults[t] for t, v in coords.items()):
            continue
        # 落在轴外的同样给不出（合成时 master 盖不住真 SegUIVar 的范围，或者
        # 源 VF 的轴本来就窄）。报出来会被夹到轴端点去画，理由同上。
        if any(t in ranges and not ranges[t][0] <= v <= ranges[t][1]
               for t, v in coords.items()):
            continue
        inst = NamedInstance()
        inst.subfamilyNameID = names.id_for(subfamily)
        # 0xFFFF = 这一档没有 PostScript 名，fvar 编译时整个字段都不写
        inst.postscriptNameID = (names.id_for(ps_name) if ps_name else 0xFFFF)
        # 每根轴都得有坐标：fontTools 编译命名实例时是按 fvar 的轴逐个取的，
        # 少一根直接 KeyError。先按各轴默认值铺满，再盖上真 SegUIVar 那一档。
        inst.coordinates = {a.axisTag: a.defaultValue for a in fvar.axes}
        inst.coordinates.update((t, v) for t, v in coords.items() if t in tags)
        fvar.instances.append(inst)
        kept.append(subfamily)
    return kept


def rebuild_stat(font, shape, names, tags):
    """重建 STAT —— 家族怎么拆全靠它。"""
    if "STAT" in font:
        del font["STAT"]
    ranges = {a.axisTag: (a.minValue, a.maxValue) for a in font["fvar"].axes}
    axes = []
    for tag, ordering, axis_name in shape.stat_axes:
        if tag not in tags:
            # 这根轴我们没有。整条轴连同它的档一起丢掉 —— 留着的话
            # DirectWrite 会照它报出并不存在的字重档。
            continue
        # 轴外的档同理，和 rebuild_instances 一个口径
        lo, hi = ranges[tag]
        vals = [v for v in shape.stat_values.get(tag, [])
                if lo <= v.get("value", v.get("nominalValue")) <= hi]
        axes.append(dict(tag=tag, name=names.id_for(axis_name),
                         ordering=ordering,
                         values=[dict(v, name=names.id_for(v["name"]))
                                 for v in vals]))
    buildStatTable(font, axes=axes, elidedFallbackName=shape.elided_fallback)
    return axes


def set_language_meta(font):
    """meta 里的语言覆盖如实反映内容 —— 有汉字就写上，没有就不写。"""
    if "meta" not in font:
        return None
    langs = "Latn, Grek, Cyrl"
    cm = font.getBestCmap()
    if any(0x4E00 <= c <= 0x9FFF for c in cm):
        langs += ", Hans"
    for k in ("dlng", "slng"):
        font["meta"].data[k] = langs
    return langs


def convert(font, real, shape, regular_weight=None):
    """把一个可变字体改造成 Windows 认可的 "Segoe UI Variable"。"""
    # 补字排在最前面：后面 set_language_meta() 要按【补完之后】的覆盖面写
    # dlng/slng，rebuild_axes() 也要在字形表定型之后才动 fvar。
    # 拼出来的复合字形引用源字体自己的字母，那个字母有 gvar 增量 —— 所以重音
    # 字母会跟着 wght 轴一起变粗，只有重音符号本身是固定的。搬进来的符号没有
    # 增量，不随字重变，符号对字重本来就不敏感。
    # 后备捐赠源按默认实例的轮廓字重排（--regular-weight 调粗过就是 N）。
    rep = patch_glyphs.patch(font, real, REAL,
                             util.outline_weight(real["OS/2"].usWeightClass,
                                                 regular_weight),
                             must=util.MUST_LATIN)
    if rep.wanted:
        log(rep.line("[补字]"))
    log("[改造] 身份照抄 %s（name 1/2/4/6/16/17/18 + OS/2 + PANOSE）" % REAL)
    util.clone_identity(font, real, "WinModernSC-%s"
                        % os.path.splitext(OUTNAME)[0],
                        regular_weight=regular_weight)
    # MVAR 会让 OS/2 / hhea 的度量随轴漂移，而我们刚把它们钉成真 SegUIVar 的
    # 值 —— 留着等于白钉。真 SegUIVar 自己有 MVAR，但那是给它自己的设计空间
    # 用的，抄不过来。
    if "MVAR" in font:
        del font["MVAR"]
        log("      note: 丢掉源字体的 MVAR，纵向度量固定按真 %s 那一套" % REAL)
    util.clone_metrics(font, real, caret=True)
    util.set_gasp(font)

    names = Names(font["name"])
    tags = rebuild_axes(font, shape, names)
    kept = rebuild_instances(font, shape, names, tags)
    axes = rebuild_stat(font, shape, names, tags)
    langs = set_language_meta(font)

    fvar = font["fvar"]
    log("[改造] fvar %d 轴 (%s) / %d 个命名实例"
        % (len(fvar.axes),
           "、".join("%s %g..%g" % (a.axisTag, a.minValue, a.maxValue)
                     for a in fvar.axes),
           len(fvar.instances)))
    log("       实例: %s" % "、".join(kept))
    log("[改造] STAT %d 轴 (%s)"
        % (len(axes), "、".join("%s×%d" % (a["tag"], len(a["values"]))
                                for a in axes)))
    if shape.dropped_formats:
        log("       note: 真 %s 里有 Format %s 的 AxisValue，照抄不过来，已跳过"
            % (REAL, "/".join(str(f) for f in sorted(shape.dropped_formats))))
    if langs:
        log("[改造] meta dlng/slng = %s" % langs)
    return font


# ============================================================ 主流程
def main():
    args = util.parse_args("用 source\\ 里的字体造出 Segoe UI Variable，"
                           "输出到 SegoeUIMod\\%s。" % OUTNAME)
    src = util.scan_source()
    rw = util.resolve_regular_weight(src, args.regular_weight)
    util.require_system_fonts([REAL])
    os.makedirs(OUTDIR, exist_ok=True)
    out = os.path.join(OUTDIR, OUTNAME)

    log("源字体 : %s" % src.describe())
    log("目录   : %s" % util.SOURCE_DIR)
    log("输出到 : %s" % out)
    if rw:
        log("Regular: 默认实例切在 wght %d（身份仍是 %d）" % (rw, util.REGULAR))
    log("")

    t0 = time.time()
    real = util.open_system_font(REAL)
    try:
        shape = RealShape(real)
        log("真 %s : 轴 %s；命名实例 %d 个；STAT %d 轴"
            % (REAL, "、".join("%s %g..%g（默认 %g）" % (a[0], a[1], a[3], a[2])
                               for a in shape.axes),
               len(shape.instances), len(shape.stat_axes)))
        log("")

        if src.kind == util.STATIC:
            font, how = synthesize(src, real, shape)
        else:
            log("[跳过合成] 源类型 %s，直接用 %s"
                % (src.kind, os.path.basename(src.vf)))
            font = TTFont(src.vf)
            font = limit_source_vf(font, shape, rw)
            if rw:
                relabel_regular(font, shape, rw)
            how = "源自带的可变字体" + ("，Regular 切在 wght %d" % rw if rw else "")
        log("")
        convert(font, real, shape, rw)
    finally:
        real.close()

    log("")
    log("保存 %s ..." % OUTNAME)
    font.save(out)
    font.close()
    # 必须放在 save 之后：head 的包围盒是编译时重算的，存之前读到的还是旧值。
    with TTFont(out, lazy=True) as f:
        util.check_metrics(f, OUTNAME)
    log("  -> %-28s %6.2f MB  (%.0fs)  %s  [%s]"
        % (OUTNAME, util.mb(out), time.time() - t0,
           "; ".join(util.family_names(out)), how))

    # 生成完当场自检，不通过就非零退出
    verify_fonts.report_after_build(*verify_fonts.verify_vf(out))


if __name__ == "__main__":
    main()
