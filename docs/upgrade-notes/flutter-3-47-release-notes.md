# Flutter 3.47 发布要点（升级笔记）

来源：https://flutter.dev/blog/whats-new-in-flutter-3-47

## 工具链矩阵（Android）
- Java 17（最低）
- Kotlin Gradle Plugin 2.4.0
- Android Gradle Plugin 9.1.0
- Gradle 9.3.1
- 默认 SDK：compileSdk/targetSdk 36、minSdk 24（本项目已一致）

## 引擎与图形
- Impeller 成为 macOS/Windows/Linux 默认渲染器（预编译着色器消除 shader jank）；临时可回退 Skia（未来移除）
- macOS 默认 Wide Gamut Color
- 桌面文本 SDF 渲染（文字/矢量更锐利）
- Web：--wasm 发布可用；实验性 Wasm 延迟加载

## Apple 平台
- iOS 27 / macOS 27 / Xcode 27 准备；iOS 27 强制 UIScene 生命周期（自定义 AppDelegate 需迁移）
- 最低版本：iOS 13→15、macOS 10.15→12
- Intel Mac 淘汰进行中（警告→未来错误）
- Swift Package Manager：Top100 插件 92 个已迁移；CocoaPods 维护模式，未迁移插件将失效

## 工具与修复
- Widget Previews 稳定
- 修复：Android 虚拟键盘修饰键卡住、文本选择手柄滚动稳定性、SelectableRegion 空容器崩溃、韩文 IME 光标（Windows）、Linux 手写笔压力/旋转

## 设计系统解耦
- material_ui / cupertino_ui 独立包 1.0（可脱离 SDK 按周更新，可选加入）
- flutter_localizations 解绑
