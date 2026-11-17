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
- **七种笔尖**：钢笔、虚线笔、铅笔、毛笔、单线笔、蜡笔、水彩；外加荧光笔、**激光笔**
- 每种笔**独立记录颜色与粗细**（自动持久化到 UserDefaults）
- **24 色色板 + 最近使用 6 色** + 系统取色器（任意颜色）
- 橡皮可切换**整笔擦 / 像素擦**；宽度 4 档预设
- **形状识别**：停笔 0.7 秒后自动把轮廓规整成直线 / 三角形 / 矩形 / 椭圆（可撤销、可关闭）。只认高置信度的图形，带钩带弧的笔画不会被抹平
- **套索**：圈住笔迹后可以**改色、复制、删除、整块拖动**
- **激光笔**：只留一道会淡出的红线，不写进笔记，适合讲课时指点
- **撤销 / 重做**：自带快照式撤销栈（最多 60 步），顶栏按钮实时可用
- **无笔手势**：**两指点击撤销 / 三指点击重做**，不拿 Pencil、只用手指也能操作（指写模式下同样有效，落指误触的笔迹会自动清掉）
- **拖动模式（默认）**：工具栏第一位是手形按钮，进入后是**纯导航**——手指和 Apple Pencil 都只拖页面 / 翻页，谁都不写字（防止看笔记时误落笔）；点任意笔立刻回到书写，再点手形又切回拖动
- 倾斜 / 压感由 PencilKit 原生支持

### 页面与纸张
- 纸张模板：**空白 / 横线 / 方格 / 点阵 / 康奈尔**
- 纸张底色：**纯白 / 米色 / 深色**
- 右侧页面缩略图栏：点按跳转、长按菜单（复制、插入空白页、删除）
- 多页管理：插入、复制、删除、上下翻页

### 缩放与书写
- **工具面板浮层**：颜色 / 粗细面板盖在页面之上（带一层淡遮罩），不再挤占画布宽度；竖直放不下时自动变成可滚动
- **双指捏合 1×–6×**，以手指中心为锚点缩放；双指拖动平移，边界自动夹取
- **工具栏浮层 + 可收起**：工具栏和颜色面板都盖在页面之上，不再挤占画布宽度；工具栏底部箭头可收起，收起后左边缘留一个小把手、顶栏也有显隐按钮，随时叫回来
- **拖动模式**：工具栏第一位的手形一键切「书写 / 拖动」；拖动模式下单指（或 Pencil）拖页面，放大后平移，1× 时上下拖动翻页 —— 不拿笔也能翻页、挪纸
- **双击切换 2.2× / 整页**（指写模式下自动关闭，避免抢走单指落笔）
- 右下角倍率徽章，一键恢复整页；缩放后 PDF 按档位重渲染，放大不糊
- Apple Pencil 笔杆双击切换「笔 ↔ 橡皮」
- 手势总表在「⋯ → 纸张样式 → 手势」里可以直接查

### 全屏与阅读
- **全屏阅读**：顶栏一键进入，隐藏顶栏 / 底栏 / 工具栏 / 缩略图，页面铺满整屏
- 全屏内保留三条窄控件：退出、翻页、**整页 / 适应宽度**切换；左侧工具栏与颜色面板和普通模式完全共用一套（之前全屏另有一条只有七支笔的窄胶囊，进出全屏时工具排列和可用项对不上）
- PDF 底图 3× 渲染，导出 PDF 时未旋转页面走矢量绘制

### 导入与批注
- 从「文件」App 导入 **PDF / Word（doc、docx）/ RTF / HTML / TXT / 图片**
- Word 等文档在前台用 `WKWebView` 渲染后 `createPDF` 转成 PDF，自动按页拆成笔记页
- 页尺寸按文档原始比例，直接在页面上书写、擦除，导出时合并为新的 PDF

### 录音（Notability 的录音笔记）
- 顶部麦克风一键录音，支持暂停 / 继续
- 录音过程中**每一笔都打时间戳**，同时**切换页面自动打书签**
- 播放录音时跟随页面书签自动翻页，支持进度拖动、删除录音

### 文字与图片
- 文字工具：**在页面上点按即在原位置输入**（不弹窗），键盘上方有「A− / A+ / 删除 / 完成」
- 点已有文字框即可改字；框体随内容自动撑高，不再固定 80pt 截断
- 选中时右上角有红色 × 直接删；内容清空后收笔，这个框会**自动消失**（不留「点按输入文字」的空占位）
- 图片：**相册选图**插入，套索模式下拖动 / 等比缩放 / **裁剪** / 删除
- 导出 PDF / PNG 时，文字、图片与手写一起合成

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
│   ├── AudioController.swift   录音与播放（AVAudioRecorder / AVAudioPlayer + 定时器）
│   └── DocumentImport.swift    Word / RTF / HTML / 图片 → PDF 的导入转换
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
- 缩略图节流刷新：抬笔后约 0.15 秒补一版，连续书写期间最多每 0.9 秒一版（渲染在独立队列，底稿层带缓存）

> 工程开启了 `UIFileSharingEnabled`，可在「文件」App 里直接查看/拷贝这些数据。

## 7. 关键实现说明（方便二次开发）

- **画布**：`DrawingCanvas` 把 `PKCanvasView` 包进 SwiftUI，`isScrollEnabled = false` 让页面固定；工具通过 `ToolStore.pkTool` 注入。用 `toolKey` 字符串比对，避免每次刷新都重设工具导致套索选区丢失。
- **画布代理（易踩的坑）**：`makeUIView` 里必须 `canvas.delegate = coordinator`。`canvasViewDrawingDidChange` 是撤销栈、自动保存、形状识别、虚线切分、录音笔迹打点的**唯一入口**，代理没接上时这些功能会全部静默失效（表现为顶栏撤销/重做一直置灰）。
- **文字层**：`NotePageView` 里每个 `TextBox` 是页面上的绝对定位视图。点按 → 直接换成 `TextField(axis: .vertical)` 就地输入（不再弹 sheet，退格/全选/输入法候选全走系统原生），键盘上方一条 `ToolbarItemGroup(placement: .keyboard)` 管字号、删除、完成；失焦或切工具即提交。内容为空时提交会把整个框删掉，避免留下一堆「点按输入文字」的空框。`NoteStore.load()` 还会做一次 `sanitizeTextBoxes()`，清掉历史遗留的空框与负宽度框（旧版在页面右边缘点按会算成负宽度，这种框连命中区域都是空的，点不到也看不到删除按钮）。
- **撤销**：不依赖 `UndoManager`，而是 `CanvasController` 保存 `PKDrawing` 快照栈，撤销时整体回填并回写存储，行为稳定。
- **无笔手势**：两指/三指 `UITapGestureRecognizer` 挂在画布上。指写模式下两根手指落下可能先留两个点，所以第二指落下时记下「撤销栈深度 + 笔画数」，识别成手势后用 `truncateHistory` 丢掉这几步、只清理点状笔迹，再执行撤销/重做。
- **墨迹归属**：`DrawingCanvas.Coordinator` 记着「画布上这份墨迹属于哪一页」（`ownerPageID` + `ownerSave`）。落盘走 `saveToOwner`，而不是用 `parent.onChange` —— 换页时 `parent` 已经换成新页了，用它落盘会把上一页的笔迹写进下一页的文件，两页互相串墨迹（表现为「下一页的笔记跑到上一页去了」）。
- **落盘节流**：`canvasViewDrawingDidChange` 在书写过程中会连续回调，逐次 `dataRepresentation()` 会卡住主线程（笔迹写到一半就断）。现在按 0.25 秒合并写一次，**编码与写盘都在 `ioQueue` 上做**，并用「代」计数丢掉过期快照；抬笔时 `flushSave` 立即落盘，画布回收时 `dismantleUIView` 再兜一次底。
- **缩略图必须后台渲染（血泪教训）**：整页「纸张 + PDF + 墨迹」合成实测要 **1.5 秒**。之前它在 `@MainActor` 上跑，写一会儿停 1.2 秒就会冻住一次，PencilKit 收不到触摸点，笔画直接断在半路——看起来就像「笔迹被截断」。现在渲染、`pngData()` 全在**独立的 `thumbnailQueue`**（不和落盘共用串行队列，否则保存的编码会排在它前面），主线程只做缓存回填。
- **缩略图刷新要「节流」而不是「消抖」**：旧实现每次落盘都把定时器重置到 1.2 秒后 —— 一直在写就永远不出新图，抬笔后还要再等 1.2 秒 + 一次整页渲染。现在按「距上次渲染多久」决定延迟：超过 0.9 秒就 0.15 秒后立刻补一版，书写期间最多每 0.9 秒一版；渲染期间又有新墨迹时，靠「墨迹代计数」比对自动再补一版（实测连续书写时刷新间隔 0.9–1.0 秒，`base=hit` 单次渲染 23–46ms）。
- **底稿层单独缓存**：`PageRenderer.renderBase` 只画纸张 / PDF 页，`renderPage(baseLayer:)` 直接贴图。书写过程中这层是常量，缓存后省掉整页 PDF 的矢量重绘（冷渲染 990ms → 23–46ms，Debug 模拟器实测）。纸张模板、底色、页面顺序一变就整本作废。缩略图的墨迹改为按输出比例栅格化（`inkScale = 520 / 页宽`），不再「按 1 倍画满页再缩小」，白算 4 倍像素。
- **缩略图取图必须异步**：`thumbnail(noteID:pageID:)` 是 async 的，磁盘读 + 预解码都在 `thumbnailQueue` 上。旧版在 SwiftUI `.task`/body 里同步 `Data(contentsOf:)` + `UIImage(data:)`，一屏十几张卡片就是十几次主线程 IO，进编辑页和回书架时都会顿一下。

- **画布视口钉死**：`PKCanvasView` 是 `UIScrollView`，墨迹超出边界时它自己会撑大 `contentSize`，`contentOffset` 一非 0，整个墨迹层就相对纸张平移（纸张是 SwiftUI 画的、墨迹是 UIKit 画的，两边一错位就像被竖线切掉）。`TrackingCanvasView.layoutSubviews` 里把 `contentSize`/`contentOffset` 钉在 `bounds` 上。
- **书写中不改 drawing**：撤销、换页、外部改色都可能撞上「笔还没离纸」的时刻，此时替换 `canvas.drawing` 会把当前这一笔整段抹掉。`applyProgrammatic` 现在遇到 `isUsingTool` 只入队，抬笔后再应用。
- **拖动模式是纯导航**：进入后把 `canvas.drawingGestureRecognizer.isEnabled` 关掉——PencilKit 的绘制手势整个停用，Pencil 也写不出笔画；单指平移 `UIPanGestureRecognizer` 的 `allowedTouchTypes` 同时包含 `.direct` 和 `.pencil`，两种输入都能拖。位移按 `fit × zoom` 换算成屏幕点，1× 时累积超过 84pt 就翻页。**只把 `drawingPolicy` 设成 `.pencilOnly` 是不够的**：那样手指写不了、Pencil 照写，两种输入行为不一致（用户以为进了拖动模式就写不了字）。另外拖动模式下画布必须保持可交互（套索 / 文字 / 激光笔这些工具会把画布整个关掉），否则拖动手势也一起失效。
- **点按换笔、长按调色**：点工具＝换这支笔并退出拖动模式，**不弹面板**（换笔是高频动作，弹面板会挡视线）；长按 0.45 秒＝展开颜色 / 粗细面板。实现上用 `simultaneousGesture(LongPressGesture)`，并在长按松手后用标记吞掉 Button 随后补发的那次点击（否则面板刚开就被关掉）。
- **工具状态单一来源**：工具栏的「手」和书写工具是互斥选择 —— 选工具即 `fingerDrawing = true`（书写），选手形即 `fingerDrawing = false`（纯拖动）。顶栏 ⋯ 菜单里那个「手指拖动页面」开关改的是同一个值，不会出现两套状态打架。旧版默认 `fingerDrawing = true`，升级时用 `tool.defaultHandMigrated` 做一次性迁移，让老用户也能落到新的默认模式。

- **页面缩放**：页面按固定点数（默认 768×1024，导入 PDF 时取 PDF 页尺寸）绘制，用 `scaleEffect` 适配屏幕。这样墨迹坐标与纸张尺寸解耦，换设备、导出都不会变形。
- **PDF 批注**：以 PDF 页的 `thumbnail` 作为底图铺在画布下，导出时再用 `UIGraphicsPDFRenderer` 把「PDF 页 + 墨迹 + 文字」按 2 倍分辨率合成新 PDF。
- **录音同步**：录音时监听 `pageIndex` 变化写入 `AudioMarker(pageIndex,time)`；播放时监听进度，命中最近的书签就自动翻页。

## 8. 已知限制 / 可继续做的方向

- 没有独立的「放大书写框」（PencilKit 不支持多画布共享笔迹），替代方案是放大后**页面跟随笔尖自动平移**
- 没有 iCloud 同步、没有手写文字识别（OCR / 手写转文字）、没有公式转换
- 录音只保留一条（重新录音会覆盖）
- 套索的改色/删除对 PencilKit 的 marker（荧光笔）会保留原 ink 类型，只换颜色
- 导出 PDF 时旋转过的页面仍回退为高倍位图，未旋转页面为矢量

## 9. 改名 / 换图标

- App 名称：`Signing & Capabilities` 同页的 `Display Name`，或在 `project.pbxproj` 里改 `INFOPLIST_KEY_CFBundleDisplayName`
- Bundle ID：`PRODUCT_BUNDLE_IDENTIFIER`
- 图标：替换 `Slate/Assets.xcassets/AppIcon.appiconset/AppIcon.png`（1024×1024，无圆角）
