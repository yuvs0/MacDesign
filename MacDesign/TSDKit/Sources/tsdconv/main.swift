import Foundation
import ImageIO
import UniformTypeIdentifiers
import TSDKit

func pngData(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return data as Data
}

let usage = """
tsdconv: convert TechSoft 2D Design V3 files (.3vs, .tsd)

Usage:
  tsdconv [--format svg|dxf|pdf|png|json|3vs|info] [-o OUTPUT_DIR] FILE_OR_FOLDER...

  --format   Output format (default: svg). "info" prints a summary only.
             "3vs" re-saves through the writer (useful for round-trip checks).
  -o         Write outputs here instead of next to each input file.

Folders are searched (not recursively) for .3vs and .tsd files.
"""

let designExtensions: Set<String> = ["3vs", "tsd"]

var format = "svg"
var outputDir: URL?
var inputs: [URL] = []

var args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty || args.contains("-h") || args.contains("--help") {
    print(usage)
    exit(args.isEmpty ? 1 : 0)
}
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--format", "-f":
        guard !args.isEmpty else { print("Missing value for \(a)"); exit(1) }
        format = args.removeFirst().lowercased()
    case "-o", "--output":
        guard !args.isEmpty else { print("Missing value for \(a)"); exit(1) }
        outputDir = URL(fileURLWithPath: args.removeFirst(), isDirectory: true)
    default:
        inputs.append(URL(fileURLWithPath: a))
    }
}

let validFormats = ["svg", "dxf", "pdf", "png", "json", "3vs", "info"]
guard validFormats.contains(format) else {
    print("Unknown format \"\(format)\". Use one of: \(validFormats.joined(separator: ", "))")
    exit(1)
}

let fm = FileManager.default
var files: [URL] = []
for url in inputs {
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
        print("Not found: \(url.path)")
        continue
    }
    if isDir.boolValue {
        let contents = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        files += contents
            .filter { designExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    } else {
        files.append(url)
    }
}

if let dir = outputDir {
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
}

func describe(_ o: DesignObject, indent: String = "  ") {
    var extra = ""
    switch o.shape {
    case .text(let t): extra = "font \(t.fontFace) \(t.fontSize)mm at (\(fmt(t.origin.x)), \(fmt(t.origin.y)))"
    case .circle(let c, let r): extra = "centre (\(fmt(c.x)), \(fmt(c.y))) r \(fmt(r))"
    case .line(let a, let b): extra = "(\(fmt(a.x)), \(fmt(a.y))) to (\(fmt(b.x)), \(fmt(b.y)))"
    case .rect(let r): extra = "\(fmt(r.width)) x \(fmt(r.height)) at (\(fmt(r.minX)), \(fmt(r.minY)))"
    case .ellipse(let c, let rx, let ry): extra = "centre (\(fmt(c.x)), \(fmt(c.y))) rx \(fmt(rx)) ry \(fmt(ry))"
    case .path(let p): extra = "\(p.segments.count) segments\(p.isClosed ? ", closed" : "")"
    default: break
    }
    let stroke = o.style.strokeColor?.hex ?? "default"
    let fill = o.style.fillColor.map { " fill \($0.hex)" } ?? ""
    print("\(indent)#\(o.fileID) \(o.shape.kindName) layer \(o.layer) stroke \(stroke)\(fill) \(extra)")
    if case .group(let kids) = o.shape { for k in kids { describe(k, indent: indent + "    ") } }
}

func fmt(_ v: Double) -> String { String(format: "%.3g", v) }

var failures = 0
for file in files {
    do {
        let doc = try TSDParser.parse(url: file)
        if format == "info" {
            let mode = doc.isReadOnly ? " (fallback reader: \(doc.fallbackReason ?? "unknown records"))" : ""
            print("\(file.lastPathComponent): \(doc.version), \(doc.pageName ?? "unknown page"), \(doc.objects.count) objects, layers: \(doc.layers.map { $0.name }.joined(separator: ", "))\(mode)")
            for o in doc.objects { describe(o) }
            continue
        }

        let data: Data
        switch format {
        case "pdf": data = Renderer.pdfData(for: doc)
        case "png":
            guard let image = Renderer.image(for: doc, dotsPerMM: 8),
                  let png = pngData(image) else { throw TSDError.cannotWrite("PNG encoding failed") }
            data = png
        case "3vs": data = try TSDWriter.data(for: doc)
        default: data = try Exporter.data(for: doc, format: ExportFormat(rawValue: format)!)
        }

        let base = file.deletingPathExtension().lastPathComponent
        let folder = outputDir ?? file.deletingLastPathComponent()
        let out = folder.appendingPathComponent(base).appendingPathExtension(format)
        try data.write(to: out)
        print("\(file.lastPathComponent) -> \(out.path)")
    } catch {
        failures += 1
        print("\(file.lastPathComponent): \(error.localizedDescription)")
    }
}

exit(failures == 0 ? 0 : 2)
