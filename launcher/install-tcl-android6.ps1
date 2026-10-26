# =============================================================================
# install-tcl-android6.ps1
# 为「TCL 旧电视 / Android 6 (API 23)」构建并安装 CleanYourTV 启动器。
#
# 与官方 build-and-install.ps1 的区别：
#   1. 不依赖仓库里缺失的 tools/tv.py / tools/b64push.py，全部改用系统 adb 命令。
#   2. 固化 TCL 固件要点：TclAppBoot 只有在 app 持有 AUTO_START / APP_AUTO_START
#      app-op 时才肯绑定无障碍服务，否则 Home 会被回退到原厂桌面（见官方脚本注释）。
#   3. 适配 Android 6：Android 6 (API 23) 没有 `cmd package set-home-activity`
#      （该命令 API 24+ 才有）。本脚本在禁用原厂桌面后，若只剩一个 HOME 候选则自动
#      成为默认；若有多个候选，会提示你在电视上按 Home 选择 CleanYourTV 并勾选「始终」。
#
# 用法（在 launcher/ 目录下，PowerShell 中）：
#   .\install-tcl-android6.ps1 -TvHost 192.168.1.50
#   .\install-tcl-android6.ps1 -TvHost 192.168.1.50 -StockLauncher none
#   .\install-tcl-android6.ps1 -TvHost 192.168.1.50 -HomeKeyService
# 先确保：电视已开启「开发者选项 -> USB 调试 / 网络调试」，且本机 adb 可连上电视
#   （adb connect 192.168.1.50:5555）。
# =============================================================================
param(
    [string]$TvHost = $env:TV_HOST,
    [string]$StockLauncher = '',
    [switch]$InputKeyService,
    [switch]$HomeKeyService,
    [switch]$RestoreKeyServices
)
$ErrorActionPreference = 'Stop'
$OutputEncoding = New-Object System.Text.UTF8Encoding $false
if (-not $TvHost) { throw 'pass -TvHost <tv ip> or set $env:TV_HOST' }
$env:TV_HOST = $TvHost
Set-Location $PSScriptRoot

# ---- 0. 找到 adb ----------------------------------------------------------
function Find-Adb {
    if ($env:ADB) { return $env:ADB }
    $candidates = @(
        "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe",
        "$env:ANDROID_HOME\platform-tools\adb.exe",
        'adb'
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
        if ($c -eq 'adb') { return 'adb' }
    }
    throw '找不到 adb。请安装 Android SDK Platform-Tools，或设置 $env:ADB 指向 adb.exe'
}
$adb = Find-Adb

# 统一执行 adb shell 命令并返回输出（失败时抛错）
function Adb-Shell([string]$cmd) {
    $out = & $adb -s "$TvHost" shell $cmd 2>&1
    if ($LASTEXITCODE -ne 0) { throw "adb shell 失败 (exit $LASTEXITCODE): $cmd`n$out" }
    "$out"
}
function Adb([string[]]$argsArr) {
    & $adb -s "$TvHost" @argsArr 2>&1
}

# ---- 1. 设置 JDK / SDK / local.properties（沿用官方逻辑） -----------------
if (-not $env:JAVA_HOME -or -not (Test-Path "$env:JAVA_HOME\bin\java.exe")) {
    $jbr = Get-ChildItem 'C:\Program Files\Android' -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'jbr' } | Where-Object { Test-Path "$_\bin\java.exe" } | Select-Object -First 1
    if (-not $jbr) { throw 'Set JAVA_HOME to a JDK 17+ (Android Studio ships one in its jbr folder)' }
    $env:JAVA_HOME = $jbr
}
$sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { "$env:LOCALAPPDATA\Android\Sdk" }
if (-not (Test-Path local.properties)) {
    "sdk.dir=$($sdk -replace '\\', '\\')" | Out-File -Encoding ascii local.properties
}

# ---- 2. 构建 release APK ---------------------------------------------------
Write-Host '==> 构建 APK (./gradlew.bat assembleRelease) ...'
.\gradlew.bat assembleRelease -q --console=plain
if ($LASTEXITCODE -ne 0) { throw 'Gradle build failed' }
$apk = 'app\build\outputs\apk\release\app-release.apk'
if (-not (Test-Path $apk)) { throw "构建成功但未找到 APK: $apk" }
Write-Host "==> APK: $apk"

# ---- 3. SDK 预检（动态读取 build.gradle 的 minSdk）------------------------
$minSdk = (Get-Content app\build.gradle | Select-String -Pattern '^\s*minSdk\s+(\d+)' | ForEach-Object { $_.Matches.Groups[1].Value } | Select-Object -First 1)
$tvSdk = (Adb-Shell 'getprop ro.build.version.sdk' | Out-String).Trim() -replace '[^0-9]', ''
if ($minSdk -and $tvSdk -and ([int]$tvSdk -lt [int]$minSdk)) {
    throw "电视 SDK=$tvSdk 低于本启动器 minSdk=$minSdk，pm install 会报 INSTALL_FAILED_OLDER_SDK。未做任何改动。"
}
Write-Host "==> 电视 SDK=$tvSdk，启动器 minSdk=$minSdk（通过预检）"

# ---- 4. 识别当前 HOME 拥有者 ----------------------------------------------
$knownStock = @('com.google.android.tvlauncher', 'com.google.android.apps.tv.launcherx', 'com.google.android.leanbacklauncher', 'com.mitv.tvhome')
if (-not $StockLauncher) {
    $homePkg = (Adb-Shell 'cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME' | Out-String).Trim() -split '/' | Select-Object -First 1
    if (-not $homePkg) { throw '无法询问电视当前 HOME 拥有者；请检查 -TvHost 与电视上的调试授权弹窗，或手动传入 -StockLauncher <package>' }
    if ($knownStock -contains $homePkg) { $StockLauncher = $homePkg }
    elseif ($homePkg -eq 'com.gathin.tvhome') { $StockLauncher = 'none'; Write-Host 'Home 已是本启动器，不会禁用任何原厂桌面。' }
    elseif ($homePkg -eq 'android') {
        $claimants = (Adb-Shell 'cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME' | Out-String)
        $found = @($knownStock | Where-Object { $claimants -match ([regex]::Escape($_) + '/') })
        if ($found.Count -eq 1) { $StockLauncher = $found[0]; Write-Host "Home 处于选择器状态；候选中的原厂桌面为 $StockLauncher。" }
        else { throw "Home 处于 Android 选择器状态且有 $($found.Count) 个已知原厂桌面，请先在电视上选一个默认桌面，或传入 -StockLauncher <package|none>。" }
    }
    else { throw "Home 当前解析为 '$homePkg'，不在已知原厂桌面列表中；请手动传入 -StockLauncher <package to disable> 或 none。" }
}
Write-Host "原厂桌面: $StockLauncher"

# ---- 5. 推送并安装 APK -----------------------------------------------------
Write-Host '==> 推送 APK 到电视 ...'
$null = Adb @('push', $apk, '/data/local/tmp/tvhome.apk')
$out = (Adb-Shell 'pm install -r /data/local/tmp/tvhome.apk; rm -f /data/local/tmp/tvhome.apk' | Out-String)
Write-Host $out
if ($out -notmatch 'Success') { throw 'pm install 失败；原厂桌面未被改动。' }

# ---- 6. 停掉被 Android 中途重启的实例，并把被停掉的无障碍服务写回 ----------
# 官方用一条 shell case 命令原子完成；这里拆成几步，逻辑等价：若当前已含本启动器的
# 无障碍服务，则先清空再写回（强制重新绑定），并恢复 accessibility_enabled。
$null = Adb-Shell 'am force-stop com.gathin.tvhome'
$cur = (Adb-Shell 'settings get secure enabled_accessibility_services' | Out-String).Trim()
if ($cur -match 'com\.gathin\.tvhome') {
    # 清空再写回；用单引号 PowerShell 字符串直接下发空值 ""
    Adb-Shell 'settings put secure enabled_accessibility_services ""'
    Adb-Shell "settings put secure enabled_accessibility_services `"$cur`""
    Adb-Shell 'settings put secure accessibility_enabled 0'
    Start-Sleep -Seconds 1
}

# ---- 7. 先单独启动新启动器（再动原厂桌面，避免电视无可用 Home）-----------
$start = (Adb-Shell 'am start -W -a android.intent.action.MAIN -c android.intent.category.HOME -n com.gathin.tvhome/.MainActivity' | Out-String)
Write-Host $start
if ($start -notmatch 'Status: ok' -or $start -match '(?m)^Error') { throw '新启动器未能启动（见上）；原厂桌面保持启用。' }

# ---- 8. 授权 + 编译 + 禁用原厂桌面 + 设为 Home ----------------------------
# 注：set-home-activity 在 Android 6(API23) 不存在，交给下面的 Home 校验逻辑兜底。
$null = Adb-Shell 'pm grant com.gathin.tvhome android.permission.ACCESS_FINE_LOCATION 2>/dev/null; echo location-granted'
# WRITE_SECURE_SETTINGS 是特殊权限（非运行时危险权限），依赖它的 ThemeProvider / GuardKeep /
# ServiceRepair 在缺失时仅为优雅降级；这里用 adb 无条件授予，避免 TCL 上相关功能失效。
$null = Adb-Shell 'pm grant com.gathin.tvhome android.permission.WRITE_SECURE_SETTINGS 2>/dev/null; echo wss-granted'
# compile -m speed 在 Android 6 可能不存在，失败不致命
try { $null = Adb-Shell 'cmd package compile -m speed -f com.gathin.tvhome' } catch { Write-Warning 'compile -m speed 不可用（Android 6 上忽略）。' }
if ($StockLauncher -ne 'none') { $null = Adb-Shell "pm disable-user --user 0 $StockLauncher" }
try { $null = Adb-Shell 'cmd package set-home-activity --user 0 com.gathin.tvhome/.MainActivity' } catch { Write-Warning 'set-home-activity 不可用（Android 6 上由禁用原厂桌面 + 选择器兜底）。' }

# ---- 9. 校验 Home 归属；若不是本启动器则尝试回退 --------------------------
function Get-HomeNow {
    $line = (Adb-Shell 'cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME' 2>$null | Out-String).Trim() -split "`n" | Where-Object { $_ -match '\S' } | Select-Object -Last 1
    "$line".Trim()
}
function Undo-Handover {
    if ($StockLauncher -eq 'none') { Write-Warning 'Home 不是新启动器且未禁用任何原厂桌面，无需回退。'; return $false }
    try { $null = Adb-Shell "pm enable --user 0 $StockLauncher" } catch { Write-Warning "启用 $StockLauncher 失败。" }
    try { $null = Adb-Shell "cmd package set-home-activity --user 0 $(Adb-Shell \"cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME $StockLauncher\" | Out-String | Select-Object -Last 1)" } catch {}
    $back = Get-HomeNow
    if ($back -like "$StockLauncher/*") { Write-Warning "$StockLauncher 重新拥有 Home。"; return $true }
    Write-Warning "恢复未完成：Home 仍为 '$(if ($back) { $back } else { '无响应' })'。需手动在电视上把 $StockLauncher 设回默认。"
    return $false
}

$homeNow = Get-HomeNow
if ($homeNow -notlike 'com.gathin.tvhome/*') {
    # Android 6 没有 set-home-activity：若已禁用原厂桌面且只剩本启动器，通常已生效；
    # 若仍有多个候选，提示用户在电视上手动选择。
    if ($StockLauncher -ne 'none') {
        $remaining = (Adb-Shell 'cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME' | Out-String) -split '/' | Where-Object { $_ -match 'com\.' } | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne 'com.gathin.tvhome' }
        if ($remaining.Count -eq 0) {
            # 禁用后已无其他 HOME 候选，理论上已生效；可能是 resolve-activity 缓存，重启 TV 即可。
            Write-Warning "已禁用原厂桌面且电视上无其他 HOME 候选；请重启电视后按 Home。若仍进原厂桌面，请在电视设置里把 CleanYourTV 设为默认。"
        }
        else {
            Write-Warning "检测到多个 HOME 候选（含 $($remaining -join ', ')）。请按电视遥控 Home 键，在弹出的选择器里选择「CleanYourTV」并勾选「始终」。"
        }
    }
    else {
        Write-Warning "Home 未解析为本启动器（$homeNow）；请手动确认。"
    }
}
else {
    Write-Host "Home 已解析为 $homeNow"
}

# ---- 10. 可选无障碍服务（含 TCL 必需的 AUTO_START app-op）-----------------
function Enable-Service([string]$Name) {
    $svc = "com.gathin.tvhome/.$Name"
    # TCL 固件：先授予 AUTO_START / APP_AUTO_START（有的型号叫其一），并 appops write-settings
    # 否则重启后授权丢失、TclAppBoot 拒绝绑定服务，Home 回退到原厂桌面。
    $null = Adb-Shell 'cmd appops set com.gathin.tvhome AUTO_START allow 2>/dev/null; cmd appops set com.gathin.tvhome APP_AUTO_START allow 2>/dev/null; appops write-settings 2>/dev/null'
    $cur = (Adb-Shell 'settings get secure enabled_accessibility_services' | Out-String).Trim()
    if ($cur -match [regex]::Escape($Name)) {
        # 已列出：清空再写回以强制重新绑定
        Adb-Shell 'settings put secure enabled_accessibility_services ""'
        Adb-Shell "settings put secure enabled_accessibility_services `"$cur`""
        Adb-Shell 'settings put secure accessibility_enabled 0'
        Start-Sleep -Seconds 1
    }
    elseif ($cur -eq 'null' -or $cur -eq '') {
        $null = Adb-Shell "settings put secure enabled_accessibility_services $svc"
    }
    else {
        $null = Adb-Shell "settings put secure enabled_accessibility_services `"$cur`:$svc`""
    }
    $null = Adb-Shell 'settings put secure accessibility_enabled 1'
    Write-Host "$Name 已启用（含 TCL AUTO_START app-op）"
}
if ($InputKeyService) { Enable-Service 'InputKeyService' }
if ($HomeKeyService) { Enable-Service 'HomeKeyService' }
if ($RestoreKeyServices) {
    $null = Adb-Shell 'pm grant com.gathin.tvhome android.permission.WRITE_SECURE_SETTINGS && echo restore-granted'
}

Write-Host '安装完成。按电视遥控 Home 键即可看到 CleanYourTV。'

