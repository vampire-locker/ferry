# 本地化与外观

应用支持简体中文和英文，开发语言与未知系统语言的回退为简体中文。界面语言默认跟随系统，也可在设置中固定选择语言；更改将在下次启动生效。语言在进程生命周期内保持不变，后台筛选、排序和 helper 使用相同语言，避免一次任务中混用语言。

## 资源与调用

- `Sources/FerryCore/Resources/<语言>.lproj/Localizable.strings` 包含界面、文件类型、动态状态与 Swift 错误文案。
- Swift 用 `L10n.text("文案")`，动态内容用 `L10n.text("共 \(count) 项")`。`LocalizedMessage` 将插值参数独立为 `%@`，用户文件名与实际数值不参与翻译键。
- `engine/internal/i18n/locales/<语言>.json` 包含 Go helper 的状态、错误和操作名称；用 `i18n.Text("文案")` 取模板，仍通过 `fmt` 格式化或包装错误，保留 `%w`、`errors.Is` 和 `errors.As` 语义。
- `Resources/Localizations/<语言>.lproj/InfoPlist.strings` 包含系统显示名称与磁盘权限说明。

中英文资源使用相同的开发语言模板作为稳定键。翻译须保留参数数量和类型；Swift 的 `%@` 可用 `%1$@` 等位置标记调整顺序，格式化文案中的字面百分号写成 `%%`。Go 的 `%d`、`%s`、`%q`、`%w` 等不能随意更改。不要把用户文件名或引擎返回的动态错误整段当成翻译键，也不要按翻译后的展示文本判断业务状态。

## 新增语言

1. 复制上述三组资源到新语言目录，使用 BCP-47 语言标识，例如 `fr`、`ja`、`pt-BR`，补全翻译并保留占位符。
2. 在 `Sources/FerryCore/Localization.swift` 的 `AppLanguage` 中注册语言标识与本国语言名称。跟随系统的匹配会读取此注册列表，缺失翻译回退开发语言。
3. 将语言标识加入 `Resources/Info.plist` 的 `CFBundleLocalizations`，让 macOS 菜单、应用名称与权限界面识别该语言。
4. `Package.swift` 自动处理 Swift 本地化目录；Go 的 embed 自动包含 JSON；`scripts/build-app.sh` 自动复制 Swift 资源包和系统本地化目录。运行构建即可生成含资源的应用。

应用优先从 `.app/Contents/Resources/Ferry_FerryCore.bundle` 读取 Swift 资源，SwiftPM 开发环境使用 `Bundle.module`；不能依赖开发机器的绝对构建路径。SwiftPM 会将部分目录名规范为小写，资源解析兼容此命名。

`EngineRunner` 为子进程设置 `FERRY_LANGUAGE`，不通过请求 JSON 字段传递语言。直接调用 helper 时可设置此环境变量；不设置时使用简体中文。报告的结构、状态值、原始文件名、`传输报告.json`、`任务记录.ndjson` 与任务目录前缀保持既有契约。

## 语言偏好与外观

语言偏好保存在 `appLanguage`；显式语言同步到应用偏好域的 `AppleLanguages`，跟随系统时移除此覆盖。重启同时切换 Cocoa 系统菜单和应用内容。未设置语言或外观时分别使用跟随系统，不覆盖操作系统的全局偏好。

`AppAppearance` 定义跟随系统、浅色和深色，保存在 `appearance`。仅由 AppKit 的 NSApp.appearance 驱动外观：浅色/深色分别设为 aqua/darkAqua，跟随系统清空应用覆盖。主窗口、设置窗口和 SwiftUI 托管内容继承同一外观，不再叠加 preferredColorScheme 或单独固定窗口外观，避免从显式颜色切回系统时标题栏与内容不同步。颜色使用系统语义背景，视频画面区域保持播放器自身样式。

浏览页的独立 NSHostingView 显式接收界面 locale 与品牌 tint，颜色外观仍从 AppKit 窗口继承；隐藏或切页不会固定另一套 ColorScheme。

任务进度条的小舟和水面图层通过继承的 effectiveAppearance 更新配色，深色下提高绿色的亮度，不覆盖窗口外观。进度条提供中英文“下载进度”及实际百分比的辅助功能文本；码头和小旗整体的可见右缘对齐轨道终点；码头、小旗及船锚沿用绿色与语义灰色，失败浮标使用系统橙色并随外观刷新。减少动态效果时移除浮动、进度插值与靠岸动画，直接显示对应场景，不改变真实传输进度。

本地工具的重命名图标统一取自 LocalTool.rename.symbol，使用 square.and.pencil，卡片与详情页保持一致。
