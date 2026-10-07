# MacDesign

A cut-down Illustrator-style editor for TechSoft 2D Design V3 files (`.3vs`, `.tsd`) on
macOS. It opens the files directly, lets you draw and edit, saves back to `.3vs`, and
exports SVG, DXF, PDF and PNG for laser cutters and other software.

## Layout

| Path | What it is |
|---|---|
| `MacDesign/MacDesign.xcodeproj` | The Xcode project (macOS 27, SwiftUI with Liquid Glass) |
| `MacDesign/MacDesign/` | App sources: document, canvas, tools, inspector, layers |
| `MacDesign/TSDKit/` | Swift package: file reader/writer, geometry, rendering, exporters, `tsdconv` CLI, tests |
| `docs/FORMAT.md` | What we know about the file format |
| `tools/tsd_reference.py` | Python mirror of the parser for format experiments |
| `samples/` | Local test files (git-ignored) |

## Build and run

Open `MacDesign/MacDesign.xcodeproj` in Xcode 26 or later, choose the **MacDesign**
scheme and press Run. The app depends on the local `TSDKit` package, which Xcode
resolves automatically.

Package tests and the converter:

```bash
cd MacDesign/TSDKit
swift test
swift run tsdconv --format dxf ~/Downloads/clock.3vs        # also svg, pdf, png, json, 3vs, info
swift run tsdconv --format svg -o ~/Desktop/out ~/Downloads/  # whole folder
```

## Using the app

- **Tools** (palette on the left, or press the key): Select `V`, Rectangle `R`,
  Ellipse `E`, Line `L`, Arc `A`, Pen `P`, Text `T`. Hold Shift for squares, circles and
  45° lines. Pen: click for corners, drag for curves, click the first point to close,
  Enter or Esc to finish.
- **Select**: click, Shift-click, or drag a marquee. Drag to move, drag the handles to
  resize (Shift keeps proportions), arrow keys nudge 1 mm (Shift: 10 mm), Delete removes.
- **Inspector** (⌥⌘I): stroke and fill colours, line type, stroke width (0 is a hairline),
  position and size, layer, text string, font, size, bold and italic.
- **Layers** tab: visibility and lock per layer and per object, drag objects to reorder,
  arrows to reorder layers, double-click a layer name to rename, `+` / `−` to add or
  delete layers. The active layer receives new shapes.
- **Object** menu: group, ungroup, bring forward or send backward.
- **File > Save** writes `.3vs`. **Export** (toolbar) writes SVG, DXF, PDF or PNG.
- Pinch or ⌘-scroll to zoom, two-finger scroll to pan, ⌘0 to fit the page.

## What the file writer keeps

A file opened and saved without changes is byte-identical, and any record you don't edit
is written back exactly as it was read. Layers, line types, widths, colours and solid
fills are stored where 2D Design stores them (see `docs/FORMAT.md`).

Hatch, gradient and pattern fills, arcs, curves, dimensions and arrows are read and drawn.
MacDesign can't create the fills itself; choosing a fill colour replaces them. An edited
dimension or arrow is saved as a group of the lines and text it shows. Pattern fills are
drawn as a light cross-hatch, because the way their tile repeats isn't decoded yet.

Shapes saved by MacDesign builds before October 2026 had their stroke colour written as
a solid fill, and will open filled.

Fonts named in a file are used when installed; otherwise text is shown in the system
font and the inspector says so.

## Quick Look

The app carries Quick Look extensions, so Finder shows thumbnails of `.3vs` and `.tsd`
files and Space previews them. They register when the app is first launched. If they
don't appear:

1. Open the app once from its build location, then check **System Settings > General >
   Login Items & Extensions > Quick Look** and turn on MacDesign Preview and MacDesign
   Thumbnails.
2. If macOS asks whether the extensions may access data from other apps, allow it. A
   build signed differently from the last one triggers this, and Quick Look waits on it
   silently (Finder shows a spinner).
3. Run `qlmanage -r` and `qlmanage -r cache`, then try again.
