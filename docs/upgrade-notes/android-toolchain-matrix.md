# Android 工具链矩阵与迁移要点（升级笔记）

来源：https://flutter.dev/blog/whats-new-in-flutter-3-47 · https://developer.android.com/build/releases/gradle-plugin · https://docs.flutter.dev/release/breaking-changes/android-java-gradle-migration-guide

## 版本矩阵（Flutter 3.47 官方配套）
| 项 | 要求 |
|---|---|
| Java | 17（最低） |
| Kotlin Gradle Plugin | 2.4.0 |
| Android Gradle Plugin | 9.1.0 |
| Gradle | 9.3.1 |
| compileSdk/targetSdk | 36；minSdk 24 |

（AGP↔Gradle 完整矩阵：https://developer.android.com/build/releases/gradle-plugin ——待网络恢复补充完整表格）

## Flutter 校验机制
- Flutter Gradle 插件在应用阶段校验 Gradle 最低版本（不满足即报错，可 `--android-skip-build-dependency-validation` 绕过——不建议，仅应急）
- `flutter analyze --suggestions` 可检查 AGP/Java/Gradle 兼容性并给出建议版本

## 已知兼容问题
- Flutter 3.47.2 + AGP 9.1.0 + Gradle 9.3.1 存在兼容 bug（GitHub issue #192111）——迁移阶段 1 前先查该 issue 状态与 workaround

## 迁移注意
- `android.builtInKotlin=false` / `android.newDsl=false` 为 Flutter 迁移器自动加的过渡开关，AGP 9 下逐个翻转验证
- 每个插件/子项目的构建脚本都可能引用被移除的 API，逐个适配（vendored 包 8 个 + 全部第三方插件）
