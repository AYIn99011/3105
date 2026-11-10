# 清扫（Qingsao）

从 3105（worse_query 适配版）拆出的独立清理 App：枚举全部 App 数据容器 → 逐个授权 → 认人（prefs + 名表字典探针）→ 全量统计 → 逐层盘点勾选删除（含保护项分批解锁）。仅 iOS 26/27（worse_query 射程），自签/开发者证书自用。

血统：3105（YangJiiii）+ worse_query（Taj C / forcequitOS），GPL-3.0。LSStoreParser（LaunchServices CSStore2 数据库解析）移植自 WQFiles（kolbicz，GPL-3.0）。

## 构建（macOS 26 / Xcode 26）

1. `brew install xcodegen`（已有可跳过）
2. 本目录执行 `xcodegen generate`，打开 `Qingsao.xcodeproj`
3. 选 target Qingsao → Signing & Capabilities：
   - 勾 Automatically manage signing，Team 选你自己的开发者账号
   - App Groups 里确认 `group.com.apple.mobile.MobileHouseArrest` 已注册（Xcode 一般自动建；报错就去开发者后台先建这个组再回来）
4. 连 iPhone（27.3 b1，**别升 b2/RSR**），Run

## 另一条签名路（不走 Xcode 直签时）

用轻松签那类工具签 IPA 时，描述文件里的 App Group 由签名档决定——App 内的组发现是动态读描述文件的，档里有哪个组就用哪个，不依赖 entitlements 里写死的组。Xcode 直签则必须让 entitlements 的组在你团队下真实存在（见上）。

## 与 3105 分叉版的差异

- 包名 com.apple.mobile.MobileHouseArrest、显示名「清扫」。2026-11-09 实测定性：containermanagerd 的 class-2 路径查询认宿主 bundle ID——换成自有 ID（com.ayinjun.cleaner）后反查验证与字典探针整场 0 命中，prefs 里没写自身 ID 的 App（酷安/抖音/QQ音乐等）全部漏检，故拍板沿用 MobileHouseArrest 身份；安装会覆盖 3105 fork 版（同 ID，替代关系）。
- 只保留清理与日志两个页；仓库/壁纸/补丁等上游功能未带入
- 未带 opa334 内核链（iOS 17/18 用，本机型不需要）；ContainerStore 里原内核门禁的一处调用已改为直接尝试扫描（无权限时自然空手而归）
- Utils.swift 只保留 AppLog/log/AppInfo；更新检查等上游逻辑未带入
- AppIconHelper（ObjC）原样带入：ContainerStore 的 appInfoForBundleID/installedAppInfo 是它提供的 C 函数（本沙盒里返回空，但链接必需）
- ContainerStore 对 PatchPathValidator 的唯一一处调用（bundle ID 规范形校验）已等价内联为私有 helper，未带入补丁工程模型文件；ContainerIdentityResolver、FileBrowserMetadata 为其真实依赖，原样带入

## 注意

- 首次启动后等列表数字「长大」：先出缓存口径，后台逐个回填整容器口径
- 保护项（Preferences、mmkv、账号 archiver）默认锁定，盘点页点锁解锁，仅当页有效；保护项与普通项分开确认、分开汇报
- 删的是数据容器内容，操作不可逆；大动作前先想一遍（该提醒只说这一次）
