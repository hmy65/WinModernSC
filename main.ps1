<#
    WinModernSC —— 把 source\ 里的字体部署成 Windows 全系统界面字体。

    需要【以管理员身份】运行。所有会被修改的原值都先备份成 JSON，
    -revert 按这份备份完整还原。

    四套机制，各管一层，缺一层就有地方换不掉：
      1  Fonts 注册表键     —— 文件级替换。GDI 和 DirectWrite 都吃这一套，
                              覆盖外壳 / UWP / WinUI / 浏览器 / Office。
                              拉丁那 12 个静态文件、Win11 外壳用的那个可变字体
                              "Segoe UI Variable"，加上中文族(微软雅黑/宋体/
                              黑体/等线)那 9 个，一共 22 个一起装，不单独开关。
                              中文那 9 个里有一档是 Windows 本来没有的雅黑
                              Semibold，给 Segoe UI Semibold 的中文回退用。
      2  FontSubstitutes    —— 只有 GDI 认。兜底那些请求 Tahoma /
                              MS Shell Dlg 的旧式 Win32 程序。
      3  WindowMetrics      —— 经典界面(comctl32)那一层的字体和字号。
                              前两套改不了字号，这一套才行。每用户。
      4  FontLink\SystemLink —— GDI 的中文回退链。Segoe UI 那 12 个静态文件的
                              汉字被裁掉了，GDI 程序显示中文全靠这张表。
                              20 个族：静态那 5 个，加 Segoe UI Variable 被
                              STAT 拆出来的 15 个（3 档光学尺寸 × 5 档字重）。

    用法见 README.md / README_zh-CN.md。

    注意：FontSubstitutes 由 GDI 在会话启动时读取并缓存，光重启字体缓存
          服务不够，必须【注销或重启】才生效。

    本文件必须保存为 UTF-8 with BOM。Windows PowerShell 5.1 在没有 BOM 时
    会按系统 ANSI 代码页去读 .ps1，中文会变乱码并导致解析错误。
#>
[CmdletBinding()]
param(
    [switch]$install,
    [switch]$revert,
    [switch]${no-fonts},
    [switch]${no-font-substitutes},
    [switch]${no-window-metrics},
    [switch]${no-font-link},
    # 机制 3（经典界面）的字号和字重，只管那 6 个 LOGFONT。
    # 9 磅是 Windows 自己的默认值。字重名和 main_window_metrics.ps1 里的
    # $MetricsWeights 一一对应 —— 换字重换的是 GDI 家族名，原因见那边。
    [ValidateRange(6, 24)]
    [double]${window-metrics-size} = 9,
    [ValidateSet('Light', 'Semilight', 'Regular', 'Semibold', 'Bold', 'Black')]
    [string]${window-metrics-weight} = 'Regular',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# ---------------------------------------------------------------- 常量
$FontsKey    = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
$SubstKey    = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\FontSubstitutes'
$FontLinkKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\FontLink\SystemLink'
# main.ps1 所在目录。模块文件里的 $PSScriptRoot 指的是 src\，所以路径一律
# 从这个变量拼，别在模块里用 $PSScriptRoot。
$RootDir     = $PSScriptRoot
$Backup      = Join-Path $PSScriptRoot 'winmodernsc-backup.json'
# 字体文件的落脚点。装到这里而不是 %windir%\Fonts：注册表指过来就行，
# 不用动系统目录，还原时整个目录删掉即可。
$TargetDir   = 'C:\Fonts'
# 所有 GDI 替换的统一目标族
$SUB         = 'Segoe UI'

# 中断时明确告知是否已经动过注册表，避免留在不确定的半吊子状态
$script:WroteSomething = $false
# 被我们停掉的字体缓存服务。必须是数组：PowerShell 对未定义变量做 += 得到的是
# 标量，第二次 += 就变成字符串拼接了。
$script:StoppedServices = @()
$script:StoppedCache = $false
$script:UsedAltName = $false

# ================================================================ 共享 helper
# 下面这些函数各个模块都要用，模块文件靠 dot-source 拿到它们。

# 返回 $null 只有一个含义：备份文件【不存在】，也就是「还没装过」。
# 文件在、内容却读不出或解析不出来时必须抛异常，【绝不能】也返回 $null ——
# 那样各机制会走「第一次安装」的分支，拿【已经被我们改过】的注册表现值重新
# 生成一份备份：原始值就此永久丢失，之后 -revert 会把 Fonts 键"还原"成
# C:\Fonts\... 再把那些文件删掉，系统字体注册项指向一堆不存在的文件。
# -revert 那条路遇到坏文件本来就是直接中止的，这里必须一致。
function Read-BackupFile {
    if (-not (Test-Path -LiteralPath $Backup)) { return $null }
    $raw = $null
    try { $raw = Get-Content -LiteralPath $Backup -Raw -ErrorAction Stop }
    catch {
        # 读不出来（被占用、权限不足）和「文件是空的」是两回事，别混成一句话
        throw ("备份文件读不出来: $Backup`n  " + $_.Exception.Message)
    }
    # 空文件 ConvertFrom-Json 是【不报错】的，会安静地给出 $null，所以得单独挡。
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw ("备份文件是空的: $Backup`n" +
               '上一次写入多半被打断了。挪走它才能继续，但那等于放弃还原到原始状态的能力。')
    }
    try { return ($raw | ConvertFrom-Json) }
    catch {
        throw ("备份文件损坏，解析失败: $Backup`n  " + $_.Exception.Message + "`n" +
               '先修好或挪走它再重试；直接删掉等于放弃还原到原始状态的能力。')
    }
}

function Write-BackupFile($obj) {
    # 用 -InputObject 而不是管道：管道对 IDictionary 的处理容易出意外
    (ConvertTo-Json -InputObject $obj -Depth 8) | Set-Content -LiteralPath $Backup -Encoding UTF8
}

# 同一份数据有两种形态：刚构造出来是 OrderedDictionary，从 JSON 读回来是
# PSCustomObject。前者的键要用 .Keys 取，后者要用属性名 —— 统一走这三个函数。
function Get-MapKeys($o) {
    if ($null -eq $o) { return @() }
    if ($o -is [System.Collections.IDictionary]) { return @($o.Keys) }
    # 【不能】写成 @($o.PSObject.Properties.Name)：属性集合为空时成员枚举返回
    # $null，@() 一包就成了「含一个 $null 的数组」，调用方会拿到 Count=1 空转
    # 一圈。走管道则空集合原样是空。
    return @($o.PSObject.Properties | ForEach-Object { $_.Name })
}

function Get-MapValue($o, [string]$name) {
    if ($null -eq $o) { return $null }
    if ($o -is [System.Collections.IDictionary]) { return $o[$name] }
    $p = $o.PSObject.Properties[$name]
    if ($p) { return $p.Value }
    return $null
}

# PSCustomObject 得走 Add-Member -Force：属性不存在时直接 $o.X = 1 会抛异常。
function Set-MapValue($o, [string]$name, $value) {
    if ($null -eq $o) { return }
    if ($o -is [System.Collections.IDictionary]) { $o[$name] = $value; return }
    $o | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force
}

function Get-RegValueOrNull($key, $name) {
    try { return (Get-ItemPropertyValue -Path $key -Name $name -ErrorAction Stop) }
    catch { return $null }
}

# 列出一个键下的所有值名。
# 不能用 "Get-ItemProperty | Get-Member" —— 键存在但一个值都没有时
# Get-ItemProperty 什么都不输出，管道给 Get-Member 会抛异常。
function Get-RegValueNames($key) {
    if (-not (Test-Path $key)) { return @() }
    try {
        $k = Get-Item -LiteralPath $key -ErrorAction Stop
        return @($k.GetValueNames() | Where-Object { $_ -ne '' -and $_ -ne $null })
    } catch {
        return @()
    }
}

# 刷新字体缓存。FontCache3.0.0.0 是 .NET 3.x 的 WPF 缓存，属可选组件，
# 很多系统根本没装，没有是正常现象。只重启【本来就在运行】的服务。
function Restart-FontCache {
    $restarted = 0
    foreach ($svc in @('FontCache3.0.0.0', 'FontCache')) {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if (-not $s) {
            Write-Host "服务 $svc 本系统没有安装（正常，可选组件）" -ForegroundColor DarkGray
            continue
        }
        if ($s.StartType -eq 'Disabled') {
            Write-Host "服务 $svc 已被禁用，跳过" -ForegroundColor DarkGray
            continue
        }
        if ($s.Status -ne 'Running') {
            # 本来就没在跑的不去动它。但如果是【我们自己】为了腾开文件句柄停掉的，
            # 就必须拉回来 —— FontCache 是 Automatic 启动，放着不管会一直停到
            # 下次重启，整机字体渲染都跟着受影响。
            if ($script:StoppedServices -contains $svc) {
                try {
                    Start-Service -Name $svc -ErrorAction Stop
                    Write-Host "已重新启动服务 $svc（复制文件时被我们停掉的）" -ForegroundColor Green
                    $restarted++
                } catch {
                    Write-Host "重新启动服务 $svc 失败: $($_.Exception.Message)" -ForegroundColor DarkYellow
                }
            } else {
                Write-Host "服务 $svc 当前未运行，无需重启（下次启动会自行重建缓存）" -ForegroundColor DarkGray
            }
            continue
        }
        try {
            Restart-Service -Name $svc -Force -ErrorAction Stop
            Write-Host "已重启服务 $svc（$($s.DisplayName)）" -ForegroundColor Green
            $restarted++
        } catch {
            Write-Host "重启服务 $svc 失败: $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    }
    if ($restarted -eq 0) {
        Write-Host '没有重启任何字体缓存服务；重启系统同样能让改动生效。' -ForegroundColor DarkYellow
    }
}

function Stop-FontCache {
    foreach ($svc in @('FontCache3.0.0.0', 'FontCache')) {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if (-not $s -or $s.Status -ne 'Running') { continue }
        # 只记下【确实被我们停掉的】，收尾时也只把这些拉回来
        try {
            Stop-Service -Name $svc -Force -ErrorAction Stop
            $script:StoppedServices += $svc
        } catch { }
    }
}

function Test-FileIdentical($src, $dst) {
    if (-not (Test-Path -LiteralPath $dst)) { return $false }
    try {
        $a = Get-Item -LiteralPath $src -ErrorAction Stop
        $b = Get-Item -LiteralPath $dst -ErrorAction Stop
    } catch { return $false }
    if ($a.Length -ne $b.Length) { return $false }
    try {
        # 必须写 -ErrorAction Stop。Get-FileHash 打不开文件时发的是【非终止】
        # 错误，catch 抓不住 —— 它会在控制台吐一条红字，然后拿 $null 去比，
        # 下面那条退路根本走不到。同一个 try 里的 Get-Item 已经这么写了。
        return ((Get-FileHash -LiteralPath $src -Algorithm SHA256 -ErrorAction Stop).Hash -eq
                (Get-FileHash -LiteralPath $dst -Algorithm SHA256 -ErrorAction Stop).Hash)
    } catch {
        # 字体一旦被系统加载就是内存映射状态，此时目标文件连读都读不了，
        # 哈希会抛异常。退回比对「大小 + 修改时间」—— Copy-Item 会保留源文件
        # 的修改时间，所以我们自己装过的那一份这两项必然相同。
        return ($a.LastWriteTimeUtc -eq $b.LastWriteTimeUtc)
    }
}

# 复制字体文件，返回实际落地的路径。
# 已经装过的机器上，目标文件会被字体缓存/DWM 内存映射住，Copy-Item -Force
# 会报「正在由另一进程使用」。所以：内容相同就直接跳过；不同就先停字体服务
# 再试；还不行就换个文件名，让注册表指向新文件。
function Copy-FontFile($src, $dstDir) {
    $leaf = Split-Path $src -Leaf
    $dst = Join-Path $dstDir $leaf

    if (Test-FileIdentical $src $dst) {
        return [pscustomobject]@{ Path = $dst; Note = '内容相同，跳过复制' }
    }
    try {
        Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop
        return [pscustomobject]@{ Path = $dst; Note = '' }
    } catch { }

    if (-not $script:StoppedCache) {
        Write-Host '  目标文件被占用，尝试停止字体缓存服务后重试 ...' -ForegroundColor DarkYellow
        Stop-FontCache
        $script:StoppedCache = $true
    }
    try {
        Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop
        return [pscustomobject]@{ Path = $dst; Note = '停服务后复制成功' }
    } catch { }

    $alt = Join-Path $dstDir ('{0}.{1}{2}' -f `
           [IO.Path]::GetFileNameWithoutExtension($leaf),
           (Get-Date -Format 'yyyyMMddHHmmss'),
           [IO.Path]::GetExtension($leaf))
    Copy-Item -LiteralPath $src -Destination $alt -Force -ErrorAction Stop
    $script:UsedAltName = $true
    return [pscustomobject]@{ Path = $alt; Note = '原文件仍被占用，改用新文件名' }
}

# 文件/目录被占用时删不掉，改为登记「重启后删除」。
# 传 $null 作为新名字，MoveFileEx 就是删除语义。
if (-not ('FontDeploy.Native' -as [type])) {
    Add-Type -Namespace FontDeploy -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode, SetLastError=true)]
public static extern bool MoveFileExW(string lpExistingFileName, string lpNewFileName, int dwFlags);
public static bool DeleteOnReboot(string path) { return MoveFileExW(path, null, 0x4); }
'@
}

# 绝不允许把系统目录当成我们的安装目录删掉
function Test-SafeToRemove($path) {
    try { $full = [IO.Path]::GetFullPath($path).TrimEnd('\') } catch { return $false }
    if ([string]::IsNullOrWhiteSpace($full)) { return $false }
    if ($full -match '^[A-Za-z]:$') { return $false }                     # 盘符根目录
    $win = $env:WinDir.TrimEnd('\')
    foreach ($bad in @($win, "$win\Fonts", $env:SystemDrive,
                       ${env:ProgramFiles}, ${env:ProgramFiles(x86)}, $env:ProgramData)) {
        if ($bad -and $full -eq $bad.TrimEnd('\')) { return $false }
    }
    return $true
}

function Remove-InstalledFile($path) {
    if (-not (Test-Path -LiteralPath $path)) { return 'missing' }
    try {
        Remove-Item -LiteralPath $path -Force -ErrorAction Stop
        return 'deleted'
    } catch {
        if ([FontDeploy.Native]::DeleteOnReboot($path)) { return 'onreboot' }
        return 'failed'
    }
}

# ================================================================ 各机制模块
. (Join-Path $PSScriptRoot 'src\main_fonts.ps1')
. (Join-Path $PSScriptRoot 'src\main_font_substitutes.ps1')
. (Join-Path $PSScriptRoot 'src\main_window_metrics.ps1')
. (Join-Path $PSScriptRoot 'src\main_font_link.ps1')
. (Join-Path $PSScriptRoot 'src\main_revert.ps1')

# ================================================================ 参数校验
function Show-Usage {
    Write-Host ''
    Write-Host 'WinModernSC —— 把 source\ 里的字体部署成 Windows 全系统界面字体' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  .\main.ps1 -install                       一键全装'
    Write-Host '  .\main.ps1 -install -no-fonts             跳过字体文件替换（机制 1）'
    Write-Host '  .\main.ps1 -install -no-font-substitutes  跳过 GDI 替换表（机制 2）'
    Write-Host '  .\main.ps1 -install -no-window-metrics    跳过经典界面（机制 3）'
    Write-Host '  .\main.ps1 -install -no-font-link         跳过中文回退链（机制 4）'
    Write-Host '  .\main.ps1 -revert                        一键恢复'
    Write-Host ''
    Write-Host '  4 个 -no-* 可任意组合；加 -DryRun 只打印将要做的改动，不产生任何副作用。'
    Write-Host ''
    Write-Host '  经典界面（机制 3）的字号和字重，跟 -install 一起用：'
    Write-Host '    -window-metrics-size <磅>       默认 9'
    Write-Host '    -window-metrics-weight <字重>   Light / Semilight / Regular / Semibold / Bold / Black，默认 Regular'
    Write-Host ''
}

if ($install -and $revert) {
    throw '-install 和 -revert 只能选一个。'
}
if (-not $install -and -not $revert) {
    Show-Usage
    return
}
# 这两个只对机制 3 的安装有意义。配 -revert 或 -no-window-metrics 时会被静默
# 忽略，而用户多半以为它生效了，所以直接报错。
foreach ($metricsArg in @('window-metrics-size', 'window-metrics-weight')) {
    if (-not $PSBoundParameters.ContainsKey($metricsArg)) { continue }
    if ($revert) { throw "-$metricsArg 只能配 -install：还原一律回到备份里的原值。" }
    if (${no-window-metrics}) { throw "-$metricsArg 和 -no-window-metrics 互相矛盾。" }
}

$admin = ([Security.Principal.WindowsPrincipal] `
          [Security.Principal.WindowsIdentity]::GetCurrent()
         ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin -and -not $DryRun) {
    throw '请以管理员身份运行 PowerShell 后重试。只有 -DryRun 不需要管理员。'
}

trap {
    Write-Host ''
    Write-Host "!! 执行中断: $($_.Exception.Message)" -ForegroundColor Red
    if ($script:WroteSomething) {
        Write-Host '!! 注册表已被部分修改，运行  .\main.ps1 -revert  可还原。' -ForegroundColor Red
    } else {
        Write-Host '!! 尚未做任何修改。' -ForegroundColor Red
    }
    # 复制文件时为了腾开句柄停掉的字体缓存服务，中断了也得拉回来：收尾那次
    # Restart-FontCache 已经轮不到了，不管的话会一直停到下次重启。
    foreach ($svc in $script:StoppedServices) {
        try {
            Start-Service -Name $svc -ErrorAction Stop
            Write-Host "!! 已重新启动服务 $svc（复制文件时被我们停掉的）" -ForegroundColor DarkYellow
        } catch { }
    }
    break
}

# ================================================================ 还原
if ($revert) {
    if (-not (Test-Path -LiteralPath $Backup)) { throw "找不到备份文件: $Backup" }
    # -LiteralPath 一路到底：脚本被解压到 "WinModernSC [1]" 这种带方括号的
    # 目录里时，不带 -LiteralPath 的 Test-Path 会把它当通配符，明明在也报不在。
    # 走 Read-BackupFile：空文件 / 坏 JSON 在那里就抛掉了。
    $saved = Read-BackupFile
    # 内容合法但一个小节都没有（比如 "{}"）也得挡下来，否则下面每一节都是空转，
    # 最后照样打印「已全部还原」，还顺手把备份文件删了 —— 什么都没还原。
    if ($null -eq $saved -or @(Get-MapKeys $saved).Count -eq 0) {
        throw "备份文件里没有任何可还原的内容: $Backup"
    }

    if ($DryRun) {
        Show-RevertPlan $saved
        Write-Host ''
        Write-Host '未做任何修改。去掉 -DryRun 即可实际还原。' -ForegroundColor Yellow
        return
    }
    Invoke-Revert $saved
    return
}

# ================================================================ 安装
$doFonts   = -not ${no-fonts}
$doSubst   = -not ${no-font-substitutes}
$doMetrics = -not ${no-window-metrics}
$doLink    = -not ${no-font-link}

Write-Host ''
Write-Host ('机制 1  字体文件   : {0}' -f $(if ($doFonts)   { '装' } else { '跳过 (-no-fonts)' })) -ForegroundColor White
Write-Host ('机制 2  GDI 替换表 : {0}' -f $(if ($doSubst)   { '装' } else { '跳过 (-no-font-substitutes)' })) -ForegroundColor White
Write-Host ('机制 3  经典界面   : {0}' -f $(if ($doMetrics) { "装（{0}pt {1}）" -f $MetricsSize, ${window-metrics-weight} }
                                            else { '跳过 (-no-window-metrics)' })) -ForegroundColor White
Write-Host ('机制 4  中文回退链 : {0}' -f $(if ($doLink)    { '装' } else { '跳过 (-no-font-link)' })) -ForegroundColor White
Write-Host ('目标族   : {0}     字体落脚点 : {1}' -f $SUB, $TargetDir) -ForegroundColor White

# 一致性提醒：机制 2/3 都把字体请求引向 "Segoe UI"，而这个族要靠机制 1 装的
# 12 个文件撑起来。跳过机制 1 的话那一族还是微软原版，观感不会变。
if (-not $doFonts -and ($doSubst -or $doMetrics -or $doLink)) {
    Write-Host ''
    Write-Host ('!! -no-fonts 跳过了字体文件，但机制 2/3 仍会把请求引向 "{0}"。' -f $SUB) -ForegroundColor DarkYellow
    Write-Host '   除非之前已经装过一次，否则那一族还是微软原版，观感不会变。' -ForegroundColor DarkYellow
    if ($doLink) {
        Write-Host '   机制 4 则会整个跳过：没有我们的文件可指，插进去等于没插。' -ForegroundColor DarkYellow
        Write-Host '   所以下面「N 条中文回退链」报 0 是正常的，不是出错。' -ForegroundColor DarkYellow
    }
}

if ($DryRun) {
    Write-Host ''
    Write-Host '=== DryRun：以下改动都不会真正写入 ===' -ForegroundColor Yellow
    if ($doFonts)   { Show-FontsPlan }
    if ($doSubst)   { Show-SubstitutesPlan }
    if ($doMetrics) { Show-WindowMetricsPlan }
    if ($doLink)    { Show-FontLinkPlan }
    Write-Host ''
    Write-Host ("备份文件将写到 : {0}{1}" -f $Backup,
                $(if (Test-Path -LiteralPath $Backup) { '   [已存在，原值会保留]' } else { '' })) -ForegroundColor Yellow
    Write-Host '未做任何修改。去掉 -DryRun 即可实际执行。' -ForegroundColor Yellow
    return
}

$fontCount = 0
$substCount = 0
$linkCount = 0
$metricsCount = 0

if ($doFonts) { $fontCount = Invoke-FontsApply }
if ($doSubst) { $substCount = Invoke-SubstitutesApply }
# 机制 3 和 4 都必须排在机制 1 之后：
#   3 写进 WindowMetrics 的 "Segoe UI" 要等 Fonts 键指向改造后的文件才算数；
#   4 的回退链第一行读的正是 Fonts 键里雅黑指向的文件。
# 这两者之间没有先后要求，按编号来。
if ($doMetrics) { $metricsCount = Invoke-WindowMetricsApply }
if ($doLink) { $linkCount = Invoke-FontLinkApply }

# 提示一下有没有只对单个用户生效的字体注册。提权后 HKCU: 指向的是管理员自己，
# 所以要走 HKEY_USERS 才看得到真正登录的那个用户。整段只是提示，不能影响部署。
try {
    $perUser = @()
    foreach ($hive in (Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue)) {
        $sid = Split-Path $hive.Name -Leaf
        # 本地 / 域账户 S-1-5-21-*，Entra ID 账户 S-1-12-1-*，同 Get-MetricsTargets
        if (($sid -notlike 'S-1-5-21-*' -and $sid -notlike 'S-1-12-1-*') -or
            $sid -like '*_Classes') { continue }
        $k = "Registry::HKEY_USERS\$sid\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts"
        $names = Get-RegValueNames $k
        if ($names.Count -eq 0) { continue }
        $who = $sid
        try {
            $who = (New-Object System.Security.Principal.SecurityIdentifier $sid).Translate(
                       [System.Security.Principal.NTAccount]).Value
        } catch { }
        $perUser += [pscustomobject]@{ Who = $who; Names = $names }
    }
    if ($perUser.Count) {
        Write-Host ''
        Write-Host '提示：以下字体是【按用户】注册的，只对该用户生效，其他用户和登录界面看不到：' -ForegroundColor DarkYellow
        foreach ($u in $perUser) {
            Write-Host ("    [$($u.Who)]") -ForegroundColor DarkYellow
            foreach ($n in $u.Names) { Write-Host ("      $n") -ForegroundColor DarkYellow }
        }
        Write-Host '    本次部署已全部写入 HKLM，不受其影响；上面这些可自行清理。' -ForegroundColor DarkYellow
    }
} catch {
    Write-Host "用户级字体注册检查跳过: $($_.Exception.Message)" -ForegroundColor DarkGray
}

Restart-FontCache

Write-Host ''
Write-Host ("完成：{0} 个字体条目 + {1} 条 GDI 替换 + {2} 条中文回退链 + {3} 个配置单元的经典界面。" -f `
            $fontCount, $substCount, $linkCount, $metricsCount) -ForegroundColor Cyan
if ($doSubst) {
    Write-Host 'FontSubstitutes 由 GDI 在会话启动时缓存，必须【注销或重启】才生效。' -ForegroundColor Cyan
}
if ($doFonts) {
    Write-Host '中文族已文件级接管：网页和 Office 文档里指定 微软雅黑/宋体 的中文也会跟着变。' -ForegroundColor Cyan
    Write-Host '新宋体(等宽)、楷体、仿宋未动，仍是原版。' -ForegroundColor Cyan
}
if ($doMetrics) {
    Write-Host '经典界面对当前用户已立即生效（已打开的程序要重启）；其他用户下次登录生效。' -ForegroundColor Cyan
}
Write-Host '出问题时: 进安全模式运行  .\main.ps1 -revert' -ForegroundColor Cyan
