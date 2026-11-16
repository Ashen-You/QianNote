import UIKit
import PencilKit
import PDFKit

/// 把「纸张 + PDF 底稿 + 手写墨迹 + 文本框」合成为图片 / PDF。
enum PageRenderer {

    // MARK: - 纸张

    static func paperImage(size: CGSize,
                           template: PaperTemplate,
                           tint: PaperTint,
                           scale: CGFloat = 2) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            drawPaper(in: context.cgContext, size: size, template: template, tint: tint)
        }
    }

    static func drawPaper(in cg: CGContext, size: CGSize, template: PaperTemplate, tint: PaperTint) {
        cg.setFillColor(tint.uiSurface.cgColor)
        cg.fill(CGRect(origin: .zero, size: size))

        guard template != .blank else { return }

        cg.setStrokeColor(tint.uiRule.cgColor)
        cg.setLineWidth(1)

        switch template {
        case .blank:
            break

        case .ruled:
            var y = PaperLayout.topInset
            while y < size.height - 20 {
                cg.move(to: CGPoint(x: PaperLayout.horizontalInset, y: y))
                cg.addLine(to: CGPoint(x: size.width - PaperLayout.horizontalInset, y: y))
                y += PaperLayout.lineSpacing
            }
            cg.strokePath()

        case .grid:
            let spacing = PaperLayout.gridSpacing
            var x: CGFloat = 0
            while x <= size.width {
                cg.move(to: CGPoint(x: x, y: 0))
                cg.addLine(to: CGPoint(x: x, y: size.height))
                x += spacing
            }
            var y: CGFloat = 0
            while y <= size.height {
                cg.move(to: CGPoint(x: 0, y: y))
                cg.addLine(to: CGPoint(x: size.width, y: y))
                y += spacing
            }
            cg.strokePath()

        case .dotted:
            cg.setFillColor(tint.uiRule.cgColor)
            let spacing = PaperLayout.dotSpacing
            var y = spacing
            while y < size.height {
                var x = spacing
                while x < size.width {
                    cg.fillEllipse(in: CGRect(x: x - 1.1, y: y - 1.1, width: 2.2, height: 2.2))
                    x += spacing
                }
                y += spacing
            }

        case .cornell:
            let topLine = size.height * 0.18
            let bottomLine = size.height * 0.82
            let marginX = size.width * 0.26

            cg.move(to: CGPoint(x: 0, y: topLine))
            cg.addLine(to: CGPoint(x: size.width, y: topLine))
            cg.move(to: CGPoint(x: 0, y: bottomLine))
            cg.addLine(to: CGPoint(x: size.width, y: bottomLine))
            cg.move(to: CGPoint(x: marginX, y: topLine))
            cg.addLine(to: CGPoint(x: marginX, y: bottomLine))
            cg.strokePath()

            var y = topLine + PaperLayout.lineSpacing
            while y < bottomLine - 10 {
                cg.move(to: CGPoint(x: PaperLayout.horizontalInset, y: y))
                cg.addLine(to: CGPoint(x: size.width - PaperLayout.horizontalInset, y: y))
                y += PaperLayout.lineSpacing
            }
            cg.strokePath()
        }
    }

    // MARK: - 页面合成

    static func renderPage(note: Note,
                           pageIndex: Int,
                           drawing: PKDrawing,
                           pdf: PDFDocument?,
                           maxWidth: CGFloat? = nil,
                           inkScale: CGFloat = 2) -> UIImage {
        let pageSize = note.pageSize
        let outputScale: CGFloat = {
            guard let maxWidth, maxWidth > 0, maxWidth < pageSize.width else { return 1 }
            return maxWidth / pageSize.width
        }()
        let outputSize = CGSize(width: max(1, pageSize.width * outputScale),
                                height: max(1, pageSize.height * outputScale))

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: outputSize, format: format).image { context in
            let cg = context.cgContext
            cg.saveGState()
            cg.scaleBy(x: outputScale, y: outputScale)

            drawContent(note: note, pageIndex: pageIndex, pdf: pdf, in: cg, size: pageSize)

            if let ink = inkImage(drawing: drawing, size: pageSize, scale: inkScale) {
                ink.draw(in: CGRect(origin: .zero, size: pageSize))
            }

            drawText(note: note, pageIndex: pageIndex, in: cg, size: pageSize)
            cg.restoreGState()
        }
    }

    // MARK: - 背景（PDF 或纸张）

    static func drawContent(note: Note, pageIndex: Int, pdf: PDFDocument?, in cg: CGContext, size: CGSize) {
        let pageRect = CGRect(origin: .zero, size: size)

        if let pdf, pageIndex >= 0, pageIndex < pdf.pageCount, let page = pdf.page(at: pageIndex) {
            cg.setFillColor(UIColor.white.cgColor)
            cg.fill(pageRect)

            let bounds = page.bounds(for: .mediaBox)
            let rotated = page.rotation % 180 != 0
            let visibleSize = CGSize(width: rotated ? bounds.height : bounds.width,
                                     height: rotated ? bounds.width : bounds.height)
            let thumbSize = CGSize(width: max(visibleSize.width, 1) * 2,
                                   height: max(visibleSize.height, 1) * 2)
            let image = page.thumbnail(of: thumbSize, for: .mediaBox)
            image.draw(in: CGRect.aspectFit(image.size, in: pageRect))
        } else {
            drawPaper(in: cg, size: size, template: note.paperTemplate, tint: note.paperTint)
        }
    }

    // MARK: - 墨迹

    static func inkImage(drawing: PKDrawing, size: CGSize, scale: CGFloat) -> UIImage? {
        guard !drawing.strokes.isEmpty else { return nil }
        return drawing.image(from: CGRect(origin: .zero, size: size), scale: scale)
    }

    // MARK: - 文本框

    static func drawText(note: Note, pageIndex: Int, in cg: CGContext, size: CGSize) {
        guard let page = note.pages[safe: pageIndex], !page.textBoxes.isEmpty else { return }

        for box in page.textBoxes where !box.text.isEmpty {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: CGFloat(box.fontSize)),
                .foregroundColor: UIColor(hex: box.colorHex) ?? .label,
                .paragraphStyle: paragraph
            ]
            let rect = CGRect(x: box.x, y: box.y, width: box.width, height: box.height)
            (box.text as NSString).draw(with: rect,
                                        options: [.usesLineFragmentOrigin, .usesFontLeading],
                                        attributes: attributes,
                                        context: nil)
        }
    }

    // MARK: - 导出 PDF

    static func pdfData(note: Note, drawings: [PKDrawing], pdf: PDFDocument?) -> Data {
        let pageRect = CGRect(origin: .zero, size: note.pageSize)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)

        return renderer.pdfData { context in
            for (index, drawing) in drawings.enumerated() {
                context.beginPage()
                let cg = context.cgContext

                drawContent(note: note, pageIndex: index, pdf: pdf, in: cg, size: note.pageSize)

                if let ink = inkImage(drawing: drawing, size: note.pageSize, scale: 2) {
                    ink.draw(in: pageRect)
                }

                drawText(note: note, pageIndex: index, in: cg, size: note.pageSize)
            }
        }
    }
}
