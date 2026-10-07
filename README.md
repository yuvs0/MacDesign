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

- **Tools** (palette on the left, or press the key): Select `V`, Direct Selection `A`,
  Rectangle `R`, Ellipse `E`, Line `L`, Arc `C`, Pen `P`, Text `T`. Hold Shift for
  squares, circles and 45° lines. Pen: click for corners, drag for curves, click the first
  point to close, Enter or Esc to finish.
- **Direct Selection**: click a shape to see its anchor points, drag an anchor to move it
  (Shift-click or marquee for several), and drag the handles of a selected anchor to
  reshape a curve. Delete removes the selected anchors. Rectangles, ellipses, circles and
  arcs become paths when you edit a point.
- **Select**: click, Shift-click, or drag a marquee. Drag to move, drag the handles to
  resize (Shift keeps proportions), arrow keys nudge 1 mm (Shift: 10 mm), Delete removes.
- **Inspector** (⌥⌘I): stroke on or off, colour, fine or thick (fine lines have no width,
  for plotters and laser cutters; thick lines have a printed width in mm), pattern; fill on
  or off and colour; position and size, layer, text string, font, height, bold and italic.
  With nothing selected the same rows set the defaults for new shapes.
- **Layers** tab: visibility and lock per layer and per object, drag objects to reorder,
  arrows to reorder layers, double-click a layer name to rename, `+` / `−` to add or
  delete layers. The active layer receives new shapes.
- **Snapping**: while you draw, move or resize, edges, centres and corners snap to other
  objects and to the page, with pink guide lines and a trackpad click when a snap engages.
  Hold ⌘ to drag without snapping. **View > Grid Lock** (⌘L) snaps everything to the
  grid, as 2D Design does by default; **Snap to Objects** (⇧⌘') and **Haptic Feedback
  When Snapping** turn the other two off.
- **Grid**: 10 mm by default, shown with **View > Show Grid** (⌘'). Spacing comes from the
  **Grid Spacing** submenu (or **Other…** for any value), with optional heavier major
  lines every few lines.
- **Align**: the align button in the toolbar, **Object > Align**, or the row in the
  inspector. One selected object aligns to the page; several align to each other. With
  three or more, distribute spaces them evenly.
- **Object** menu: group, ungroup, bring forward or send backward. **Make Path** (⌘H)
  joins the selected shapes wherever their ends touch: one contiguous run becomes a single
  path, several runs become a group of paths. **Explode…** (⌘E) asks how far to go:
  one level (a group into its members, a path into its separate runs; joined lines stay
  joined) or fully (down to lines, curves, circles and arcs).
- **File > Save** writes `.3vs`. **Export** (toolbar) writes SVG, DXF, PDF or PNG.
- Pinch or ⌘-scroll to zoom, two-finger scroll to pan, ⌘0 to fit the page.

## What the file writer keeps

A file opened and saved without changes is byte-identical, and any record you don't edit
is written back exactly as it was read. Layers, line types, widths, colours and solid
fills are stored where 2D Design stores them (see `docs/FORMAT.md`).

Hatch, gradient, texture and pattern fills, arcs, curves, dimensions and double lines are
read and drawn. MacDesign can't create the fills itself; choosing a fill colour replaces
them. An edited dimension or double line is saved as a group of the lines and text it
shows.

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
