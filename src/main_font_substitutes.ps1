# 机制 2：FontSubstitutes（界面族）。
#
# 只有 GDI 认这张表，DirectWrite 完全无视。所以它的作用范围就是那些还在请求
# Tahoma / MS Shell Dlg / MS Sans Serif 的旧式 Win32 程序 —— 那些族名在
# 现代 Windows 上根本没有对应的好字体，不接管就一直是老样子。
#
# 中文族【不走】这里。它们在机制 1 已经文件级接管了，而 "Segoe UI" 那 12 个
# 文件的汉字是裁掉的 —— 再把中文族替换成 Segoe UI，只会让 GDI 程序拿到一个
# 没有汉字的字体。

$SubUI = [ordered]@{
    'MS Shell Dlg'           = $SUB
    'MS Shell Dlg 2'         = $SUB
    'MS Sans Serif'          = $SUB
    'MS Sans Serif,0'        = "$SUB,0"
    'Microsoft Sans Serif'   = $SUB
    'Microsoft Sans Serif,0' = "$SUB,0"
    'Tahoma'                 = $SUB
    'Tahoma,0'               = "$SUB,0"
}

function Show-SubstitutesPlan {
    Write-Host ''
    Write-Host ('=== 机制 2  FontSubstitutes，{0} 条 ===' -f $SubUI.Count) -ForegroundColor Yellow
    foreach ($e in $SubUI.GetEnumerator()) {
        $cur = Get-RegValueOrNull $SubstKey $e.Key
        Write-Host ("  {0,-24} : {1,-16} -> {2}" -f $e.Key,
                    $(if ($null -eq $cur) { '(不存在)' } else { $cur }), $e.Value)
    }
}

function Invoke-SubstitutesApply {
    # --- 备份。同样只备份一次，新增的值名补录当前值。
    $bk = Read-BackupFile
    if ($null -eq $bk) { $bk = [pscustomobject]@{} }
    $sub = Get-MapValue $bk 'FontSubstitutes'
    if ($null -eq $sub) {
        Set-MapValue $bk 'FontSubstitutes' ([ordered]@{})
        $sub = Get-MapValue $bk 'FontSubstitutes'
    } else {
        Write-Host 'FontSubstitutes 备份已存在，保留原值。' -ForegroundColor DarkGray
    }
    $known = @(Get-MapKeys $sub)
    foreach ($k in $SubUI.Keys) {
        if ($known -notcontains $k) { Set-MapValue $sub $k (Get-RegValueOrNull $SubstKey $k) }
    }
    Write-BackupFile $bk        # 先落盘再写注册表
    Write-Host ("已备份 {0} 个 FontSubstitutes 值 -> {1}" -f @(Get-MapKeys $sub).Count, $Backup) -ForegroundColor Yellow

    foreach ($e in $SubUI.GetEnumerator()) {
        Set-ItemProperty -Path $SubstKey -Name $e.Key -Value $e.Value
        $script:WroteSomething = $true
        Write-Host ("[Subst] {0,-24} -> {1}" -f $e.Key, $e.Value) -ForegroundColor Green
    }
    return $SubUI.Count
}
