# Changelog

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
