# 回退：按备份 JSON 把所有改过的键完整还原，并删掉装进去的字体文件。
#
# 备份 JSON 的几个小节，各对应一套机制：
#   Fonts           机制 1          值 = 原来的路径，$null = 原本不存在
#   FontSubstitutes 机制 2          同上
#   WindowMetrics   机制 3          每个配置单元 6 个 base64 LOGFONT + 2 个标量
#   AutoRestore     机制 3 的登录自动恢复：Run 值原值、脚本目录和文件清单
#   FontLink        机制 4          值是 REG_MULTI_SZ，要包成数组写回
#   Install         装了哪些文件、目录是不是我们建的

# 注册表那三节共用的表：小节名 -> 注册表键 + 是不是 MULTI_SZ
$RevertRegSections = @(
    [pscustomobject]@{ Name = 'Fonts';           Key = $FontsKey;    Multi = $false }
    [pscustomobject]@{ Name = 'FontSubstitutes'; Key = $SubstKey;    Multi = $false }
    [pscustomobject]@{ Name = 'FontLink';        Key = $FontLinkKey; Multi = $true }
)

# -revert -DryRun：把备份里记着的东西摊开，让人确认「确实能回到原点」，
# 一个字节都不改。
function Show-RevertPlan($saved) {
    Write-Host ''
    Write-Host '=== -revert 计划（只读，不会改任何东西）===' -ForegroundColor Yellow
    Write-Host ("备份文件 : {0}" -f $Backup)
    Write-Host ("备份小节 : {0}" -f ((Get-MapKeys $saved) -join '、'))

    foreach ($s in $RevertRegSections) {
        $data = Get-MapValue $saved $s.Name
        $names = @(Get-MapKeys $data)
        if ($names.Count -eq 0) { continue }
        $del = @($names | Where-Object { $null -eq (Get-MapValue $data $_) })
        Write-Host ''
        Write-Host ('  [{0}] {1} 项：还原 {2} 项原值，删除 {3} 项本来不存在的' -f `
                    $s.Name, $names.Count, ($names.Count - $del.Count), $del.Count)
        foreach ($n in $names) {
            $old = Get-MapValue $data $n
            # MULTI_SZ 一个值就是【一条】链，@($old).Count 数的是链【里】有几行。
            # 写成「N 条链」会和 main.ps1 收尾那句「{0} 条中文回退链」（数的是
            # 族数）打架，同一个量词指两个东西。
            $what = if ($null -eq $old) { '删除（原本不存在）' }
                    elseif ($s.Multi)   { '还原原链 ' + @($old).Count + ' 行' }
                    else                { '还原为 ' + $old }
            Write-Host ('      {0,-44} {1}' -f $n, $what) -ForegroundColor DarkGray
        }
    }

    $ar = Get-MapValue $saved 'AutoRestore'
    if ($ar) {
        $orig = Get-MapValue $ar 'RunValue'
        $files = @(Get-MapValue $ar 'Files' | Where-Object { $_ })
        Write-Host ''
        Write-Host ('  [AutoRestore] 登录自动恢复，最先拆：Run 值 {0} {1}' -f $AutoRestoreName,
                    $(if ($null -eq $orig) { '删除（原本不存在）' } else { '还原为 ' + $orig }))
        Write-Host ('      删除 {0} 个脚本，目录 {1}（{2}）' -f $files.Count, (Get-MapValue $ar 'Dir'),
                    $(if (Get-MapValue $ar 'CreatedDir') { '本脚本创建，清空后连目录一起删' } else { '非本脚本创建，只删文件' })) -ForegroundColor DarkGray
    }

    $wm = Get-MapValue $saved 'WindowMetrics'
    if ($wm) {
        Write-Host ''
        Write-Host ('  [WindowMetrics] {0} 个配置单元：' -f @(Get-MapKeys $wm).Count)
        foreach ($k in (Get-MapKeys $wm)) {
            $e = Get-MapValue $wm $k
            $vals = Get-MapValue $e 'Values'
            $have = @(Get-MapKeys $vals | Where-Object { $null -ne (Get-MapValue $vals $_) })
            Write-Host ('      {0,-42} 还原 {1} 项 / 删除 {2} 项  (dpi={3})' -f `
                        (Get-MapValue $e 'Who'), $have.Count,
                        (@(Get-MapKeys $vals).Count - $have.Count), (Get-MapValue $e 'Dpi')) -ForegroundColor DarkGray
        }
    }

    $inst = Get-MapValue $saved 'Install'
    Write-Host ''
    if ($inst) {
        # 必须滤空：Install 节在、Files 缺时 @($null) 是一个元素，下面的
        # Test-Path -LiteralPath '' 会抛「参数不能为空字符串」。
        $files = @(Get-MapValue $inst 'Files' | Where-Object { $_ })
        $exist = @($files | Where-Object { Test-Path -LiteralPath ([string]$_) })
        Write-Host ('  [文件] 清单 {0} 个，其中 {1} 个还在，会删除。目录 {2}（{3}）' -f `
                    $files.Count, $exist.Count, (Get-MapValue $inst 'TargetDir'),
                    $(if (Get-MapValue $inst 'CreatedDir') { '本脚本创建，清空后连目录一起删' } else { '非本脚本创建，只删文件' }))
    } else {
        Write-Host '  [文件] 备份里没有安装清单，没有字体文件要删。' -ForegroundColor DarkGray
    }
}

function Invoke-Revert($saved) {
    # 登录自动恢复最先拆，理由见 Remove-MetricsAutoRestore。
    Remove-MetricsAutoRestore $saved

    # 先还原不涉及文件的那几层。它们失败了也不影响后面删字体。
    Restore-WindowMetricsSection $saved

    foreach ($s in $RevertRegSections) {
        $data = Get-MapValue $saved $s.Name
        foreach ($n in (Get-MapKeys $data)) {
            $old = Get-MapValue $data $n
            if ($null -eq $old) {
                # 原本不存在 —— 删除我们新加的条目
                Remove-ItemProperty -Path $s.Key -Name $n -ErrorAction SilentlyContinue
                Write-Host ("删除 [{0}] {1}" -f $s.Name, $n) -ForegroundColor Green
            } elseif ($s.Multi) {
                # REG_MULTI_SZ 必须包成数组还原，否则单元素的那条会被写成 REG_SZ
                Set-ItemProperty -Path $s.Key -Name $n -Value @($old) -Type MultiString
                Write-Host ("还原 [{0}] {1}" -f $s.Name, $n) -ForegroundColor Green
            } else {
                Set-ItemProperty -Path $s.Key -Name $n -Value $old
                Write-Host ("还原 [{0}] {1,-44} = {2}" -f $s.Name, $n, $old) -ForegroundColor Green
            }
        }
    }

    # 先重启字体缓存，让服务放开对字体文件的句柄，再删文件成功率更高
    Restart-FontCache

    $inst = Get-MapValue $saved 'Install'
    if ($inst) {
        $dir = [string](Get-MapValue $inst 'TargetDir')
        $createdDir = [bool](Get-MapValue $inst 'CreatedDir')
        $files = @(Get-MapValue $inst 'Files' | Where-Object { $_ })

        Write-Host ''
        $del = $reboot = $fail = 0
        foreach ($f in $files) {
            switch (Remove-InstalledFile ([string]$f)) {
                'deleted'  { $del++;    Write-Host ("已删除   $f") -ForegroundColor Green }
                'onreboot' { $reboot++; Write-Host ("重启后删除 $f（当前被占用）") -ForegroundColor DarkYellow }
                'missing'  { }
                default    { $fail++;   Write-Host ("删除失败 $f") -ForegroundColor Red }
            }
        }
        Write-Host ("字体文件：已删除 {0}，重启后删除 {1}，失败 {2}" -f $del, $reboot, $fail)

        # 目录本身：只在【我们创建的】或【已经空了】时才删，且绝不碰系统目录
        if ($dir -and (Test-Path -LiteralPath $dir)) {
            $left = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)
            if (-not (Test-SafeToRemove $dir)) {
                Write-Host "目录 $dir 属于系统关键路径，不删除。" -ForegroundColor DarkYellow
            } elseif (-not $createdDir -and $left.Count -gt 0) {
                Write-Host "目录 $dir 非本脚本创建且尚有其它文件，保留。" -ForegroundColor DarkGray
            } elseif ($left.Count -eq 0) {
                try {
                    Remove-Item -LiteralPath $dir -Force -ErrorAction Stop
                    Write-Host "已删除目录 $dir" -ForegroundColor Green
                } catch {
                    [void][FontDeploy.Native]::DeleteOnReboot($dir)
                    Write-Host "目录 $dir 将在重启后删除" -ForegroundColor DarkYellow
                }
            } else {
                # 我们建的目录，但还有文件（多半是被占用、已登记重启后删除）
                [void][FontDeploy.Native]::DeleteOnReboot($dir)
                Write-Host "目录 $dir 仍有 $($left.Count) 个文件被占用，已登记重启后删除。" -ForegroundColor DarkYellow
            }
        }
    }

    # 还原完成后备份就没用了，留着反而会让下次安装误以为「已备份过」
    try {
        Remove-Item -LiteralPath $Backup -Force -ErrorAction Stop
        Write-Host "已移除备份文件 $Backup" -ForegroundColor DarkGray
    } catch { }

    Write-Host ''
    Write-Host '已全部还原。必须【注销或重启】才会完全生效。' -ForegroundColor Cyan
}
