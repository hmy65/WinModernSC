#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
产出物自检：身份字段、覆盖、hinting、gasp 是不是都对。

两侧的不变式是【相反】的，别搞混：
    CJKMod\\      必须有汉字、有符号
    SegoeUIMod\\  必须【没有】汉字 —— 剥干净了，中文才会回退到 CJKMod 那一套

make_cjk.py 和 make_segoe_ui.py 生成完会自动跑对应的那一半。也可以两边一起
单独跑一遍（不需要 source\\，只看产物）：

    python src\\verify_fonts.py
"""

import os

from fontTools.ttLib import TTFont, TTCollection

import util
from util import log

# 中文里的高频符号，中文族必须全有
PROBE = "←→↑↓■●▲◆○□★☆※°×÷≠≤≥∞√∑∏∫∈℃℅№™§¶©®ⅠⅡⅢ〇々〆‰′″‖"
# 覆盖面探针，从常用到生僻
HANZI = "汉字测试壹贰叁国际标准万象更新龘齉"
# 横画密集的字，用来看有没有逐字形的 hinting 指令
DENSE = "最具量工书面直真置章"
# 拉丁那一侧的对应探针。SegoeUIMod\ 里一个汉字都没有（那正是它的不变式），
# 拿 DENSE 去量必然是 0，量不出任何东西 —— 那边必须用这一组。
DENSE_LATIN = "AaBbEeHhMmNnRSgo0123"

GASP_DOGRAY = 0x02
GASP_SYM_SMOOTHING = 0x08


def open_faces(path):
    """打开产物，ttc 返回全部 face。

    ttc 的几个 face 共用一个文件句柄，关掉任何一个另几个就读不了了 ——
    所以调用方必须全部读完再一起关。
    """
    if path.lower().endswith(".ttc"):
        return TTCollection(path, lazy=True).fonts
    return [TTFont(path, lazy=True)]


def name_of(font, nid, lid=0x409):
    r = font["name"].getName(nid, 3, 1, lid)
    return r.toUnicode() if r else None


def identity_records(font):
    """IDENTITY_NAME_IDS 那几个 nameID 的全部 name 记录，按平台/编码/语言分开。

    解不出编码的跳过 —— clone_identity 照抄时也是这么跳的，两边口径要一致，
    否则源字体里一条坏记录会被报成「产物少了一条」。
    """
    out = {}
    for r in font["name"].names:
        if r.nameID not in util.IDENTITY_NAME_IDS:
            continue
        try:
            out[(r.nameID, r.platformID, r.platEncID, r.langID)] = r.toUnicode()
        except Exception:
            continue
    return out


def identity_problems(font, real):
    """身份字段有没有照抄到位 —— 系统就是靠这几项认字体的。

    比的是产物和它冒充的那个系统字体，【全部平台 / 编码 / 语言】逐条对齐，
    一条不多一条不少。不能只抽查英文(0x409)和中文(0x804)那两条：真
    segoeui.ttf 光 nameID 2 就带 25 种语言，只抽两条的话，本地化记录被整批
    丢掉也照样报「通过」。
    """
    got, want = identity_records(font), identity_records(real)
    out = []
    for k in sorted(set(got) & set(want))[:200]:
        if got[k] != want[k]:
            out.append("nameID %d (plat %d/%d, lang %#x) 是 %r，应为 %r"
                       % (k + (got[k], want[k])))
    for label, gap, src in (("少", sorted(set(want) - set(got)), want),
                            ("多", sorted(set(got) - set(want)), got)):
        if gap:
            k = gap[0]
            out.append("%s了 %d 条 name 记录，例如 nameID %d (plat %d/%d, lang %#x) = %r"
                       % ((label, len(gap)) + k + (src[k],)))
    return out


def missing_chars(font, chars):
    cm = font.getBestCmap()
    return "".join(c for c in chars if ord(c) not in cm)


def present_chars(font, chars):
    cm = font.getBestCmap()
    return "".join(c for c in chars if ord(c) in cm)


def italic_problem(font, outname):
    """名字里带 Italic 的产物，post.italicAngle 必须非零。

    这是整套流程里最容易静默失败的一条。斜体产物的身份字段 —— 族名、样式名、
    head.macStyle 的斜体位、OS/2.fsSelection —— 全是从真的 segoeui*i.ttf 整段
    照抄的，轮廓有没有真的斜过，它们一个字都反映不出来；文件名更是照样叫
    Italic。所以 oblique() 漏调、异常被吞、复合字形那条分支走空，上面那几条
    自检没有一条会响。italicAngle 是唯一跟着轮廓走的字段：真斜体源自带、伪斜
    由 oblique() 写上，两条路都该有值。

    本模块只看产物、不读 source\\，所以这里不区分真斜和伪斜 —— 也不用区分，
    不变式是「斜过了」，怎么斜的不是。
    """
    if not util.is_italic(outname):
        return None
    if not font["post"].italicAngle:
        return ("post.italicAngle 是 0 —— 名字叫 Italic，轮廓却没斜过"
                "（源字体的真斜体没设这个字段？还是算法伪斜没跑成？）")
    return None


def hint_zero_note(outname):
    """hint=0 到底是谁丢的 —— 光看产物分不出来，把可能的原因都摆出来。

    正体产物只有一种可能：源字体本来就不带指令。斜体产物多一种：算法伪斜
    会主动把指令丢掉（见 util.oblique() —— 指令是照正体坐标写的，留着会把
    剪斜的竖笔又掰回竖直）。两者都只是「小字号发虚」，所以仍然是 warn。
    """
    if util.is_italic(outname):
        return "源字体本来就不带，或者这是算法伪斜体、指令在伪斜时被丢掉了"
    return "源字体不带指令"


def hint_bytes(font, probe=DENSE):
    """probe 里那些字形上，平均每个带多少字节的指令。0 = 没有 hinting。

    probe 得挑这个字体确实覆盖的字符 —— 一个都没命中同样返回 0，和「有字形
    但不带指令」分不开。中文族用 DENSE，拉丁族用 DENSE_LATIN。
    """
    if "fpgm" not in font:
        return 0
    cm, glyf = font.getBestCmap(), font["glyf"]
    n = tot = 0
    for ch in probe:
        gn = cm.get(ord(ch))
        if not gn:
            continue
        g = glyf[gn]
        tot += len(g.program.getBytecode()) if hasattr(g, "program") else 0
        n += 1
    return tot // n if n else 0


def gasp_problem(font):
    """每一档都得带 DOGRAY 和 SYMMETRIC_SMOOTHING，缺了返回原因。"""
    if "gasp" not in font:
        return "没有 gasp"
    rng = font["gasp"].gaspRange
    for flag, tag, why in ((GASP_DOGRAY, "DOGRAY", "那一段会变黑白锯齿"),
                           (GASP_SYM_SMOOTHING, "SYMMETRIC_SMOOTHING",
                            "那一段会走 GDI Classic")):
        bad = sorted(p for p, f in rng.items() if not f & flag)
        if bad:
            return "gasp 有不带 %s 的档 (≤%s ppem)，%s" % (
                tag, ",".join(str(p) for p in bad), why)
    return None


def fmt_gasp(font):
    if "gasp" not in font:
        return "-"
    return "{%s}" % ",".join("%d:%d" % (p, f)
                             for p, f in sorted(font["gasp"].gaspRange.items()))


def stem_width(font):
    """大写 I 的字面宽度，约等于竖笔宽度。用来一眼看出各档字重确实不一样。

    斜体不算：斜过之后 I 的外框宽是竖笔加上倾斜量（一个 700 单位高的 I 斜
    12° 就凭空宽出 148），量出来虚高，跟正体那几档没法比。

    判断「是不是斜体」靠的就是 italicAngle —— 真斜体源自带、伪斜由
    oblique() 写上，两条路都有值，所以这条短路是可靠的。反过来说，万一哪个
    斜体产物没设 italicAngle，这里就会当成正体去量，报出一个虚高的竖笔宽 ——
    那是 italic_problem() 拦的那个 bug 的另一个症状，不是两回事。
    """
    try:
        if font["post"].italicAngle:
            return 0
        g = font["glyf"][font.getBestCmap()[0x49]]
        return g.xMax - g.xMin
    except Exception:
        return 0


def stray_files(outdir, expected):
    """目录里有没有不该在的字体文件，多半是改过文件名之后剩下的旧产物。"""
    if not os.path.isdir(outdir):
        return []
    have = set(f for f in os.listdir(outdir)
               if f.lower().endswith((".ttf", ".ttc")))
    return sorted(have - set(expected))


# ------------------------------------------------------------------ 中文族
def verify_cjk(targets, outdir):
    """CJKMod\\：必须有汉字、有符号，身份和被冒充的系统字体逐项对得上。"""
    fails, warns = [], []
    log("")
    log("自检 CJKMod\\ —— 应有汉字 + 符号 + hinting")

    for name in stray_files(outdir, [t[0] for t in targets]):
        fails.append("CJKMod\\%s 不在产物清单里（旧文件？）" % name)

    for outname, _chain, faces_spec, _reg in targets:
        path = os.path.join(outdir, outname)
        if not os.path.exists(path):
            fails.append("%s 不存在" % outname)
            log("  [缺失] %s" % outname)
            continue
        try:
            fonts = open_faces(path)
        except Exception as e:
            # 文件在但读不开（截断了、或者 ttc/ttf 弄反了）
            fails.append("%s 打不开: %s" % (outname, e))
            log("  [坏文件] %s" % outname)
            continue
        try:
            if len(fonts) != len(faces_spec):
                fails.append("%s 有 %d 个 face，应该是 %d"
                             % (outname, len(fonts), len(faces_spec)))
            for i, font in enumerate(fonts):
                if i >= len(faces_spec):
                    break
                realname, idx, keep = faces_spec[i]
                label = "%s face%d" % (outname, i)
                bad = []

                real = util.open_system_font(realname, idx, lazy=True)
                try:
                    bad += identity_problems(font, real)
                finally:
                    real.close()

                gone = missing_chars(font, HANZI)
                if gone:
                    bad.append("缺汉字 %s" % gone)

                if keep:
                    # 原样搬运的真字体，有自己的点阵和分档，不按我们的规矩查
                    note = "原样搬运"
                else:
                    hb = hint_bytes(font)
                    gone = missing_chars(font, PROBE)
                    if gone:
                        bad.append("缺符号 %s" % gone)
                    g = gasp_problem(font)
                    if g:
                        bad.append(g)
                    it = italic_problem(font, outname)
                    if it:
                        bad.append(it)
                    if hb == 0:
                        warns.append("%s 没有 hinting 指令（%s）—— "
                                     "小字号汉字的横画会粘连"
                                     % (label, hint_zero_note(outname)))
                    note = "gasp %-14s hint %dB" % (fmt_gasp(font), hb)

                fails += ["%s %s" % (label, b) for b in bad]
                # 族名放最后：中文是双宽字符，夹在中间会把后面的列全顶歪
                zh = name_of(font, 1, 0x804)
                log("  %s %-30s face%d  %6d 字形  %-30s  %s%s"
                    % ("OK " if not bad else "!! ", outname, i,
                       font["maxp"].numGlyphs, note, name_of(font, 1) or "?",
                       " / " + zh if zh else ""))
        finally:
            for f in fonts:
                f.close()
    return fails, warns


# ------------------------------------------------------------------ 拉丁族
def verify_segoe(styles, outdir):
    """SegoeUIMod\\：不变式反过来 —— 汉字必须已经裁掉，交给回退。"""
    fails, warns = [], []
    log("")
    log("自检 SegoeUIMod\\ —— 汉字应已裁掉，交给回退落到 CJKMod")

    for name in stray_files(outdir, [s[0] for s in styles]):
        fails.append("SegoeUIMod\\%s 不在产物清单里（旧文件？）" % name)

    for outname, realname, _chain, _reg in styles:
        path = os.path.join(outdir, outname)
        if not os.path.exists(path):
            fails.append("%s 不存在" % outname)
            log("  [缺失] %s" % outname)
            continue
        try:
            font = TTFont(path, lazy=True)
        except Exception as e:
            fails.append("%s 打不开: %s" % (outname, e))
            log("  [坏文件] %s" % outname)
            continue
        with font:
            bad = []
            real = util.open_system_font(realname, lazy=True)
            try:
                bad += identity_problems(font, real)
            finally:
                real.close()

            left = present_chars(font, HANZI)
            if left:
                bad.append("还留着汉字 %s —— 中文不会回退到 CJKMod 那一套" % left)
            g = gasp_problem(font)
            if g:
                bad.append(g)
            it = italic_problem(font, outname)
            if it:
                bad.append(it)
            hb = hint_bytes(font, DENSE_LATIN)
            if hb == 0:
                warns.append("%s 没有 hinting 指令（%s）—— "
                             "小字号的拉丁笔画会糊"
                             % (outname, hint_zero_note(outname)))

            fails += ["%s %s" % (outname, b) for b in bad]
            log("  %s %-30s %-20s %-12s %5d 字形  wc=%-4d 竖笔=%-4s hint %-5s gasp %s"
                % ("OK " if not bad else "!! ", outname,
                   name_of(font, 1) or "?", name_of(font, 2) or "-",
                   font["maxp"].numGlyphs, font["OS/2"].usWeightClass,
                   stem_width(font) or "-", "%dB" % hb, fmt_gasp(font)))
    return fails, warns


def report(fails, warns=()):
    """打印自检结论。有失败就非零退出。"""
    log("")
    for w in warns:
        log("注意: %s" % w)
    if fails:
        log("自检失败 %d 项：" % len(fails))
        for m in fails:
            log("  - %s" % m)
        raise SystemExit(1)
    log("自检通过。")


def main():
    # 放在函数里 import：这两个模块反过来也要 import 本模块
    import make_cjk
    import make_segoe_ui

    f1, w1 = verify_segoe(make_segoe_ui.STYLES, make_segoe_ui.OUTDIR)
    f2, w2 = verify_cjk(make_cjk.TARGETS, make_cjk.OUTDIR)
    report(f1 + f2, w1 + w2)


if __name__ == "__main__":
    main()
