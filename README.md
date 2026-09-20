# Absorb

[![Buy Me A Coffee](https://img.shields.io/badge/Buy_Me_A_Coffee-FFDD00?style=for-the-badge&logo=buy-me-a-coffee&logoColor=black)](https://buymeacoffee.com/BarnabasApps)

一款基于 Audiobookshelf 的现代有声书客户端，提供卡片式播放体验。

> **关于本 Fork 的说明：** 本仓库为 [pounat/absorb](https://github.com/pounat/absorb) 的 Fork 版本，**所有后续修改均由 AI（OpenCode / Claude Code）生成并提交**。Fork 后的改动集中在 **Android 平台的 UI 体验优化与功能增强**，仅打包 Android 版本，不涉及 iOS 构建。

---

## 截图

<p align="center">
  <img src="screenshots/absorbing.png" width="200">
  &nbsp;
  <img src="screenshots/library.png" width="200">
  &nbsp;
  <img src="screenshots/details.png" width="200">
</p>
<p align="center">
  <img src="screenshots/fullScreen.png" width="200">
  &nbsp;
  <img src="screenshots/stats.png" width="200">
</p>

## 功能特性

- **卡片式播放器** — 全屏"正在收听"卡片替代传统播放界面
- **Audiobookshelf 集成** — 连接自托管 Audiobookshelf 服务器
- **离线播放** — 下载书籍，无需网络即可收听
- **播客支持** — 带章节的播客，富 HTML 描述
- **备份与恢复** — 导出所有设置到 `.absorb` 文件，支持账户凭证迁移
- **多账户** — 登录多个服务器并切换
- **睡眠定时器** — 可视化进度条、自动定时、摇一摇重置
- **播放速度** — 精细滑块控制，按书记忆速度
- **自动回退** — 可配置暂停后自动回退时长
- **均衡器** — 内置音频 EQ，支持频段和预设
- **书签** — 任意时刻保存和跳转
- **章节导航** — 双进度条（全书 + 章节）
- **搜索与筛选** — 全文搜索、按进度/类型/系列筛选、多种排序
- **Audible 评分** — 在书籍上查看 Audible 星级评分
- **自动播放下一集** — 自动继续系列中的下一本书或下一个播客
- **Android Auto & Apple CarPlay** — 车载浏览和收听
- **Chromecast** — 投屏播放（仅 Android）
- **自定义请求头** — 适配反向代理
- **OIDC/SSO 登录** — OpenID Connect 支持
- **服务器管理** — 管理用户、备份、播客
- **收听统计** — 追踪收听历史
- **Audnexus 元数据** — 丰富封面、描述、系列信息
- **发现即将上架** — 通过 Audible 目录发现系列新书
- **笔记** — 按书籍或章节记录
- **播放列表与收藏** — 创建自定义分组并播放
- **最近播放** — 快速访问收听历史
- **实时同步** — 通过 socket.io 同步进度、书库变更
- **桌面小组件** — Android/iOS 桌面正在播放小组件
- **车载模式** — 大按钮驾驶 UI（无需 Android Auto）
- **国际化** — 社区翻译（Crowdin）

## 新增功能 / Fork Additions

> 以下功能由 AI 在 Fork 后新增，原始项目不包含。仅打包 Android 版本。

- **章节跳过** — 支持为单本书单独配置片头/片尾跳过时长，上一章按钮可选直接跳上一章或重启当前章
- **章节级下载管理** — 支持单章/多章增量下载，保留已下载章节，可删除任意已下载章节
- **下载确认弹窗** — 所有下载入口新增确认步骤，防止误触下载
- **下载位置引导** — 首次下载时引导选择公共存储目录，适配 Scoped Storage
- **下载自动清理** — 启动时自动验证并移除不存在的本地下载条目
- **本地 JSON 缓存系统** — 按账户隔离的本地文件缓存，冷启动直接展示缓存数据，后台静默更新
- **图片无闪烁加载** — 旧图保留至新图就绪，封面切换时零占位符、零闪烁
- **列表/书架无抖动刷新** — 数据合并更新，刷新时标题/封面/进度条原地更新不重建
- **启动预热** — 后台预取前 20 张封面 + Provider 数据并行加载，切换标签页零卡顿
- **网格/列表布局切换** — 图书馆支持网格和列表视图，每个媒体库独立记忆布局偏好
- **封面状态标签** — 书籍卡片展示已下载章节占比
- **睡眠定时器增强** — 新增时分滚轮选择器、摇一摇模式、淡入淡出策略
- **Socket 软重连** — 凭证检测 + 自动重连，网络波动下更稳定
- **本地缓存手动清理** — 设置页可手动清理书架缓存、阅读进度缓存
- **服务器日志本地化** — 支持多语言展示日志等级与过滤选项

---

## 国际化翻译

[![Crowdin](https://badges.crowdin.net/absorb/localized.svg)](https://crowdin.com/project/absorb)

Absorb 通过 [Crowdin](https://crowdin.com/project/absorb) 进行社区翻译。欢迎贡献你的语言翻译。

## 安装

[![GitHub Releases](https://img.shields.io/badge/GitHub_Releases-blue?style=for-the-badge&logo=github)](../../releases)
[![Obtainium](https://img.shields.io/badge/Get_it_on-Obtainium-teal?style=for-the-badge&logo=data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBhdGggZD0iTTEyIDJMMiAyMmgyMEwxMiAyeiIgZmlsbD0id2hpdGUiLz48L3N2Zz4=)](https://apps.obtainium.imranr.dev/redirect.html?r=obtainium://add/https://github.com/pounat/absorb)

> **注意：** 本 Fork 版本仅发布 Android APK，不提供 iOS 构建。如需 iOS 版本请使用原始仓库 [pounat/absorb](https://github.com/pounat/absorb)。

### Android Auto

Absorb 支持 Android Auto 车载浏览和收听。使用 GitHub 版本需要启用未知来源：

> 1. 打开手机上的 **Android Auto** 设置
> 2. 底部多次点击 **版本号** 启用开发者模式
> 3. 点击右上角三点菜单 → **开发者设置**
> 4. 启用 **未知来源**

## 环境要求

- [Audiobookshelf](https://www.audiobookshelf.org/) 服务器（自托管）
- Android 7.0+

## 许可证

版权所有 (C) 2026 Nathan Poulson

本程序是自由软件：您可以在自由软件基金会发布的 GNU 通用公共许可证的条款下重新分发和/或修改它（版本 3 或更高版本）。

本程序的发布是希望它会有用，但没有任何保证；甚至没有适销性或特定用途适用性的暗示保证。有关详细信息，请参阅 GNU 通用公共许可证。

您应该已经收到了 GNU 通用公共许可证的副本。如果没有，请参阅 <https://www.gnu.org/licenses/>。

---

## 更新日志

> 以下为 Fork 后由 AI 生成的主要变更记录，仅涉及 Android 平台修改。
> 详细变更请查看 [CHANGELOG_FULL.md](CHANGELOG_FULL.md)

<details>
<summary><b>展开查看完整更新日志 (v1.11.2+280 → v1.21.3+353)</b></summary>

### v1.21.3+353 — 列表/封面加载无闪烁终极优化

- 封面缓存键简化：仅读本地 `updatedAt`，彻底消除冷启动封面重载闪烁
- `StableCachedNetworkImage` 重写：gapless 预热切换，旧图保留至新图就绪
- 数据合并工具：`_mergeSections()` / `_mergeItems()` 原地更新 Map，列表/书架刷新零抖动
- 启动预热：后台预取前 20 张封面 + Provider 数据并行加载，切 Tab 零卡顿

### v1.21.2 — 下载管理与缓存清理

- 下载位置引导：首次下载提示选择公共存储目录（Scoped Storage 兼容）
- 本地缓存手动清理：设置页可清理书架、阅读进度缓存
- Socket 软重连：凭证检测 + 自动重连，网络波动下更稳定
- 下载自动清理：启动时验证并移除不存在的本地下载条目
- 旧图保留参数：所有图片加载组件添加旧图保留，避免切换闪烁

### v1.21.0+340 — 图片加载防闪烁

- 全项目 `CachedNetworkImage` 添加 `useOldImageOnUrlChange`，URL 变更时保留旧图
- 书架实体更新时间与封面状态统一注册，避免首次加载重复触发封面下载
- 图书馆页面标签切换淡入淡出动画

### v1.21.0+338 — 本地 JSON 缓存系统

- `JsonFileCache`：按账户隔离的本地文件缓存，替代大体积 SharedPreferences 存储
- 进度刷新、书架加载、列表查询冷却节流，避免重复网络请求
- 首页/图书馆/收藏/播放列表缓存优先 + 后台更新，冷启动直接展示缓存数据

### v1.20.5+336 — 章节级下载与布局切换

- 章节级下载管理：单章/多章增量下载，保留已下载章节
- 网格/列表布局切换：每库记忆布局偏好
- 封面状态标签：展示已下载章节占比
- 本地播放进度并行请求，媒体库首页加载提速

### v1.20.3~1.20.4 — 设置与下载优化

- 章节选择下载功能，支持指定章节增量下载
- 服务器日志本地化过滤
- 设置页面展开分区滚动对齐优化

### v1.20.1~1.20.2 — 播放器增强

- 下载确认弹窗，防误触
- 睡眠定时器重构：时分滚轮、摇一摇模式、淡入淡出策略
- 上一章跳章设置，可选直接跳上一章或重启当前章
- 后退跳过时长调整为 15 秒

### v1.20.0+290~291 — Android 图标修复与国际化

- Android 快退/快进播放控制图标方向修正
- 通知栏播放按钮拦截修复
- 多语言本地化全面覆盖

### v1.11.2+280 — 早期版本基线

- Android 媒体通知按钮重排与样式优化
- GitHub Actions 发布工作流简化

</details>

---

> **本 Fork 所有修改均由 AI 生成，仅打包 Android 版本。**
> 如需 iOS 版本或原始功能，请使用上游仓库 [pounat/absorb](https://github.com/pounat/absorb)。
