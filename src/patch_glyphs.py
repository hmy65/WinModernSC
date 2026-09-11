#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
给产物补上「被它顶替的那个 Windows 字体有、而源字体没有」的字形。

为什么需要这一步：
    源字体只要覆盖面不如被顶替的那个系统字体，顶上去就有东西掉出去。掉出去
    不等于变豆腐块 —— 机制 4 保留的原链和 DirectWrite 自己的回退会把字找回
    来 —— 但找回来的是【别的字体】的字形，和正文不是一套。极端情况实测过：
    有的源只保留了 CJK，真 segoeui.ttf 的 3996 个码位只命中 110 个，顶上去
    整个界面的西文全靠回退，那一层等于白装了。

补哪些（见 PATCH_BLOCKS）：
    西欧重音字母、通用标点、货币 / 字母式 / 数字形式、箭头 / 数学 / 几何 /
    杂项符号、CJK 符号和标点。**再和「被冒充的那个字体自己的覆盖面」取交集**
    —— 这一步很关键，它让分工自动成立：拉丁那一族按真 segoeui.ttf 的覆盖面
    补，不会莫名其妙多出汉字标点；中文族按真雅黑的覆盖面补，℃ 〇 ※ 这些自然
    就进来了。也不必再维护一张「哪个输出该补什么」的表。

    IPA、组合用变音符号、Latin Extended-A/B、希腊、西里尔【不在】这里：中文
    字体本来就不会全带，实测好用的源（更纱、HarmonyOS）命中率也只有 47% /
    20%，按比例要求等于把它们全挡在门外。这些交给回退。要加的话在
    PATCH_BLOCKS 里加一行就是 —— Latin Extended-A（0x0100..0x017F，中东欧）
    是最值得加的一档，128 个里 108 个能拼。

怎么补 —— **能拼就拼，拼不了才搬**：
    拼  这个字符能正则分解成 base + 组合符号，而且【源字体自己有 base】。
        造一个复合字形：base 直接引用源字体自己的字母，只把组合符号从捐赠
        字体搬过来。字形风格、字宽都还是源字体的，看不出补过。
        对可变字体这不只是好看：搬进来的字形没有 gvar 增量、不随字重变，而
        复合字形引用的是源字体自己的字母（它有增量，跟着变粗），只有重音符号
        固定不动 —— 重音符号本来就几乎不随字重变。也就是说【只有拼这条路能
        让重音字母跟着字重走】。
    搬  分解不出来（绝大多数符号：← ■ ● ℃ № ™ 等），或者源字体连 base 都
        没有。整个字形从捐赠字体搬过来，按 upem 比例缩放。符号各家画得大同
        小异，搬过来基本看不出；字母就很扎眼，所以字母尽量走「拼」。

捐赠源的顺序：
    第一顺位永远是【被冒充的那个文件本身】—— 它和输出同字重、同风格，借出来
    最不违和，而且是调用方传进来的，不用查表。它没有的才往下走 DONOR_POOL，
    按 usWeightClass 离输出多远排序。后备是必需的：simhei.ttf 自己就缺
    À É Î Õ Ü î õ Ñ ñ Ç ç £ ¥ © ® µ ¿ 和 ™ ¶ © ®，只认它一个的话黑体那一档
    补完还是缺。
"""

import os
import unicodedata

from fontTools.pens.recordingPen import DecomposingRecordingPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib.tables._g_l_y_f import Glyph, GlyphComponent

import util
from util import log

# 要补的 Unicode 区块。实际补的是「这些区块 ∩ 被冒充的那个字体的覆盖面
# - 源字体已有的」，所以这张表是上限，不是清单。
PATCH_BLOCKS = (
    (0x00A0, 0x00FF, "Latin-1 补充"),        # é ü ñ ° ± × ÷ £ § © ® µ ¿
    (0x2000, 0x206F, "通用标点"),            # – — ‘ ’ “ ” … ‰ † ‡ • ′ ″ ‖
    (0x2070, 0x209F, "上标下标"),            # ² ³ ⁿ ₀ ₁
    (0x20A0, 0x20CF, "货币符号"),            # € ₹ ₽
    (0x2100, 0x214F, "字母式符号"),          # ℃ ℅ № ™ Ω Å
    (0x2150, 0x218F, "数字形式"),            # ½ ⅓ Ⅰ Ⅱ Ⅲ
    (0x2190, 0x21FF, "箭头"),                # ← → ↑ ↓
    (0x2200, 0x22FF, "数学运算符"),          # ≠ ≤ ≥ ∞ √ ∑ ∏ ∫ ∈
    (0x25A0, 0x25FF, "几何图形"),            # ■ ● ▲ ◆ ○ □
    (0x2600, 0x26FF, "杂项符号"),            # ★ ☆ ☑ ♪
    (0x2700, 0x27BF, "装饰符号"),            # ✓ ✗ ❶
    (0x3000, 0x303F, "CJK 符号和标点"),      # 〇 々 〆 、 。 「 」 ※
)

WANTED = set()
for _lo, _hi, _n in PATCH_BLOCKS:
    WANTED |= set(range(_lo, _hi + 1))

# 第一顺位（被冒充的那个文件）之外的备选。按 usWeightClass 离输出多远排序，
# 一样远的按这里的先后。雅黑排在 Segoe UI 前面：中文语境的标点（· 、 。）
# 它的度量是按中文排版做的，Segoe UI 的不是 —— 实测 U+00B7 苹方给 500、
# 雅黑 241、Segoe UI 217，从 Segoe UI 搬会把间隔号缩成一个点。
# seguisym / msgothic 是兜底，只在前面全都没有时才轮得到。
DONOR_POOL = (
    ("msyh.ttc", 0), ("msyhl.ttc", 0), ("msyhbd.ttc", 0),
    ("segoeui.ttf", None), ("segoeuil.ttf", None), ("segoeuib.ttf", None),
    ("simsun.ttc", 0), ("Deng.ttf", None),
    ("seguisym.ttf", None), ("msgothic.ttc", 0),
)

# 组合符号往哪儿摆，按 Unicode 的 canonical combining class 判定，不猜。
#   230 及以上 = 字母上方（´ ` ˆ ˜ ¨ ˚ ˇ）
#   220 / 202  = 字母下方（¸ 尾钩、点、横线）
#   1          = 叠在字上（U+0338 长斜杠，≠ ∉ 就是这么来的）
ABOVE, BELOW, OVERLAY = "above", "below", "overlay"

# 软点字母（Unicode 的 Soft_Dotted）：上面加符号时，字母自己的点要去掉，
# 换成无点形。真字体就是这么画的 —— 真 SegUIVar.ttf 的 icircumflex 引用的是
# dotlessi，不是 i。拿带点的 i 硬拼，点和折角会上下叠在一起，实测比原版高
# 283/2048 ≈ 14% em，一眼就看得出不对。î 还在 util.MUST_LATIN 里，是自检
# 要求必须有的那一档。
# 源字体没有无点形就别拼了，整个搬过来 —— 搬来的是人家画好的。
SOFT_DOTTED = {0x0069: 0x0131,      # i -> ı
               0x006A: 0x0237}      # j -> ȷ


def placement_of(mark_cp):
    ccc = unicodedata.combining(chr(mark_cp))
    if ccc == 0:
        return OVERLAY          # 不该发生，保守当叠加处理
    if ccc >= 230:
        return ABOVE
    if ccc == 1:
        return OVERLAY
    return BELOW


def decompose(cp):
    """正则分解成 (base 码位, [组合符号码位])。分解不出来返回 None。

    递归到底：ǻ = å + ́ = a + ̊ + ́ ，一路拆到真正的基字母。兼容分解
    （<compat> 那种，比如 ² -> 2）不算 —— 那不是同一个字形。
    """
    d = unicodedata.decomposition(chr(cp))
    if not d or d.startswith("<"):
        return None
    parts = [int(x, 16) for x in d.split()]
    base, marks = parts[0], parts[1:]
    for _ in range(4):
        d2 = unicodedata.decomposition(chr(base))
        if not d2 or d2.startswith("<"):
            break
        p2 = [int(x, 16) for x in d2.split()]
        base, marks = p2[0], p2[1:] + marks
    return base, marks


# ------------------------------------------------------------------ 捐赠源
# 捐赠字体开一次用一整趟。make_cjk 那边 9 个输出 × 最多 2 个 face = 18 次
# 补字，每次都重开一遍 msyh.ttc（20 MB、三万个字形）就白等了。
# 一律 lazy：只有真被借走的那几百个字形会解开，整张 glyf 不会进内存。
_DONOR_CACHE = {}


def _open_donor(name, idx):
    key = (name.lower(), idx)
    if key not in _DONOR_CACHE:
        _DONOR_CACHE[key] = util.open_system_font(name, idx, lazy=True)
    return _DONOR_CACHE[key]


class Donors(object):
    """一次补字用到的捐赠源，按字重排好序。字体本身走 _DONOR_CACHE。"""

    # usWeightClass 查一次就够，一次运行里十几个输出都在问同样几个文件
    _weights = {}

    def __init__(self, first, first_name, weight):
        # first 是被冒充的那个字体，调用方已经开好了，也由调用方负责关
        self._order = [first_name]
        self._font = {first_name: first}
        self._cmaps = {}
        # 后备按字重距离排序。取不到 usWeightClass 的（文件不存在）直接踢掉。
        rest = []
        for name, idx in DONOR_POOL:
            if name.lower() == first_name.lower():
                continue
            if not os.path.exists(os.path.join(util.WINFONTS, name)):
                continue
            if (name, idx) not in Donors._weights:
                try:
                    Donors._weights[(name, idx)] = util.system_font_weight(name, idx)
                except Exception:
                    Donors._weights[(name, idx)] = None
            w = Donors._weights[(name, idx)]
            if w is None:
                continue
            rest.append((abs(w - weight), len(rest), name, idx))
        self._idx = {}
        for _d, _i, name, idx in sorted(rest):
            self._order.append(name)
            self._idx[name] = idx              # 先记着，用到再开

    def names(self):
        return list(self._order)

    def get(self, name):
        if name not in self._font:
            self._font[name] = _open_donor(name, self._idx[name])
        return self._font[name]

    def cmap(self, name):
        """getBestCmap() 每次都重新拼一遍表，几百个码位挨个问就白等了。"""
        if name not in self._cmaps:
            self._cmaps[name] = self.get(name).getBestCmap()
        return self._cmaps[name]

    def close(self):
        # 字体本身归 _DONOR_CACHE，整趟运行都留着，这里只丢自己那份 cmap 缓存
        self._cmaps = {}
        self._font = {}


# ------------------------------------------------------------------ 搬字形
def _bbox(glyph, glyf):
    """字形的包围盒；空字形返回 None。"""
    if glyph.numberOfContours == 0:
        return None
    glyph.recalcBounds(glyf)
    return (glyph.xMin, glyph.yMin, glyph.xMax, glyph.yMax)


def _composite(parts):
    """用 [(字形名, dx, dy)] 拼一个复合字形。

    不走 TTGlyphPen：它的 _buildComponents 要拿 glyphSet 查每个 component
    在不在，而我们引用的字形有一部分是这一趟【刚加进去的】组合符号，那时候
    glyphSet 还没刷新。直接建 GlyphComponent 反而更直白 ——
    ARGS_ARE_XY_VALUES 和 MORE_COMPONENTS 由 fontTools 编译时自己补，
    这里只要给 ROUND_XY_TO_GRID。
    """
    g = Glyph()
    g.numberOfContours = -1
    g.components = []
    for name, dx, dy in parts:
        c = GlyphComponent()
        c.glyphName = name
        c.x, c.y = int(dx), int(dy)
        c.flags = 0x04                  # ROUND_XY_TO_GRID
        g.components.append(c)
    return g


def _copy_outline(donor, gname, k):
    """把捐赠字体的一个字形按 k 缩放搬出来，返回 (Glyph, 缩放后的字宽)。

    先分解复合字形：捐赠字体里的 Aacute 引用的是【它自己的】A，搬过来那个 A
    在我们的字体里不存在（或者是另一个字），只能摊平成轮廓。
    """
    gset = donor.getGlyphSet()
    rec = DecomposingRecordingPen(gset)
    gset[gname].draw(rec)
    pen = TTGlyphPen(None)
    rec.replay(TransformPen(pen, (k, 0, 0, k, 0, 0)))
    return pen.glyph(), util.otRound(donor["hmtx"][gname][0] * k)


def _donor_offset(donor, cp, base_cp, mark_cp, k):
    """从捐赠字体自己的复合字形里量出「符号相对基字形」的摆放，按 k 缩放。

    返回 (水平偏移, 垂直偏移)，都是「相对于纯居中 / 纯贴边」的修正量；
    捐赠字体里这个字不是复合字形（或者压根没有）就返回 (0, 0)，走几何默认值。

    为什么要量而不是直接用捐赠字体的 component 偏移：那个偏移是相对【捐赠
    字体的】base 算的，我们的 base 宽度和高度都不一样，直接抄会歪。量出来的
    是「设计师有意让它偏离居中多少」这个意图，再按我们自己的 base 重新落位。

    符号那一半【不能】按 cmap 里 mark_cp 对应的字形名去认。按 AGL 惯例，
    U+0300 在 cmap 里是 gravecomb，而复合字形 Agrave 引用的是间距形的
    grave —— 两个不同的字形，名字永远对不上。实测真 SegUIVar.ttf 和真
    segoeui.ttf 的每一个重音字母都是这样，按名字认的话每次都量不到，一律退回
    「符号底边紧贴字母顶端」的几何默认值，重音比原版低 5%~14% em，几乎压在
    字母上。所以只按名字认 base，复合字形里【剩下那一个】就是符号。
    """
    zero = (0, 0)
    try:
        glyf = donor["glyf"]
        cm = donor.getBestCmap()
        gn, bn = cm.get(cp), cm.get(base_cp)
        if not (gn and bn):
            return zero
        g = glyf[gn]
        if not g.isComposite():
            return zero
        if any(hasattr(c, "firstPt") for c in g.components):
            return zero                     # 点匹配定位的，量不了
        base_c = [c for c in g.components if c.glyphName == bn]
        marks_c = [c for c in g.components if c.glyphName != bn]
        # 正好「一个 base + 一个符号」才认得出谁是谁。双重音（ǻ 之类）在这里
        # 分不出哪个是哪个，退回几何默认值。
        if len(base_c) != 1 or len(marks_c) != 1:
            return zero
        bpos = (base_c[0].x, base_c[0].y)
        mpos = (marks_c[0].x, marks_c[0].y)
        bb = _bbox(glyf[bn], glyf)
        mb = _bbox(glyf[marks_c[0].glyphName], glyf)
        if bb is None or mb is None:
            return zero
        bx0, by0, bx1, by1 = (bb[0] + bpos[0], bb[1] + bpos[1],
                              bb[2] + bpos[0], bb[3] + bpos[1])
        mx0, my0, mx1, my1 = (mb[0] + mpos[0], mb[1] + mpos[1],
                              mb[2] + mpos[0], mb[3] + mpos[1])
        cls = placement_of(mark_cp)
        h = ((mx0 + mx1) / 2.0) - ((bx0 + bx1) / 2.0)
        if cls == ABOVE:
            v = my0 - by1
        elif cls == BELOW:
            v = my1 - by0
        else:
            v = ((my0 + my1) / 2.0) - ((by0 + by1) / 2.0)
        return util.otRound(h * k), util.otRound(v * k)
    except Exception:
        # 捐赠字体千奇百怪，量不出来就走几何默认值，不值得为此中断
        return zero


# ------------------------------------------------------------------ 报告
class Report(object):
    def __init__(self):
        self.composed = 0       # 拼出来的
        self.imported = 0       # 搬过来的
        self.marks = 0          # 为了拼而搬进来的组合符号
        self.varied = 0         # 补了 gvar、字宽跟着字重变的（可变字体才有）
        self.missing = set()    # 捐赠源里也没有的
        self.by_donor = {}      # 文件名 -> 提供了几个
        self.wanted = 0

    @property
    def added(self):
        return self.composed + self.imported + self.marks

    def line(self, label):
        if not self.wanted:
            return "%s 无需补字" % label
        bits = ["补 %d 个码位" % self.wanted,
                "拼 %d" % self.composed, "搬 %d" % self.imported]
        if self.marks:
            bits.append("组合符号 %d" % self.marks)
        if self.varied:
            bits.append("其中 %d 个跟着字重变" % self.varied)
        if self.missing:
            bits.append("仍缺 %d" % len(self.missing))
        who = "、".join("%s %d" % (n, c) for n, c in
                        sorted(self.by_donor.items(), key=lambda x: -x[1]))
        return "%s %s；来源 %s" % (label, "，".join(bits), who or "（无）")


# ------------------------------------------------------------------ 主入口
def patch(font, real, real_name, weight, label="", must=""):
    """把 font 缺的那些字形补上，原地改。返回 Report。

    font       产物（静态或可变都行）
    real       被冒充的那个系统字体，已打开。它既决定【补哪些】（取交集），
               也是第一顺位捐赠源。
    real_name  它的文件名，只用于日志和排除重复
    weight     这个输出的字重，用来给后备捐赠源排序
    must       无论 real 有没有都得补上的那些字符（util.MUST_*）。主规则是
               「real 有什么就补什么」—— 顶替一个本来就没有 ™ 的字体，产物
               也没有 ™，那不算退步。但项目自己的自检有个下限，而被冒充的
               字体可能连那个下限都够不着（simhei.ttf 缺 ™ ¶ © ®），所以这
               一小撮要单独兜住，从后备捐赠源借。
    """
    rep = Report()
    have = set(font.getBestCmap().keys())
    want = (WANTED & set(real.getBestCmap().keys())) | {ord(c) for c in must}
    need = sorted(want - have)
    rep.wanted = len(need)
    if not need:
        return rep

    if "glyf" not in font:
        # 扫描只按扩展名收 .ttf，但 .ttf 里装 CFF 轮廓是合法的，真会撞上。
        raise SystemExit(
            "补字只会往 TrueType 轮廓里加字形，这个源字体是 CFF/OTF"
            "（没有 glyf 表）。换一套 TrueType 源字体。")

    # 动字形表之前必须先把这些解开。gvar 的 decompile 里有
    # assert len(glyphOrder) == glyphCount —— 等加完字形再碰它就直接炸；
    # 而如果一直不碰，fontTools 会把原始二进制原样写回去，那更糟：产出的
    # gvar 偏移数组长度和字形数对不上，是个坏字体。
    for tag in ("glyf", "hmtx", "vmtx", "vhea", "maxp", "hhea", "cmap",
                "post", "gvar", "HVAR", "VVAR", "VORG"):
        if tag in font:
            _ = font[tag]
    if "gvar" in font:
        _ = font["gvar"].variations

    glyf, hmtx = font["glyf"], font["hmtx"]
    vmtx = font["vmtx"] if "vmtx" in font else None
    vorg_y = font["VORG"].defaultVertOriginY if "VORG" in font else None
    upem = font["head"].unitsPerEm
    order = list(font.getGlyphOrder())
    n_old = len(order)          # HVAR 改显式映射时要知道哪些是原有字形
    taken = set(order)
    cmap_now = font.getBestCmap()

    donors = Donors(real, real_name, weight)
    added = {}          # 码位 -> 字形名
    mark_glyph = {}     # 组合符号码位 -> 字形名（源字体自己有的直接用它的）
    base_of = {}        # 新字形名 -> 它引用的 base 字形名（HVAR 要用）

    def uniq(cp, prefix="wmsc"):
        n = "%s_uni%04X" % (prefix, cp)
        i = 0
        while n in taken:
            i += 1
            n = "%s_uni%04X_%d" % (prefix, cp, i)
        return n

    def find_donor(cp):
        """哪个捐赠源有这个码位。返回 (名字, TTFont, 字形名)。"""
        for name in donors.names():
            gn = donors.cmap(name).get(cp)
            if gn:
                return name, donors.get(name), gn
        return None, None, None

    def bring(cp, prefix="wmsc"):
        """把一个码位整个搬进来，返回字形名；搬不到返回 None。"""
        name, d, gn = find_donor(cp)
        if d is None:
            return None
        k = upem / float(d["head"].unitsPerEm)
        g, adv = _copy_outline(d, gn, k)
        new = uniq(cp, prefix)
        glyf[new] = g
        g.recalcBounds(glyf)
        hmtx[new] = (adv, g.xMin if g.numberOfContours != 0 else 0)
        order.append(new)
        taken.add(new)
        rep.by_donor[name] = rep.by_donor.get(name, 0) + 1
        return new

    def get_mark(cp):
        """组合符号的字形。源字体自己有就用它自己的（风格最统一）。"""
        if cp in mark_glyph:
            return mark_glyph[cp]
        own = cmap_now.get(cp)
        if own:
            mark_glyph[cp] = own
            return own
        new = bring(cp, "wmscmk")
        if new:
            rep.marks += 1
        mark_glyph[cp] = new
        return new

    # --- 先拼，拼不了的记下来一起搬
    to_import = []
    for cp in need:
        dec = decompose(cp)
        base_cp = dec[0] if dec else None
        if base_cp is not None and any(placement_of(m) == ABOVE for m in dec[1]):
            base_cp = SOFT_DOTTED.get(base_cp, base_cp)   # i -> ı，见 SOFT_DOTTED
        base_gn = cmap_now.get(base_cp) if base_cp is not None else None
        # 用 taken 而不是 glyf.keys()：后者每次都现拼一个几万条的 list，
        # 三百个码位挨个 in 一遍就是上千万次比较
        if not base_gn or base_gn not in taken:
            to_import.append(cp)
            continue
        marks = [(m, get_mark(m)) for m in dec[1]]
        if any(gn is None for _m, gn in marks):
            to_import.append(cp)        # 组合符号哪儿都借不到
            continue

        bb = _bbox(glyf[base_gn], glyf)
        if bb is None:
            to_import.append(cp)        # base 是个空字形，拼不出东西
            continue
        _dname, dfont, _dgn = find_donor(cp)
        dk = upem / float(dfont["head"].unitsPerEm) if dfont else 1.0

        parts = [(base_gn, 0, 0)]
        top, bottom = bb[3], bb[1]
        for mcp, mgn in marks:
            mb = _bbox(glyf[mgn], glyf)
            if mb is None:
                continue
            # 传 base_cp 不是 dec[0]：捐赠字体的 icircumflex 引用的也是
            # dotlessi，按 i 去认它的 base 一样认不出来。
            hoff, voff = (_donor_offset(dfont, cp, base_cp, mcp, dk)
                          if dfont else (0, 0))
            cls = placement_of(mcp)
            dx = util.otRound((bb[0] + bb[2]) / 2.0 - (mb[0] + mb[2]) / 2.0) + hoff
            if cls == ABOVE:
                dy = util.otRound(top - mb[1]) + voff
                top = max(top, mb[3] + dy)      # 多个符号往上叠
            elif cls == BELOW:
                dy = util.otRound(bottom - mb[3]) + voff
                bottom = min(bottom, mb[1] + dy)
            else:
                dy = util.otRound((bb[1] + bb[3]) / 2.0 - (mb[1] + mb[3]) / 2.0) + voff
            parts.append((mgn, dx, dy))

        g = _composite(parts)
        new = uniq(cp)
        glyf[new] = g
        g.recalcBounds(glyf)
        # 字宽用【源字体自己那个 base 的】—— é 就该和 e 一样宽
        hmtx[new] = (hmtx[base_gn][0], g.xMin if g.numberOfContours != 0 else 0)
        order.append(new)
        taken.add(new)
        added[cp] = new
        base_of[new] = base_gn
        rep.composed += 1

    for cp in to_import:
        new = bring(cp)
        if new is None:
            rep.missing.add(cp)
            continue
        added[cp] = new
        rep.imported += 1

    if not added and not rep.marks:
        donors.close()
        return rep

    # --- 收尾：字形表、cmap、纵向度量、HVAR
    font.setGlyphOrder(order)
    glyf.glyphOrder = order
    font["maxp"].numGlyphs = len(order)

    if vmtx is not None:
        # 纵排度量：照源字体自己的规律填（vAdv = upem，tsb = VORG 原点 - yMax）
        for new in order:
            if new in vmtx.metrics:
                continue
            g = glyf[new]
            ymax = g.yMax if getattr(g, "numberOfContours", 0) != 0 else 0
            vmtx[new] = (upem, (vorg_y - ymax) if vorg_y is not None else 0)

    for st in font["cmap"].tables:
        if not st.isUnicode():
            continue
        bmp_only = st.format == 4
        for cp, gname in added.items():
            if bmp_only and cp > 0xFFFF:
                continue
            st.cmap[cp] = gname

    _extend_gvar(font, base_of, rep)
    _extend_hvar(font, order, n_old, added, mark_glyph, base_of)

    try:
        font["OS/2"].recalcUnicodeRanges(font, pruneOnly=False)
    except Exception:
        pass

    donors.close()
    return rep


def _extend_gvar(font, base_of, rep):
    """拼出来的复合字形补一份 gvar，让【字宽】也跟着字重变。

    轮廓那一半本来就对：复合字形引用的是源字体自己的字母，那个字母有自己的
    gvar 增量，粗细跟着轴走 —— 实测 é 的框宽在 wght 300/400/700 下是
    483/493/516，和 e 一模一样。

    字宽那一半【不】自动对。TrueType 可变字体的字宽增量存在 gvar 每个字形
    最后 4 个 phantom point 上，新字形没有 gvar 条目就一个增量都没有 ——
    实测 e 的字宽 546→585 而 é 一直是 555，Bold 下重音字母比周围挤。
    （HVAR 也管字宽，而且按规范优先级更高，下面 _extend_hvar 已经挂对了；
     但 fontTools 的 instancer 是按 gvar 的 phantom point 算的，两边都得对，
     不能赌渲染器走哪条。）

    做法：照抄 base 的每一条 TupleVariation，component 偏移全给 0，phantom
    point 原样搬过来。é 和 e 的默认字宽本来就相同（上面 hmtx 就是照抄的），
    所以增量直接通用。

    component 偏移留 0 的代价：base 变粗时会略微变宽，重音符号不跟着挪，
    最粗那一档会偏心几个单位（实测 e 从 483 到 516，偏心约 8/1000 em）。
    肉眼看不出来，不值得为此去反推 base 的框宽增量。
    """
    if "gvar" not in font or not base_of:
        return
    from fontTools.ttLib.tables.TupleVariation import TupleVariation
    gvar = font["gvar"]
    glyf = font["glyf"]
    n = 0
    for gname, base in base_of.items():
        src = gvar.variations.get(base)
        if not src:
            continue                    # base 自己就不随字重变，那就都不变
        ncomp = len(glyf[gname].components)
        out = []
        for tv in src:
            coords = tv.coordinates
            if not coords or len(coords) < 4:
                continue
            phantom = [(0, 0) if p is None else tuple(p) for p in coords[-4:]]
            out.append(TupleVariation(dict(tv.axes), [(0, 0)] * ncomp + phantom))
        if out:
            gvar.variations[gname] = out
            n += 1
    rep.varied = n


def _extend_hvar(font, order, n_old, added, mark_glyph, base_of):
    """可变字体：把新字形挂到正确的字宽增量上。

    不挂的话按规范会套用「最后一条」的 delta，字宽在非默认字重下会飘。
    两类新字形要挂到【不同】的地方：
      拼出来的 -> 挂到它 base 那一条。é 的字宽本来就该和 e 一模一样地随字重
                  变；挂全零行的话 e 变粗了 é 却没变宽，间距就错了。
      搬过来的 -> 挂全零行。它们没有 gvar 增量、字形根本不随字重变，字宽跟着
                  变反而不对。
    """
    if "HVAR" not in font:
        return
    hvar = font["HVAR"].table
    vs = hvar.VarStore

    zero = None
    for outer, vd in enumerate(vs.VarData):
        for inner, item in enumerate(vd.Item):
            if not any(item):
                zero = (outer << 16) | inner
                break
        if zero is not None:
            break
    if zero is None:
        vd = vs.VarData[0]
        vd.Item.append([0] * len(vd.VarRegionIndex))
        vd.ItemCount = len(vd.Item)
        zero = (0 << 16) | (vd.ItemCount - 1)

    if hvar.AdvWidthMap is None:
        # 隐式 1:1 映射：字形 i 用第 i 条。新字形排在后面就越界了，所以改成
        # 显式表 —— 老字形逐个映到自己原来那条，新字形才好单独指。
        from fontTools.ttLib.tables import otTables as ot
        m = ot.VarIdxMap()
        m.mapping = {}
        for i, gname in enumerate(order):
            m.mapping[gname] = i if i < n_old else zero
        hvar.AdvWidthMap = m
        log("      note: HVAR 原本是隐式映射，已改成显式表（%d 条）" % len(m.mapping))

    mapping = hvar.AdvWidthMap.mapping
    new_names = set(added.values()) | {g for g in mark_glyph.values() if g}
    for gname in new_names:
        if gname in mapping and gname not in base_of:
            continue                     # 源字体自己的组合符号，别动它
        base = base_of.get(gname)
        mapping[gname] = mapping.get(base, zero) if base else zero
