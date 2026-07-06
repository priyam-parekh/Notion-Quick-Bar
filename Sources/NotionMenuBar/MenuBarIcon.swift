import AppKit

/// Draws the menu bar icon as a post-it note with a large centered task
/// count and a curled bottom-right corner, stacking one note per open task
/// (capped at 3 — the stack stops growing after that).
/// With zero tasks it shows the same curled-note silhouette as a dashed
/// outline with a 0.
/// Rendered as a template image so the menu bar tints it for light/dark.
@MainActor
enum MenuBarIcon {
    /// The label view re-renders on every store update; the drawing only
    /// depends on the displayed variant, so cache by it. Counts above 9 all
    /// render as "9+" with a 3-note stack, so they share one entry.
    private static var cache: [Int: NSImage] = [:]

    private static let noteSize: CGFloat = 14
    private static let cornerRadius: CGFloat = 2.5
    private static let curl: CGFloat = 5

    static func image(taskCount: Int) -> NSImage {
        let key = min(max(taskCount, 0), 10)
        if let cached = cache[key] { return cached }
        let rendered = render(taskCount: key)
        cache[key] = rendered
        return rendered
    }

    private static func render(taskCount: Int) -> NSImage {
        let size = NSSize(width: 20, height: 18)

        let image = NSImage(size: size, flipped: false) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }

            if taskCount == 0 {
                drawEmptyNote(in: rect, cg: cg)
                return true
            }

            let noteCount = min(taskCount, 2)
            let offsetStep: CGFloat = 2.0
            let topMargin: CGFloat = 1

            for layer in 0..<noteCount {
                let isFront = layer == noteCount - 1
                let inset = CGFloat(noteCount - 1 - layer) * offsetStep
                let noteRect = NSRect(
                    x: rect.minX + inset + 0.5,
                    y: rect.maxY - noteSize - inset - topMargin,
                    width: noteSize,
                    height: noteSize
                )

                let transform = NSAffineTransform()
                if !isFront {
                    let angle: CGFloat = layer % 2 == 0 ? -5 : 4
                    transform.translateX(by: noteRect.midX, yBy: noteRect.midY)
                    transform.rotate(byDegrees: angle)
                    transform.translateX(by: -noteRect.midX, yBy: -noteRect.midY)
                }

                NSGraphicsContext.current?.saveGraphicsState()
                transform.concat()

                let path = isFront
                    ? curledBodyPath(in: noteRect)
                    : NSBezierPath(roundedRect: noteRect, xRadius: cornerRadius, yRadius: cornerRadius)

                // Punch a thin gap around every sheet above the bottom one so
                // the layers read as separate pieces of paper.
                if layer > 0 {
                    cg.setBlendMode(.destinationOut)
                    let punch = path.copy() as! NSBezierPath
                    punch.lineWidth = 1.4
                    punch.lineJoinStyle = .round
                    punch.stroke()
                    punch.fill()
                    cg.setBlendMode(.normal)
                }

                if isFront {
                    NSColor.black.setFill()
                    path.fill()
                    drawFlap(in: noteRect, alpha: 0.5)
                    drawCount(taskCount, centeredIn: noteRect, punched: true, in: cg)
                } else {
                    let alpha: CGFloat = layer == noteCount - 2 ? 0.5 : 0.28
                    NSColor.black.withAlphaComponent(alpha).setFill()
                    path.fill()
                }

                NSGraphicsContext.current?.restoreGraphicsState()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Empty day: a plain dashed post-it outline with a centered 0.
    private static func drawEmptyNote(in rect: NSRect, cg: CGContext) {
        let noteRect = NSRect(
            x: rect.midX - noteSize / 2,
            y: rect.midY - noteSize / 2,
            width: noteSize,
            height: noteSize
        )

        let border = NSBezierPath(
            roundedRect: noteRect.insetBy(dx: 0.5, dy: 0.5),
            xRadius: cornerRadius, yRadius: cornerRadius
        )
        border.lineWidth = 1
        border.lineCapStyle = .round
        border.setLineDash([2.4, 2.0], count: 2, phase: 0)
        NSColor.black.withAlphaComponent(0.85).setStroke()
        border.stroke()

        drawCount(0, centeredIn: noteRect, punched: false, in: cg)
    }

    /// Note body whose bottom-right corner is scooped away by a concave
    /// curve — the classic peeling-sticker silhouette.
    private static func curledBodyPath(in noteRect: NSRect) -> NSBezierPath {
        let r = cornerRadius
        let body = NSBezierPath()
        body.move(to: NSPoint(x: noteRect.minX + r, y: noteRect.minY))
        body.line(to: NSPoint(x: noteRect.maxX - curl, y: noteRect.minY))
        body.curve(
            to: NSPoint(x: noteRect.maxX, y: noteRect.minY + curl),
            controlPoint1: NSPoint(x: noteRect.maxX - curl * 0.75, y: noteRect.minY + curl * 0.75),
            controlPoint2: NSPoint(x: noteRect.maxX - curl * 0.75, y: noteRect.minY + curl * 0.75)
        )
        body.line(to: NSPoint(x: noteRect.maxX, y: noteRect.maxY - r))
        body.appendArc(
            withCenter: NSPoint(x: noteRect.maxX - r, y: noteRect.maxY - r),
            radius: r, startAngle: 0, endAngle: 90
        )
        body.line(to: NSPoint(x: noteRect.minX + r, y: noteRect.maxY))
        body.appendArc(
            withCenter: NSPoint(x: noteRect.minX + r, y: noteRect.maxY - r),
            radius: r, startAngle: 90, endAngle: 180
        )
        body.line(to: NSPoint(x: noteRect.minX, y: noteRect.minY + r))
        body.appendArc(
            withCenter: NSPoint(x: noteRect.minX + r, y: noteRect.minY + r),
            radius: r, startAngle: 180, endAngle: 270
        )
        body.close()
        return body
    }

    /// The curled flap: a crescent between the concave scoop and a convex
    /// outer edge, fainter so it reads as the back of the paper.
    private static func drawFlap(in noteRect: NSRect, alpha: CGFloat) {
        let flap = NSBezierPath()
        flap.move(to: NSPoint(x: noteRect.maxX - curl, y: noteRect.minY))
        flap.curve(
            to: NSPoint(x: noteRect.maxX, y: noteRect.minY + curl),
            controlPoint1: NSPoint(x: noteRect.maxX - curl * 0.75, y: noteRect.minY + curl * 0.75),
            controlPoint2: NSPoint(x: noteRect.maxX - curl * 0.75, y: noteRect.minY + curl * 0.75)
        )
        flap.curve(
            to: NSPoint(x: noteRect.maxX - curl, y: noteRect.minY),
            controlPoint1: NSPoint(x: noteRect.maxX - curl * 0.1, y: noteRect.minY + curl * 0.1),
            controlPoint2: NSPoint(x: noteRect.maxX - curl * 0.1, y: noteRect.minY + curl * 0.1)
        )
        flap.close()
        NSColor.black.withAlphaComponent(alpha).setFill()
        flap.fill()
    }

    /// Draws the count large and centered on the note. Punched (cut out of
    /// the fill) on a solid note; drawn normally inside the dashed empty note.
    private static func drawCount(_ count: Int, centeredIn noteRect: NSRect, punched: Bool, in cg: CGContext) {
        let text = count > 9 ? "9+" : "\(count)"
        let font = NSFont.systemFont(ofSize: count > 9 ? 7 : 9.5, weight: .bold)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.black
        ])
        let textSize = attributed.size()
        let origin = NSPoint(
            x: noteRect.midX - textSize.width / 2,
            y: noteRect.midY - textSize.height / 2
        )

        if punched { cg.setBlendMode(.destinationOut) }
        attributed.draw(at: origin)
        if punched { cg.setBlendMode(.normal) }
    }
}
