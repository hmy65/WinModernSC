# 机制 3：WindowMetrics，经典界面(comctl32)那一层。
#
# 传统 Win32 控件的字体既不看 Fonts 也不看 FontSubstitutes —— 是系统主动通过
#   SystemParametersInfo(SPI_GET/SET NONCLIENTMETRICS)  5 个 LOGFONTW + 10 个几何值
#   SystemParametersInfo(SPI_GET/SET ICONTITLELOGFONT)  第 6 个 LOGFONTW
# 发给应用的，并落盘在 <用户>\Control Panel\Desktop\WindowMetrics（6 个 92 字节
# REG_BINARY 就是这 6 个 LOGFONTW）。
#
# 前两套机制只能做「家族名替换」，改不了字号 / 字重 / 渲染质量，也改不了
# 标题栏、菜单、滚动条的几何尺寸 —— 那些都在这一层。
# 这一层是【每用户】的，所以要遍历所有用户配置单元。
# 挂的族名也和前两套不一样：这里写中文族 "Microsoft YaHei UI"，理由见下面 $YaHei。
#
# 显示缩放一变，Windows 会在下次登录时把这一层重置回默认。字号或字重非默认时这会
# 丢东西，所以还登记了一个登录脚本负责写回去（默认 9pt Regular 不装，理由见文末
# 「登录自动恢复」）。那个脚本（logon_window_metrics.ps1）单独 dot-source 本文件，
# 那边没有 main.ps1，只补了 $SUB、两个 window-metrics 参数（三个都由 Run 那行命令传
# 给它）和 Get-MapValue。它用到的 Test-MetricsInRegistry、Test-MetricsInSession、
# Update-MetricsHive -BackupOnly、Set-MetricsViaSpi，连同这几个往下调的函数，都不能再
# 依赖 main.ps1 里别的 helper。

# 这一层挂的中文族名，GDI 家族名。机制 4 的回退链挂的也是它（main_font_link.ps1 里
# 那些 'Microsoft YaHei UI ...' 字面量），zh-CN 版 Windows 重置这一层时也落回它。
# 不跟着 main.ps1 的 $SUB 走，所以写死在这儿：$SUB 是「GDI 替换的目标族」那个旋钮，
# 这里要的是「Windows 自己的经典界面默认族」，两者不是一回事。
$YaHei = 'Microsoft YaHei UI'

# -window-metrics-weight 的字重名 -> 写进 LOGFONT 的 (lfFaceName, lfWeight)。
#
# 这一层挂的是【中文族名】"Microsoft YaHei UI"，不是前两套机制那个 "Segoe UI"。
# 理由是这一层和别的层不一样 —— 它有个 Windows 自己认定的默认值，而且会被强制写回：
#   · zh-CN 版 Windows 的经典界面默认就是 Microsoft YaHei UI，显示缩放一变，Windows
#     也是把这 6 项重置回这个族（见文末「登录自动恢复」）。挂同一个族，装完的状态
#     和系统默认状态就是一回事，重置只会丢字号字重，不会再出现「装完是 Segoe UI、
#     缩放改过之后变 Microsoft YaHei UI」这两种外观。
#   · 中文直接来自这一族的文件，不必再过 FontLink\SystemLink（机制 4）那条回退链，
#     也就没有链上那个 128,96 的缩放。
#   · Bold 拿到的是真 Bold 文件：Win11 26200 实测 msyhl/msyh/msyhbd 三个 ttc 的
#     usWeightClass 是 290/400/700，"Microsoft YaHei UI" 这个 GDI 家族里 400 和 700
#     都是真文件（EnumFontFamiliesEx 确认）。走 "Segoe UI" 时中文是雅黑合成加粗。
# 机制 1 把这几档雅黑全指向了我们的文件，所以挂中文族名拿到的仍然是源字体；反过来说，
# 【没装机制 1 的话这一层等于没换】，和挂 Segoe UI 时是一个道理。
#
# 换字重换的仍然是【家族名】，不是 lfWeight：GDI 先按 lfFaceName 找家族、再在家族里
# 挑文件。雅黑这边 Light 和 Semibold 各自是独立家族，Regular / Bold 共用一个家族、
# 靠 lfWeight 区分。lfWeight 写该文件真实的 usWeightClass —— GDI 下写不写真值画出来
# 一样，但 GetTextMetrics 报回来的就是真值，WPF 这类单独读 lfWeight 的程序
# （SystemFonts.MessageFontWeight）也就读得对。所以 Light 写 290 不是 300。
#
# Semilight 和 Black 例外，仍旧挂 "$SUB ..."：雅黑没有这两档，换过去会把拉丁的这两个
# 字重一起丢掉（拉丁退成 Regular / Bold）。它们的中文照旧走机制 4 的回退链 ——
# Semilight -> 雅黑 Regular，Black -> 雅黑 Bold，和那边的挂法一致。
# 雅黑 Semibold 是 make_cjk.py 派生出来的那一档（Windows 本来没有），face1 的族名
# 就叫 "Microsoft YaHei UI Semibold"，机制 4 的回退链挂的也是它。
#
# 斜体那 6 个不在这里：界面文字不能是斜的，Set-LogFontFields 也会把 lfItalic 清零。
# 名字和 main.ps1 里 -window-metrics-weight 的 ValidateSet 一一对应。
$MetricsWeights = [ordered]@{
    Light     = @{ Face = "$YaHei Light";    Weight = 290 }
    Semilight = @{ Face = "$SUB Semilight";  Weight = 350 }
    Regular   = @{ Face = $YaHei;            Weight = 400 }
    Semibold  = @{ Face = "$YaHei Semibold"; Weight = 600 }
    Bold      = @{ Face = $YaHei;            Weight = 700 }
    Black     = @{ Face = "$SUB Black";      Weight = 900 }
}
if (-not $MetricsWeights.Contains(${window-metrics-weight})) {
    throw "字重表里没有 ${window-metrics-weight}，和 main.ps1 的 ValidateSet 对不上了。"
}

$MetricsFace    = $MetricsWeights[${window-metrics-weight}].Face
$MetricsWeight  = $MetricsWeights[${window-metrics-weight}].Weight
$MetricsSize    = ${window-metrics-size}   # 磅
$MetricsCharSet = 1         # 1 = DEFAULT_CHARSET
$MetricsQuality = 5         # 5 = CLEARTYPE_QUALITY

# 结构偏移，Windows 11 26200 上实测确认：
#   NONCLIENTMETRICSW = 504 字节
#       0 cbSize            4 iBorderWidth     8 iScrollWidth    12 iScrollHeight
#      16 iCaptionWidth    20 iCaptionHeight  24 lfCaptionFont(92)
#     116 iSmCaptionWidth 120 iSmCaptionHeight 124 lfSmCaptionFont(92)
#     216 iMenuWidth      220 iMenuHeight     224 lfMenuFont(92)
#     316 lfStatusFont(92) 408 lfMessageFont(92) 500 iPaddedBorderWidth
#   LOGFONTW = 92 字节
#       0 lfHeight  16 lfWeight  20 lfItalic  21 lfUnderline  22 lfStrikeOut
#      23 lfCharSet 26 lfQuality 28 lfFaceName(32 个 WCHAR)
$NCM_SIZE      = 504
$LF_SIZE       = 92
$MetricsSubKey = 'Control Panel\Desktop\WindowMetrics'

# 界面上那 6 处文字 -> WindowMetrics 里的值名
$MetricsRoles = [ordered]@{
    CaptionFont   = '标题栏'
    IconFont      = '追随图标的文字'
    SmCaptionFont = '调色板标题'
    StatusFont    = '当前焦点文字(状态栏/提示)'
    MessageFont   = '对话框'
    MenuFont      = '菜单'
}
# 其中 5 个在 NONCLIENTMETRICSW 里的偏移；IconFont 是独立的一个 API
$NcmFontOffset = [ordered]@{
    CaptionFont   = 24
    SmCaptionFont = 124
    MenuFont      = 224
    StatusFont    = 316
    MessageFont   = 408
}
# 注册表里跟着联动的两个标量（存的是负 twip，1 英寸 = 1440 twip）
$NCM_OFF_CAPTIONHEIGHT = 20
$NCM_OFF_PADDEDBORDER  = 500
$NcmScalarOffset = [ordered]@{
    CaptionHeight     = $NCM_OFF_CAPTIONHEIGHT
    PaddedBorderWidth = $NCM_OFF_PADDEDBORDER
}

# SPI / GDI 那几个 P/Invoke。【按需】编译，不在 dot-source 时就编：Windows PowerShell
# 5.1 的 Add-Type 走的是 Microsoft.CSharp.CSharpCodeProvider，会现拉一个 csc.exe 把这段
# C# 编成程序集 —— 本机实测进程内第一次 270ms（第二次 13ms，贵的是启动编译器），登录
# 那会儿磁盘正忙，冷启动能占掉一两秒。而登录脚本绝大多数时候只查一下注册表就收工
# （Test-MetricsInRegistry），根本用不到这些函数，不该为此付这笔钱。
# 用到它们的四个函数各自在开头调一次，编过就直接返回。
function Initialize-SpiType {
    if ('FontDeploy.Spi' -as [type]) { return }
    Add-Type -Namespace FontDeploy -Name Spi -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true)]
public static extern bool SystemParametersInfoW(uint uiAction, uint uiParam, System.IntPtr pvParam, uint fWinIni);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetProcessDPIAware();
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr SendMessageTimeoutW(System.IntPtr hWnd, uint Msg, System.IntPtr wParam,
    string lParam, uint fuFlags, uint uTimeout, out System.UIntPtr lpdwResult);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern System.IntPtr GetDC(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern int ReleaseDC(System.IntPtr hWnd, System.IntPtr hDC);
[System.Runtime.InteropServices.DllImport("gdi32.dll")]
public static extern int GetDeviceCaps(System.IntPtr hdc, int nIndex);
'@
}

# Windows 那边是「四舍五入、远离零」，而 .NET 默认是银行家舍入。必须显式指定，
# 否则 12.5 会变成 12 而不是 13，算出来的像素和系统对不上。
function Get-Rounded([double]$v) {
    return [int][Math]::Round($v, [System.MidpointRounding]::AwayFromZero)
}

# 必须在任何 DPI 查询之前调用 SetProcessDPIAware。否则在高 DPI 机器上 SPI
# 返回的是被虚拟化的 96-DPI 值，原样写回去等于把整个界面缩小一圈。
function Get-SystemDpi {
    Initialize-SpiType
    [void][FontDeploy.Spi]::SetProcessDPIAware()
    $dc = [FontDeploy.Spi]::GetDC([IntPtr]::Zero)
    if ($dc -eq [IntPtr]::Zero) { return 96 }
    try {
        $v = [FontDeploy.Spi]::GetDeviceCaps($dc, 90)   # LOGPIXELSY
        if ($v -ge 48 -and $v -le 960) { return $v }
        return 96
    } finally { [void][FontDeploy.Spi]::ReleaseDC([IntPtr]::Zero, $dc) }
}

# 在 92 字节 LOGFONTW 上【就地】改写我们关心的字段。escapement / orientation /
# outPrecision / clipPrecision / pitchAndFamily 一律保持原样。
function Set-LogFontFields {
    param([byte[]]$Bytes, [string]$Face, [int]$Height, [int]$Weight, [int]$CharSet, [int]$Quality)

    $b = New-Object byte[] $LF_SIZE
    if ($Bytes -and $Bytes.Length -ge $LF_SIZE) { [Array]::Copy($Bytes, $b, $LF_SIZE) }

    [Array]::Copy([BitConverter]::GetBytes([int]$Height), 0, $b, 0,  4)   # lfHeight
    [Array]::Copy([BitConverter]::GetBytes([int]0),       0, $b, 4,  4)   # lfWidth = 0 (自动)
    [Array]::Copy([BitConverter]::GetBytes([int]$Weight), 0, $b, 16, 4)   # lfWeight
    $b[20] = 0                      # lfItalic
    $b[21] = 0                      # lfUnderline
    $b[22] = 0                      # lfStrikeOut
    $b[23] = [byte]$CharSet
    $b[26] = [byte]$Quality

    # lfFaceName 是定长 32 个 WCHAR，必须整段清零后再写，且留出终止符
    for ($i = 28; $i -lt $LF_SIZE; $i++) { $b[$i] = 0 }
    $n = [System.Text.Encoding]::Unicode.GetBytes($Face)
    if ($n.Length -gt 62) { $n = $n[0..61] }
    [Array]::Copy($n, 0, $b, 28, $n.Length)
    return ,$b
}

function Get-LogFontInfo([byte[]]$b) {
    if (-not $b -or $b.Length -lt $LF_SIZE) { return $null }
    $face = [System.Text.Encoding]::Unicode.GetString($b, 28, 64)
    $z = $face.IndexOf([char]0)
    if ($z -ge 0) { $face = $face.Substring(0, $z) }
    [pscustomobject]@{
        Face    = $face
        Height  = [BitConverter]::ToInt32($b, 0)
        Weight  = [BitConverter]::ToInt32($b, 16)
        CharSet = $b[23]
        Quality = $b[26]
    }
}

function Format-LogFont([byte[]]$b, [int]$dpi) {
    $f = Get-LogFontInfo $b
    if (-not $f) { return '(无)' }
    $pt = if ($f.Height -ne 0) { [Math]::Round([Math]::Abs($f.Height) * 72 / $dpi, 1) } else { 0 }
    return ('{0} {1}pt  h={2} w={3} cs={4} q={5}' -f $f.Face, $pt, $f.Height, $f.Weight, $f.CharSet, $f.Quality)
}

function Get-MetricsHeight([double]$pt, [int]$dpi) {
    return (0 - (Get-Rounded ($pt * $dpi / 72)))
}

# WindowMetrics 里的标量（CaptionHeight / PaddedBorderWidth ...）是 win.ini
# 时代留下来的格式，Windows 自己写的一律是 REG_SZ 字符串，不是 REG_DWORD。
function Set-MetricScalar($key, [string]$name, [int]$twips) {
    $key.SetValue($name, [string]$twips, [Microsoft.Win32.RegistryValueKind]::String)
}

# 把一个 LOGFONT 的 lfHeight 从 $fromDpi 换算到 $toDpi。
# 备份里存的是【像素】，基准是备份当时那个配置单元的 AppliedDPI。还原时 DPI
# 可能已经变了（用户改过显示缩放）—— 那时 Windows 已经按新 DPI 把
# WindowMetrics 整体重算过并把 AppliedDPI 更新成了新值，我们再把旧像素原样
# 写回去，字号就永久错下去了。
function Convert-LogFontDpi([byte[]]$b, [int]$fromDpi, [int]$toDpi) {
    if (-not $b) { return $null }
    # 前面加逗号：不然 PowerShell 会把 byte[] 摊平成 92 个独立的 byte 返回。
    if ($b.Length -lt $LF_SIZE) { return ,$b }
    if ($fromDpi -le 0 -or $toDpi -le 0 -or $fromDpi -eq $toDpi) { return ,$b }
    $out = New-Object byte[] $LF_SIZE
    [Array]::Copy($b, $out, $LF_SIZE)
    $h = [BitConverter]::ToInt32($b, 0)
    if ($h -ne 0) {
        $n = Get-Rounded ([Math]::Abs($h) * $toDpi / $fromDpi)
        if ($n -lt 1) { $n = 1 }
        if ($h -lt 0) { $n = 0 - $n }
        [Array]::Copy([BitConverter]::GetBytes([int]$n), 0, $out, 0, 4)
    }
    return ,$out
}

# 标题栏该多高。$Original 是这个配置单元在备份里的那一项。
#
# 比的是【备份里的原值】，不是当前值 —— 当前值可能是上一趟我们自己写的：先
# -window-metrics-size 14 再改回 9，按当前值比会觉得「变小了、不用动」，标题栏
# 就停在 14pt 的高度回不来。按原值比，每次 -install 的结果只取决于原始状态和
# 这次的参数，跟跑过几次无关。
#   新字号比原来的大 -> Raise，Px 抬到放得下新字号，但不低于原来的高度
#   否则             -> 还原：Raw 是原来的注册表值（$null = 原本没有这一项），
#                       Twips 是解析出来的数（解析不了是 $null，那就别碰），
#                       Px 是原来的高度，给表达不了「没有这一项」的 SPI 用
# 原本就没有标题栏字体的配置单元（.DEFAULT、新用户模板）按 Windows 默认的 9pt 比；
# 没有标题栏高度（或解析不了）的按 Windows 默认的 -330 twip（96 DPI 下 22px）算。
function Get-CaptionTarget($Original, [int]$NewFontPx, [int]$Dpi) {
    $vals = Get-MapValue $Original 'Values'
    $fontPx = [Math]::Abs((Get-MetricsHeight 9 $Dpi))
    $cf = Get-MapValue $vals 'CaptionFont'
    if ($cf) {
        $from = Get-MapValue $Original 'Dpi'
        $info = Get-LogFontInfo (Convert-LogFontDpi ([Convert]::FromBase64String([string]$cf)) `
                                     $(if ($from) { [int]$from } else { 96 }) $Dpi)
        if ($info -and $info.Height -ne 0) { $fontPx = [Math]::Abs($info.Height) }
    }
    $raw = Get-MapValue $vals 'CaptionHeight'
    $tw = 0
    $twips = if ($null -ne $raw -and [int]::TryParse([string]$raw, [ref]$tw)) { $tw } else { $null }
    $px = if ($null -ne $twips) { Get-Rounded ([Math]::Abs($twips) * $Dpi / 1440) }
          else                  { Get-Rounded (330 * $Dpi / 1440) }
    $raise = $NewFontPx -gt $fontPx
    if ($raise) { $px = [Math]::Max($px, $NewFontPx + 10 * (Get-Rounded ($Dpi / 96))) }
    return [pscustomobject]@{ Raise = $raise; Px = $px; Raw = $raw; Twips = $twips }
}

# --------------------------------------------------------------- 目标配置单元
# 标量 metric 存的是 twip（DPI 无关），但 LOGFONT 的 lfHeight 是像素，基准是该
# 配置单元自己的 AppliedDPI —— 登录时 Windows 会按新 DPI 重算。所以逐个 hive 取。
function Get-HiveDpi($userKey) {
    try {
        $k = $userKey.OpenSubKey($MetricsSubKey)
        if ($k) {
            try {
                $v = $k.GetValue('AppliedDPI', $null)
                if ($v -is [int] -and $v -ge 48 -and $v -le 960) { return [int]$v }
            } finally { $k.Dispose() }
        }
    } catch { }
    return 96
}

function Resolve-Sid([string]$sid) {
    try {
        return (New-Object System.Security.Principal.SecurityIdentifier $sid).Translate(
                   [System.Security.Principal.NTAccount]).Value
    } catch { return $sid }
}

function Get-MySid {
    return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

# SPI_* 写的是【调用进程所属用户】的配置 + 当前会话。自己 UAC 提权时 SID 和
# 会话都不变，没问题；但 runas 成另一个管理员、或从计划任务/SYSTEM 跑，就会
# 写进错误的配置单元。用 explorer.exe 的属主判断真正坐在屏幕前的是谁。
function Get-InteractiveSid {
    try {
        $p = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop |
             Select-Object -First 1
        if ($p) {
            $o = Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction Stop
            if ($o.ReturnValue -eq 0 -and $o.Sid) { return [string]$o.Sid }
        }
    } catch { }
    return $null
}

# 返回要处理的配置单元清单。Key 就是备份 JSON 里的键名。
function Get-MetricsTargets {
    $out = @()
    $plKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    foreach ($sub in (Get-ChildItem $plKey -ErrorAction SilentlyContinue)) {
        $sid = Split-Path $sub.Name -Leaf
        # 真人账户只有两种 SID：本地 / 域账户 S-1-5-21-*，Entra ID（Azure AD）
        # 账户 S-1-12-1-*。SYSTEM / LOCAL / NETWORK SERVICE 这些跳过。
        if ($sid -notlike 'S-1-5-21-*' -and $sid -notlike 'S-1-12-1-*') { continue }
        $img = $null
        try { $img = (Get-ItemProperty $sub.PSPath -Name ProfileImagePath -ErrorAction Stop).ProfileImagePath } catch { }
        if (-not $img) { continue }
        $img = [Environment]::ExpandEnvironmentVariables($img)
        $loaded = Test-Path "Registry::HKEY_USERS\$sid"
        $dat = Join-Path $img 'NTUSER.DAT'
        if (-not $loaded -and -not (Test-Path -LiteralPath $dat)) { continue }
        $out += [pscustomobject]@{
            Key = $sid; Sid = $sid; Who = Resolve-Sid $sid
            Dat = $dat; Loaded = $loaded
        }
    }

    # .DEFAULT = LocalSystem 的配置，登录/锁屏前的一些经典界面走它
    $out += [pscustomobject]@{
        Key = '.DEFAULT'; Sid = '.DEFAULT'; Who = 'HKU\.DEFAULT (系统)'
        Dat = $null; Loaded = $true
    }

    # 新用户模板：以后新建的账户从这份 NTUSER.DAT 复制
    try {
        $defRoot = (Get-ItemProperty $plKey -Name 'Default' -ErrorAction Stop).Default
        $defRoot = [Environment]::ExpandEnvironmentVariables($defRoot)
        $defDat = Join-Path $defRoot 'NTUSER.DAT'
        if (Test-Path -LiteralPath $defDat) {
            $out += [pscustomobject]@{
                Key = 'DefaultProfile'; Sid = $null; Who = "新用户模板 ($defRoot)"
                Dat = $defDat; Loaded = $false
            }
        }
    } catch { }

    return $out
}

# Windows PowerShell 5.1 的坑：$ErrorActionPreference = 'Stop' 时，本机命令只要
# 往 stderr 写了东西、又用 2>&1 合流，就会当场抛终止性错误 —— 而 reg.exe 的
# 失败信息全部走 stderr，于是按 $LASTEXITCODE 判断的分支根本轮不到执行。
# 所以把偏好在本函数作用域内降回 Continue，老老实实按退出码判断。
function Invoke-Reg {
    param([string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    $out = & reg.exe @Arguments 2>&1
    $code = $LASTEXITCODE        # 紧挨着取，别隔着下面的管道
    # stderr 每一行都被包成 ErrorRecord，取 .Exception.Message 才是原文；
    # reg.exe 末尾那个空行会 ToString() 成类型名，滤掉。
    $text = @($out | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message }
        else { [string]$_ }
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    return [pscustomobject]@{
        Code   = $code
        Output = (($text -join ' ').Trim())
    }
}

# 对一个配置单元执行 $Action（参数是打开的 RegistryKey）。没加载的用 reg.exe
# 临时挂上。卸载前必须先释放所有 RegistryKey 句柄并 GC，否则 reg unload 必失败。
#
# 本函数的局部变量【一律加 hive 前缀】。PowerShell 的 scriptblock 是动态作用域：
# & $Action 里出现的自由变量先在本函数的局部里找，找不到才往调用方走 —— 调用方
# 传进来的 scriptblock 靠的正是后者（比如 $entry / $entryDpi）。局部名撞上调用方
# 的变量名会把它悄悄换掉，而且没有任何报错。反过来，调用方交给 scriptblock 的
# 变量也别以 hive 打头。
function Invoke-OnUserHive {
    param($Target, [scriptblock]$Action)

    if ($Target.Loaded) {
        $hiveName = if ($Target.Sid) { $Target.Sid } else { throw '已加载的配置单元必须有 SID' }
        $hiveRoot = [Microsoft.Win32.Registry]::Users.OpenSubKey($hiveName, $true)
        if (-not $hiveRoot) { throw "打不开 HKEY_USERS\$hiveName（权限不足？）" }
        try { return (& $Action $hiveRoot) } finally { $hiveRoot.Dispose() }
    }

    if (-not $Target.Dat -or -not (Test-Path -LiteralPath $Target.Dat)) {
        throw "找不到配置单元文件: $($Target.Dat)"
    }
    $hiveTmp = 'WMSC_' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $hiveLoad = Invoke-Reg @('load', "HKU\$hiveTmp", $Target.Dat)
    if ($hiveLoad.Code -ne 0) {
        throw ("reg load 失败 ({0}): {1} —— {2}" -f $hiveLoad.Code, $Target.Dat, $hiveLoad.Output)
    }
    try {
        $hiveRoot = [Microsoft.Win32.Registry]::Users.OpenSubKey($hiveTmp, $true)
        if (-not $hiveRoot) { throw "打不开临时配置单元 HKU\$hiveTmp" }
        try { return (& $Action $hiveRoot) } finally { $hiveRoot.Dispose() }
    } finally {
        $hiveDone = $false
        $hiveLast = ''
        for ($i = 0; $i -lt 5; $i++) {
            [GC]::Collect(); [GC]::WaitForPendingFinalizers(); [GC]::Collect()
            $hiveUl = Invoke-Reg @('unload', "HKU\$hiveTmp")
            $hiveLast = $hiveUl.Output
            if ($hiveUl.Code -eq 0) { $hiveDone = $true; break }
            Start-Sleep -Milliseconds 300
        }
        if (-not $hiveDone) {
            Write-Host ("  警告: 临时配置单元 HKU\$hiveTmp 卸载失败（{0}），重启后会自动释放。" -f `
                        $hiveLast) -ForegroundColor DarkYellow
        }
    }
}

# --------------------------------------------------------------- 直接写配置单元
# 返回该 hive 的原值（base64 / 字符串 / $null 表示原本不存在），供还原用。
# 实写那趟要给 $Original（这个 hive 在备份里的那一项），标题栏高度按它算。
function Update-MetricsHive {
    param($root, [switch]$BackupOnly, $Original)

    $dpi  = Get-HiveDpi $root
    $vals = [ordered]@{}

    # 备份阶段必须是纯只读：用 OpenSubKey，不能用 CreateSubKey，否则会在还没
    # 打算改的配置单元里凭空建出一个空的 WindowMetrics 键。
    if ($BackupOnly) {
        $k = $root.OpenSubKey($MetricsSubKey)
        if (-not $k) {
            # 键本来就不存在：全部记成 $null，还原时按「删除」处理。
            # 两个标量也要记 —— 实写那趟会 CreateSubKey 把键建出来并往里写
            # PaddedBorderWidth，不记的话还原时没人负责删它。
            foreach ($role in $MetricsRoles.Keys) { $vals[$role] = $null }
            $vals['CaptionHeight'] = $null
            $vals['PaddedBorderWidth'] = $null
            return [ordered]@{ Dpi = $dpi; Values = $vals }
        }
    } else {
        $k = $root.CreateSubKey($MetricsSubKey)
        if (-not $k) { throw "无法打开 $MetricsSubKey" }
    }
    try {
        foreach ($role in $MetricsRoles.Keys) {
            $old = $k.GetValue($role, $null)
            if ($old -is [byte[]]) {
                $vals[$role] = [Convert]::ToBase64String($old)
            } else {
                $vals[$role] = $null
                $old = $null
            }
            if ($BackupOnly) { continue }

            $h = Get-MetricsHeight $MetricsSize $dpi
            $new = Set-LogFontFields -Bytes $old -Face $MetricsFace -Height $h `
                       -Weight $MetricsWeight -CharSet $MetricsCharSet -Quality $MetricsQuality
            $k.SetValue($role, $new, [Microsoft.Win32.RegistryValueKind]::Binary)
        }

        # 几何联动。注册表里这两个标量存的是【负 twip】：twip = px * 1440 / dpi。
        # 【无条件】备份，不管这一趟到底改不改它们 —— 备份只做第一趟，而下面的
        # 判定条件读的是当前值，第二趟条件可能由不成立变成成立，那时备份早已存在
        # 不会再存，于是「改了却没备份」。只记不写没有任何代价。
        $oldCH = $k.GetValue('CaptionHeight', $null)
        $vals['CaptionHeight'] = if ($null -eq $oldCH) { $null } else { [string]$oldCH }
        $pb = $k.GetValue('PaddedBorderWidth', $null)
        $vals['PaddedBorderWidth'] = if ($null -eq $pb) { $null } else { [string]$pb }

        # 标题栏高度按备份里的原值算，见 Get-CaptionTarget。还原走的是原值本身，
        # 不经过像素换算 —— twip 换成像素再换回来，某些 DPI 下会差几个 twip。
        if (-not $BackupOnly -and $Original) {
            $cap = Get-CaptionTarget $Original ([Math]::Abs((Get-MetricsHeight $MetricsSize $dpi))) $dpi
            if ($cap.Raise) {
                Set-MetricScalar $k 'CaptionHeight' (0 - (Get-Rounded ($cap.Px * 1440 / $dpi)))
            } elseif ($null -eq $cap.Raw) {
                $k.DeleteValue('CaptionHeight', $false)
            } elseif ($null -ne $cap.Twips) {
                Set-MetricScalar $k 'CaptionHeight' $cap.Twips
            }
        }
        # Win11 边框：为 0 时补一个最小值。解析不出数字的（空串之类）当作
        # 「看不懂，别碰」，不要让 [int] 抛异常把整个配置单元带崩。
        $pbNum = 0
        $pbIsZero = if ($null -eq $pb) { $true }
                    else { [int]::TryParse([string]$pb, [ref]$pbNum) -and $pbNum -eq 0 }
        if (-not $BackupOnly -and $pbIsZero) {
            $px = 1 + (Get-Rounded ($dpi / 96))
            Set-MetricScalar $k 'PaddedBorderWidth' (0 - (Get-Rounded ($px * 1440 / $dpi)))
        }
    } finally { $k.Dispose() }

    return [ordered]@{ Dpi = $dpi; Values = $vals }
}

function Restore-MetricsHive {
    param($root, $values, [int]$FromDpi = 0)

    # 备份里的 lfHeight 是像素，基准是备份当时的 AppliedDPI；这个配置单元现在的
    # AppliedDPI 可能已经不一样了（用户改过缩放）。差了就换算。
    $toDpi = Get-HiveDpi $root

    # 全是 $null 说明这个配置单元原本就没有 WindowMetrics 键，
    # 那就别用 CreateSubKey 把它建出来 —— 还原应该不留痕迹。
    $hasValue = $false
    foreach ($n in (Get-MapKeys $values)) {
        if ($null -ne (Get-MapValue $values $n)) { $hasValue = $true; break }
    }
    $k = if ($hasValue) { $root.CreateSubKey($MetricsSubKey) }
         else           { $root.OpenSubKey($MetricsSubKey, $true) }
    if (-not $k) { return }
    $dropKey = $false
    try {
        foreach ($name in (Get-MapKeys $values)) {
            $v = Get-MapValue $values $name
            if ($null -eq $v) {
                # 原本不存在 —— 删掉我们加的
                try { $k.DeleteValue($name, $false) } catch { }
                continue
            }
            if ($MetricsRoles.Contains($name)) {
                $lf = Convert-LogFontDpi ([Convert]::FromBase64String([string]$v)) $FromDpi $toDpi
                $k.SetValue($name, $lf, [Microsoft.Win32.RegistryValueKind]::Binary)
            } else {
                # 能解析成整数的按整数写回（和 Windows 自己落盘的格式一致）；
                # 解析不了的原样写回字符串 —— 还原路径上不该因为一个几何标量
                # 抛异常，把剩下几项也一起带没。
                $tw = 0
                if ([int]::TryParse([string]$v, [ref]$tw)) { Set-MetricScalar $k $name $tw }
                else { $k.SetValue($name, [string]$v, [Microsoft.Win32.RegistryValueKind]::String) }
            }
        }

        # 原本没有这个键时，光把值删干净还不算还原干净 —— 键本身是安装那趟
        # CreateSubKey 建出来的，也得收掉。只在确实空了的时候删：这中间可能有
        # 别的东西往里写过值，那就不是我们的东西了。
        if (-not $hasValue) {
            $dropKey = (@($k.GetValueNames()).Count -eq 0 -and
                        @($k.GetSubKeyNames()).Count -eq 0)
        }
    } finally { $k.Dispose() }

    # 必须先释放句柄再删。只删 WindowMetrics 这一层：它上面的 Control Panel\Desktop
    # 几乎每份 NTUSER.DAT 里本来就有（壁纸等一堆设置都在那儿），不碰。
    if ($dropKey) {
        try { $root.DeleteSubKey($MetricsSubKey, $false) } catch { }
    }
}

# --------------------------------------------------------------- 当前用户走 API
function Send-MetricsSettingChange {
    Initialize-SpiType
    $r = [UIntPtr]::Zero
    # HWND_BROADCAST=0xFFFF  WM_SETTINGCHANGE=0x001A  SMTO_ABORTIFHUNG=0x0002
    # 不用 SPIF_SENDCHANGE：那是同步广播，遇到一个卡死的程序整个调用就挂住。
    [void][FontDeploy.Spi]::SendMessageTimeoutW(
        [IntPtr]0xFFFF, 0x001A, [IntPtr]0x0022, $null, 0x0002, 5000, [ref]$r)
    [void][FontDeploy.Spi]::SendMessageTimeoutW(
        [IntPtr]0xFFFF, 0x001A, [IntPtr]0x002A, 'WindowMetrics', 0x0002, 5000, [ref]$r)
}

# $LogFonts 为空 = 按上面那几个常量设置；否则用给定的 6 个 LOGFONT 写回（还原用）。
# $MetricsTwips 还原用，单位是【负 twip】，和注册表里那份一模一样，换算成
#   NONCLIENTMETRICS 要的像素在这里做 —— 只有这里知道当前会话的 DPI。
# $FromDpi = $LogFonts 里那些 lfHeight 的 DPI 基准。
# $Original 安装用，当前用户在备份里的那一项，标题栏高度按它算。
# [CmdletBinding()] 不是摆设：没有它，简单函数会把认不出来的 -Xxx 悄悄塞进
# $args，参数名写错就变成「静默不生效」。
function Set-MetricsViaSpi {
    [CmdletBinding()]
    param([hashtable]$LogFonts, [hashtable]$MetricsTwips, [int]$FromDpi = 0, $Original)

    Initialize-SpiType
    $dpi = Get-SystemDpi

    # --- 1) 图标字体 ---
    $q = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($LF_SIZE)
    try {
        if ([FontDeploy.Spi]::SystemParametersInfoW(0x001F, $LF_SIZE, $q, 0)) {   # SPI_GETICONTITLELOGFONT
            $lf = New-Object byte[] $LF_SIZE
            [System.Runtime.InteropServices.Marshal]::Copy($q, $lf, 0, $LF_SIZE)
            $new = if ($LogFonts -and $LogFonts['IconFont']) {
                Convert-LogFontDpi $LogFonts['IconFont'] $FromDpi $dpi
            } else {
                Set-LogFontFields -Bytes $lf -Face $MetricsFace `
                    -Height (Get-MetricsHeight $MetricsSize $dpi) -Weight $MetricsWeight `
                    -CharSet $MetricsCharSet -Quality $MetricsQuality
            }
            [System.Runtime.InteropServices.Marshal]::Copy($new, 0, $q, $LF_SIZE)
            if (-not [FontDeploy.Spi]::SystemParametersInfoW(0x0022, $LF_SIZE, $q, 0x01)) {  # SPI_SETICONTITLELOGFONT
                Write-Host ('  SPI_SETICONTITLELOGFONT 失败 (Win32 错误 {0})' -f `
                    [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()) -ForegroundColor DarkYellow
            }
        }
    } finally { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($q) }

    # --- 2) 其余 5 个 + 几何 ---
    $p = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($NCM_SIZE)
    try {
        # cbSize 必须先填进缓冲区，否则 SPI_GET 直接失败
        [System.Runtime.InteropServices.Marshal]::WriteInt32($p, 0, $NCM_SIZE)
        if (-not [FontDeploy.Spi]::SystemParametersInfoW(0x0029, $NCM_SIZE, $p, 0)) {  # SPI_GETNONCLIENTMETRICS
            throw ('SPI_GETNONCLIENTMETRICS 失败 (Win32 错误 {0})' -f `
                   [System.Runtime.InteropServices.Marshal]::GetLastWin32Error())
        }
        $buf = New-Object byte[] $NCM_SIZE
        [System.Runtime.InteropServices.Marshal]::Copy($p, $buf, 0, $NCM_SIZE)

        foreach ($e in $NcmFontOffset.GetEnumerator()) {
            $old = New-Object byte[] $LF_SIZE
            [Array]::Copy($buf, $e.Value, $old, 0, $LF_SIZE)
            $new = if ($LogFonts -and $LogFonts[$e.Key]) {
                Convert-LogFontDpi $LogFonts[$e.Key] $FromDpi $dpi
            } else {
                Set-LogFontFields -Bytes $old -Face $MetricsFace `
                    -Height (Get-MetricsHeight $MetricsSize $dpi) `
                    -Weight $MetricsWeight -CharSet $MetricsCharSet -Quality $MetricsQuality
            }
            [Array]::Copy($new, 0, $buf, $e.Value, $LF_SIZE)
        }

        # 这里的几何值是【像素】，不是注册表那套 twip
        if (-not $LogFonts) {
            # 标题栏高度按备份里的原值算，见 Get-CaptionTarget。会话里没有「这一项
            # 不存在」这个状态，原值缺了（或解析不了）就用 Windows 的默认高度。不能
            # 维持现状：现状可能是上一趟我们自己抬高的，先 14pt 再 9pt 就回不来了。
            if ($Original) {
                $newCaptionH = [BitConverter]::ToInt32($buf, $NcmFontOffset['CaptionFont'])
                $cap = Get-CaptionTarget $Original ([Math]::Abs($newCaptionH)) $dpi
                [Array]::Copy([BitConverter]::GetBytes([int]$cap.Px), 0, $buf, $NCM_OFF_CAPTIONHEIGHT, 4)
            }
            if ([BitConverter]::ToInt32($buf, $NCM_OFF_PADDEDBORDER) -eq 0) {
                $pb = 1 + (Get-Rounded ($dpi / 96))
                [Array]::Copy([BitConverter]::GetBytes([int]$pb), 0, $buf, $NCM_OFF_PADDEDBORDER, 4)
            }
        }

        # 还原几何值。必须在这里做：SPI_GET 拿到的是【当前会话】里已经被我们改过
        # 的值，不还原的话这次 SPI_SET 又会把它原样写回注册表，把刚刚还原好的
        # 注册表值再盖掉。备份里是负 twip（DPI 无关），换算要用【当前】DPI。
        if ($MetricsTwips) {
            foreach ($n in $NcmScalarOffset.Keys) {
                $tw = $MetricsTwips[$n]
                if ($null -eq $tw) { continue }
                $px = Get-Rounded ([Math]::Abs([int]$tw) * $dpi / 1440)
                [Array]::Copy([BitConverter]::GetBytes([int]$px), 0, $buf, $NcmScalarOffset[$n], 4)
            }
        }

        [System.Runtime.InteropServices.Marshal]::Copy($buf, 0, $p, $NCM_SIZE)
        if (-not [FontDeploy.Spi]::SystemParametersInfoW(0x002A, $NCM_SIZE, $p, 0x01)) {  # SPI_SETNONCLIENTMETRICS + SPIF_UPDATEINIFILE
            throw ('SPI_SETNONCLIENTMETRICS 失败 (Win32 错误 {0})' -f `
                   [System.Runtime.InteropServices.Marshal]::GetLastWin32Error())
        }
    } finally { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($p) }

    Send-MetricsSettingChange
    return $dpi
}

# 当前会话里的 6 个 LOGFONT，键名同 $MetricsRoles。只读。
# SetProcessDPIAware 【必须】赶在下面两个 SPI_GET 之前，理由见 Get-SystemDpi：
# 进程还没声明 DPI 感知时，SPI 返回的 lfHeight 是被虚拟化成 96 DPI 的值，拿去和
# 按真实 DPI 算出来的目标值比，缩放不是 100% 的机器上永远比不上。所以自己调一次，
# 不指望调用方先调 Get-SystemDpi —— 写成 Test-MetricsMatch (Read-SessionLogFonts)
# (Get-SystemDpi) 的话，PowerShell 求值参数是从左到右的，反而是本函数先跑。
function Read-SessionLogFonts {
    Initialize-SpiType
    [void][FontDeploy.Spi]::SetProcessDPIAware()
    $out = [ordered]@{}
    $q = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($LF_SIZE)
    try {
        if (-not [FontDeploy.Spi]::SystemParametersInfoW(0x001F, $LF_SIZE, $q, 0)) {   # SPI_GETICONTITLELOGFONT
            throw ('SPI_GETICONTITLELOGFONT 失败 (Win32 错误 {0})' -f `
                   [System.Runtime.InteropServices.Marshal]::GetLastWin32Error())
        }
        $lf = New-Object byte[] $LF_SIZE
        [System.Runtime.InteropServices.Marshal]::Copy($q, $lf, 0, $LF_SIZE)
        $out['IconFont'] = $lf
    } finally { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($q) }

    $p = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($NCM_SIZE)
    try {
        [System.Runtime.InteropServices.Marshal]::WriteInt32($p, 0, $NCM_SIZE)
        if (-not [FontDeploy.Spi]::SystemParametersInfoW(0x0029, $NCM_SIZE, $p, 0)) {  # SPI_GETNONCLIENTMETRICS
            throw ('SPI_GETNONCLIENTMETRICS 失败 (Win32 错误 {0})' -f `
                   [System.Runtime.InteropServices.Marshal]::GetLastWin32Error())
        }
        $buf = New-Object byte[] $NCM_SIZE
        [System.Runtime.InteropServices.Marshal]::Copy($p, $buf, 0, $NCM_SIZE)
        foreach ($e in $NcmFontOffset.GetEnumerator()) {
            $lf = New-Object byte[] $LF_SIZE
            [Array]::Copy($buf, $e.Value, $lf, 0, $LF_SIZE)
            $out[$e.Key] = $lf
        }
    } finally { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($p) }
    return $out
}

# 给定的这组 LOGFONT 是不是都已经是这次的目标值（字号按给定 DPI 算）。
# 比的就是 Set-LogFontFields 会写的那几个字段。
function Test-MetricsMatch($LogFonts, [int]$Dpi) {
    $h = Get-MetricsHeight $MetricsSize $Dpi
    foreach ($b in $LogFonts.Values) {
        $f = Get-LogFontInfo $b
        if (-not $f) { return $false }
        # -ne 比字符串不分大小写，和 GDI 认族名的规矩一致
        if ($f.Face -ne $MetricsFace -or $f.Height -ne $h -or $f.Weight -ne $MetricsWeight -or
            $f.CharSet -ne $MetricsCharSet -or $f.Quality -ne $MetricsQuality) { return $false }
    }
    return $true
}

# 会话里那 6 个是不是已经是目标值。登录脚本靠它判断 Windows 有没有把我们写的值重置
# 掉：没被重置就什么都不做，免得每次登录都广播一遍 WM_SETTINGCHANGE。
# 会话才是屏幕上真正在用的那一份，所以它说了算 —— 代价是要调 SPI，也就要先编
# P/Invoke（Initialize-SpiType）。快的那条路见下面 Test-MetricsInRegistry。
function Test-MetricsInSession {
    return (Test-MetricsMatch (Read-SessionLogFonts) (Get-SystemDpi))
}

# 同样的判断，但只读 HKCU，不碰 SPI —— 也就不用现编程序集（理由见 Initialize-SpiType）。
# 登录脚本拿它当快速路径：绝大多数登录压根没发生过重置，读完注册表就能收工。
#
# 它只负责【提前收工】：返回 $true 才跳过，别的情况一律往下走 Test-MetricsInSession
# 重新判定，所以拿不准时返回 $false 永远是安全的。
#   · 字号要按像素比，得知道 DPI。用同一个键里的 AppliedDPI —— 主题引擎自己的记录，
#     缩放一变，它和这 6 个值是被同一个组件一起改写的。没有或不像话就返回 $false，
#     不猜。
#   · 注册表和会话读出来逐字节相同（Win11 26200 实测）。万一不同步，也只会是「注册表
#     对、会话错」这一种，而会话本来就是登录时从注册表加载的，下次登录自然对上。
function Test-MetricsInRegistry {
    $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($MetricsSubKey)
    if (-not $k) { return $false }
    try {
        $dpi = $k.GetValue('AppliedDPI', $null)
        if ($dpi -isnot [int] -or $dpi -lt 48 -or $dpi -gt 960) { return $false }
        $vals = [ordered]@{}
        foreach ($role in $MetricsRoles.Keys) {
            $b = $k.GetValue($role, $null)
            if ($b -isnot [byte[]]) { return $false }
            $vals[$role] = $b
        }
    } finally { $k.Dispose() }
    return (Test-MetricsMatch $vals $dpi)
}

# --------------------------------------------------------------- 编排
function Show-WindowMetricsPlan {
    $dpi = Get-SystemDpi
    Write-Host ''
    Write-Host '=== 机制 3  WindowMetrics，6 项（现值取自当前用户）===' -ForegroundColor Yellow

    # 读一份当前值只是为了给人看，读不到就算了
    $cur = $null
    try { $cur = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($MetricsSubKey) } catch { }
    try {
        foreach ($r in $MetricsRoles.GetEnumerator()) {
            $now = '(读不到)'
            if ($cur) {
                $b = $cur.GetValue($r.Key, $null)
                if ($b -is [byte[]]) { $now = Format-LogFont $b $dpi }
            }
            Write-Host ('  {0,-14} {1}' -f $r.Key, $r.Value)
            Write-Host ('      现: {0}' -f $now) -ForegroundColor DarkGray
            Write-Host ('      新: {0} {1}pt  h={2} w={3} cs={4} q={5}  @{6}dpi' -f `
                        $MetricsFace, $MetricsSize, (Get-MetricsHeight $MetricsSize $dpi),
                        $MetricsWeight, $MetricsCharSet, $MetricsQuality, $dpi) -ForegroundColor Gray
        }
    } finally { if ($cur) { $cur.Dispose() } }
    Write-Host '  标题栏高度和 Win11 边框宽度会跟着字号联动。'
    Write-Host '  目标配置单元：' -ForegroundColor Yellow
    foreach ($t in (Get-MetricsTargets)) {
        $state = if ($t.Loaded) { '已加载' } else { '未加载，将临时挂载' }
        Write-Host ('    {0,-42} [{1}]' -f $t.Who, $state)
    }
    Show-AutoRestorePlan
}

function Invoke-WindowMetricsApply {
    $mySid = Get-MySid
    $interactive = Get-InteractiveSid

    Write-Host ''
    Write-Host ('经典界面 : {0}  {1}pt  weight={2} charset={3} quality={4}' -f `
                $MetricsFace, $MetricsSize, $MetricsWeight,
                $MetricsCharSet, $MetricsQuality) -ForegroundColor White

    if ($interactive -and $interactive -ne $mySid) {
        Write-Host ('注意：当前进程属于 {0}，但坐在屏幕前的是 {1}。' -f `
                    (Resolve-Sid $mySid), (Resolve-Sid $interactive)) -ForegroundColor DarkYellow
        Write-Host '      对方的设置只能直接写配置单元，要【注销后重新登录】才生效。' -ForegroundColor DarkYellow
    }

    $targets = @(Get-MetricsTargets)

    # --- 第一遍：只读，把原值全部备份并落盘。必须先于任何写入完成，否则中途
    #     Ctrl-C 就会留下一堆改过但没备份的配置单元。
    #     已经备份过就跳过 —— 再存一遍存下来的将是「我们自己写的值」。
    $bk = Read-BackupFile
    if ($null -eq $bk) { $bk = [pscustomobject]@{} }
    if (Get-MapValue $bk 'WindowMetrics') {
        Write-Host '经典界面备份已存在，保留原值。' -ForegroundColor DarkGray
    } else {
        $wm = [ordered]@{}
        foreach ($t in $targets) {
            try {
                $b = Invoke-OnUserHive $t { param($root) Update-MetricsHive $root -BackupOnly }
                $wm[$t.Key] = [ordered]@{
                    Who = $t.Who; Dat = $t.Dat; Loaded = $t.Loaded; Sid = $t.Sid
                    Dpi = $b.Dpi; Values = $b.Values
                }
            } catch {
                Write-Host ('[经典] {0,-42} 备份失败，将跳过: {1}' -f `
                            $t.Who, $_.Exception.Message) -ForegroundColor DarkYellow
            }
        }
        if ($wm.Count -eq 0) { throw '没有任何配置单元可以备份，中止。' }
        Set-MapValue $bk 'WindowMetrics' $wm
        Write-BackupFile $bk
        Write-Host ("已备份 {0} 个配置单元的 WindowMetrics -> {1}" -f $wm.Count, $Backup) -ForegroundColor Yellow
    }

    # 只动备份里确实记录了的那些，保证「改过的 ⊆ 备份过的」
    $wmBackup = Get-MapValue $bk 'WindowMetrics'
    $backedUp = Get-MapKeys $wmBackup

    # --- 第二遍：写入
    $ok = 0
    $skipped = 0
    foreach ($t in $targets) {
        if ($backedUp -notcontains $t.Key) {
            Write-Host ('[经典] {0,-42} 无备份，跳过' -f $t.Who) -ForegroundColor DarkYellow
            $skipped++
            continue
        }
        # 标题栏高度要和【原值】比，不能和当前值比，见 Get-CaptionTarget。
        # scriptblock 里靠动态作用域拿到它，所以名字别以 hive 打头（见 Invoke-OnUserHive）。
        $original = Get-MapValue $wmBackup $t.Key
        try {
            if ($t.Sid -eq $mySid) {
                # 自己：走 API。SPIF_UPDATEINIFILE 会自己落盘，而且当场生效，不用注销
                $dpi = Set-MetricsViaSpi -Original $original
                Write-Host ('[经典] {0,-42} 已通过 SystemParametersInfo 立即生效 (dpi={1})' -f `
                            $t.Who, $dpi) -ForegroundColor Green
            } else {
                $b = Invoke-OnUserHive $t { param($root) Update-MetricsHive $root -Original $original }
                Write-Host ('[经典] {0,-42} 已写入 6 项 (dpi={1})，下次登录生效' -f `
                            $t.Who, $b.Dpi) -ForegroundColor Green
            }
            $script:WroteSomething = $true
            $ok++
        } catch {
            Write-Host ('[经典] {0,-42} 跳过: {1}' -f $t.Who, $_.Exception.Message) -ForegroundColor DarkYellow
        }
    }
    if ($skipped -gt 0) {
        Write-Host ("有 {0} 个配置单元不在现有备份里，被跳过了。先 -revert 再重跑即可覆盖它们。" -f `
                    $skipped) -ForegroundColor DarkYellow
    }

    # 登录自动恢复。它失败不该拖垮后面的机制 4，刚写好的 6 项也照样有效，报一句就行。
    if ($ok -gt 0) {
        if (Test-MetricsAutoRestoreNeeded) {
            try {
                $cmd = Install-MetricsAutoRestore
                $script:AutoRestoreOn = $true
                Write-Host ('[经典] 已登记登录自动恢复 {0}\{1}' -f $AutoRestoreRunKey, $AutoRestoreName) -ForegroundColor Green
                Write-Host ('       {0}' -f $cmd) -ForegroundColor DarkGray
            } catch {
                Write-Host ('[经典] 登录自动恢复没有登记: {0}' -f $_.Exception.Message) -ForegroundColor DarkYellow
                Write-Host '       以后改了显示缩放，重新登录后把这次的安装命令再跑一遍即可。' -ForegroundColor DarkYellow
            }
        } else {
            # 字号字重都是默认值，缩放重置无害，不装。之前用非默认值装过、这次改回
            # 默认的话，顺手拆掉：不然旧的 Run 命令行还带着老字号，下次缩放一变又会把
            # 它写回来，跟这次的默认值打架。$bk 里没有 AutoRestore 一节（从没装过）时，
            # Remove-MetricsAutoRestore 直接返回，什么都不做、不报错。
            #
            # 这里必须自己接住异常。Remove-MetricsAutoRestore 是按【还原】那条路写的
            # ——删不掉就抛，好让 -revert 整个停下 —— 但安装这条路上它只是收尾，抛出去
            # 会被 main.ps1 的 trap 接走直接 break：机制 4 和 Restart-FontCache 全都轮不
            # 到，用户还会看到「注册表已被部分修改」，而其实这一趟该写的 6 项一个没少。
            try {
                Remove-MetricsAutoRestore $bk
                Write-Host '[经典] 字号字重均为默认值，缩放重置后仍是替换字体，未安装登录自动恢复。' -ForegroundColor DarkGray
            } catch {
                Write-Host ('[经典] 旧的登录自动恢复没拆干净: {0}' -f $_.Exception.Message) -ForegroundColor DarkYellow
                Write-Host ('       它还带着上一次的字号字重，下次改显示缩放会跟本次的默认值打架，手动删掉 {0}\{1} 即可。' -f `
                            $AutoRestoreRunKey, $AutoRestoreName) -ForegroundColor DarkYellow
            }
        }
    }
    return $ok
}

# 由 main_revert.ps1 调用：这一节的还原要用到上面整套 LOGFONT / SPI / hive 机器，
# 所以留在本文件里。
function Restore-WindowMetricsSection($saved) {
    $wm = Get-MapValue $saved 'WindowMetrics'
    if (-not $wm) {
        Write-Host '备份里没有经典界面(WindowMetrics)一节，跳过。' -ForegroundColor DarkGray
        return
    }
    $mySid = Get-MySid

    # 有的配置单元原本就缺某几项。注册表那边好办 ——「不存在」就是删掉；但会话里
    # 没有「不存在」这个状态：SPI 必须给出一个具体的 LOGFONT，不给就等于把我们
    # 写进去的字号留在那儿。所以先在整个备份里找一份「这台机器自己的原始 UI
    # 字体」当模板，缺项拿它补。
    $tmpl = $null
    foreach ($k2 in (Get-MapKeys $wm)) {
        $e2 = Get-MapValue $wm $k2
        foreach ($role in $MetricsRoles.Keys) {
            $v2 = Get-MapValue $e2.Values $role
            if ($v2) {
                $tmpl = @{ Bytes = [Convert]::FromBase64String([string]$v2)
                           Dpi   = $(if ($e2.Dpi) { [int]$e2.Dpi } else { 96 }) }
                break
            }
        }
        if ($tmpl) { break }
    }

    foreach ($key in (Get-MapKeys $wm)) {
        $entry = Get-MapValue $wm $key
        # 备份里的 Loaded 记的是【安装当时】的状态，这中间用户可能注销或登录过，
        # 照着旧值走两个方向都会失败。所以现场重新判定一次。
        # .DEFAULT 没有 NTUSER.DAT 可挂，只能按已加载处理。
        $loaded = if ($entry.Sid) { Test-Path ("Registry::HKEY_USERS\" + $entry.Sid) } else { $false }
        if (-not $loaded -and -not $entry.Dat) { $loaded = $true }
        $t = [pscustomobject]@{
            Key = $key; Sid = $entry.Sid; Who = $entry.Who
            Dat = $entry.Dat;  Loaded = $loaded
        }
        try {
            # 自己的话先走 API（省一次注销），再写注册表。顺序不能反：
            # SPI_SET 带 SPIF_UPDATEINIFILE 会自己落盘，放在后面就会把刚还原好的
            # 注册表值又盖掉一次。注册表放最后才是最终裁决，「原本不存在」的条目
            # 也才能真正被删掉。
            $entryDpi = if ($entry.Dpi) { [int]$entry.Dpi } else { 96 }

            if ($t.Sid -eq $mySid) {
                # 缺项不能让整趟 SPI 都不做：有几项还几项，缺的用模板补，
                # 实在没有模板才退回 Segoe UI 9pt —— 那是 Windows 自己的默认值，
                # 也正是「该项不存在」时的效果。
                $lf = @{}
                $filled = @()
                foreach ($role in $MetricsRoles.Keys) {
                    $v = Get-MapValue $entry.Values $role
                    if ($v) { $lf[$role] = [Convert]::FromBase64String([string]$v); continue }
                    $filled += $role
                    if ($tmpl) {
                        $lf[$role] = Convert-LogFontDpi $tmpl.Bytes $tmpl.Dpi $entryDpi
                    } else {
                        $lf[$role] = Set-LogFontFields -Bytes $null -Face 'Segoe UI' `
                            -Height (Get-MetricsHeight 9 $entryDpi) -Weight 400 `
                            -CharSet 1 -Quality 5
                    }
                }
                # 备份里的几何值是负 twip（DPI 无关），原样交给 Set-MetricsViaSpi，
                # 由它按【当前】DPI 换算成像素。这里再换一次就会用错 DPI。
                $geo = @{}
                foreach ($n in (Get-MapKeys $NcmScalarOffset)) {
                    $v = Get-MapValue $entry.Values $n
                    if ($null -eq $v) { continue }
                    $tw = 0
                    if (-not [int]::TryParse([string]$v, [ref]$tw)) { continue }
                    $geo[$n] = $tw
                }
                [void](Set-MetricsViaSpi -LogFonts $lf -MetricsTwips $geo -FromDpi $entryDpi)
                Write-Host ('[经典] {0,-42} 已通过 SystemParametersInfo 立即生效' -f `
                            $t.Who) -ForegroundColor Green
                if ($filled.Count) {
                    Write-Host ('        原值里没有 {0}，已按系统默认补上；注册表里这几项会被删掉。' -f `
                                ($filled -join '/')) -ForegroundColor DarkYellow
                }
            }

            Invoke-OnUserHive $t { param($root) Restore-MetricsHive $root $entry.Values -FromDpi $entryDpi } | Out-Null
            Write-Host ('[经典] {0,-42} 注册表已还原' -f $t.Who) -ForegroundColor Green
        } catch {
            Write-Host ('[经典] {0,-42} 还原失败: {1}' -f $t.Who, $_.Exception.Message) -ForegroundColor Red
        }
    }
}

# --------------------------------------------------------------- 登录自动恢复
# 显示缩放一变，Windows 会在下一次登录时把这 6 个字体整个重置成主题自带的默认值
# （Win11 中文版是 Microsoft YaHei UI 9pt Regular），不是按比例换算 —— 我们写的
# 族名、字号、字重一起没了，标题栏高度也回到默认。noMeiryoUI 也一样会丢。
#
# 这是 Windows 自己的机制，拦不住。winlogon 登录时调 UXInit.dll 的 ThemesOnLogon
# 加载主题；DPI 相关的记录（ThemeManager\LastLoadedDPI、WindowMetrics\AppliedDPI）
# 只有 UXInit.dll / uxtheme.dll 这些主题组件在用，内核里读 WindowMetrics 的
# win32kbase.sys 连 AppliedDPI 都不认，只会原样加载像素值（Win11 26200 上查过这几个
# 文件里的字符串）。所以也别想着把注册表锁成只读：挡住了重置，150% 回到 100% 后
# 10pt（20px）会原样变成 15pt。
#
# 能做的是被重置之后写回去：往 HKLM\...\Run 登记 logon_window_metrics.ps1，每个用户
# 每次登录查一遍，被重置了就按当前 DPI 重写。
#   · 只在字号或字重非默认时才装（Test-MetricsAutoRestoreNeeded）。这一层挂的就是
#     Windows 重置回落的那个族（文件开头的 $YaHei），所以默认 9pt Regular 时重置写出来
#     的和我们装的【一模一样】，没必要每次登录跑脚本、闪窗口。
#   · 用 Run 不用计划任务：Run 由 Explorer 在桌面起来之后才跑，一定排在主题引擎的
#     重置后面；计划任务的登录触发器和它谁先谁后没有保证。
#   · 脚本放 %ProgramFiles%\WinModernSC\：每个账户（包括管理员）登录都会执行它，放在
#     标准用户写得进去的地方就是现成的提权口子。ProgramFiles 默认就是「管理员 /
#     SYSTEM 可写、其余只读」，新建的子目录继承这套权限，不用自己铺 DACL
#     （$TargetDir 那边要自己铺，因为它建在 C:\ 根下，见 main_fonts.ps1）。
#   · 登录时跑的是 PowerShell，控制台程序，会闪一下窗口。已知，接受。
# 覆盖不到的：远程桌面断开后重连不算登录，Run 不会再跑；登录前的界面（.DEFAULT）
# 也没有 Run 可跑。
# 破例的：它不看备份（读不到），所以安装之后才建的账户、安装时备份失败被跳过的
# 账户，登录时也会被写成目标值 —— 这两类不在「改过的 ⊆ 备份过的」之内，-revert
# 手里没有它们的原值。前一类本来就从新用户模板继承了我们的值，要的正是这个效果。
$AutoRestoreRunKey      = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
# Explorer 给 HKLM\...\Run 里每一项记的启用 / 禁用状态，在任务管理器「启动应用」里
# 开关过就会有。Run 值删了它也不会自己消失，还原时一起清。
$AutoRestoreApprovedKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
$AutoRestoreName        = 'WinModernSC'
$AutoRestoreDir         = Join-Path $env:ProgramFiles 'WinModernSC'
# 登录脚本本身，加上它要 dot-source 的本文件
$AutoRestoreScript      = 'logon_window_metrics.ps1'
$AutoRestoreFiles       = @($AutoRestoreScript, 'main_window_metrics.ps1')
# 微软文档：Run 值里的命令行不能超过 260 个字符。
$AutoRestoreMaxCmd      = 260

# Windows 缩放重置后落到的默认值：主题自带的 Regular + 9pt（族名是 $YaHei，正是这一层
# 的目标族）。字号字重正好也是我们两个参数的默认值（main.ps1 的 ValidateRange/ValidateSet）。
$MetricsResetWeight     = 'Regular'
$MetricsResetSize       = 9

# 要不要装登录自动恢复。只在字号或字重【偏离】重置后的默认值时才装：都是默认值的话，
# 重置写出来的 $YaHei 9pt Regular 和我们装的逐字节相同，等于没被动过，没必要每次登录
# 都跑脚本、闪一下窗口。字号是 double，用 double 比，避免 9 和 9.0 被当成不同。
function Test-MetricsAutoRestoreNeeded {
    return (([double]$MetricsSize -ne [double]$MetricsResetSize) -or
            (${window-metrics-weight} -ne $MetricsResetWeight))
}

# 登录时 Run 执行的那一行。
#   · 不管 -install 是在 PowerShell 7 还是 5.1 里跑的，登录时一律用系统自带的
#     Windows PowerShell 5.1：哪台 Windows 都有，路径固定。写全路径，不靠 PATH。
#   · 字号和字重就是这一趟 -install 的参数，写死在命令行里 —— 登录脚本读不到备份
#     JSON。字号按固定区域格式写：德语系统上 10.5 会 ToString 成 "10,5"。
#   · 目标族（main.ps1 的 $SUB）也一起传：登录脚本自己再抄一份的话，$SUB 一改两边就
#     对不上，而那种不一致没有任何东西会报出来，见登录脚本里 $SUB 那几行。
function Get-AutoRestoreCommand {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    return ('"{0}" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}" -Size {2} -Weight {3} -Sub "{4}"' -f `
            $ps, (Join-Path $AutoRestoreDir $AutoRestoreScript),
            ([double]$MetricsSize).ToString([System.Globalization.CultureInfo]::InvariantCulture),
            ${window-metrics-weight}, $SUB)
}

# 登记登录自动恢复，返回写进 Run 的那一行。和别的机制一样只备份一次、先落盘再
# 动手：Run 值的原值（原本没有就记 $null，还原时删掉）、目录是不是我们建的、复制
# 了哪些文件。重跑 -install 换了字号字重，就是把脚本重新复制一遍、把 Run 改写掉。
function Install-MetricsAutoRestore {
    $cmd = Get-AutoRestoreCommand
    if ($cmd.Length -gt $AutoRestoreMaxCmd) {
        throw ('命令行 {0} 个字符，超过 Run 值 {1} 个字符的上限，Windows 不会执行它' -f `
               $cmd.Length, $AutoRestoreMaxCmd)
    }

    $bk = Read-BackupFile
    if ($null -eq $bk) { $bk = [pscustomobject]@{} }
    if (-not (Get-MapValue $bk 'AutoRestore')) {
        Set-MapValue $bk 'AutoRestore' ([ordered]@{
            RunValue   = (Get-RegValueOrNull $AutoRestoreRunKey $AutoRestoreName)
            Dir        = $AutoRestoreDir
            CreatedDir = (-not (Test-Path -LiteralPath $AutoRestoreDir))
            Files      = @($AutoRestoreFiles | ForEach-Object { Join-Path $AutoRestoreDir $_ })
        })
        Write-BackupFile $bk
    }

    if (-not (Test-Path -LiteralPath $AutoRestoreDir)) {
        New-Item -ItemType Directory -Path $AutoRestoreDir -Force | Out-Null
    }
    foreach ($f in $AutoRestoreFiles) {
        Copy-Item -LiteralPath (Join-Path $RootDir "src\$f") -Destination (Join-Path $AutoRestoreDir $f) -Force
    }
    # 最后才写 Run：文件没复制全就登记，登录时只会跑出一个找不到文件的错。
    Set-ItemProperty -Path $AutoRestoreRunKey -Name $AutoRestoreName -Value $cmd -Type String
    $script:WroteSomething = $true
    return $cmd
}

function Show-AutoRestorePlan {
    if (-not (Test-MetricsAutoRestoreNeeded)) {
        Write-Host '  登录自动恢复：字号 9pt、字重 Regular 都是默认值，缩放重置后仍是替换字体，不安装。' -ForegroundColor DarkGray
        $cur = Get-RegValueOrNull $AutoRestoreRunKey $AutoRestoreName
        if ($null -ne $cur) {
            Write-Host ('    注：之前用非默认值装过，本次会拆掉现有的 {0}\{1}。' -f $AutoRestoreRunKey, $AutoRestoreName) -ForegroundColor DarkGray
        }
        return
    }
    $cmd = Get-AutoRestoreCommand
    $cur = Get-RegValueOrNull $AutoRestoreRunKey $AutoRestoreName
    Write-Host '  登录自动恢复（改了显示缩放，Windows 会把上面 6 项重置回默认，由它写回去）：' -ForegroundColor Yellow
    Write-Host ('    {0}\{1}' -f $AutoRestoreRunKey, $AutoRestoreName)
    Write-Host ('      现: {0}' -f $(if ($null -eq $cur) { '(不存在)' } else { $cur })) -ForegroundColor DarkGray
    Write-Host ('      新: {0}' -f $cmd) -ForegroundColor Gray
    Write-Host ('    脚本复制到 {0}\ ：{1}' -f $AutoRestoreDir, ($AutoRestoreFiles -join '、'))
    if ($cmd.Length -gt $AutoRestoreMaxCmd) {
        Write-Host ('    !! 命令行 {0} 个字符，超过 Run 值 {1} 个字符的上限，实际安装时会跳过这一项。' -f `
                    $cmd.Length, $AutoRestoreMaxCmd) -ForegroundColor DarkYellow
    }
}

# 由 main_revert.ps1 最先调用。必须赶在还原字体之前拆：还原中途出错的话它还在，
# 下次登录又会把我们的字号写回去。删不掉就直接抛，让整个还原停在原地、备份留着。
function Remove-MetricsAutoRestore($saved) {
    $ar = Get-MapValue $saved 'AutoRestore'
    if (-not $ar) { return }

    $orig = Get-MapValue $ar 'RunValue'
    if ($null -ne $orig) {
        Set-ItemProperty -Path $AutoRestoreRunKey -Name $AutoRestoreName -Value $orig
        Write-Host ('还原 [AutoRestore] {0} = {1}' -f $AutoRestoreName, $orig) -ForegroundColor Green
    } else {
        if ($null -ne (Get-RegValueOrNull $AutoRestoreRunKey $AutoRestoreName)) {
            Remove-ItemProperty -Path $AutoRestoreRunKey -Name $AutoRestoreName
        }
        if ($null -ne (Get-RegValueOrNull $AutoRestoreApprovedKey $AutoRestoreName)) {
            Remove-ItemProperty -Path $AutoRestoreApprovedKey -Name $AutoRestoreName
        }
        Write-Host ('删除 [AutoRestore] {0}' -f $AutoRestoreName) -ForegroundColor Green
    }

    foreach ($f in @(Get-MapValue $ar 'Files' | Where-Object { $_ })) {
        switch (Remove-InstalledFile ([string]$f)) {
            'deleted'  { Write-Host ("已删除   $f") -ForegroundColor Green }
            'onreboot' { Write-Host ("重启后删除 $f（当前被占用）") -ForegroundColor DarkYellow }
            'missing'  { }
            default    { Write-Host ("删除失败 $f") -ForegroundColor Red }
        }
    }

    # 目录只在是我们建的时候才删。还剩东西的话（登记了重启后删的文件，或者别人放进来
    # 的），也登记重启后删 —— 到时候不空，Windows 自己会放弃，不会误删。
    $dir = [string](Get-MapValue $ar 'Dir')
    if ($dir -and (Get-MapValue $ar 'CreatedDir') -and (Test-Path -LiteralPath $dir) -and (Test-SafeToRemove $dir)) {
        $left = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)
        $gone = $false
        if ($left.Count -eq 0) {
            try { Remove-Item -LiteralPath $dir -Force -ErrorAction Stop; $gone = $true } catch { }
        }
        if ($gone) {
            Write-Host "已删除目录 $dir" -ForegroundColor Green
        } else {
            [void][FontDeploy.Native]::DeleteOnReboot($dir)
            Write-Host "目录 $dir 将在重启后删除" -ForegroundColor DarkYellow
        }
    }
}
