# AGP 9.1 + Gradle 9.3.1 迁移尝试：完整阻塞地图（2026-11-13 实测）

> 本文件是阶段 1 迁移尝试（6 次本地构建迭代）的完整结论。迁移目标组合
> Flutter 3.47.2 + Gradle 9.3.1 + AGP 9.1.0 + KGP 2.4.0 当前**不可行**，
> 阻塞点全部来自插件生态（issue #192111 的"所有插件必须迁移内置 Kotlin"之墙），
> 而非本项目代码。未来重试时按本文件反向解锁。

## 三向不可行三角（实测）

| 组合 | 结果 |
|---|---|
| `newDsl=true` + `builtInKotlin=false` | ❌ `kotlin-android`（外部 KGP）应用失败：ApplicationExtension 无法 cast 到 BaseExtension（外部 KGP 与新 DSL 互斥） |
| `newDsl=true` + `builtInKotlin=true` | ❌ 理论可行但要求**全部 ~40 个插件模块**迁移内置 Kotlin——issue #192111 之墙，生态未就绪 |
| `newDsl=false` + `builtInKotlin=false` | ❌ 兼容模式禁用特性：`defaultConfig contains custom resource values, but the feature is disabled`（resValue/buildConfigField 不可用）；且 Kotlin DSL 脚本在 `android{}`（BaseAppModuleExtension）、`kotlinOptions`、`srcDir` 上为**错误级废弃**，kts 不可用，须转 Groovy（已验证 Groovy 可配置） |

## 需要迁移的清单（解锁 builtInKotlin=true 时逐一处理）

1. **app 构建脚本**：`kotlinOptions` → KGP `compilerOptions`；`srcDir` → 新 API；`applicationVariants`（AGP 9 已删除）→ `androidComponents.onVariants` + `output.filters`（`FilterConfiguration.FilterType.ABI`）+ `output.versionCode.set(...)`——fdroid 的 versionCode*10+abiCode 方案在新 API 有对应入口（本次已验证 API 成员存在）
2. **APK 文件命名**：新变体 API 的 `VariantOutput` **没有 outputFileName**——旧命名逻辑（absorb-<ver>-<code>[-dev]-<abi|all-universal>.apk）需移到 package 任务 doLast 重命名或 CI 侧步骤
3. **resValue/buildConfigField**：`app_name`（flavor 差异）与 `ABSORB_BASE_VERSION_CODE`——迁移内置 Kotlin 后应恢复可用；若仍受限则改为 per-flavor `src/<flavor>/res/values/strings.xml` + PackageInfo 运行时读取
4. **全部第三方插件模块**（约 30 个 pub.dev 插件的 android 目录）：它们各自 apply 的 `org.jetbrains.kotlin.android` 在 AGP 9 + builtInKotlin=true 下与项目冲突——等各插件发 AGP 9 兼容版本
5. **vendored 8 包**的构建脚本逐一适配

## 已验证可用的事实（未来迁移可直接复用）

- Gradle wrapper 9.3.1 下载与运行正常（Java 17 ✓）
- AGP 9.1.0 配置阶段可到达（插件解析 ✓）
- Groovy 脚本兼容模式下可配置（Kotlin DSL 不可用）
- `androidComponents.onVariants$default(ext, null, closure as Action, 1, null)` 的 Groovy 调用可达（需 `as Action` 消歧 Function1/Action 双重载歧义）
- `VariantOutput.filters`（继承自 VariantOutputConfiguration）+ `FilterType.ABI` + `versionCode Property` 在新 API 中存在——fdroid versionCode 方案有 API 入口

## 重试时机

- 上游（pounat/absorb）完成 AGP 9 迁移后同步其工具链提交
- 或 issue #192111 关闭 + 主流插件（workmanager/background_downloader/home_widget/cached_network_image 族）发布 AGP 9 兼容版后
- 届时按本文件"需要迁移的清单"反向执行
