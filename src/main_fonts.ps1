# 机制 1：Fonts 注册表键，文件级替换。
#
# 把 Fonts 键里的注册项指向我们生成的文件。GDI 和 DirectWrite 都从字体文件的
# name 表读族名，所以这一层两条渲染路径都认，覆盖面最广。
#
# 两组文件：
#   拉丁 = "Segoe UI" 那 12 个静态文件 + "Segoe UI Variable" 那 1 个可变字体
#          （都在 SegoeUIMod\）
#   汉字 = 微软雅黑/宋体/黑体/等线 那 9 个（CJKMod\）
# 两组一起装：拉丁那些文件的汉字已经裁掉了，外壳的中文要靠回退落到
# 「微软雅黑」，也就是落到汉字这一组。只装其中一半，中文就还是原版微软雅黑。
#
# 雅黑 Semibold 那一项是 Windows 本来【没有】的，原值记成「不存在」，还原时
# 删掉。它给 "Segoe UI Semibold" 的中文回退用（机制 4），为什么要多造这一档
# 见 make_cjk.py 开头。
#
# Segoe UI Variable 是【另一个】注册项、另一个文件：Windows 11 的外壳（设置、
# 开始菜单、通知中心）和所有 WinUI 3 程序用的是它，不是上面那 12 个静态文件。
# 少了它，Win11 外壳那一层文字就一直是微软原版。和另外 21 个一起装、一起还原，
# 不单独开关 —— 它和那 12 个静态文件是同一族的两种形态，分开装只会得到一半
# 换了一半没换的界面。
#
# 不动的：新宋体(等宽，老程序拿它对齐表格)、楷体/仿宋(书法体)、
#         SimSun-ExtB/ExtG(生僻字扩展)、微軟正黑體(繁体)。
# 新宋体和宋体挤在同一个注册项下，所以 WinModernSC-SimSun.ttc 里 face0 是替身，
# face1 是原样搬过来的新宋体。

$MapUI = [ordered]@{
    'Segoe UI (TrueType)'                  = 'SegoeUIMod\SegoeUI-Regular.ttf'
    'Segoe UI Bold (TrueType)'             = 'SegoeUIMod\SegoeUI-Bold.ttf'
    'Segoe UI Italic (TrueType)'           = 'SegoeUIMod\SegoeUI-Italic.ttf'
    'Segoe UI Bold Italic (TrueType)'      = 'SegoeUIMod\SegoeUI-BoldItalic.ttf'
    'Segoe UI Light (TrueType)'            = 'SegoeUIMod\SegoeUI-Light.ttf'
    'Segoe UI Light Italic (TrueType)'     = 'SegoeUIMod\SegoeUI-LightItalic.ttf'
    'Segoe UI Semilight (TrueType)'        = 'SegoeUIMod\SegoeUI-Semilight.ttf'
    'Segoe UI Semilight Italic (TrueType)' = 'SegoeUIMod\SegoeUI-SemilightItalic.ttf'
    'Segoe UI Semibold (TrueType)'         = 'SegoeUIMod\SegoeUI-Semibold.ttf'
    'Segoe UI Semibold Italic (TrueType)'  = 'SegoeUIMod\SegoeUI-SemiboldItalic.ttf'
    'Segoe UI Black (TrueType)'            = 'SegoeUIMod\SegoeUI-Black.ttf'
    'Segoe UI Black Italic (TrueType)'     = 'SegoeUIMod\SegoeUI-BlackItalic.ttf'
    'Segoe UI Variable (TrueType)'         = 'SegoeUIMod\SegoeUI-Variable.ttf'
}

$MapCJK = [ordered]@{
    'Microsoft YaHei & Microsoft YaHei UI (TrueType)'                   = 'CJKMod\WinModernSC-YaHei.ttc'
    'Microsoft YaHei Bold & Microsoft YaHei UI Bold (TrueType)'         = 'CJKMod\WinModernSC-YaHei-Bold.ttc'
    'Microsoft YaHei Light & Microsoft YaHei UI Light (TrueType)'       = 'CJKMod\WinModernSC-YaHei-Light.ttc'
    'Microsoft YaHei Semibold & Microsoft YaHei UI Semibold (TrueType)' = 'CJKMod\WinModernSC-YaHei-Semibold.ttc'
    'SimSun & NSimSun (TrueType)'                                       = 'CJKMod\WinModernSC-SimSun.ttc'
    'SimHei (TrueType)'                                                 = 'CJKMod\WinModernSC-SimHei.ttf'
    'DengXian (TrueType)'                                               = 'CJKMod\WinModernSC-DengXian.ttf'
    'DengXian Bold (TrueType)'                                          = 'CJKMod\WinModernSC-DengXian-Bold.ttf'
    'DengXian Light (TrueType)'                                         = 'CJKMod\WinModernSC-DengXian-Light.ttf'
}

# 注册表值名 -> 源文件绝对路径 + 在不在，两条路径共用。
function Get-FontSourceState {
    $out = @()
    foreach ($map in @($MapUI, $MapCJK)) {
        foreach ($e in $map.GetEnumerator()) {
            $src = Join-Path $RootDir $e.Value
            $out += [pscustomobject]@{
                Key    = $e.Key
                Rel    = $e.Value
                Src    = $src
                Exists = (Test-Path -LiteralPath $src)
            }
        }
    }
    return $out
}

function Get-MissingFontHint($rel) {
    if ($rel -like 'CJKMod\*') { return 'python src\make_cjk.py' }
    # SegoeUIMod\ 里住着两个脚本的产物：12 个静态文件归 make_segoe_ui.py，
    # 那一个可变字体归 make_vf.py。按目录分不出来，得按文件名分。
    if ($rel -like '*\SegoeUI-Variable.ttf') { return 'python src\make_vf.py' }
    return 'python src\make_segoe_ui.py'
}

function Show-FontsPlan {
    $state = @(Get-FontSourceState)
    $missing = @($state | Where-Object { -not $_.Exists })
    Write-Host ''
    Write-Host ('=== 机制 1  Fonts 注册表键，{0} 个条目 ===' -f $state.Count) -ForegroundColor Yellow
    foreach ($s in $state) {
        $dst = Join-Path $TargetDir (Split-Path $s.Src -Leaf)
        $note = if (-not $s.Exists) { '   [源文件不存在！]' }
                elseif (Test-FileIdentical $s.Src $dst) { '   [文件已就位，无需复制]' }
                elseif (Test-Path -LiteralPath $dst) { '   [目标已存在但内容不同，将覆盖]' }
                else { '' }
        Write-Host ("  {0}" -f $s.Key)
        Write-Host ("      现: {0}" -f (Get-RegValueOrNull $FontsKey $s.Key)) -ForegroundColor DarkGray
        Write-Host ("      新: {0}{1}" -f $dst, $note) -ForegroundColor Gray
    }
    if ($missing.Count) {
        Write-Host ''
        Write-Host ('!! {0} 个源文件还没生成，实际安装会在这里停下：' -f $missing.Count) -ForegroundColor Yellow
        foreach ($m in ($missing | Group-Object { Get-MissingFontHint $_.Rel })) {
            Write-Host ('     先运行  {0}   （缺 {1} 个）' -f $m.Name, $m.Count) -ForegroundColor DarkYellow
        }
    }
    $exists = Test-Path -LiteralPath $TargetDir
    Write-Host ("  目录 {0}{1}：{2}" -f $TargetDir,
                $(if ($exists) { '（已存在）' } else { '（将新建）' }),
                $(if ($exists) { '本脚本建的会锁成管理员可写、其余只读；别人预先建的保留原权限' }
                  else { '会锁成管理员 / SYSTEM 可写、其余只读（对齐 C:\Windows\Fonts）' })) -ForegroundColor DarkGray
}

function Invoke-FontsApply {
    $state = @(Get-FontSourceState)
    # 先确认所有源文件都在，避免装到一半把系统搞成半残
    $missing = @($state | Where-Object { -not $_.Exists })
    if ($missing.Count) {
        $hints = @($missing | ForEach-Object { Get-MissingFontHint $_.Rel } | Sort-Object -Unique)
        throw ("有 {0} 个字体文件还没生成，第一个是: {1}`n请先运行: {2}" -f `
               $missing.Count, $missing[0].Src, ($hints -join ' 和 '))
    }

    # --- 备份。只备份一次：再存一遍存下来的是【我们自己写的值】，
    #     那就永远还原不回原始状态了。
    $bk = Read-BackupFile
    if ($null -eq $bk) { $bk = [pscustomobject]@{} }
    $fonts = Get-MapValue $bk 'Fonts'
    if ($null -eq $fonts) {
        $fonts = [ordered]@{}
        # 把现有的 Segoe UI* 全记下来 —— 不只是我们要改的那 12 个，
        # 免得漏了 Windows 版本差异带来的额外条目。
        foreach ($n in (Get-RegValueNames $FontsKey)) {
            if ($n -like 'Segoe UI*') { $fonts[$n] = Get-RegValueOrNull $FontsKey $n }
        }
        Set-MapValue $bk 'Fonts' $fonts
        $fonts = Get-MapValue $bk 'Fonts'
    } else {
        Write-Host ("Fonts 备份已存在，保留原值: {0}" -f $Backup) -ForegroundColor DarkGray
    }
    # 本次要改、之前没备份过的值名，补录当前值。已备份的绝不覆盖。
    $known = @(Get-MapKeys $fonts)
    foreach ($s in $state) {
        if ($known -notcontains $s.Key) {
            Set-MapValue $fonts $s.Key (Get-RegValueOrNull $FontsKey $s.Key)
        }
    }
    # 必须先落盘再写注册表：中途失败（磁盘满、文件占用）也还原得回去。
    Write-BackupFile $bk
    Write-Host ("已备份 {0} 个 Fonts 值 -> {1}" -f @(Get-MapKeys $fonts).Count, $Backup) -ForegroundColor Yellow

    # --- 复制到稳定路径，并确保所有用户可读
    $dirExisted = Test-Path -LiteralPath $TargetDir
    if (-not $dirExisted) { New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null }
    $createdDir = (-not $dirExisted)
    $prevInst = Get-MapValue $bk 'Install'
    if ($prevInst -and (Get-MapValue $prevInst 'CreatedDir')) { $createdDir = $true }

    # C:\Fonts 会被 Fonts 注册项指向，【每个用户、包括管理员和登录界面】都会加载
    # 里面的文件。所以它必须像 C:\Windows\Fonts 那样：管理员 / SYSTEM 可写，其他人
    # 只读。默认继承来的权限【不能】直接用 —— 新建在 C:\ 根下的目录会继承根目录的
    # "Authenticated Users:(M)"（改写权），于是任何标准用户都能替换全机所有账户在用
    # 的界面字体，还能拿这些被高权限进程解析的字体文件当本地提权面。所以断掉继承，
    # 重铺一套显式 DACL。
    #
    # 授权对象和 C:\Windows\Fonts 对齐（icacls 实测）：
    #   NT AUTHORITY\SYSTEM                  S-1-5-18     完全控制
    #   BUILTIN\Administrators               S-1-5-32-544 完全控制
    #   BUILTIN\Users                        S-1-5-32-545 只读 + 执行
    #   ALL APPLICATION PACKAGES             S-1-15-2-1   只读 + 执行
    #   ALL RESTRICTED APPLICATION PACKAGES  S-1-15-2-2   只读 + 执行
    # 后两个不能省：AppContainer 进程（MSIX/UWP/WinUI3）鉴权分两段，除了常规组 SID
    # 那一遍，DACL 里还得单独命中包 SID 或这两个通配 SID 才放行。全用众所周知 SID，
    # 不靠本地化账户名。五条都带 ContainerInherit,ObjectInherit，复制进来的文件跟着
    # 继承这套受保护 DACL。
    #
    # 只在【我们自己建的】目录上重铺权限（$createdDir，含之前某趟建的）。C:\Fonts
    # 若是别人预先建好的，不知道人家拿它做什么，不擅自改它的 ACL，只提示一句。
    $grantees = @(
        @{ Sid = 'S-1-5-18';     Rights = 'FullControl'    }
        @{ Sid = 'S-1-5-32-544'; Rights = 'FullControl'    }
        @{ Sid = 'S-1-5-32-545'; Rights = 'ReadAndExecute' }
        @{ Sid = 'S-1-15-2-1';   Rights = 'ReadAndExecute' }
        @{ Sid = 'S-1-15-2-2';   Rights = 'ReadAndExecute' }
    )
    if ($createdDir) {
        try {
            # -ErrorAction Stop：Get-Acl / Set-Acl 也发非终止错误，不写的话 catch
            # 抓不住，会绕过下面那句「锁定权限失败」直接把红字甩给用户。
            $acl = Get-Acl -LiteralPath $TargetDir -ErrorAction Stop
            # 断继承，且【不】把继承来的 ACE 复制成显式（第二个参数 false）：C:\ 那条
            # Authenticated Users 改写权就此不在这个目录上生效。
            $acl.SetAccessRuleProtection($true, $false)
            # 断继承后可能还留着历史【显式】ACE（重装、或别的工具加过的），先清干净
            # 再铺，保证最终就是上面那五条，不多不少。继承来的这时已经不在集合里，
            # 只删非继承的。
            foreach ($r in @($acl.Access | Where-Object { -not $_.IsInherited })) {
                [void]$acl.RemoveAccessRule($r)
            }
            foreach ($g in $grantees) {
                # SID 串合法就能构造，不要求当前系统能翻译成账户名，所以
                # S-1-15-2-* 在没有 AppContainer 的老系统上也不会抛。
                $sid = New-Object System.Security.Principal.SecurityIdentifier $g.Sid
                $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $sid, $g.Rights, 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
            }
            Set-Acl -LiteralPath $TargetDir -AclObject $acl -ErrorAction Stop
            Write-Host "$TargetDir 权限已锁定：管理员 / SYSTEM 可写，其余只读（含 UWP 沙箱），标准用户不能改。" -ForegroundColor Green
        } catch {
            Write-Host "锁定 $TargetDir 权限失败: $($_.Exception.Message)" -ForegroundColor DarkYellow
            Write-Host "  标准用户可能仍能写入，建议手动比对  icacls C:\Windows\Fonts  收紧。" -ForegroundColor DarkYellow
        }
    } else {
        Write-Host "$TargetDir 非本脚本创建，保留其现有权限不动。" -ForegroundColor DarkGray
        Write-Host "  提示：若它继承了 C:\ 的 'Authenticated Users:(M)'，标准用户能替换字体文件；" -ForegroundColor DarkYellow
        Write-Host "        可手动比对  icacls C:\Windows\Fonts  自行收紧。" -ForegroundColor DarkYellow
    }

    $installedFiles = @()
    # 清单在 finally 里落盘：复制到一半失败（磁盘满、换了文件名还是写不进去）
    # 时，前面已经复制过去的文件也得记上，否则 -revert 拿不到清单，这些文件
    # 连同 $TargetDir 都会留在盘上。
    try {
        foreach ($s in $state) {
            $r = Copy-FontFile $s.Src $TargetDir
            $installedFiles += $r.Path
            $script:WroteSomething = $true
            Set-ItemProperty -Path $FontsKey -Name $s.Key -Value $r.Path
            $suffix = if ($r.Note) { "   [$($r.Note)]" } else { '' }
            Write-Host ("[Fonts] {0,-44} -> {1}{2}" -f $s.Key, $r.Path, $suffix) -ForegroundColor Green
        }
    } finally {
        # 安装清单，供 -revert 清理。并入上次记录的文件，这样历史上因占用而改过名的
        # 旧文件也不会被漏掉。
        $allFiles = @($installedFiles)
        if ($prevInst) { $allFiles += @(Get-MapValue $prevInst 'Files' | Where-Object { $_ }) }
        Set-MapValue $bk 'Install' ([ordered]@{
            TargetDir  = $TargetDir
            CreatedDir = $createdDir
            Files      = @($allFiles | Sort-Object -Unique)
        })
        Write-BackupFile $bk
    }

    if ($script:UsedAltName) {
        Write-Host ''
        Write-Host '注意：部分字体文件因被占用而改用了新文件名，注册表已指向新文件。' -ForegroundColor DarkYellow
        Write-Host "      重启后可自行清理 $TargetDir 里没被引用的旧文件。" -ForegroundColor DarkYellow
    }
    return $state.Count
}
