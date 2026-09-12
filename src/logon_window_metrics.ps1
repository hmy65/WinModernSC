<#
    WinModernSC —— 登录时的经典界面检查，机制 3 的自动恢复。

    显示缩放一变，Windows 会在下一次登录时把 WindowMetrics 那 6 个字体整个重置成
    主题自带的默认值，-install 写的字号、字重、族名一起丢掉。原因和对策见
    main_window_metrics.ps1 末尾「登录自动恢复」那一节。

    -install 把本文件和 main_window_metrics.ps1 一起复制到 %ProgramFiles%\WinModernSC\，
    再往 HKLM\...\Run 登记，于是每个用户每次登录都跑一遍：6 个字体还是目标值就什么
    都不做；被重置了就按当前 DPI 重写，走的就是 -install 给当前用户用的那条
    SystemParametersInfo 路径（Set-MetricsViaSpi），结果和重跑一次 -install 相同。

    每次登录都要跑，所以「什么都不用做」那条路要尽量短 —— 它只读一次注册表就收工
    （Test-MetricsInRegistry），既不调 SPI 也不编 P/Invoke（见 Initialize-SpiType）。
    剩下的就是 powershell.exe 自己的启动时间，窗口闪一下的时长基本就是它。

    运行环境和 main.ps1 不一样：
      · 普通用户权限，不提权，只动当前用户自己的会话和 HKCU；
      · 窗口是隐藏的，出错没人看得见，而且绝不能卡住登录，所以整个包在 try 里；
      · 读不到备份 JSON —— 那份文件在装的人自己的目录里，别的账户进不去 ——
        目标族、字号、字重全由 Run 那一行命令直接传进来。

    手动跑一遍，能看到它做了什么：
      powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\WinModernSC\logon_window_metrics.ps1" -Size 10 -Weight Semibold

    本文件必须保存为 UTF-8 with BOM，理由同 main.ps1。
#>
param(
    [double]$Size = 9,
    [string]$Weight = 'Regular',
    # 默认值只管手动跑这一种情况：-install 登记的那行命令一定把它显式传进来，
    # 以 main.ps1 的 $SUB 为准（见 Get-AutoRestoreCommand）。
    [string]$Sub = 'Segoe UI'
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# main_window_metrics.ps1 顶层要用的三个变量，和 main.ps1 里同名同义。
# 三个都由 Run 那行命令传进来，不在这里写死：$SUB 是 main.ps1 那边可调的旋钮
# （机制 2 也吃它），这边再抄一份的话，它一改，登录脚本算出来的族名就和安装写进去的
# 对不上 —— 每次登录都会判定「被重置了」，把 6 项改写成过时的族名，还没人报错。
# 字重名不对的话，main_window_metrics.ps1 加载时自己会抛。
$SUB = $Sub
${window-metrics-size} = $Size
${window-metrics-weight} = $Weight

# 和 main.ps1 里那份相同。Get-CaptionTarget 靠它读原值，原值有两种形态：
# 刚构造的 OrderedDictionary 和从 JSON 读回来的 PSCustomObject。
function Get-MapValue($o, [string]$name) {
    if ($null -eq $o) { return $null }
    if ($o -is [System.Collections.IDictionary]) { return $o[$name] }
    $p = $o.PSObject.Properties[$name]
    if ($p) { return $p.Value }
    return $null
}

try {
    . (Join-Path $PSScriptRoot 'main_window_metrics.ps1')

    # 快速路径。绝大多数登录根本没发生过重置，这一趟只读注册表就该收工 —— 不碰 SPI，
    # 也就不用现拉 csc.exe 编那段 P/Invoke（见 Initialize-SpiType），窗口少闪一会儿。
    # 它说「不一致」不算数，接着走下面那条会话判定。
    if (Test-MetricsInRegistry) {
        Write-Host ('经典界面仍是 {0} {1}pt，无需恢复。' -f $MetricsFace, $MetricsSize)
        return
    }

    if (Test-MetricsInSession) {
        Write-Host ('经典界面仍是 {0} {1}pt（注册表另说），无需恢复。' -f $MetricsFace, $MetricsSize)
        return
    }

    # 标题栏高度按「被重置之后的现状」算：Windows 刚把它连同字体一起打回了默认，
    # 这就等于在一台没装过的机器上跑 -install。Update-MetricsHive -BackupOnly
    # 只读不写，拿到的正是 Get-CaptionTarget 要的那种原值。
    $original = Update-MetricsHive ([Microsoft.Win32.Registry]::CurrentUser) -BackupOnly
    $dpi = Set-MetricsViaSpi -Original $original
    Write-Host ('已恢复经典界面：{0} {1}pt (dpi={2})' -f $MetricsFace, $MetricsSize, $dpi)
} catch {
    # 只打印，退出码照样是 0：登录时没人看退出码，而默认终端是 Windows Terminal 时，
    # 非 0 退出可能让它把窗口留在屏幕上显示退出代码，一闪而过就变成了一直挂着。
    Write-Host ('恢复经典界面失败: ' + $_.Exception.Message)
}
