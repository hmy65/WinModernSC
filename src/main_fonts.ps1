# 机制 1：Fonts 注册表键，文件级替换。
#
# 把 Fonts 键里的注册项指向我们生成的文件。GDI 和 DirectWrite 都从字体文件的
# name 表读族名，所以这一层两条渲染路径都认，覆盖面最广。
#
# 两组文件：
#   拉丁 = "Segoe UI" 那 12 个（SegoeUIMod\）
#   汉字 = 微软雅黑/宋体/黑体/等线 那 8 个（CJKMod\）
# 两组一起装：Segoe UI 那 12 个文件的汉字已经裁掉了，外壳的中文要靠回退落到
# 「微软雅黑」，也就是落到汉字这一组。只装其中一半，中文就还是原版微软雅黑。
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
}

$MapCJK = [ordered]@{
    'Microsoft YaHei & Microsoft YaHei UI (TrueType)'             = 'CJKMod\WinModernSC-YaHei.ttc'
    'Microsoft YaHei Bold & Microsoft YaHei UI Bold (TrueType)'   = 'CJKMod\WinModernSC-YaHei-Bold.ttc'
    'Microsoft YaHei Light & Microsoft YaHei UI Light (TrueType)' = 'CJKMod\WinModernSC-YaHei-Light.ttc'
    'SimSun & NSimSun (TrueType)'                                 = 'CJKMod\WinModernSC-SimSun.ttc'
    'SimHei (TrueType)'                                           = 'CJKMod\WinModernSC-SimHei.ttf'
    'DengXian (TrueType)'                                         = 'CJKMod\WinModernSC-DengXian.ttf'
    'DengXian Bold (TrueType)'                                    = 'CJKMod\WinModernSC-DengXian-Bold.ttf'
    'DengXian Light (TrueType)'                                   = 'CJKMod\WinModernSC-DengXian-Light.ttf'
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

    # 授权对象和 C:\Windows\Fonts 保持一致（icacls 实测结果）：
    #   BUILTIN\Users                       S-1-5-32-545
    #   ALL APPLICATION PACKAGES            S-1-15-2-1
    #   ALL RESTRICTED APPLICATION PACKAGES S-1-15-2-2
    # 后两个不能省：AppContainer 进程（MSIX/UWP/WinUI3）鉴权分两段，除了常规
    # 组 SID 那一遍，DACL 里还得单独命中包 SID 或这两个通配 SID 才放行。而
    # C:\ 根目录没有可继承的 AppContainer ACE，新建的 C:\Fonts 一条都拿不到，
    # 访问面比它要顶替的系统字体目录还窄。目录里只有系统界面字体，本来就该
    # 全机器可读，放开不泄漏任何东西。
    $grantees = [ordered]@{
        'S-1-5-32-545' = 'BUILTIN\Users'
        'S-1-15-2-1'   = 'ALL APPLICATION PACKAGES'
        'S-1-15-2-2'   = 'ALL RESTRICTED APPLICATION PACKAGES'
    }
    try {
        # -ErrorAction Stop：这两个也发非终止错误，不写的话 catch 抓不住，
        # 会绕过下面那句「设置 ACL 失败（通常仍可用）」直接把红字甩给用户。
        $acl = Get-Acl -LiteralPath $TargetDir -ErrorAction Stop
        foreach ($sidStr in $grantees.Keys) {
            # SID 串合法就能构造，不要求当前系统能翻译成账户名，所以
            # S-1-15-2-* 在没有 AppContainer 的老系统上也不会抛。
            $sid = New-Object System.Security.Principal.SecurityIdentifier $sidStr
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $sid, 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
            $acl.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $TargetDir -AclObject $acl -ErrorAction Stop
        Write-Host "已授予 BUILTIN\Users + 应用包 SID 对 $TargetDir 的读取权限（所有用户 / UWP 沙箱可用）" -ForegroundColor Green
    } catch {
        Write-Host "设置 ACL 失败（通常仍可用）: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }

    $installedFiles = @()
    foreach ($s in $state) {
        $r = Copy-FontFile $s.Src $TargetDir
        $script:WroteSomething = $true
        Set-ItemProperty -Path $FontsKey -Name $s.Key -Value $r.Path
        $installedFiles += $r.Path
        $suffix = if ($r.Note) { "   [$($r.Note)]" } else { '' }
        Write-Host ("[Fonts] {0,-44} -> {1}{2}" -f $s.Key, $r.Path, $suffix) -ForegroundColor Green
    }

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

    if ($script:UsedAltName) {
        Write-Host ''
        Write-Host '注意：部分字体文件因被占用而改用了新文件名，注册表已指向新文件。' -ForegroundColor DarkYellow
        Write-Host "      重启后可自行清理 $TargetDir 里没被引用的旧文件。" -ForegroundColor DarkYellow
    }
    return $state.Count
}
