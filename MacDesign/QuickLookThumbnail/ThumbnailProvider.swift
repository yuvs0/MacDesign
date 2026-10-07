import AppKit
import QuickLookThumbnailing
import TSDKit

/// Draws a 2D Design file as its Finder icon and Quick Look thumbnail.
final class ThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let document: TSDDocument
        do {
            document = try TSDParser.parse(url: request.fileURL)
        } catch {
            handler(nil, error)
            return
        }

        let page = document.pageSize
        let maxSize = request.maximumSize
        let scale = min(maxSize.width / page.width, maxSize.height / page.height)
        let contextSize = CGSize(width: page.width * scale, height: page.height * scale)

        let reply = QLThumbnailReply(contextSize: contextSize, currentContextDrawing: { () -> Bool in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: contextSize))
            ctx.scaleBy(x: scale, y: scale)
            var options = Renderer.Options()
            // Keep hairlines visible at icon sizes.
            options.minimumStrokeWidth = 1.2 / Double(scale)
            Renderer.draw(document, in: ctx, options: options)
            return true
        })
        handler(reply, nil)
    }
}
