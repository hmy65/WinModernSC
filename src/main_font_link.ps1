# 机制 4：FontLink\SystemLink，GDI 的中文回退链。
#
# Segoe UI 那 12 个静态文件的汉字被裁掉了（拉丁归它，汉字归中文族），
# SegoeUI-Variable.ttf 从静态源合成时同样是裁到真 SegUIVar 覆盖面、不带汉字。
# GDI 程序拿它们显示中文全靠这张表。可系统自带的链是按【文件名】写的：
#     MSYH.TTC,Microsoft YaHei UI
# GDI 会直接去 %windir%\Fonts 拿原版雅黑，【绕过】机制 1 改的 Fonts 注册项 ——
# 于是 DirectWrite 那边是新字体、GDI 这边是原版雅黑，同一屏两套中文。
# 办法是在这些拉丁族的链最前面插指向我们文件的行（带缩放参数那条 + 不带的
# 那条，和原链一个形状），两边就统一了。
#
# 一共 20 个族：静态那 5 个（下面 $LinkFaces），加上可变字体 Segoe UI Variable
# 被 STAT 拆出来的 15 个（3 档光学尺寸 × 5 档字重，见 $VarWeightCuts）。

# 键名是【GDI 家族名】，也就是 GetTextFace 返回的那个，不是"族名 + 字重"。
#
# 注册表里另有 Segoe UI Bold / Meiryo Bold / Nirmala UI Bold 这类值，看着像
# 「粗体单独一条链」，但 GDI 不从那儿查。Win11 26200 实测（原始 GDI 渲染
# U+4E2D 比对点阵）：
#     CreateFont("Segoe UI", FW_BOLD) 拉丁拿到的是真 segoeuib.ttf（H 的竖笔
#     3px->5px、横杠 2 行->5 行，是真字形），中文却是 "Segoe UI" 这条链里的
#     MSYH 再【合成加粗】—— 竖笔 3px->4px、横笔仍是 3 行；真 MSYHBD 是竖笔
#     5px、横笔 5 行，完全不是一回事。把 lfFaceName 直接写成 "Segoe UI Bold"
#     也一样。Nirmala UI 拿来对照，w=700 的点阵和 Segoe UI w=700 逐字节相同。
# 所以往 Segoe UI Bold 里写是死键，白占一个 HKLM 值和一条备份。粗体中文由 GDI
# 从我们这条链合成，和正文同一套字，不会出现两套中文。
#
# 值 = 这一族的中文该挂哪一档，写成 Fonts 键里的值名（机制 1 改的就是它们）
# 加 TTC 里 face1 的全名。三件事都要对：
#   · 字重要对上。Segoe UI Light 是独立 GDI 家族（tmWeight=300），它自己那条链
#     确实被查，原链挂的是 MSYHL；塞 Regular 进去就成了细拉丁配常规粗细的中文。
#   · Semilight 原链用 Regular 档（雅黑没这一档），照抄，不自作主张。
#   · Semibold 原链也是 Regular 档，但这里【不】照抄，挂 make_cjk.py 派生的那档
#     雅黑 Semibold。Win11 26200 实测（ClearType 渲染比对点阵）：
#     "Segoe UI Semibold" 的 lfWeight 从 400 写到 700，拉丁都是真 Semibold，
#     中文却和 "Segoe UI" 400 逐像素相同 —— GDI 不给回退来的中文合成加粗。
#     照抄的话，GDI 程序点名要 "Segoe UI Semibold" 时就只加粗了拉丁。
#     （机制 3 的 -window-metrics-weight Semibold 不在此列：它直接挂
#     "Microsoft YaHei UI Semibold"，中文不过这条链，见 main_window_metrics.ps1。
#     这条链仍然要有 —— 程序自己请求 "Segoe UI Semibold" 走的还是它。）
#   · face 名用 "Microsoft YaHei UI" 系列 —— 全表其它链都这么写，那也正是我们
#     TTC 里 face1 的 nameID 4。
#   · Segoe UI Black 系统压根没给链（全表 83 个值名里没有 Black），Windows 自己
#     的默认回退把它落到【原版】SIMSUN.TTC（点阵和 SimSun 直接渲染逐字节相同），
#     正是机制 1 绕不过去的那种。这里给它挂 Bold 档：Black 是 900，配常规粗细
#     的中文明显偏细。
#
# ScaleFrom：缩放后缀从原链里哪个 face 的那一行抄，缺省就是 Face 自己。只有
# Semibold 用得上 —— 原链里没有 "Microsoft YaHei UI Semibold"，被顶掉的是
# Regular 那一行，后缀照它抄（见 Get-LinkScaleSuffix）。
$YaHeiSemibold = @{ Reg       = 'Microsoft YaHei Semibold & Microsoft YaHei UI Semibold (TrueType)'
                    Face      = 'Microsoft YaHei UI Semibold'
                    ScaleFrom = 'Microsoft YaHei UI' }
$LinkFaces = [ordered]@{
    'Segoe UI'           = @{ Reg  = 'Microsoft YaHei & Microsoft YaHei UI (TrueType)'
                              Face = 'Microsoft YaHei UI' }
    'Segoe UI Light'     = @{ Reg  = 'Microsoft YaHei Light & Microsoft YaHei UI Light (TrueType)'
                              Face = 'Microsoft YaHei UI Light' }
    'Segoe UI Semilight' = @{ Reg  = 'Microsoft YaHei & Microsoft YaHei UI (TrueType)'
                              Face = 'Microsoft YaHei UI' }
    'Segoe UI Semibold'  = $YaHeiSemibold
    'Segoe UI Black'     = @{ Reg  = 'Microsoft YaHei Bold & Microsoft YaHei UI Bold (TrueType)'
                              Face = 'Microsoft YaHei UI Bold' }
}

# ---------------------------------------------------------------- 可变字体那一族
# Segoe UI Variable 不是一个 GDI 家族，是 15 个：DirectWrite 按 STAT 把它拆成
# 光学尺寸 3 档 × 字重 5 档，每一档都是独立的 GDI 家族名，各有各的 SystemLink。
# 这 15 条系统自带（Win11 26200 实测全在），指向的都是裸文件名 MSYH*.TTC ——
# 和静态那 5 个族一模一样的问题：GDI 会绕过机制 1 改的 Fonts 项，直接去
# %windir%\Fonts 拿原版雅黑。产物是 DirectWrite 那边新字体、GDI 这边原版雅黑。
#
# 【为什么非补不可】：STATIC 源合成出来的 SegoeUI-Variable.ttf 是裁到真
# SegUIVar 覆盖面的，一个汉字都没有（和那 12 个静态文件同一个道理），GDI 程序
# 拿它显示中文全靠这张表。源本身是可变字体时产物带汉字，走不到这几行，插了也
# 只是多几行不生效的，没有代价。
#
# 挂哪一档和静态那 5 个族的规矩一致：照抄原链（实测每一条都对得上），
# Semibold 例外，理由同上：
#     无后缀 / Semilight -> MSYH.TTC   Microsoft YaHei UI
#     Light              -> MSYHL.TTC  Microsoft YaHei UI Light
#     Bold               -> MSYHBD.TTC Microsoft YaHei UI Bold
#     Semibold           -> 派生的雅黑 Semibold（原链是 MSYH.TTC）
# 缩放后缀不写死，Get-LinkScaleSuffix 按 face 名从原链里抄（这 15 条原链的
# 雅黑行全都带 ,128,96，抄出来就是它）。
$VarWeightCuts = [ordered]@{
    ''          = @{ Reg  = 'Microsoft YaHei & Microsoft YaHei UI (TrueType)'
                     Face = 'Microsoft YaHei UI' }
    'Light'     = @{ Reg  = 'Microsoft YaHei Light & Microsoft YaHei UI Light (TrueType)'
                     Face = 'Microsoft YaHei UI Light' }
    'Semilight' = @{ Reg  = 'Microsoft YaHei & Microsoft YaHei UI (TrueType)'
                     Face = 'Microsoft YaHei UI' }
    'Semibold'  = $YaHeiSemibold
    'Bold'      = @{ Reg  = 'Microsoft YaHei Bold & Microsoft YaHei UI Bold (TrueType)'
                     Face = 'Microsoft YaHei UI Bold' }
}

# GDI 家族名最长 31 个字符：LOGFONT.lfFaceName 是 LF_FACESIZE = 32 个 WCHAR，
# 含结尾的 NUL。超出的直接截断，注册表里那几个看着像打错字的值名就是这么来的：
#     "Segoe UI Variable Display Semibold" -> "Segoe UI Variable Display Semib"
#     "Segoe UI Variable Small Semilight"  -> "Segoe UI Variable Small Semilig"
# 按同一条规则拼出来的 15 个名字和 Win11 自带的那 15 个值名逐字相同（实测）。
# 万一以后的 Windows 改了命名，这里拼出来的就成了 15 个没人查的新值 —— 备份
# 里记成「原本不存在」，-revert 时删掉，不留残渣。和 Segoe UI Black 那条本来
# 就不存在的值是同一个处理方式。
$LF_FACESIZE = 31

function Get-GdiFaceName([string]$name) {
    if ($name.Length -le $LF_FACESIZE) { return $name }
    return $name.Substring(0, $LF_FACESIZE)
}

foreach ($size in @('Small', 'Text', 'Display')) {
    foreach ($cut in $VarWeightCuts.Keys) {
        $full = ('Segoe UI Variable {0} {1}' -f $size, $cut).Trim()
        $spec = $VarWeightCuts[$cut]
        $LinkFaces[(Get-GdiFaceName $full)] = @{ Reg = $spec.Reg; Face = $spec.Face
                                                 ScaleFrom = $spec.ScaleFrom }
    }
}

# 我们自己装的字体一律落在 $TargetDir 下。插入和剔除都按这一条判定 ——
# Fonts 键里还是裸文件名（msyh.ttc）就说明机制 1 没装过。
function Test-OurFontFile([string]$s) {
    return ($s -like "$TargetDir\*")
}

# 原链里被我们顶掉的那条带一对数字：MSYH.TTC,Microsoft YaHei UI,128,96。
# 实测（Win11 26200，GDI GetTextExtentPoint32W，lfHeight=-960）：
#   Segoe UI 基准 -> MSYH 那条【带】数字：U+4E2D 宽 1008，直接请求
#     Microsoft YaHei UI 是 960，即被链字体放大到 1.05 倍；
#   同一条链里 SEGUISYM.TTF,Segoe UI Symbol【不带】数字：U+2665 宽 657，
#     和直接请求逐像素相同，1.00 倍；
#   Tahoma 基准 -> SIMSUN.TTC,SimSun【不带】数字：也是 1.00 倍，而两者的
#     usWin 框差了 20%（1.20703 vs 1.00000）—— 所以不是「不带数字也会按度量
#     缩放」，是【带数字才开这个开关】。
# 放大多少由两边的纵向度量决定，不是这对数字本身算出来的：同样是 128,96，
# Segoe UI 挂 MALGUN.TTF（usWin 框和 Segoe UI 一样是 1.33008）实测正好
# 1.0000。具体公式没查出来，也不需要 —— 照抄被顶掉那条的后缀就行。
#
# 顺带：我们的 TTC 经 clone_metrics 之后 usWin 框是 1.32000，本来就贴着
# Segoe UI 的 1.33008，所以补上数字之后拿到的倍数在 1.008 上下，不是雅黑那
# 5%。那 5% 是给雅黑 1.27002 的矮框做的补偿，我们不需要 —— 补数字是为了把
# 尺寸匹配交还给 GDI，而不是靠 clone_metrics 碰巧对上。
function Get-LinkScaleSuffix([string[]]$Existing, [string]$Face) {
    foreach ($l in $Existing) {
        $p = $l -split ','
        # 注册表里 Jhenghei / JhengHei 大小写不统一，-eq 默认忽略大小写，正好。
        if ($p.Count -gt 2 -and $p[1].Trim() -eq $Face) {
            return ',' + ($p[2..($p.Count - 1)] -join ',')
        }
    }
    return ''
}

# 拼一个族的新链：我们那条打头，原来的链原样接在后面。
#
# 【保留原链】。系统默认那条不只管简体中文，还带着繁体(MSJH/MingLiU)、
# 日文(Meiryo/MS Gothic/Yu Gothic)、韩文(Malgun/Gulim)和 Segoe UI Symbol，
# 顺序和 ,128,96 那些缩放参数也是调过的 —— 整条覆盖掉，这些文字的字体和大小
# 就全变了。
#
# （但别把理由说成「覆盖了这些字就没字体」—— 那是不对的。实测：链走完 GDI
#  不会放弃，后面还有它自己一套默认回退。"Microsoft YaHei UI" 那条链里没有
#  任何带天城文/泰文/希伯来文/格鲁吉亚文的字体，U+0915/U+0E01/U+05D0/U+10A0
#  照样渲染得出来。丢的是顺序和缩放，不是有无。）
#
# 我们那条只在 Fonts 键指向 $TargetDir 时才插：没装过机制 1 就该什么都不做。
# 真插进去反而有害 —— 裸文件名拼出来的 "msyh.ttc,Microsoft YaHei UI" 和原链
# 第 3 行大小写无关地相等，会被下面的去重顶到第 1 位，把 Tahoma 和 ,128,96
# 那两行的顺序打乱。
# 格式是 REG_MULTI_SZ，每行 "文件,族名"，按顺序往下试，文件缺失就跳到下一条。
function Get-CjkLinkTargets([string]$Face, [string[]]$Existing) {
    $spec = $LinkFaces[$Face]
    $out = @()

    # 先把原链里【上一趟我们自己写进去的】那些行剔掉。重复跑、或者像
    # Segoe UI Light 那样换了字重档之后，旧行还留在链里，正确那条一缺字就会
    # 退到它，等于改了个寂寞。判定按 $TargetDir 前缀，所以 Copy-FontFile 撞上
    # 文件占用改出来的时间戳文件名（WinModernSC-YaHei.20250910120000.ttc）
    # 一样抓得住，不会攒下死行。
    $stock = @($Existing | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and -not (Test-OurFontFile $_)
    })

    $file = [string](Get-RegValueOrNull $FontsKey $spec.Reg)
    if ($file -and (Test-OurFontFile $file)) {
        # 缩放后缀只从【原链】里抄，不看我们上一趟写的 —— 否则抄错一次就会
        # 自我延续，而且从旧版本（不写后缀）升上来时也补不回去。
        $suffix = Get-LinkScaleSuffix $stock $(if ($spec.ScaleFrom) { $spec.ScaleFrom } else { $spec.Face })
        # Segoe UI Black 本来就没这个值，没得抄。全表 83 个值名里，Segoe UI
        # 各档挂 Microsoft YaHei UI 各档用的都是 128,96，无一例外，照这个给它
        # —— 唯一的一条反而不开缩放说不过去。
        if (-not $suffix -and -not $stock) { $suffix = ',128,96' }
        $out += ('{0},{1}{2}' -f $file, $spec.Face, $suffix)
        # 带数字那条后面再跟一条不带的。原链里每一条带 ,128,96 的下面都跟着
        # 一条同文件同 face 不带数字的（全表统一如此），照抄这个形状，不自作
        # 主张。前一条能覆盖的字它永远走不到，多一行而已。
        if ($suffix) { $out += ('{0},{1}' -f $file, $spec.Face) }
    }

    # 原链接在后面
    $out += $stock

    # 去重。大小写按 Windows 的规矩忽略。
    $seen = @{}
    return @($out | Where-Object {
        $k = $_.ToLowerInvariant()
        if ($seen.ContainsKey($k)) { $false } else { $seen[$k] = $true; $true }
    })
}

# 拼好的链里我们那一条（没插上就是 $null）。空数组取 [0] 在 PowerShell 里是
# $null，不会抛。
function Get-OurLinkLine([string[]]$Chain) {
    return @($Chain | Where-Object { Test-OurFontFile $_ })[0]
}

function Show-FontLinkPlan {
    Write-Host ''
    Write-Host ('=== 机制 4  FontLink\SystemLink，{0} 个拉丁族各插两条 ===' -f $LinkFaces.Count) -ForegroundColor Yellow
    $first = $true
    $none = 0
    foreach ($face in $LinkFaces.Keys) {
        $cur = Get-RegValueOrNull $FontLinkKey $face
        $new = Get-CjkLinkTargets $face $cur
        $ours = Get-OurLinkLine $new
        # 列宽 31 = GDI 家族名的上限（LF_FACESIZE - 1），可变字体那 15 个正好
        # 顶到这个长度，窄了会把后面的列全顶歪。
        Write-Host ('  {0,-31} : {1,2} 条  ->  {2,2} 条' -f $face,
                    $(if ($null -eq $cur) { 0 } else { @($cur).Count }), $new.Count)
        $ourLines = @($new | Where-Object { Test-OurFontFile $_ })
        if ($ours) {
            foreach ($l in $ourLines) {
                Write-Host ('      新增 {0}' -f $l) -ForegroundColor Gray
            }
        } else {
            $none++
            Write-Host '      没有可插入的行，这一族保持原样，不写' -ForegroundColor DarkGray
        }
        if ($first -and $new.Count -gt 1) {
            # 只跳过我们自己写进去的那几条。没插的时候第 1 行是原链自己的，
            # 跳掉它等于对着人少报一行（比如 Segoe UI 的 TAHOMA.TTF,Tahoma）。
            $rest = if ($ours) { @($new | Select-Object -Skip $ourLines.Count) } else { $new }
            Write-Host $(if ($ours) { '      其余原样保留：' } else { '      这一族当前的链：' }) -ForegroundColor DarkGray
            foreach ($l in $rest) {
                Write-Host ("        $l") -ForegroundColor DarkGray
            }
            $first = $false
        }
    }
    if ($none) {
        Write-Host ('  注：{0} 个族取不到 {1} 下的文件 —— 机制 1 还没装过，那几档雅黑的' -f $none, $TargetDir) -ForegroundColor DarkGray
        Write-Host '        Fonts 项还是裸文件名。机制 1 装完再看就有了。' -ForegroundColor DarkGray
    }
}

function Invoke-FontLinkApply {
    if (-not (Test-Path $FontLinkKey)) { New-Item -Path $FontLinkKey -Force | Out-Null }

    # --- 备份。已备份过的原值绝不覆盖，只补录这次新增的族名。
    #     跳过没写的族也照样记 —— 记的是 $null，还原时按「删除」处理，代价为零。
    $bk = Read-BackupFile
    if ($null -eq $bk) { $bk = [pscustomobject]@{} }
    $link = Get-MapValue $bk 'FontLink'
    if ($null -eq $link) {
        Set-MapValue $bk 'FontLink' ([ordered]@{})
        $link = Get-MapValue $bk 'FontLink'
    } else {
        Write-Host 'FontLink 备份已存在，保留原值。' -ForegroundColor DarkGray
    }
    $known = @(Get-MapKeys $link)
    foreach ($face in $LinkFaces.Keys) {
        if ($known -notcontains $face) { Set-MapValue $link $face (Get-RegValueOrNull $FontLinkKey $face) }
    }
    Write-BackupFile $bk        # 先落盘再写注册表
    Write-Host ("已备份 {0} 条 SystemLink -> {1}" -f @(Get-MapKeys $link).Count, $Backup) -ForegroundColor Yellow

    $wrote = 0
    foreach ($face in $LinkFaces.Keys) {
        # 每个族的原链不一样，逐个读、逐个拼
        $chain = Get-CjkLinkTargets $face (Get-RegValueOrNull $FontLinkKey $face)
        $ours = Get-OurLinkLine $chain
        if (-not $ours) {
            # 机制 1 没装过。原链原样留着别动；Segoe UI Black 本来就没这个值，
            # 更不能凭空建一条只有原链残渣、甚至是空的出来。
            Write-Host ("[FontLink] {0,-31} 跳过（机制 1 未安装，没有可插入的行）" -f $face) -ForegroundColor DarkGray
            continue
        }
        Set-ItemProperty -Path $FontLinkKey -Name $face -Value $chain -Type MultiString
        $script:WroteSomething = $true
        $wrote++
        Write-Host ("[FontLink] {0,-31} {1,2} 条，首行 {2}" -f $face, $chain.Count, $ours) -ForegroundColor Green
    }
    return $wrote
}
