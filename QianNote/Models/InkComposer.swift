import Foundation
import PencilKit
import CoreGraphics

/// 连续滚动模式下，所有页共用一块画布，墨迹以「整本笔记」的全局坐标存在：
/// 第 i 页的原点在 (0, i * pageHeight)，页与页之间没有任何间隙。
///
/// 这套工具负责在两个坐标系之间搬运墨迹：
/// - `merge`：把各页的 drawing 平移到全局坐标后拼成一整条
/// - `split`：把全局 drawing 按页边界切开，跨页的那一笔会在边界处被截成两段
enum InkComposer {

    // MARK: - 单笔平移

    /// 把一笔整体平移。PKDrawing 没有提供直接改坐标的接口，
    /// 只能逐点重建 PKStrokePath；ink（笔的类型/颜色/粗细）原样保留。
    static func translated(_ stroke: PKStroke, by offset: CGPoint) -> PKStroke {
        guard offset != .zero else { return stroke }

        var points: [PKStrokePoint] = []
        points.reserveCapacity(stroke.path.count)
        for point in stroke.path {
            points.append(PKStrokePoint(location: CGPoint(x: point.location.x + offset.x,
                                                          y: point.location.y + offset.y),
                                        timeOffset: point.timeOffset,
                                        size: point.size,
                                        opacity: point.opacity,
                                        force: point.force,
                                        azimuth: point.azimuth,
                                        altitude: point.altitude))
        }
        return PKStroke(ink: stroke.ink,
                        path: PKStrokePath(controlPoints: points, creationDate: stroke.path.creationDate))
    }

    // MARK: - 合并

    /// 把各页墨迹拼成一条全局 drawing。传入顺序必须与页面顺序一致。
    static func merge(pageDrawings: [PKDrawing], pageHeight: CGFloat) -> PKDrawing {
        var strokes: [PKStroke] = []
        for (index, drawing) in pageDrawings.enumerated() {
            guard !drawing.strokes.isEmpty else { continue }
            let offset = CGPoint(x: 0, y: CGFloat(index) * pageHeight)
            for stroke in drawing.strokes {
                strokes.append(translated(stroke, by: offset))
            }
        }
        return PKDrawing(strokes: strokes)
    }

    // MARK: - 切分

    /// 把全局 drawing 按页归位。
    ///
    /// **一笔不切开**：跨页的笔整条留在它起笔的那一页。
    /// 之前试过按页边界把笔切成两段，结果两段各自有端点，渲染出来中间有条缝
    ///（PencilKit 的笔尖在端点会收窄），看起来就是用户说的「断层」。
    /// 整笔归属之后墨迹永远是同一条 stroke，连续视图里绝对不会有接缝。
    ///
    /// 代价：跨页的笔在「超出页面」的那部分只属于起始页，导出单页 PDF 时会被裁掉。
    /// 这是刻意取舍 —— 连续书写的手感优先于单页导出的完整性。
    /// - Returns: pageIndex -> 该页墨迹（每页都会出现，空页值为空 drawing）
    static func split(global: PKDrawing,
                      pageHeight: CGFloat,
                      pageCount: Int) -> [Int: PKDrawing] {
        guard pageHeight > 0, pageCount > 0 else { return [:] }

        var buckets = [Int: [PKStroke]]()
        for index in 0..<pageCount { buckets[index] = [] }

        for stroke in global.strokes {
            let ys = stroke.path.map(\.location.y)
            // 用笔迹最高点决定归属：一笔从下往上写时也落在它起笔的那页
            let top = ys.min() ?? 0
            let page = pageIndex(for: top, pageHeight: pageHeight, pageCount: pageCount)
            let offset = CGPoint(x: 0, y: -CGFloat(page) * pageHeight)
            buckets[page, default: []].append(translated(stroke, by: offset))
        }

        var result = [Int: PKDrawing]()
        for (page, strokes) in buckets {
            result[page] = PKDrawing(strokes: strokes)
        }
        return result
    }

    /// 某个纵坐标落在第几页（越界时夹到首尾页）
    static func pageIndex(for y: CGFloat, pageHeight: CGFloat, pageCount: Int) -> Int {
        guard pageHeight > 0, pageCount > 0 else { return 0 }
        let raw = Int(floor(y / pageHeight))
        return min(max(raw, 0), pageCount - 1)
    }
}
