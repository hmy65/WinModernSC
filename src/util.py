#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""make_cjk.py 和 make_segoe_ui.py 的公共部分。"""

import math
import os
import re

from fontTools.misc.roundTools import otRound
from fontTools.ttLib import TTFont, TTCollection, newTable

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SOURCE_DIR = os.path.join(ROOT, "source")
WINFONTS = os.path.join(os.environ.get("WINDIR", r"C:\Windows"), "Fonts")

WIN = (3, 1, 0x409)
MAC = (1, 0, 0)

# 家族名和样式名：照抄被顶替的那个系统字体。GDI 和 DirectWrite 都是从字体
# 文件的 name 表读族名的，所以这几项决定了系统把产物认成谁。
IDENTITY_NAME_IDS = (1, 2, 4, 6, 16, 17, 18, 21, 22)
# 版本、版权、许可、厂商：保留源字体自己的，不动。
SOURCE_NAME_IDS = (0, 5, 7, 8, 9, 11, 13, 14)

LOCAL_NOTE = ("Repackaged locally by WinModernSC for system font substitution. "
              "Outlines, copyright and license belong to the source font. "
              "Not affiliated with Microsoft; product names are trademarks of "
              "their respective owners.")

# gasp 的四个标志位。全尺寸都用 15（四位全开）= 灰度 + 网格对齐 +
# 对称网格对齐 + 对称平滑。
GASP_ALL = 15

# 算法伪斜体的倾斜角度。真 Segoe UI Italic 就是 12°（post.italicAngle = -12，
# hhea 的 caretSlopeRise/Run = 2048/435 也正好是 12），跟着它走，文本光标的
# 斜度才和字形的斜度对得上 —— 那个 caret 是 clone_metrics(caret=True) 从真
# 文件照抄的，这边随便定一个角度两者就歪开了。
ITALIC_ANGLE = 12.0


def log(m):
    print(m, flush=True)


# ------------------------------------------------------------------ source\
# 至少要有这几个样式，缺一个都不做。只要正体 —— 斜体缺了不算错，会退到对应
# 正体源、由 oblique() 剪切出伪斜体（见那个函数的说明和 README 里的代价）。
# 简中字体带真斜体的本来就不多，按成对要求等于把大半可用的源字体挡在门外。
REQUIRED_ALWAYS = ("Regular", "Light")
# 这两个满足其中一个即可（粗体档可以是 Bold 也可以是 Black）。
REQUIRED_EITHER = (("Bold",), ("Black",))


def norm_style(style):
    """样式名比对用的规范形式：只留字母数字，全小写。"""
    return re.sub(r"[^a-z0-9]", "", style.lower())


def is_italic(style):
    """样式名（或输出文件名）是不是斜体的那一档。"""
    return "italic" in norm_style(style)


def upright_chain(chain):
    """把一条斜体并档链换成对应的正体链，给伪斜体找源文件用。

    ("SemiBoldItalic", "BoldItalic", "BlackItalic") -> ("SemiBold", "Bold", "Black")
    单独一个 "Italic" 去掉之后是空串 —— 那一档的正体就叫 Regular。

    不另写一张正体对照表是为了免得两张表各改各的：并档链本来就只有这一处
    定义（STYLES / TARGETS 的那一列），换算规则放在这里，加字重时不用改两遍。
    """
    out = []
    for want in chain:
        s = re.sub("(?i)italic", "", want).strip() or "Regular"
        if s not in out:
            out.append(s)
    return tuple(out)


def scan_source(srcdir=None):
    """扫描 source\\，返回 (族名, {规范样式名: (样式名, 路径)})。

    命名必须是 <Family>-<Style>.ttf，同一目录里 <Family> 必须完全一致。
    """
    if srcdir is None:
        srcdir = SOURCE_DIR
    if not os.path.isdir(srcdir):
        raise SystemExit("找不到源字体目录: %s" % srcdir)

    families = {}
    styles = {}
    bad = []
    for fn in sorted(os.listdir(srcdir)):
        stem, ext = os.path.splitext(fn)
        if ext.lower() != ".ttf":
            continue
        if "-" not in stem:
            bad.append(fn)
            continue
        family, style = stem.rsplit("-", 1)
        if not family or not style:
            bad.append(fn)
            continue
        families.setdefault(family, []).append(fn)
        styles[norm_style(style)] = (style, os.path.join(srcdir, fn))

    if bad:
        raise SystemExit("这些文件名不符合 <Family>-<Style>.ttf: %s"
                         % ", ".join(bad))
    if not styles:
        raise SystemExit("%s 里一个 <Family>-<Style>.ttf 都没有。" % srcdir)
    if len(families) > 1:
        detail = "; ".join("%s: %s" % (f, ", ".join(v))
                           for f, v in sorted(families.items()))
        raise SystemExit("source\\ 里混了多个族名，只能放一套字体。%s" % detail)

    family = list(families)[0]
    check_required(styles, srcdir, family)
    return family, styles


def check_required(styles, srcdir, family):
    """必需样式缺了就报错退出，并明确列出缺哪些。"""
    missing = [s for s in REQUIRED_ALWAYS if norm_style(s) not in styles]

    ok_pairs = [p for p in REQUIRED_EITHER
                if all(norm_style(s) in styles for s in p)]
    if not ok_pairs:
        # 两组都不全：把缺得少的那组报出来，缺得一样多就报第一组
        gaps = [[s for s in p if norm_style(s) not in styles]
                for p in REQUIRED_EITHER]
        missing += min(gaps, key=len)

    if missing:
        want = " / ".join("%s-%s.ttf" % (family, s) for s in missing)
        raise SystemExit(
            "source\\ 缺少必需字重，共 %d 个: %s\n目录: %s\n"
            "必需的是 Regular / Light，外加 Bold 或 Black。\n"
            "斜体不是必需的：缺了会拿对应的正体剪切出伪斜体。"
            % (len(missing), want, srcdir))


def pick_source(styles, chain, what, required=True):
    """按 chain 的顺序找第一个存在的样式，返回 (样式名, 路径, 是否并档)。

    chain[0] 是同名样式，后面几个是退而求其次的最近字重。
    required=False 时整条链落空返回 None 而不是退出，留给调用方兜底 ——
    斜体链落空是常事，那条路要接到 upright_chain() + oblique() 上去。
    """
    for i, want in enumerate(chain):
        hit = styles.get(norm_style(want))
        if hit:
            return hit[0], hit[1], (i > 0)
    if not required:
        return None
    raise SystemExit("%s 找不到可用的源字重，试过: %s" % (what, " -> ".join(chain)))


# ------------------------------------------------------------- 系统字体
def open_system_font(name, index=None, lazy=False):
    """打开 C:\\Windows\\Fonts 里的一个字体，ttc 按索引取 face。"""
    path = os.path.join(WINFONTS, name)
    if path.lower().endswith(".ttc"):
        return TTCollection(path, lazy=lazy).fonts[index or 0]
    return TTFont(path, lazy=lazy)


def require_system_fonts(names):
    """系统里缺了要照抄身份的字体就报错退出。"""
    missing = sorted({n for n in names
                      if not os.path.exists(os.path.join(WINFONTS, n))})
    if missing:
        raise SystemExit("系统里找不到这些字体，无法照抄身份: %s\n目录: %s"
                         % (", ".join(missing), WINFONTS))


# --------------------------------------------------------------- 改造
def clone_identity(font, real, unique_id):
    """把 real 的身份字段照抄到 font 上，源字体的版权许可原样留着。

    含本地化族名（nameID 1 的中文那一条）—— 网页里 font-family: 微软雅黑
    匹配的正是它，只写英文名等于只做了一半。
    """
    name = font["name"]
    name.names = [r for r in name.names if r.nameID in SOURCE_NAME_IDS]
    for r in real["name"].names:
        if r.nameID not in IDENTITY_NAME_IDS:
            continue
        try:
            s = r.toUnicode()
        except Exception:
            continue
        name.setName(s, r.nameID, r.platformID, r.platEncID, r.langID)
    for nid, s in ((3, unique_id), (10, LOCAL_NOTE)):
        name.setName(s, nid, *MAC)
        name.setName(s, nid, *WIN)

    os2, ros2 = font["OS/2"], real["OS/2"]
    os2.usWeightClass = ros2.usWeightClass
    os2.usWidthClass = ros2.usWidthClass
    # fsSelection 的 bit 7/8/9 要 OS/2 v4+ 才有定义，源字体版本低就屏蔽掉
    fs = ros2.fsSelection
    if os2.version < 4:
        fs &= ~0x0380
    os2.fsSelection = fs
    for f in ("bFamilyType", "bSerifStyle", "bWeight", "bProportion", "bContrast",
              "bStrokeVariation", "bArmStyle", "bLetterForm", "bMidline", "bXHeight"):
        setattr(os2.panose, f, getattr(ros2.panose, f))
    font["head"].macStyle = real["head"].macStyle


def clone_metrics(font, real, caret=False):
    """把 real 的纵向度量按 upem 比例抄过来，行高就和原版 Windows 一致。"""
    os2, ros2 = font["OS/2"], real["OS/2"]
    hhea, rhhea = font["hhea"], real["hhea"]
    k = font["head"].unitsPerEm / float(real["head"].unitsPerEm)
    s = lambda v: int(round(v * k))

    os2.sTypoAscender = s(ros2.sTypoAscender)
    os2.sTypoDescender = s(ros2.sTypoDescender)
    os2.sTypoLineGap = s(ros2.sTypoLineGap)
    os2.usWinAscent = s(ros2.usWinAscent)
    os2.usWinDescent = s(ros2.usWinDescent)
    hhea.ascent = s(rhhea.ascent)
    hhea.descent = s(rhhea.descent)
    hhea.lineGap = s(rhhea.lineGap)
    if caret:
        hhea.caretSlopeRise = rhhea.caretSlopeRise
        hhea.caretSlopeRun = rhhea.caretSlopeRun
        hhea.caretOffset = rhhea.caretOffset


def check_metrics(font, label):
    """字形超出 usWin 框只报告，不修正 —— 组合符号本来就不参与行高，
    抬高 usWin* 会让所有拿它算行距的程序凭空多出一截行高。"""
    os2, head = font["OS/2"], font["head"]
    if head.yMax > os2.usWinAscent or -head.yMin > os2.usWinDescent:
        log("      note: %s 字形超出 usWin 框 (yMax=%d/%d)，与原版行为一致"
            % (label, head.yMax, os2.usWinAscent))


def set_gasp(font):
    """全尺寸写 15：灰度 + 网格对齐 + 对称网格对齐 + 对称平滑。"""
    if "gasp" not in font:
        font["gasp"] = newTable("gasp")
    font["gasp"].version = 1
    font["gasp"].gaspRange = {65535: GASP_ALL}


def _shear_component(compo, t, gname):
    """把复合字形的一个 component 改成「被引用字形已经剪过」之后的等效摆放。

    整字要的是 P·S，而被引用的基字形自己已经被剪成 C·S 了，所以这里要把
    component 的矩阵 M 换成 S⁻¹MS、偏移换成 (x,y)·S，两边才对得上。
    S = ((1,0),(t,1))，S⁻¹ = ((1,0),(-t,1))，都按 fontTools 的行向量约定
    （x' = x·m[0][0] + y·m[1][0]）。

    M = I 时 S⁻¹MS 还是 I —— 而 fontTools 对单位矩阵的 component 根本不建
    transform 属性，所以绝大多数复合字形只用改偏移，一个字节都不会变长。
    """
    if hasattr(compo, "transform"):
        (a, b), (c, d) = compo.transform
        m = ((a + b * t, b),
             (c - t * a + t * d - t * t * b, d - t * b))
        # component 矩阵存的是 F2Dot14，只装得下 [-2, 2)。真字体里的
        # component 变换都是缩放和翻转，剪切量又小，正常越不了界；越了说明
        # 源字体有古怪的 component，宁可在这里停下也别让 struct 在编译阶段
        # 抛一个看不出是哪个字形的错。
        for row in m:
            for v in row:
                if not -2.0 <= v < 2.0:
                    raise SystemExit(
                        "字形 %s 的 component 变换剪切后超出 F2Dot14 范围 (%.4f)，"
                        "这个源字体没法算法伪斜，请在 source\\ 里补真斜体。"
                        % (gname, v))
        compo.transform = m
    # 点匹配定位的 component（有 firstPt/secondPt，没有 x/y）不用管：它的位置
    # 是从父字形里已经剪过的那个点算出来的，跟着一起斜了。
    if not hasattr(compo, "firstPt"):
        compo.x, compo.y = otRound(compo.x + compo.y * t), compo.y


def oblique(font, angle_deg=ITALIC_ANGLE):
    """源里没有真斜体时的兜底：沿基线剪切出一个算法伪斜体。

    x' = x + y·tan(angle)，y 不变，字宽不变。只动轮廓、lsb 和
    post.italicAngle —— 斜体的身份位（head.macStyle bit1、OS/2.fsSelection
    bit0）不归这里管，clone_identity() 会把真 segoeui*i.ttf 的那两个字段整段
    照抄过来，比自己拼准。两边字段不重叠，所以谈不上打架，但调用顺序仍然是
    先 clone_identity() 后 oblique()：伪斜是「把轮廓补上」，身份已经先立好了。
    """
    if "glyf" not in font:
        # 扫描只按扩展名收 .ttf，但 .ttf 里装 CFF 轮廓是合法的，真会撞上。
        raise SystemExit(
            "算法伪斜只会剪 TrueType 轮廓，这个源字体是 CFF/OTF（没有 glyf 表）。"
            "请在 source\\ 里补上真斜体，或者换一套 TrueType 源字体。")

    t = math.tan(math.radians(angle_deg))
    glyf, hmtx = font["glyf"], font["hmtx"]

    # 第一趟只动坐标和 component 的摆放，不算包围盒。复合字形的框要递归到被
    # 引用的基字形去算，而 glyphOrder 里复合字形完全可能排在基字形前面 ——
    # 一趟做完会拿还没剪过的基字形算出一个旧框来。
    for name in glyf.keys():
        g = glyf[name]
        if g.isComposite():
            for compo in g.components:
                _shear_component(compo, t, name)
        elif g.numberOfContours > 0:
            g.coordinates.transform(((1, 0), (t, 1)))
            g.coordinates.toInt()
        # numberOfContours == 0 是空字形（空格之类）：没有轮廓可剪，连 xMin
        # 都没有，lsb 本来也是 0，整个跳过。

    # 第二趟才算框。save 时 glyf 还会自己再算一遍，这里不是白算 —— 下面那行
    # lsb 要读 xMin，得先有个剪切之后的值。
    for name in glyf.keys():
        g = glyf[name]
        if g.numberOfContours == 0:
            continue
        g.recalcBounds(glyf)
        adv, _lsb = hmtx[name]
        hmtx[name] = (adv, g.xMin)   # lsb 不跟着新 xMin 走，整个字会横向错位

    # 指令全丢掉。指令是照着正体的坐标写的：按点号认竖笔，再拿 cvt 里的笔宽
    # 把两条边对齐到像素网格。轮廓剪斜之后点号没变、指令照跑，于是它会把已经
    # 斜过去的竖笔在 x 方向又掰回竖直，小字号下字形扭曲、笔画断续，比干脆没有
    # 指令难看得多。代价是 y 方向的基线 / x-height 对齐也一并没了，小字号会发
    # 虚 —— 这笔账伪斜体绕不过去，README 里如实写着。
    glyf.removeHinting()
    for tag in ("fpgm", "prep", "cvt "):
        # prep/fpgm 留着也没用了（逐字形指令没了），而且 prep 还能改全局图形
        # 状态，留一半反而说不清行为，三张表一起清掉。
        if tag in font:
            del font[tag]

    font["post"].italicAngle = -angle_deg
    # head.flags 的 bit1（「左边距点在 x=0」）这里【不用】动。它的实际含义就是
    # 「所有字形 lsb == xMin」，而 fontTools 在 maxp.recalc() 里是逐字形量出来
    # 重写这一位的，手工设了也会被覆盖。上面那趟已经把 lsb 跟到新 xMin 上，
    # 这一位本来就该是 1 —— 反过来说，产物里它要是 0，就是 lsb 那一步漏了。


def subset_to_coverage(font, unicodes):
    """把 font 裁到只剩 unicodes 这些码位，返回 (裁前字形数, 裁后字形数)。

    subset 会丢掉它不认识的表（meta 就是一个），所以先存后补。
    """
    from fontTools import subset
    # 用 glyphOrder 数，别用 maxp.numGlyphs —— 后者要到编译时才更新
    before = len(font.getGlyphOrder())
    meta = dict(font["meta"].data) if "meta" in font else None
    # name_languages 必须显式写 "*"。它的默认值是 [0x409]，语言过滤是【独立
    # 于】name_IDs / name_legacy 的一道，那两个拦不住它 —— clone_identity 刚
    # 从真字体照抄过来的本地化 name 记录会在这里被悄悄删光（真 segoeui.ttf
    # 光 nameID 2 就带 25 种语言，加上 Mac 平台那几条，38 条会只剩 8 条）。
    # recalc_average_width：裁完只剩拉丁，而 xAvgCharWidth 还是源字体按四万
    # 多个字形（含全角汉字）算出来的那个值。GDI 把它当 tmAveCharWidth 报给
    # 程序，老对话框拿它算控件尺寸，留着就是个偏大的陈旧值。
    opts = subset.Options(layout_features="*", name_IDs="*", name_legacy=True,
                          name_languages="*", notdef_outline=True,
                          recalc_average_width=True,
                          drop_tables=[], hinting=True, glyph_names=True)
    # 包围盒重算归 TTFont 管。subset.Options 里那个 recalc_bounds 只有
    # subset.load_font() 会读，字体是我们自己开的，写在 Options 里是空转。
    font.recalcBBoxes = True
    ss = subset.Subsetter(options=opts)
    ss.populate(unicodes=sorted(unicodes))
    ss.subset(font)
    if meta is not None:
        if "meta" not in font:
            font["meta"] = newTable("meta")
            font["meta"].data = {}
        for k in ("dlng", "slng"):
            if k in meta:
                font["meta"].data[k] = "Latn, Grek, Cyrl"
    return before, len(font.getGlyphOrder())


def family_names(path):
    """读回产物的族名，(英文, 中文) 拼成一行给人看。"""
    def one(f):
        n = f["name"]
        en = n.getName(1, 3, 1, 0x409)
        zh = n.getName(1, 3, 1, 0x804)
        return "%s%s" % (en.toUnicode() if en else "?",
                         " / " + zh.toUnicode() if zh else "")

    # ttc 的几个 face 共用同一个文件句柄，得全读完再一次性关掉
    if path.lower().endswith(".ttc"):
        col = TTCollection(path, lazy=True)
        try:
            return [one(f) for f in col.fonts]
        finally:
            col.close()
    with TTFont(path, lazy=True) as f:
        return [one(f)]


def mb(path):
    return os.path.getsize(path) / 1048576.0
