#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""make_cjk.py 和 make_segoe_ui.py 的公共部分。"""

import math
import os
import re
import shutil
import tempfile

from fontTools.misc.roundTools import otRound
from fontTools.ttLib import TTFont, TTCollection, newTable
from fontTools.varLib import instancer

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SOURCE_DIR = os.path.join(ROOT, "source")
WINFONTS = os.path.join(os.environ.get("WINDIR", r"C:\Windows"), "Fonts")

# make_vf.py 的产物名。放在这里是因为它和 make_segoe_ui.py 那 12 个文件同住
# SegoeUIMod\ —— 那边的「目录里有没有不该在的旧产物」检查得知道它不是旧文件。
VF_OUTNAME = "SegoeUI-Variable.ttf"

# 产物必须覆盖的最小字符集。放在这里是因为有两个模块要用【同一份】：
#   verify_fonts  拿它当不变式检查（缺了就判失败）
#   patch_glyphs  拿它当补字的下限 —— 「被冒充的那个字体有什么就补什么」是
#                 主规则，但那条规则挡不住被冒充的字体自己就缺：实测
#                 simhei.ttf 没有 ™ ¶ © ®，只按主规则补的话黑体那一档补完
#                 还是过不了自检。两份分开写迟早会对不上。
MUST_CJK = "←→↑↓■●▲◆○□★☆※°×÷≠≤≥∞√∑∏∫∈℃℅№™§¶©®ⅠⅡⅢ〇々〆‰′″‖"
MUST_LATIN = "ÀÉÎÕÜàéîõüÑñÇç°±·×÷£¥§©®µ¿"

WIN = (3, 1, 0x409)
MAC = (1, 0, 0)

# 家族名和样式名：照抄被顶替的那个系统字体。GDI 和 DirectWrite 都是从字体
# 文件的 name 表读族名的，所以这几项决定了系统把产物认成谁。
IDENTITY_NAME_IDS = (1, 2, 4, 6, 16, 17, 18, 21, 22)
# 版本、版权、许可、厂商：保留源字体自己的，不动。
SOURCE_NAME_IDS = (0, 5, 7, 8, 9, 11, 13, 14)

LOCAL_NOTE = ("Repackaged locally by WinModernSC for system font substitution. "
              "Outlines, copyright and license belong to the source font, "
              "except glyphs patched in from Windows fonts, which belong to "
              "Microsoft. Not affiliated with Microsoft; product names are trademarks of "
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

# 可变字体那一档的样式名。<Family>-VF.ttf 是【唯一】被认成可变字体的写法 ——
# 靠文件名而不是「有没有 fvar 表」来认，是为了让校验结果一眼看得出来，也让
# 「静态 + VF 并存」这种目录的分工是明摆着的，不用开文件才知道。
VF_STYLE = "VF"

# 源类型。校验的核心产物：make_vf / make_segoe_ui / make_cjk 三个脚本都按它
# 分支，所以它必须是【明确的三选一】，不能是「猜」出来的。
STATIC = "STATIC"   # 只有静态字重
VF = "VF"           # 只有一个 <Family>-VF.ttf
BOTH = "BOTH"       # 两者都有；静态那半仍须满足 REQUIRED_*

KIND_DESC = {
    STATIC: "纯静态字重",
    VF: "纯可变字体",
    BOTH: "静态 + 可变并存",
}


class Source(object):
    """source\\ 的校验结果。

    三个生成脚本拿到的都是这一个对象，分支只看 .kind：
        STATIC  静态那条路（各脚本的现有实现）
        VF      从 .vf 实例化出各字重再派生
        BOTH    静态那半已经齐了，走 STATIC 那条路；.vf 留给 make_vf.py 用
    """

    def __init__(self, family, kind, styles, vf):
        self.family = family
        self.kind = kind
        self.styles = styles    # {规范样式名: (样式名, 路径)}，【不含】VF 那一档
        self.vf = vf            # <Family>-VF.ttf 的绝对路径，没有就是 None

    def describe(self):
        """开跑前打的那一行。源类型必须打出来 —— 后面每个分支都由它决定。"""
        bits = ["%s（%s）" % (self.kind, KIND_DESC[self.kind])]
        if self.styles:
            bits.append("静态 %d 个样式" % len(self.styles))
        if self.vf:
            bits.append("VF %s" % os.path.basename(self.vf))
        return "%s : %s" % (self.family, "，".join(bits))


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


LEGAL_SHAPES = (
    "source\\ 只认这三种摆法：\n"
    "  1  纯静态字重：至少 <Family>-Regular.ttf + <Family>-Light.ttf，\n"
    "     外加 <Family>-Bold.ttf 或 <Family>-Black.ttf 之一\n"
    "  2  纯可变字体：单独一个 <Family>-VF.ttf\n"
    "  3  两者并存：<Family>-VF.ttf 加上满足第 1 条的那几个静态文件")


def scan_source(srcdir=None):
    """扫描并校验 source\\，返回一个 Source。

    命名必须是 <Family>-<Style>.ttf，同一目录里 <Family> 必须完全一致 ——
    族名混了直接判非法，不去猜哪一套是主的。样式名 VF 是保留字，指的是
    可变字体，见 VF_STYLE。
    """
    if srcdir is None:
        srcdir = SOURCE_DIR
    if not os.path.isdir(srcdir):
        raise SystemExit("找不到源字体目录: %s" % srcdir)

    families = {}
    styles = {}
    vfs = []
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
        path = os.path.join(srcdir, fn)
        if norm_style(style) == norm_style(VF_STYLE):
            vfs.append(path)
        else:
            styles[norm_style(style)] = (style, path)

    if bad:
        raise SystemExit("这些文件名不符合 <Family>-<Style>.ttf: %s\n%s"
                         % (", ".join(bad), LEGAL_SHAPES))
    if not styles and not vfs:
        raise SystemExit("%s 里一个 <Family>-<Style>.ttf 都没有。\n%s"
                         % (srcdir, LEGAL_SHAPES))
    if len(families) > 1:
        detail = "; ".join("%s: %s" % (f, ", ".join(v))
                           for f, v in sorted(families.items()))
        raise SystemExit("source\\ 里混了多个族名，只能放一套字体。%s" % detail)
    if len(vfs) > 1:
        raise SystemExit("source\\ 里有 %d 个可变字体，只能放一个: %s"
                         % (len(vfs), ", ".join(os.path.basename(p) for p in vfs)))

    family = list(families)[0]
    vf = vfs[0] if vfs else None
    check_variability(styles, vf)

    if vf and styles:
        kind = BOTH
    elif vf:
        kind = VF
    else:
        kind = STATIC
    # 并存时静态那半照样得齐 —— 12 个 Segoe UI 和 8 个中文族仍然从静态那半
    # 派生（BOTH 走的就是 STATIC 那条路），少一档就少一档。
    if kind in (STATIC, BOTH):
        check_required(styles, srcdir, family, kind)
    return Source(family, kind, styles, vf)


def check_variability(styles, vf):
    """文件名说自己是什么，表结构就得是什么，反过来也一样。

    两种都得挡：
      · <Family>-VF.ttf 里没有 fvar —— 那是个静态文件，改名了也变不出字重来，
        后面 instantiate() 会在一个没有轴的字体上切，报的错和真正的原因隔着
        好几层。
      · 静态那一档的文件里【有】fvar —— 那是把可变字体当静态用。make_segoe_ui
        会把它连 fvar/STAT 一起当成静态 Segoe UI 装进去，DirectWrite 于是拿
        STAT 去推 WSS 家族名，整族的字重档位全乱。
    """
    if vf and not has_fvar(vf):
        raise SystemExit(
            "%s 没有 fvar 表，不是可变字体。\n"
            "样式名 %s 是保留给可变字体的；这是个静态文件的话，"
            "改成它真正的字重名（Regular / Light / Bold …）。"
            % (os.path.basename(vf), VF_STYLE))
    wrong = sorted(os.path.basename(p) for _s, p in styles.values() if has_fvar(p))
    if wrong:
        raise SystemExit(
            "这些文件带 fvar 表，是可变字体，却用了静态字重的样式名: %s\n"
            "可变字体必须叫 <Family>-%s.ttf —— 当成静态文件用的话，"
            "fvar/STAT 会跟着装进 Segoe UI 那一族，字重档位会乱。"
            % (", ".join(wrong), VF_STYLE))


def has_fvar(path):
    """只读表目录，不解析任何一张表 —— 20 MB 的文件也是一瞬间的事。"""
    with TTFont(path, lazy=True) as f:
        return "fvar" in f


def check_required(styles, srcdir, family, kind):
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
        # 并存那种摆法多一条出路：把静态的全撤走，只留 VF，就变成合法的第 2 种。
        extra = ("" if kind != BOTH else
                 "\n目录里已经有 %s-%s.ttf 了 —— 静态那几个凑不齐的话，"
                 "把它们全挪走、只留这一个也是合法的（纯 VF）。"
                 % (family, VF_STYLE))
        raise SystemExit(
            "source\\ 缺少必需字重，共 %d 个: %s\n目录: %s\n%s\n"
            "斜体不是必需的：缺了会拿对应的正体剪切出伪斜体。%s"
            % (len(missing), want, srcdir, LEGAL_SHAPES, extra))


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


# --------------------------------------------------------- 可变字体源
# 源是 VF 时，「哪一档」不再是文件名里的样式词，而是 fvar 上的一个坐标。
# 要哪一档由调用方给一个 usWeightClass —— 各脚本都是从【被冒充的那个系统
# 字体】读出来的，所以这里不需要任何字重对照表。

def fvar_axis(font, tag):
    """取 fvar 里的一根轴，没有返回 None。"""
    for a in font["fvar"].axes:
        if a.axisTag == tag:
            return a
    return None


def weight_coord(font, weight):
    """要 weight 这一档时，wght 轴该停在哪。返回 (坐标, 是否被夹住)。

    源字体的 wght 范围各不相同（实测：HarmonyOS VF 是 40–900、苹方是
    100–900），要的档位落在范围外就夹到端点 —— 那是这个源能给出的最接近的
    一档。夹了要报出来，不然「Black 和 Bold 一模一样」看着像 bug。
    """
    a = fvar_axis(font, "wght")
    if a is None:
        return None, False
    v = min(max(float(weight), a.minValue), a.maxValue)
    return v, v != float(weight)


def italic_coord(font):
    """真斜体轴的坐标，没有这根轴返回 None（那就只能算法伪斜）。

    ital 是 0/1 的开关，取 1 那一端；slnt 是角度，按规范负值向右倾，取最小值。
    """
    a = fvar_axis(font, "ital")
    if a is not None:
        return {"ital": a.maxValue}
    a = fvar_axis(font, "slnt")
    if a is not None:
        return {"slnt": a.minValue}
    return None


def vf_location(font, weight, italic=False):
    """算出实例化坐标。返回 (坐标表, 是否真斜体, wght 是否被夹住)。

    wght 之外的轴一律停在【源字体自己的默认值】：宽度、光学尺寸这些我们没有
    立场替源字体选，默认值就是它作者定的那一档。
    """
    loc = {}
    clamped = False
    for a in font["fvar"].axes:
        loc[a.axisTag] = a.defaultValue
    w, clamped = weight_coord(font, weight)
    if w is not None:
        loc["wght"] = w
    ital = italic_coord(font) if italic else None
    if ital:
        loc.update(ital)
    return loc, bool(ital), clamped


class VFInstances(object):
    """一个 VF 源在一次运行里的静态实例缓存。

    实例化一次几十 MB 的可变字体要几十秒，而 12 个 Segoe UI 输出里好几个共用
    同一档字重（Regular 和 Italic 都是 400，Semibold 和 SemiboldItalic 都是
    600 …）—— 按 (字重, 斜不斜) 缓存，每档只切一次。

    中间文件落在临时目录，close() 一起删。【不能】往产物目录里放：
    verify_fonts.stray_files() 会把产物目录里的陌生字体文件当成旧产物报错。
    """

    def __init__(self, vf_path):
        self.vf_path = vf_path
        self._dir = None
        self._cache = {}
        # 有没有真斜体轴，开一次就够了。没有的话 italic=True 切出来的和正体
        # 逐字节相同，先把 key 归一，免得同一档字重白切两遍。
        with TTFont(vf_path, lazy=True) as f:
            self.has_italic_axis = italic_coord(f) is not None

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def instance(self, weight, italic=False):
        """返回 (静态实例的路径, 是不是真斜体)。

        产物里 fvar / STAT / gvar 那一套全删掉 —— 真的 Segoe UI 静态文件和
        真的 msyh.ttc 里都没有这些表，留着的话 DirectWrite 会改用 STAT 去推
        WSS 家族名，我们照抄的那套身份就被绕过去了。
        """
        key = (int(weight), bool(italic) and self.has_italic_axis)
        if key in self._cache:
            return self._cache[key]

        if self._dir is None:
            self._dir = tempfile.mkdtemp(prefix="winmodernsc-vf-")
        font = TTFont(self.vf_path)
        loc, real_italic, clamped = vf_location(font, weight, key[1])
        what = "wght %g%s" % (loc.get("wght", 0),
                              "" if not real_italic else " + 真斜体轴")
        log("  [VF] 实例化 %s%s ..."
            % (what, "（源字体的 wght 只到这里，已夹住）" if clamped else ""))
        font = instancer.instantiateVariableFont(
            font, loc, inplace=True, optimize=False, updateFontNames=False)
        for tag in ("fvar", "STAT", "gvar", "avar", "cvar",
                    "HVAR", "VVAR", "MVAR"):
            if tag in font:
                del font[tag]
        # 名字叫 Italic 的产物，post.italicAngle 必须非零 —— verify_fonts 拿它
        # 当「轮廓到底斜没斜」的唯一凭据。可真斜体轴切出来的实例常常还是 0
        # （那个字段不随轴变），补上：slnt 轴本身就是角度，照抄；ital 是 0/1
        # 的开关，没有角度可抄，用和算法伪斜同一个 12°。
        if real_italic and not font["post"].italicAngle:
            slnt = loc.get("slnt")
            font["post"].italicAngle = slnt if slnt else -ITALIC_ANGLE
        out = os.path.join(self._dir, "inst_%d%s.ttf"
                           % (key[0], "i" if real_italic else ""))
        font.save(out)
        font.close()
        self._cache[key] = (out, real_italic)
        return self._cache[key]

    def close(self):
        if self._dir and os.path.isdir(self._dir):
            shutil.rmtree(self._dir, ignore_errors=True)
        self._dir = None
        self._cache = {}


# ------------------------------------------------------------- 系统字体
def open_system_font(name, index=None, lazy=False):
    """打开 C:\\Windows\\Fonts 里的一个字体，ttc 按索引取 face。"""
    path = os.path.join(WINFONTS, name)
    if path.lower().endswith(".ttc"):
        return TTCollection(path, lazy=lazy).fonts[index or 0]
    return TTFont(path, lazy=lazy)


def system_font_weight(name, index=None):
    """被冒充的那个系统字体的 usWeightClass。源是 VF 时拿它当「切哪一档」。

    这样就不必另立一张「输出 -> 字重」的对照表：clone_identity() 本来就把
    这个值原样抄进产物，轮廓跟着身份走，两边永远对得上；系统换了版本、某一档
    的 usWeightClass 变了，也是自动跟着变。
    """
    f = open_system_font(name, index, lazy=True)
    try:
        return f["OS/2"].usWeightClass
    finally:
        f.close()


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
