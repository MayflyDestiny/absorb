# Gradle 9 升级要点（升级笔记）

来源：https://docs.gradle.org/9.0.0/release-notes.html · https://gradle.org/whats-new/gradle-9 · https://blog.gradle.org/road-to-configuration-cache

## 性能
- 配置缓存稳定且默认开启（配置阶段结果复用，跳过 build.gradle.kts 重复执行）
- Kotlin K2 编译器支持；社区实测小模块单文件修改提速约 50%
- 各阶段并行与开销优化

## 破坏性变更（迁移关注点）
- 移除大量废弃 API（Kotlin DSL、插件 API）——插件与项目脚本需适配
- 配置缓存不兼容的任务需显式处理或关闭（过渡期）

## 目标版本
- 本项目目标：9.3.1（2026-01-29 发布，补丁版，含 bug 修复）
