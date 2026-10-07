import QuickLookUI
import TSDKit

/// Full-size Quick Look preview (space bar in Finder) for 2D Design files.
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let document = try TSDParser.parse(url: request.fileURL)
        let mmToPt = 72.0 / 25.4
        let size = CGSize(width: document.pageSize.width * mmToPt, height: document.pageSize.height * mmToPt)

        let reply = QLPreviewReply(contextSize: size, isBitmap: false) { ctx, reply in
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.scaleBy(x: mmToPt, y: mmToPt)
            var options = Renderer.Options()
            options.minimumStrokeWidth = 0.15
            Renderer.draw(document, in: ctx, options: options)
            reply.title = request.fileURL.lastPathComponent
        }
        return reply
    }
}
