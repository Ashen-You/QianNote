# Qian's Note — iPad 手写笔记 App

一个用 **SwiftUI + PencilKit** 编写的 iPad 手写笔记应用，覆盖手写、PDF 批注、多页笔记、文档导入与导出。当前版本 **v2.1.2（build 18）**。

工程名、Bundle ID、数据目录、类型名均已统一为 **QianNote**，App 显示名为 **Qian's Note**。工程不含签名配置，打开后选择自己的开发者 Team 即可编译运行。

> 版本说明：v2.0.0 已移除录音与逐笔回放，v2.1.1 已移除手写 OCR，v2.1.2 修复连续滚动下 Pencil 被滚动手势抢走、无法书写。搜索只匹配笔记标题与文字框，不再索引手写内容。

---

## 1. 环境要求

| 项目 | 要求 |
| --- | --- |
| Xcode | **26.0 及以上**（代码使用 iOS 26 的 Liquid Glass，Xcode 16.x 只有 iOS 18 SDK 会编译失败） |
| 系统 | iOS / iPadOS 17.0+（iOS 26 起启用系统玻璃质感，低版本自动降级为毛玻璃） |
| 语言 | Swift 5（工程使用 Swift 5 语言模式） |
| 设备 | iPad（推荐配 Apple Pencil）；iPhone 也能运行 |
| 依赖 | 无第三方库，全部使用系统框架（SwiftUI、PencilKit、PDFKit、WebKit、PhotosUI、Security） |

> CI 工作流 `.github/workflows/build-ipa.yml` 跑在 `macos-26`（当前默认 Xcode 26.6 / iOS 26.5 SDK）。若自建 CI 仍用 `macos-15`，会在 `Components.swift` 的 `Glass` / `.glassEffect` 上报 `cannot find type 'Glass'`。

## 2. 打开 & 签名（三步）

1. 双击 `QianNote.xcodeproj` 打开工程。
2. 左侧选中项目 **QianNote** → `TARGETS: QianNote` → **Signing & Capabilities**：
   - 勾选 **Automatically manage signing**
   - **Team** 选择你自己的 Apple ID / 开发者团队
   - 如果提示 Bundle ID 冲突，把 `Bundle Identifier` 改成 `com.你的名字.qiannote`
3. 顶部设备选择你的 iPad（或模拟器），按 `⌘R` 运行。

> 免费 Apple ID 也能签名，但证书 7 天过期，到期重新 `⌘R` 一次即可；付费开发者账号为 1 年。
> 工程里 `CODE_SIGN_STYLE = Automatic`、没有 `.mobileprovision`、没有 Team，所以不会因为签名报错，只等你选 Team。

想直接拿到 IPA、或没有 Mac：见下一节。

## 3. 生成 IPA（不依赖 Apple 签名）

> 硬性前提：IPA 里的 arm64 二进制必须由 Apple 的 iOS SDK 编译，**只能在 macOS 上产出**。Linux / Windows 上无法产出。

### 路径 A：GitHub Actions 云端编译（没有 Mac 也能用）

工程里已经放好 `.github/workflows/build-ipa.yml`，会在 GitHub 的 macOS 机器上编译并打包成未签名 IPA。

1. 新建一个 GitHub 仓库（public / private 都行），`git init` 后把 **本目录的内容**（保证 `QianNote.xcodeproj` 在仓库根目录）推上去：
   ```bash
   cd QianNote
   git init && git add . && git commit -m "init"
   git branch -M main
   git remote add origin https://github.com/你的用户名/qiannote.git
   git push -u origin main
   ```
2. 工作流会在推送到 `main` / `master` 时自动运行，也可以在 **Actions** 标签页手动 `Run workflow`。
3. 等 3～6 分钟，进入这次运行，页面底部 **Artifacts** 下载 `QianNote-unsigned-ipa`，解压得到 `QianNote-unsigned.ipa`。

> private 仓库的 macOS runner 按 10 倍计费，免费额度 2000 分钟/月约能跑 30 多次；public 仓库完全免费。

### 路径 B：自己的 Mac 上一条命令

```bash
bash Scripts/build_ipa.sh              # 产出 build/QianNote-unsigned.ipa
TEAM_ID=你的TeamID bash Scripts/build_ipa.sh --signed   # 用本机证书导出已签名 IPA
```

> `build_ipa.sh` 会先清空 `build/` 目录再归档，不要把需要保留的产物放在里面。

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

### 手写与工具

- **七种笔尖**：钢笔、虚线笔、铅笔、毛笔、单线笔、蜡笔、水彩；外加荧光笔与激光笔
- 每种笔独立记录颜色与粗细（自动持久化到 UserDefaults）；颜色支持 24 色色板、最近使用 6 色与系统取色器
- 橡皮可切换**整笔擦 / 像素擦**，每种工具有独立宽度档位
- **形状识别**：停笔约 0.7 秒后自动把轮廓规整成直线、三角形、矩形或椭圆，可撤销、可关闭；带弯曲度的笔画不会被误判成直线
- **套索**：圈住笔迹后可以改色、复制、删除、整块拖动（自建多边形命中，不依赖 PencilKit 选区 API）
- **激光笔**：只留一道会淡出的红线，不写入笔记
- **撤销 / 重做**：每页独立的快照式撤销栈（最多 60 步），顶栏按钮实时可用
- **无笔手势**：两指点击撤销 / 三指点击重做，指写模式下同样有效，落指误触的点状笔迹会自动清理
- **拖动工具**：工具栏第一位的手形按钮，进入后手指和 Apple Pencil 都只拖页面 / 翻页，谁都不落墨；再点任意笔立即回到书写
- Apple Pencil 笔杆双击切换「笔 / 橡皮」；倾斜与压感由 PencilKit 原生支持

### 页面与视图

- 纸张模板：空白 / 横线 / 方格 / 点阵 / 康奈尔；纸张底色：纯白 / 米色 / 深色
- **连续滚动**：多页笔记默认把整本页面铺成一条共享画布，跨页书写不出现页缝；可在 `⋯` 菜单切回单页模式
- 单页模式支持双指捏合 1×–6×、以手指中心为锚点缩放、双指平移、双击切换整页 / 2.2×，以及放大后书写时页面跟随笔尖
- 单页模式下 PDF 底图按缩放档位重渲染（3× / 4.5× / 6×，约 1200 万像素上限），放大不糊；连续滚动由共享画布统一缩放
- 右侧页面缩略图栏：点按跳转、长按菜单（复制、插入空白页、删除）
- 全屏阅读：隐藏顶栏、底栏、工具栏与缩略图，保留退出、翻页与整页 / 适应宽度切换
- 顶栏菜单支持插入页面、清空当前页、切换纸张样式、导出单页图片与整本 PDF

### 文字与图片

- 文字工具在页面上**就地输入**，不弹窗；键盘上方有字号加减、删除与完成
- 文字框随内容自动撑高，内容清空后自动删除，不留「点按输入文字」的空占位
- 图片：从相册选图插入，套索模式下拖动、等比缩放、裁剪、删除
- 导出 PDF / PNG 时，文字、图片与手写一起合成

### 文档导入与导出

- 从「文件」App 导入 **PDF / Word（doc、docx）/ RTF（rtf、rtfd）/ HTML / TXT / Markdown / CSV / 图片**
- Word、RTF、HTML、文本等先由离屏 `WKWebView` 渲染并 `createPDF`，再复用 PDF 导入管线；转换超时 18 秒
- PDF 按原始宽高比导入，每页拆成笔记页，可直接在页面上书写、擦除
- 页面尺寸按最长边 1400pt 归一化，避免超大 PDF 页面触发 PencilKit / Metal 帧缓冲崩溃
- 导出整本 PDF 时，未旋转页面走矢量绘制，旋转页面回退为高倍位图；墨迹按 2 倍栅格化

### 笔记库

- 网格布局 + 首页缩略图预览、收藏星标、PDF 角标
- **文件夹**：新建、重命名、删除、移动笔记
- 搜索、排序（最近修改 / 创建时间 / 标题）、收藏筛选
- 长按菜单：重命名、收藏、复制副本、移动、删除
- **资料库备份 / 恢复**：把整个资料库备份到用户挑选的目录（通常是「文件」App 里的 iCloud 云盘），另一台设备再从该目录恢复；按 `updatedAt` 合并，本地较新的笔记不会被旧备份覆盖
- **两套 App 图标可切换**：默认「手写笔记」截图版，备用「AI 重绘」版；切换走系统 `setAlternateIconName`
- 主屏快捷方式：新建笔记 / 导入文档；支持从「文件」App 或其他 App 用 QianNote 打开文档

### 诊断与更新

- App 内采集运行日志（操作与异常），支持预览、导出到「文件」，或上传到 GitHub 专用私有日志仓库
- GitHub Token 存在 Keychain，不写死、不落明文盘
- 「关于」页检查 GitHub Releases 最新版本，做语义化版本比较

## 5. 代码结构

```
QianNote/
├── QianNoteApp.swift           App 入口、外部打开与主屏快捷方式
├── Models/
│   ├── Note.swift              数据模型：Note / NotePage / TextBox / ImageItem / Folder / LibraryIndex
│   ├── PaperStyle.swift        纸张模板与底色（SwiftUI + UIKit 双份配色）
│   ├── ToolStore.swift         工具状态（笔种、颜色、粗细、橡皮模式、持久化、PKTool 生成）
│   └── InkComposer.swift       整本墨迹合并 / 拆分（跨页笔画按最高点归属）
├── Services/
│   ├── NoteStore.swift         数据仓库：索引读写、增删改查、墨迹文件、缩略图、PDF 导入导出、备份恢复
│   ├── PageRenderer.swift      渲染合成：纸张 / PDF 底稿 / 图片 / 墨迹 / 文字 → UIImage 或 PDF
│   ├── DocumentImport.swift    Word / RTF / HTML / 图片 → PDF 的导入转换
│   ├── DocumentOpenCoordinator.swift  外部文档 / 快捷操作导入的统一协调入口
│   ├── AppLogger.swift         运行日志采集、按天落盘、异常退出检测
│   ├── GitHubLogUploader.swift 日志上传（Keychain Token + GitHub Contents API）
│   └── UpdateChecker.swift     GitHub Releases 版本检查
├── Views/
│   ├── LibraryView.swift       笔记库（网格、文件夹、搜索、排序、导入、备份恢复、图标入口）
│   ├── NoteCardView.swift      笔记卡片（缩略图 + 元信息）
│   ├── EditorView.swift        编辑页骨架：顶栏 / 工具栏 / 画布 / 底栏 / 缩略图栏
│   ├── NotePageView.swift      单页：背景 + 画布 + 文字层 + 图片层 + 激光层
│   ├── DrawingCanvas.swift     单页 PKCanvasView 封装 + CanvasController（撤销 / 重做）
│   ├── ContinuousInkCanvas.swift  连续滚动共享画布（单一滚动权威）
│   ├── ToolRailView.swift      左侧工具栏 + 颜色 / 粗细面板
│   ├── PageStripView.swift     右侧页面缩略图栏
│   ├── Components.swift        通用组件（玻璃面板、图标按钮、颜色点、分享面板、错误条、AppIconPicker）
│   └── AboutView.swift         关于页（版本、更新、日志、Token 设置）
├── Support/
│   ├── Theme.swift             主题色与背景
│   ├── Extensions.swift        Color↔Hex、数组安全下标、等比缩放、AppIconChoice / AppIconManager
│   └── InkProbe.swift          UI 测试用画布状态探针（-uiTestProbe）
└── Assets.xcassets             AppIcon + AppIconAI 两套图标 + 强调色 + 图标选择缩略图

QianNoteTests/                  单元测试（模型、墨迹合成、撤销、备份恢复、连续画布几何）
QianNoteUITests/                UI 黑盒测试（真实触摸注入 + InkProbe）
Scripts/                        构建与测试脚本
```

## 6. 数据存放方式

全部存在沙盒 `Documents/QianNote/` 下，纯文件、无数据库：

```
Documents/QianNote/
├── index.json                     所有笔记与文件夹的元数据
└── Notes/<笔记UUID>/
    ├── p_<页面UUID>.drawing       PKDrawing 二进制（每页一个）
    ├── t_<页面UUID>.png           页面缩略图缓存
    ├── source.pdf                 导入的 PDF 原稿（若有）
    └── img_<UUID>.png             插入的图片（若有）
```

- 元数据用 `Codable` + JSON（ISO8601 日期），改动后 0.7 秒防抖落盘
- 每页墨迹单独存文件，边写边增量保存，避免大文件重写
- 缩略图节流刷新：抬笔后约 0.15 秒补一版，连续书写期间最多每 0.9 秒一版（渲染在独立队列，底稿层带缓存）
- 备份产物是普通文件夹：`QianNote-Backup-yyyyMMdd-HHmmss/index.json` + `Notes/`，可直接在「文件」App 里查看、拷贝
- 恢复按笔记 ID 合并：本地没有就新增，本地有且备份更新才覆盖
- 工程开启了 `UIFileSharingEnabled`，可在「文件」App 里直接查看 / 拷贝这些数据

> 页面尺寸在 `Note.init`、宽松解码与 `importPDF` 三处统一按 `Note.maxPageSide = 1400` 归一化；已经存进索引的老笔记读出来也会被夹回合法区间。

## 7. 关键实现说明（方便二次开发）

### 连续滚动：单一滚动权威

`ContinuousInkCanvas` 把整本笔记放在一张共享画布上。层级是 `UIScrollView → contentView → (背景 host.view + PKCanvasView)`：

- 只有外层 `UIScrollView` 负责滚动与缩放；内层 `PKCanvasView` 的逻辑尺寸是 `pageWidth × pageHeight × pageCount`，`zoomScale` 恒为 1
- 背景层（纸张 / PDF / 图片 / 文字）和墨迹层共用同一逻辑坐标系，页面之间不会出现接缝或错位
- 进入连续模式或页面数量变化时，用 `InkComposer.merge(pageDrawings:pageHeight:)` 把整本墨迹合成一份全局 drawing；每次抬笔后与退出时用 `split(global:pageHeight:pageCount:)` 拆回每页文件，只写真正变化的页
- 跨页笔画保持整笔，按最高点归属到某一页；单页导出时跨页溢出的部分会被裁剪（取舍见「已知限制」）
- 四条必须守住的不变量：
  1. 墨迹与背景使用同一坐标系
  2. 内层画布 `zoomScale` 始终为 1
  3. 不把缩放比例回写给 SwiftUI 状态，否则会滚动频闪
  4. 写 `contentView` 的 frame / bounds 前先移除 transform，并显式同步 `scroll.contentSize`

### 单页画布：归属与落盘

- `DrawingCanvas` 把 `PKCanvasView` 包进 SwiftUI，`isScrollEnabled = false` 让页面固定；工具通过 `ToolStore.pkTool` 注入
- `makeUIView` 里必须 `canvas.delegate = coordinator`。`canvasViewDrawingDidChange` 是撤销栈、自动保存、形状识别、虚线切分的唯一入口，代理没接上时这些功能会全部静默失效
- Coordinator 记着「画布上这份墨迹属于哪一页」（`ownerPageID` + `ownerSave`），所有落盘走 `saveToOwner`；换页顺序必须是「先按旧页 flush → 再改归属 → 再绑新页的撤销栈」，否则会把上一页的笔迹写进下一页
- 书写过程中按 0.25 秒合并保存，编码与写盘在 `ioQueue` 上执行，并用代计数丢掉过期快照；抬笔时立即 flush，`dismantleUIView` 再兜底一次
- 撤销、换页、外部改色撞上「笔还没离纸」时，`applyProgrammatic` 只入队，抬笔后再应用，避免替换 `canvas.drawing` 抹掉当前笔画
- `TrackingCanvasView.layoutSubviews` 把 `contentSize` / `contentOffset` 钉在 `bounds` 上，防止 PencilKit 因墨迹越界撑大视口造成纸张与墨迹错位
- 首帧 bounds 还是 `.zero` 时，drawing 先寄存到 `pendingDrawing`，等尺寸合法再交给 PencilKit

### 撤销

- 不依赖 PencilKit 内建撤销，而是 `CanvasController` 保存 `PKDrawing` 快照栈（上限 60），撤销时整体回填并回写存储
- `CanvasControllerPool` 为每页维护独立控制器，切页时重新绑定系统 `UndoManager`，撤销不会串页
- 两指点击撤销 / 三指点击重做；识别成手势后会截断误触产生的历史，只清理点状笔迹（小于约 14pt）

### 工具状态

- `ToolStore` 是工具状态的单一来源，每种笔的颜色、粗细与橡皮模式独立持久化
- `activeTool = .hand` 不写 UserDefaults：拖动只是临时浏览状态，不应跨启动；否则下次进笔记会停在拖动工具上，笔怎么画都不出墨
- iPad 默认「手指拖动页面、Pencil 书写」，iPhone 没有 Pencil，首次进入默认打开手指书写；老用户通过一次性迁移标记落到新默认
- 点工具 = 换笔并退出拖动，长按 0.45 秒 = 展开颜色 / 粗细面板；长按后吞掉 Button 补发的 tap，避免面板刚开就被关掉

### 渲染与缩略图

- 整页渲染在独立的 `thumbnailQueue` 上执行，不和落盘共用串行队列；主线程只做缓存回填
- `PageRenderer.renderBase` 只画纸张 / PDF 页并缓存，`renderPage(baseLayer:)` 直接贴图；纸张模板、底色或页面顺序变化时整本缓存作废
- 缩略图按输出比例栅格化（`inkScale = 520 / 页宽`），不再按 1 倍画满页再缩小
- 缩略图版本号按页维护（`thumbnailVersions`），某页变新时只刷新对应单元格
- `thumbnail(noteID:pageID:)` 是异步的，磁盘读与预解码都在后台队列，避免书架一屏十几张卡片阻塞主线程

### 导入与搜索

- `DocumentImporter` 统一把 PDF / 图片 / Word / RTF / HTML / 文本转换为 PDF，再交给 `NoteStore.importPDF`
- 图片按 612×792pt 的信纸尺寸居中生成 PDF；网页 / Office 文档用离屏 `WKWebView` 渲染后 `createPDF`
- 搜索只匹配标题与文字框。手写 OCR 已移除：Vision 对中文手写识别率有限，索引成本高，收益不稳定

### 备份与恢复

- `backupLibrary` 先等 `ioQueue` 跑空，再同步写一份索引并拷贝 `Notes/`，避免备份到上一版墨迹
- `restoreLibrary` 同样先等队列跑空，按 `updatedAt` 合并；覆盖后清掉对应的墨迹 / PDF / 缩略图缓存
- 恢复是逐文件覆盖而不是「删目录再整拷」，中途失败不会把已有数据全丢掉

## 8. 测试

### 单元测试（QianNoteTests）

- `NoteTests`：模型解码、页面尺寸归一化、宽松解码
- `InkComposerTests`：整本墨迹合并 / 拆分、跨页笔画归属
- `CanvasControllerTests`：撤销 / 重做、历史截断、系统 UndoManager 桥接
- `BackupRestoreTests`：备份恢复的合并方向，本地较新的笔记不能被旧备份覆盖
- `ContinuousCanvasChaosTests`：连续画布几何不变量。同一逻辑点在画布与背景坐标中的屏幕位置误差小于 0.01pt；`zoomScale` 始终为 1；`contentSize = 逻辑尺寸 × 缩放`；SwiftUI 刷新不能移动 offset；5 个随机种子 × 300 步随机操作

### UI 测试（QianNoteUITests）

- `CanvasInteractionTests`：手指 / Pencil 书写、拖动翻页、工具切换、边界长笔画
- `ChaosRound1Tests`：拖动工具不落墨、跨页隔离、连续滚动开关、前后台切换、快速翻页
- `ChaosRound2Tests`：每页独立持久化、清空页、全部笔种、旋转
- `EditorFeatureTests`：撤销重做、清空页、插页、重命名、全屏、工具栏收起、激光笔、连续滚动书写、捏合缩放、快速换工具、末页禁用下一页
- `LibraryFeatureTests`：新建、重命名、收藏、复制、移动、删除、搜索、导入、备份恢复

测试基类 `NoteUITestCase` 用真实触摸注入，并通过 `-uiTestProbe` 暴露的 `InkProbe` 读取当前页笔画数与墨迹包围盒；少数场景仍用截图像素增量做粗粒度断言。

UI 用例建议分批跑：

```bash
SIM_ID=<模拟器 UDID> bash Scripts/run_uitests_batched.sh
SIM_ID=<模拟器 UDID> bash Scripts/run_uitests_batched.sh chaos2
```

脚本按 canvas / chaos1 / chaos2 / editor-a / editor-b / library 六批执行，批间重启模拟器。一次性串行跑全部用例时，模拟器后半段容易劣化并出现假失败；分批后结果更可信。原始日志落在 `build/uitest/`。

有两台 iPad 模拟器时，用 `Scripts/run_uitests_pair.sh` 两波并行分片（模拟器保持开机，只重装 App 与 Runner），全套 37 项约二十分钟：

```bash
bash Scripts/run_uitests_pair.sh          # 两波全部批次
WAVE=1 bash Scripts/run_uitests_pair.sh   # 第一波
WAVE=2 bash Scripts/run_uitests_pair.sh   # 第二波
```

## 9. 已知限制

- 没有独立「放大书写框」。PencilKit 不支持多个画布共享同一份 drawing，替代方案是放大后页面跟随笔尖平移
- 没有 iCloud 自动同步、协作、演示模式；跨设备请用备份 / 恢复
- 没有手写 OCR、手写转文字、公式转换；搜索只覆盖标题与文字框
- 录音与逐笔回放已在 v2.0.0 移除
- PPT 导入不支持：`WKWebView` 的 QuickLook 插件只能渲染 doc / xls / rtf，pptx 会变成下载图标；正确做法需要接 Office 转换服务
- 连续滚动下跨页笔画保持整笔，按最高点归属页面；单页导出时跨页溢出的部分会被裁剪
- 导出 PDF 时旋转过的页面回退为高倍位图，未旋转页面为矢量
- 缩略图连续书写时最多每 0.9 秒刷新一版，不是逐笔实时
- 索引是单个 `index.json`，笔记数量很大时启动会整体读入内存
- 套索改色对 PencilKit marker（荧光笔）会保留原 ink 类型，只换颜色

## 10. 改名 / 换图标

- **App 显示名**（主屏下方文字，当前 `Qian's Note`）：`Signing & Capabilities` 同页的 `Display Name`，或改 `project.pbxproj` 两处 `INFOPLIST_KEY_CFBundleDisplayName`（Debug / Release 都要改）。代码里的用户可见文案（欢迎笔记标题、导出默认名、权限提示等）也要一起改，散落在 `NoteStore.swift`、`DocumentImport.swift`、`DocumentOpenCoordinator.swift` 与 `Views/` 下的界面文案中。
- **内部标识**（均已统一为 QianNote）：`PRODUCT_BUNDLE_IDENTIFIER = com.example.qiannote`、数据目录 `Documents/QianNote/`、`QianNoteApp` / `QianNoteGlass*` 类型名。
- **主图标**：替换 `QianNote/Assets.xcassets/AppIcon.appiconset/AppIcon.png`（1024×1024，无圆角、满幅）。
- **加一套备用图标**（运行时可切换，当前已有 `AppIconAI`）：
  1. 新建 `QianNote/Assets.xcassets/<名字>.appiconset`，放入 1024×1024 满幅 png + 对应 `Contents.json`；
  2. 在 `project.pbxproj` **两处** buildSettings 加 `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES = <名字>;`；
  3. 在 `Extensions.swift` 的 `AppIconChoice`、`Components.swift` 的 `AppIconPicker` 里加对应项与缩略图。
  **不要**在 `Info.plist` 手写 `CFBundleIcons / CFBundleAlternateIcons / CFBundleIconFiles`：那样要求包里真有同名 png，否则 `setAlternateIconName` 会「成功」但系统找不到图，主屏变白底网格占位图。正确做法是由 `actool` 依据构建设置把 `CFBundleAlternateIcons` 写进产物 plist。
  验证：clean build 后 `xcrun assetutil --info <app>/Assets.car` 里要同时出现两套图标的 `Name`。
