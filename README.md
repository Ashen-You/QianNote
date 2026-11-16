# Slate — iPad 手写笔记 App（Notability 风格）

一个用 **SwiftUI + PencilKit** 编写的 iPad 手写笔记应用，参考 Notability 的核心体验：手写、PDF 批注、录音同步、多页笔记、导出分享。

工程**不含任何签名配置**，打开后选择你自己的开发者 Team 即可编译运行。

---

## 1. 环境要求

| 项目 | 要求 |
| --- | --- |
| Xcode | 15.0 及以上（推荐 16.x） |
| 系统 | iOS / iPadOS 17.0+ |
| 语言 | Swift 5（工程已设为 Swift 5 语言模式） |
| 设备 | iPad（推荐配 Apple Pencil）；iPhone 也能运行 |
| 依赖 | 无第三方库，全部使用系统框架（SwiftUI、PencilKit、PDFKit、AVFoundation） |

## 2. 打开 & 签名（三步）

1. 双击 `Slate.xcodeproj` 打开工程。
2. 左侧选中项目 **Slate** → `TARGETS: Slate` → **Signing & Capabilities**：
   - 勾选 **Automatically manage signing**
   - **Team** 选择你自己的 Apple ID / 开发者团队
   - 如果提示 Bundle ID 冲突，把 `Bundle Identifier` 改成 `com.你的名字.slate`
3. 顶部设备选择你的 iPad（或模拟器），按 `⌘R` 运行。

> 免费 Apple ID 也能签名，但证书 7 天过期，到期重新 `⌘R` 一次即可；付费开发者账号为 1 年。
> 工程里 `CODE_SIGN_STYLE = Automatic`、没有 `.mobileprovision`、没有 Team，所以不会因为签名报错——只等你选 Team。

想直接拿到 ipa、或没有 Mac：见下一节。

## 3. 生成 IPA（不依赖 Apple 签名）

> 硬性前提：IPA 里的 arm64 二进制必须由 Apple 的 iOS SDK 编译，**只能在 macOS 上产出**。Linux / Windows 上无论如何都编不出来，这里也一样。

### 路径 A：GitHub Actions 云端编译（没有 Mac 也能用）★ 推荐

工程里已经放好 `.github/workflows/build-ipa.yml`，会在 GitHub 的 macOS 机器上编译并打包成未签名 IPA。

1. 新建一个 GitHub 仓库（public / private 都行），`git init` 后把 **本目录的内容**（保证 `Slate.xcodeproj` 在仓库根目录）推上去：
   ```bash
   cd Slate
   git init && git add . && git commit -m "init"
   git branch -M main
   git remote add origin https://github.com/你的用户名/slate.git
   git push -u origin main
   ```
2. 打开仓库的 **Actions** 标签页 → 左侧 `Build unsigned IPA` → 右侧 `Run workflow`。
3. 等 3～6 分钟，进入这次运行，页面底部 **Artifacts** 下载 `Slate-unsigned-ipa`，解压得到 `Slate-unsigned.ipa`。

> private 仓库的 macOS runner 按 10 倍计费，免费额度 2000 分钟/月 ≈ 能跑 30 多次；public 仓库完全免费。

### 路径 B：自己的 Mac 上一条命令

```bash
bash Scripts/build_ipa.sh              # 产出 build/Slate-unsigned.ipa
TEAM_ID=你的TeamID bash Scripts/build_ipa.sh --signed   # 用本机证书导出已签名 IPA
```

### 路径 C：Xcode 图形界面

`Product > Archive` → Organizer 里 `Distribute App` → `Development`（装到自己设备）或 `Ad Hoc`（装到指定 UDID）。

### 装到 iPad 上

未签名 IPA **不能**直接双击/拖进「访达」安装，必须用工具补签名：

| 工具 | 平台 | 说明 |
| --- | --- | --- |
| **Sideloadly** | Win / Mac | 最简单，拖入 ipa + 填 Apple ID，自动签名安装 |
| **AltStore / SideStore** | iOS 端自签 | 电脑端装一次，之后无线续签，7 天一次 |
| **爱思助手** | Windows | 国内网络友好，工具箱里有 IPA 签名 |
| **TrollStore** | iOS 14.0–17.0 特定版本 | 系统漏洞永久签名，无需续签；不支持则用上面几种 |

**免费 Apple ID 的限制**：证书 7 天过期（到期重新签一次，笔记数据不会丢）、最多同时 3 个自签 App、无法使用 iCloud 等需要付费账号的 entitlement。工程本身没有用到任何受限能力，免费账号可完整运行。

## 4. 功能一览

### 手写
- **四种笔**：钢笔、铅笔、荧光笔 + 橡皮 + 套索 + 文字
- 每种笔**独立记录颜色与粗细**（自动持久化到 UserDefaults）
- **12 色常用色板** + 系统取色器（任意颜色）
- 橡皮为矢量擦除（只擦笔迹不擦底图）
- **撤销 / 重做**：自带快照式撤销栈（最多 60 步），顶栏按钮实时可用
- 手指书写开关（关闭后只能用 Pencil 书写）
- 倾斜 / 压感由 PencilKit 原生支持

### 页面与纸张
- 纸张模板：**空白 / 横线 / 方格 / 点阵 / 康奈尔**
- 纸张底色：**纯白 / 米色 / 深色**
- 右侧页面缩略图栏：点按跳转、长按菜单（复制、插入空白页、删除）
- 多页管理：插入、复制、删除、上下翻页

### 全屏与阅读
- **全屏阅读**：顶栏一键进入，隐藏顶栏 / 底栏 / 工具栏 / 缩略图，页面铺满整屏
- 全屏内保留三条窄控件：退出、翻页、**整页 / 适应宽度**切换；左侧另有一条窄工具带可直接换笔
- PDF 底图 3× 渲染，导出 PDF 时未旋转页面走矢量绘制

### PDF 批注
- 从「文件」App 导入 PDF，自动按页数拆成笔记页，页尺寸按 PDF 原始比例
- 直接在 PDF 上书写、擦除，导出时与原 PDF 内容合并为新的 PDF

### 录音（Notability 的录音笔记）
- 顶部麦克风一键录音，支持暂停 / 继续
- 录音过程中**切换页面会自动打书签**（记录「第几页 / 第几秒」）
- 回放时**自动跟随书签翻页**，边听边看当时写的那一页
- 支持进度拖动、删除录音

### 文字
- 文字工具：在页面上点按即可插入文本框
- 可拖动位置、修改字号、删除；导出 PDF 时与手写一起合成

### 笔记库
- 网格布局 + 首页缩略图预览、收藏星标、PDF / 录音角标
- **文件夹**：新建、重命名、删除、移动笔记
- 搜索、排序（最近修改 / 创建时间 / 标题）、收藏筛选
- 长按菜单：重命名、收藏、复制副本、移动、删除
- 导出 PDF（当前笔记全部页面）→ 系统分享面板

## 5. 代码结构

```
Slate/
├── SlateApp.swift              App 入口
├── Models/
│   ├── Note.swift              数据模型：Note / NotePage / TextBox / AudioMarker / Folder
│   ├── PaperStyle.swift        纸张模板与底色（SwiftUI + UIKit 双份配色）
│   └── ToolStore.swift         工具状态（笔种、颜色、粗细、持久化、PKTool 生成）
├── Services/
│   ├── NoteStore.swift         数据仓库：索引读写、增删改查、墨迹文件、缩略图、PDF 导入导出、录音元数据
│   ├── PageRenderer.swift      渲染合成：纸张 / PDF 底稿 / 墨迹 / 文字 → UIImage 或 PDF
│   └── AudioController.swift   录音与播放（AVAudioRecorder / AVAudioPlayer + 定时器）
├── Views/
│   ├── LibraryView.swift       笔记库（网格、文件夹、搜索、排序、导入）
│   ├── NoteCardView.swift      笔记卡片（缩略图 + 元信息）
│   ├── EditorView.swift        编辑页骨架：顶栏 / 左侧工具栏 / 画布 / 底栏 / 缩略图栏
│   ├── NotePageView.swift      单页：背景 + 画布 + 文字层 + 纸张绘制
│   ├── DrawingCanvas.swift     PKCanvasView 封装 + CanvasController（撤销 / 重做）
│   ├── ToolRailView.swift      左侧工具栏 + 底部颜色 / 粗细栏
│   ├── PageStripView.swift     右侧页面缩略图栏
│   ├── AudioViews.swift        录音按钮、录音浮条、页面-录音同步器
│   └── Components.swift        通用组件（毛玻璃面板、图标按钮、颜色点、分享面板、错误条）
├── Support/
│   ├── Theme.swift             主题色
│   └── Extensions.swift        Color↔Hex、数组安全下标、等比缩放等
└── Assets.xcassets             App 图标 + 强调色
```

## 6. 数据存放方式

全部存在沙盒 `Documents/Slate/` 下，纯文件、无数据库：

```
Documents/Slate/
├── index.json                     所有笔记与文件夹的元数据
└── Notes/<笔记UUID>/
    ├── p_<页面UUID>.drawing       PKDrawing 二进制（每页一个）
    ├── t_<页面UUID>.png           页面缩略图缓存
    ├── source.pdf                 导入的 PDF 原稿（若有）
    └── audio.m4a                  录音（若有）
```

- 元数据用 `Codable` + JSON（ISO8601 日期），改动后 0.7 秒防抖落盘
- 每页墨迹单独存文件，边写边增量保存，避免大文件重写
- 缩略图在停笔 1.2 秒后后台重绘

> 工程开启了 `UIFileSharingEnabled`，可在「文件」App 里直接查看/拷贝这些数据。

## 7. 关键实现说明（方便二次开发）

- **画布**：`DrawingCanvas` 把 `PKCanvasView` 包进 SwiftUI，`isScrollEnabled = false` 让页面固定；工具通过 `ToolStore.pkTool` 注入。用 `toolKey` 字符串比对，避免每次刷新都重设工具导致套索选区丢失。
- **撤销**：不依赖 `UndoManager`，而是 `CanvasController` 保存 `PKDrawing` 快照栈，撤销时整体回填并回写存储，行为稳定。
- **页面缩放**：页面按固定点数（默认 768×1024，导入 PDF 时取 PDF 页尺寸）绘制，用 `scaleEffect` 适配屏幕。这样墨迹坐标与纸张尺寸解耦，换设备、导出都不会变形。
- **PDF 批注**：以 PDF 页的 `thumbnail` 作为底图铺在画布下，导出时再用 `UIGraphicsPDFRenderer` 把「PDF 页 + 墨迹 + 文字」按 2 倍分辨率合成新 PDF。
- **录音同步**：录音时监听 `pageIndex` 变化写入 `AudioMarker(pageIndex,time)`；回放时监听播放进度，命中最近的书签就自动翻页。

## 8. 已知限制 / 可继续做的方向

- 没有 Notability 的「放大书写框」（zoom box），目前是整页适配屏幕书写
- 没有形状识别（画三角自动变三角形）、没有贴纸/图片插入
- 没有 iCloud 同步、没有手写文字识别（OCR / 手写转文字）
- 录音只保留一条（重新录音会覆盖），且不记录笔迹回放（只做页面级书签同步）
- 套索选中后的「移动/缩放选中笔迹」由 PencilKit 原生提供，功能较基础
- 导出 PDF 时整页会被合成为 2 倍分辨率的位图（不是矢量 PDF），文字与笔迹清晰但不可再选中

这些都留了扩展位，例如加图片只需在 `NotePage` 里加 `ImageItem` 数组并在 `PageRenderer` 里多画一层。

## 9. 改名 / 换图标

- App 名称：`Signing & Capabilities` 同页的 `Display Name`，或在 `project.pbxproj` 里改 `INFOPLIST_KEY_CFBundleDisplayName`
- Bundle ID：`PRODUCT_BUNDLE_IDENTIFIER`
- 图标：替换 `Slate/Assets.xcassets/AppIcon.appiconset/AppIcon.png`（1024×1024，无圆角）
