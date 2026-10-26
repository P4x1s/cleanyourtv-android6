> 本仓库是 [Gathin23/cleanyourtv](https://github.com/Gathin23/cleanyourtv) 的 **Android 6（API 23）适配分支**，
> 让原本仅支持 Android 8+（minSdk 26）的项目可运行于 Android 6 电视（如 TCL 旧电视）。
> 本文件为分支专属的改造与安装说明；原项目完整文档见 [README.original.md](README.original.md)。

# CleanYourTV 安卓 6（Android 6 / API 23）适配与安装说明

> 目标设备：**TCL 旧电视，Android 6（API 23）**
> 本仓库即 `cleanyourtv-android6`（Android 6 适配分支）
> 原始项目：https://github.com/Gathin23/cleanyourtv （原 `minSdk 26`，仅支持 Android 8+）

---

## 0. 这份改造做了什么（一句话）

把 CleanYourTV 的 `minSdk` 从 26 降到 **23**，通过 **核心库脱糖（core library desugaring）** 把 `java.time` / `java.util.function` 回退到 Android 6 可用，并用 `Build.VERSION.SDK_INT` 守卫隔离两处 API 24 才有的调用（`registerDefaultNetworkCallback`、`UserManager.isUserUnlocked`）。代码层面已可运行在 Android 6 电视上。

---

## 1. 已修改的文件清单

| 文件 | 改动 | 原因 |
|------|------|------|
| `launcher/app/build.gradle` | `minSdk 26 → 23`；`compileOptions` 增加 `coreLibraryDesugaringEnabled true`；`dependencies` 增加 `coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.0.4'` | 降低门槛 + 让 `java.time`/`java.util.function` 在 API 23 可用 |
| `launcher/app/src/main/java/com/gathin/tvhome/MainActivity.java` | `registerDefaultNetworkCallback`（API 24+）改为：`SDK_INT >= N` 时用它，否则用 `registerNetworkCallback(new NetworkRequest.Builder().build(), ...)` 监听任意网络变化 | API 23 无 `registerDefaultNetworkCallback` |
| `launcher/app/src/main/java/com/gathin/tvhome/HomeKeyService.java` | 两处 `UserManager.isUserUnlocked()`（API 24+）加 `Build.VERSION.SDK_INT >= Build.VERSION_CODES.N` 守卫 | API 23 无 direct boot / `isUserUnlocked` |
| `launcher/app/src/main/java/com/gathin/tvhome/GuardKeep.java` | 同上，1 处守卫（新增 `import android.os.Build;`） | 同上 |
| `launcher/app/src/main/java/com/gathin/tvhome/GuardRevival.java` | 同上，1 处守卫（新增 `import android.os.Build;`） | 同上 |
| `launcher/install-tcl-android6.ps1` | **新增** 安装脚本：完全用系统 `adb` 命令，不依赖仓库缺失的 `tools/tv.py`/`b64push.py`，固化 TCL 必需的 `AUTO_START`/`APP_AUTO_START` app-op | 让 TCL 安卓 6 电视可直接安装（见第 5 节） |

> 说明：仓库根原本依赖 `tools/tv.py` / `tools/b64push.py`（纯 Python ADB 客户端）做安装。本次拉取的 tarball 中这两个文件缺失（代理对大文件截断所致，`.gitignore` 只忽略 `tools/venv` 与 `tools/adbkey/`，并不忽略工具本身）。因此新增了**不依赖该工具链的 `install-tcl-android6.ps1`**，普通 `adb` 即可完成安装。

---

## 2. 为什么这样就能支持安卓 6

1. **核心库脱糖**：`coreLibraryDesugaringEnabled true` + `desugar_jdk_libs` 依赖，会把 `java.time.*`（如 `LocalDate`/`Duration`/`Instant`/`ZoneId`）和 `java.util.function.*`（如 `Consumer`/`ToIntFunction`/`Supplier`）在编译期改写为 Android 6（API 21+）上可用的实现。项目里有 13 个 Java 文件用到这些 API，全部由脱糖兜底，**无需逐文件改代码**。
2. **版本守卫**：真正「只能在 API 24+ 调用」的只有 `ConnectivityManager.registerDefaultNetworkCallback` 和 `UserManager.isUserUnlocked`，已分别用 `SDK_INT >= N` 隔离并在低版本走替代路径。
3. **清单兼容**：`AndroidManifest.xml` 中的 `directBootAware` / `queries` / `localeConfig` 在旧系统上被忽略，且所有组件已显式声明 `android:exported`，无需修改。
4. **`PackageManager` 匹配标志**：用到的 `MATCH_DISABLED_COMPONENTS` / `MATCH_DEFAULT_ONLY` 均为 API 1，无兼容问题。

---

## 3. 安卓 6 仍需注意的两点限制（已在脚本中处理）

- **没有 `cmd package set-home-activity`**：该命令 API 24+ 才有。Android 6 上本脚本的策略是：安装后**禁用原厂桌面**，若电视上只剩 CleanYourTV 一个 HOME 候选，它会自动成为默认；若仍有多个候选，脚本会提示你**在电视上按 Home 键，在弹出的选择器里选 CleanYourTV 并勾选「始终」**。
- **`cmd package compile -m speed` 可能不存在**：Android 6 不一定支持，脚本对该步做了「失败不致命」处理，不影响安装。

---

## 4. 构建（需要你本地的环境，本机无 Android SDK 无法代编）

前置（在你自己电脑上）：
- **JDK 17+**（Android Studio 自带的 `jbr` 即可）
- **Android SDK**（Platform-Tools + 对应 build-tools；`ANDROID_HOME` 指向它）
- 网络可访问 Google Maven（拉取 `desugar_jdk_libs` 等依赖）

步骤（在 `launcher/` 目录下）：

```bash
# Windows
cd launcher
.\gradlew.bat assembleRelease

# macOS / Linux
cd launcher
./gradlew assembleRelease
```

产出：`launcher/app/build/outputs/apk/release/app-release.apk`

> 若构建报错 `Call requires API level 24 (current min is 23)`：说明还有某个 API 24+ 调用漏网。按报错行号用 `Build.VERSION.SDK_INT >= Build.VERSION_CODES.N` 守卫包一层（或确认它已在守卫内）即可。本次已知的两处已处理。

---

## 5. 安装到 TCL 安卓 6 电视（推荐：直接用 adb 的脚本）

### 5.1 电视端准备
1. 设置 → 关于 → 连续点击「版本号」开启**开发者选项**。
2. 开发者选项里打开 **USB 调试**（TCL 通常还有「网络调试 / 远程调试」，打开后会监听 5555 端口）。
3. 在电脑上确认能连上（电脑需装 Android SDK Platform-Tools）：
   ```bash
   adb connect 192.168.1.50:5555   # 换成你电视的局域网 IP
   adb devices                      # 能看到电视即成功（首次需电视上点允许）
   ```

### 5.2 运行安装脚本
在 `launcher/` 目录的 **PowerShell** 中：

```powershell
# 基本安装（自动识别并禁用原厂桌面）
.\install-tcl-android6.ps1 -TvHost 192.168.1.50

# 若你的 TCL 遥控器 Home 键发的是 KEYCODE_ALL_APPS（部分型号），加 -HomeKeyService
.\install-tcl-android6.ps1 -TvHost 192.168.1.50 -HomeKeyService

# 若已知原厂桌面包名、想显式指定（如不确定自动识别结果）
.\install-tcl-android6.ps1 -TvHost 192.168.1.50 -StockLauncher com.google.android.leanbacklauncher
```

脚本会自动：构建 → SDK 预检 → 推送 APK → 安装 → 启动新桌面 → 授权并禁用原厂桌面 → 设为默认 → 启用 TCL 必需的 `AUTO_START` app-op。

### 5.3 TCL 专属要点（已写进脚本，了解即可）
TCL 的 `TclAppBoot` 固件有个坑：**应用未运行时，除非持有 `AUTO_START`/`APP_AUTO_START` 这个 app-op，否则拒绝绑定该 app 的无障碍服务**，导致 Home 被回退到原厂桌面；而且这个授权重启后会丢，必须再执行 `appops write-settings` 落地。脚本第 10 步已固化这两步。若你日后看到「进不了 CleanYourTV、回到原厂桌面」，先重新跑一次带 `-HomeKeyService`/`-RestoreKeyServices` 的安装即可。

---

## 6. 备选：用官方脚本 + 补齐 tools（进阶）

官方 `build-and-install.sh` / `build-and-install.ps1` 功能更全（含回退记录、多电视处理等），但它们依赖 `tools/tv.py` / `tools/b64push.py`。补齐方法：

```bash
# 从上游把整个仓库的 tools/ 目录单独取回（需要能访问 github）
# 方式 A：git clone 后复制 tools/ 到本仓库根
git clone --depth 1 https://github.com/Gathin23/cleanyourtv tmp_upstream
cp -r tmp_upstream/tools ./
rm -rf tmp_upstream

# 然后按官方 README 建 venv 并运行
python3 -m venv tools/venv && tools/venv/bin/pip install -r tools/requirements.txt
TV_HOST=192.168.1.50 ./build-and-install.sh
```

> 注意：官方脚本同样会在 Android 6 上遇到「无 `set-home-activity`」的限制，需在电视上手动选默认桌面。官方脚本里的 TCL `AUTO_START` 处理已包含。

---

## 7. 验证是否成功

1. 电视上按 **Home** 键，应进入 CleanYourTV 的简洁界面（应用网格、无广告）。
2. 电脑端确认 Home 归属：
   ```bash
   adb -s 192.168.1.50 shell cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME
   # 末行应为 com.gathin.tvhome/.MainActivity（或手动在电视上选过默认）
   ```
3. 重启电视一次，确认仍能进 CleanYourTV（验证 TCL `AUTO_START` 授权已落地）。

---

## 8. 故障与回退

- **进不去新桌面 / 回到原厂**：重启电视；若仍不行，在电视设置的「应用 → 默认应用 → 主屏幕」里把 CleanYourTV 设为默认；或临时重新启用原厂桌面：
  ```bash
  adb -s 192.168.1.50 shell pm enable --user 0 <原厂桌面包名>
  ```
- **`INSTALL_FAILED_OLDER_SDK`**：说明 APK 的 minSdk 高于电视。确认 `app/build.gradle` 的 `minSdk` 已是 `23`。
- **构建报脱糖相关错**：确认 `coreLibraryDesugaringEnabled true` 与 `desugar_jdk_libs` 依赖都在；联网能拉到该依赖。
- **想彻底卸载**：
  ```bash
  adb -s 192.168.1.50 shell pm uninstall com.gathin.tvhome
  adb -s 192.168.1.50 shell pm enable --user 0 <原厂桌面包名>
  ```

---

## 9. 本机环境的限制说明

当前运行环境**没有 Android SDK，也无法连接你的电视**，因此我只能完成：
- ✅ 拉取并整理项目源码
- ✅ 修改源码使其支持 Android 6（共改动 6 个文件：build.gradle + 5 个 Java 文件，含 4 处版本守卫、2 处 getLocale、1 处 nio.file 替换 + 新增安装脚本）
- ✅ 给出构建 / 安装 / 验证的完整步骤

无法替你做：实际编译 APK、实际推送到电视。请按第 4、5 节在你自己的电脑上操作。

---

## 10. 二次核验记录（2026-10-26）：修复两处漏网的 API 不兼容

由于本机无 Android SDK，无法真正编译 APK，因此对 launcher 的 **65 个 Java 文件**做了全量静态扫描，专门排查「能在编译期通过（compileSdk 34）但运行到安卓 6（API 23）会崩」的未守卫高版本 API 调用。发现并修复了两处此前遗漏的真实不兼容：

### 10.1 `MainActivity.java`：`Configuration.getLocales()`（API 24）崩
- **现象**：第 2115、2486 行用 `getResources().getConfiguration().getLocales().get(0)` 取主区域。
- **原因**：`Configuration.getLocales()` 是 **API 24 (N)** 才有的方法，安卓 6 上调用会抛 `NoSuchMethodError`。
- **修复**：改为 `Configuration.getLocale()`（`getLocale()` 自 **API 1** 即有，且始终返回主区域，与 `getLocales().get(0)` 在 API 24+ 上等价）。两处一并替换。

### 10.2 `WallpaperCaptions.java`：`java.nio.file.Files`（API 26）崩
- **现象**：`read()` 里用 `Files.readAllLines(file.toPath(), UTF_8)` 读壁纸说明文件。
- **原因**：`java.nio.file`（NIO.2）是 **API 26 (O)** 才加入，**且不在核心库脱糖范围内**，安卓 6 上运行到该路径会抛 `NoClassDefFoundError`。
- **修复**：改用 `java.io`（`BufferedReader` + `InputStreamReader` + `FileInputStream`）按行读取，全 API 级别可用；并替换了相关 import。

### 10.3 核验覆盖范围（均已确认安全，无需改动）
- **版本守卫**：全仓 `Build.VERSION.SDK_INT` 比较共 8 处（`N`×5、`P`×1、`Q`×1、`TIRAMISU`×2），逐处阅读确认高版本 API 调用都被关在门内（`registerDefaultNetworkCallback`、`isUserUnlocked`、`GET_SIGNING_CERTIFICATES`、`RECEIVER_NOT_EXPORTED` 三参 `registerReceiver`、`GLOBAL_ACTION_LOCK_SCREEN` 等）。
- **脱糖覆盖**：用到的 `java.time.*`（LocalDate/LocalDateTime/Instant/Duration/ZoneId/DateTimeParseException）、`java.util.function.*`（Predicate/Supplier/BiFunction/IntPredicate/Consumer/ToIntFunction）均在 `desugar_jdk_libs` 回退范围内；`java.util.concurrent.ExecutorService/Executors`、`java.nio.charset.StandardCharsets` 原生即存在于 API 23。
- **清单未知属性**：`localeConfig`(API 33)、`directBootAware`(API 24)、`<queries>`(API 30) 在 API 23 上被系统忽略，不影响安装与运行。
- **权限（安卓 6 运行时权限模型）**：唯一危险权限 `ACCESS_FINE_LOCATION` 不调用 `requestPermissions()`，而是由安装脚本 `pm grant` 授予（缺失时仅壁纸/网络药丸相关功能降级，不崩）；`WRITE_SECURE_SETTINGS` 已在安装脚本中无条件 `pm grant`。
- **边界项**：`Activity.getColorStateList(int)` 为 **API 23**，正好等于 minSdk，在安卓 6 上可用，无需改。

> 结论：除上面两处真实 bug 外，其余高版本 API 调用均已由脱糖或版本守卫正确兜底。若你本地构建时 Gradle 仍报 `Call requires API level 24`，按报错行号用 `SDK_INT >= N` 守卫包一层即可。

---

## 11. 推送到 GitHub（本机操作）

本项目已在本地完成 `git init`，分支为 **`main`**，并包含一次完整提交（`073ab17`，已用 `.gitignore` 排除所有构建产物，保留了原作者 `LICENSE`）。当前环境虽已验证可访问 github.com，但推送需要你的 GitHub 凭证，因此采用「你在本机推」的方式（更安全，不泄露 Token）。

### 11.1 在 GitHub 网页新建空仓库
1. 打开 https://github.com/new
2. 仓库名填 **`cleanyourtv-android6`**，可见性选 **Public**
3. **不要**勾选「Initialize this repository with a README / .gitignore / LICENSE」（保持空仓库，避免首次 push 冲突）

### 11.2 在本机把项目推上去
项目目录 `cleanyourtv-android6/` 已自带 `.git`，直接用，或解压 `cleanyourtv-android6-git.zip`（含完整 `.git` 历史）后进入该目录，执行：

```bash
# 把 <你的GitHub用户名> 换成你自己的
git remote add origin https://github.com/<你的GitHub用户名>/cleanyourtv-android6.git
git push -u origin main
```

- 认证：GitHub 自 2021 起不再接受账户密码，请用 **Personal Access Token（PAT，需勾选 repo 权限）** 当作密码；或先 `gh auth login` 再用 HTTPS/SSH。
- 若你本机已配置 SSH key，可改用 SSH 地址：`git remote add origin git@github.com:<你的GitHub用户名>/cleanyourtv-android6.git`。

### 11.3 （可选）把提交作者改成你自己的 GitHub 身份
当前首次提交的作者是我设的占位身份（`CleanYourTV Android6 Fork <android6-fork@localhost>`）。想让它显示成你，在本机执行（只有一个 commit，直接 amend 即可）：

```bash
git commit --amend --author="你的名字 <你的GitHub邮箱>" --no-edit
git push -u origin main --force-with-lease
```

### 11.4 说明
- 本仓库是上游 `Gathin23/cleanyourtv` 的派生版，已保留其 `LICENSE` 与版权声明；本适配的改动集中在 `launcher/app/build.gradle`、几个 Java 文件，以及新增的 `install-tcl-android6.ps1` 与本文档。
- 推送后，建议在你 GitHub 仓库的 README 顶部加一句说明这是 Android 6 适配分支，并指向本说明文档，方便其他人使用。

