import Foundation
import PencilKit
import Combine

/// UI 测试用的画布状态探针。
///
/// 为什么需要它：UI 测试原先靠「截屏 + 数深色像素」判断有没有写上字，
/// 这条路有三个硬伤——
///   1. 慢：每次断言要抓一张 2064×2752 的全屏图再转灰度，单次 0.5~1.5s；
///   2. 脆：读数跟采样矩形强绑定，笔迹画在矩形外就是「一片空白」（多次误判的根源）；
///   3. 瞎：只知道"有/没有墨"，分不清笔迹落到了哪一页、哪一层。
///
/// 这里改成直接把 PencilKit 的真实状态（笔画数、墨迹包围盒）通过一个
/// 无障碍元素暴露出来，测试断言变成一次 a11y 读取（几十毫秒），
/// 且读数与屏幕坐标无关。
///
/// 只在带 `-uiTestProbe` 启动参数时启用；正式运行时 `update` 直接返回，
/// 不产生任何发布事件，界面上也不会出现那个元素。
final class InkProbe: ObservableObject {
    static let shared = InkProbe()

    /// 是否启用（进程启动即确定，运行期不变）
    static let enabled = ProcessInfo.processInfo.arguments.contains("-uiTestProbe")

    /// 形如 `strokes=3;len=812;w=412;h=96`
    @Published private(set) var text = "strokes=0;len=0;w=0;h=0"

    private init() {}

    /// 由画布在"墨迹落定"的时机调用（落盘 / 撤销恢复）。
    /// 必须主线程调用：PKDrawing 不是线程安全的。
    func update(_ drawing: PKDrawing) {
        guard Self.enabled else { return }
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.update(drawing) }
            return
        }
        let box = drawing.bounds
        let next = "strokes=\(drawing.strokes.count)"
            + ";len=\(Self.length(of: drawing))"
            + ";w=\(Int(box.width.rounded()))"
            + ";h=\(Int(box.height.rounded()))"
        if next != text { text = next }
    }

    /// 墨迹总长度（所有笔画的采样点连起来的折线长度，单位是画布点）。
    ///
    /// 为什么不只报笔画数：PencilKit 的橡皮会把一笔擦成两笔，笔画数不减反增。
    /// 长度是单调的——写一笔变长，擦一块变短，撤销回退到原值。
    private static func length(of drawing: PKDrawing) -> Int {
        var total: CGFloat = 0
        for stroke in drawing.strokes {
            let path = stroke.path
            guard path.count > 1 else { continue }
            var prev = path[0].location
            for i in 1..<path.count {
                let point = path[i].location
                total += hypot(point.x - prev.x, point.y - prev.y)
                prev = point
            }
        }
        return Int(total.rounded())
    }
}
