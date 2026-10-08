# Changelog

## Unreleased

### Tools
- Press and hold a palette button for other ways to draw with that tool, as in 2D Design.
  Rectangle: by corners, around an object, tilted (two taps for one side, then the width), or of a
  set size. Ellipse: by corners, circle or oval from the centre, circle through two or three
  points, tangent circle. Line: by ends, set length, set angle, tangent to a circle or arc.
  Methods that need a number (set size, length, angle, sides, star points) ask for it in a sheet
  when picked; the values stay editable under New Shapes in the inspector.
- Polygon tool (N) with a Star variant.
- Delete tool variant: Delete Between Intersections removes the part of a line, arc, circle or
  path between its two nearest crossings, inside groups too (`Trim` in TSDKit).
- Arc tool icon is a plain arc.

### Canvas
- Attach, beside the lock and snap controls (⌘;): a loose click lands on the nearest end point,
  corner, centre or intersection inside the cursor box. A small box shows the point caught.
- Double-tapping text edits it with any drawing tool, not only Select.

### iPad
- Long-press context menu opens beside the shape without a snapshot of the canvas.
- Undo and Redo sit first in the trailing toolbar group on both platforms. At the leading edge,
  beside the document title, iPadOS 26 dropped them after a few edits.
- Fixed a crash on iPad when a text field got focus with a hardware keyboard: the Edit menu's ⌘A
  duplicated the field's own Select All. The canvas now handles ⌘A and ⇧⌘A itself.

## 0.2.0 (8 October 2026)

### iPad
- MacDesign now runs on iPadOS 26 as well as macOS 27, from one multiplatform target. The canvas,
  tools, inspector and menus are shared; the iPad gets touch, Apple Pencil, pinch zoom, two-finger
  pan, long-press context menus and a share sheet for exports.
- Touch and Apple Pencil input modes, chosen from the toolbar. In Pencil mode the Pencil uses the
  current tool and fingers only select and move. Double-tapping the Pencil swaps between the Delete
  tool and the previous tool.

### Tools
- Delete tool (X): tap an object to remove it, or sweep across several in one undo step.
- After drawing a rectangle, ellipse, line or arc its handles work straight away, so the shape can
  be resized without switching to the Select tool.
- Direct Selection tool (A) for moving anchors and handles of paths.
- Make Path (⌘H), Explode (⌘E, one level or fully) and Fillet Corners (⌘F, arc or smooth, with a
  live preview) in the Object menu. Align and Distribute in the Object menu and toolbar.
- Undo and Redo buttons in the toolbar.

### Canvas
- Snapping with pink guides and haptic feedback. Lock modes: grid (10 mm), step (1 mm) or none;
  object and page snapping is a separate toggle. Both sit in a pill beside the zoom readout.
- Dot grid drawn the way 2D Design draws it, with spacing and major-line settings in the View menu.
- Selection shown as a highlight outline around the shape with handles set clear of it.
- Illustrator-style transform panel with a reference-point grid and a width/height lock.
- Stroke and fill toggles, Fine/Thick line widths and line patterns in the inspector.
- Fading toast messages for status.

### Files
- Corrected record layout: header, line block, fill block, body. Unedited records are written back
  byte for byte. Line types 2/3/4, hatch spacing, gradient angles, texture fills, double lines and
  text sizes decoded from 2D Design.

### Settings
- Fillet style, smoothing and default radius, in the Settings window (Mac) or sheet (iPad).

## 0.1.0 (7 October 2026)

First working version: opens, draws, edits, saves and exports TechSoft 2D Design V3 files
(`.3vs`, `.tsd`), with Quick Look thumbnails and previews on the Mac and the `tsdconv`
command-line converter.
