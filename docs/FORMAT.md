# TechSoft 2D Design V3 file format (.3vs / .tsd)

Working notes from reverse engineering three files written by V3.28. Nothing here is
official. The structured reader (`TSDReader.swift`) and writer (`TSDWriter.swift`)
implement exactly this; `tools/tsd_reference.py` is a Python version for experiments.
All three sample files round-trip byte for byte.

## Basics

- Windows MFC `CArchive` serialisation. Integers and floats are little-endian.
- Strings are MFC Unicode `CString`s: `FF FE FF`, a length (one byte; or `FF` + UInt16;
  or `FF FF FF` + UInt32), then that many UTF-16LE code units.
- Coordinates are `Double` in **millimetres**, origin **bottom-left** of the sheet, **y up**.
- Colours are Windows `COLORREF`: `RR GG BB 00`.

## File layout

```
prefix        header, texture JPEG, hidden template graphic, page + plotter setup
layer table   UInt32 count, then one entry per layer
middle        hatch, pen and settings tables (3240 bytes, identical in every sample)
objects       UInt32 count, then one record per top-level object
trailer       33 bytes, identical in every sample
```

The **prefix** varies in length between files (the plotter-settings area differs) but
contains nothing that refers to the objects, so it is kept verbatim when saving and a
copy from `clock.3vs` is bundled as the template for new documents. It includes a
"smiley" drawing at about `0xFC64` that is not part of the user's drawing (it appears in
every file and never shows in 2D Design); only objects after the layer table are the
drawing.

### Layer entry

```
01 00 03 00
CString name
CString name            (written twice)
UInt16 index            1-based
UInt8  flag, UInt8 flag (01 01 in every sample; probably visible / printable)
00 ×7
FF ×16
00
```

### Middle

Starts `02 00 00 01 01 00 0E 00 00 00 02 00 01 00 00 00` and ends
`19 00 09 00 00 00 03 00` immediately before the object count.

## Object records

Every record starts with the same header:

```
UInt16 type
03 00 01 00
UInt16 id               object number; members of a group or text share their parent's
00 ×6
FF ×8  00
CString ";"  CString ";"
03 00 01 00
12 bytes                all zero in the samples (MacDesign writes the layer index in the
                        first UInt16 when an object is not on the first layer; unverified)
05 00
UInt16 hasPen
[17 bytes pen block]    only when hasPen == 1
```

Pen block: `01 00`, stroke COLORREF, 4 bytes (MacDesign stores a fill COLORREF here),
4 bytes (MacDesign stores 1 here when filled), `01 00 00`. 2D Design itself only sets the
stroke colour in the samples; the fill use of the spare bytes is our own and unverified.

| type | object | body |
|---|---|---|
| `09` | path | `03 00 01 00`, UInt32 count, then per vertex `03 00`, x, y, UInt16 flag |
| `05` | line | `01 00`, x1, y1, x2, y2 |
| `06` | circle | `01 00`, cx, cy, px, py (a point on the circumference), `00` |
| `02` | point | x, y, `01`. Preceded by an extra `04 00` in the sample. |
| `0A` | group | `04 00 00 00 03 00`, UInt32 count, then the member records |
| `0C` | text | see below |
| `00` | font | sub-record of text |
| `0B` | glyph | sub-record of text |

Path vertex flags: 0 move, 1 line, 2 Bézier control point, 3 Bézier end point (preceded by
two control points). A closed shape repeats its first point. Rectangles are five vertices
starting top-left going clockwise; ellipses are a move plus four Béziers starting at the
top. Arcs and ellipses drawn in MacDesign are written as paths.

### Text

```
04 00 00 00
CString string
x, y                    baseline origin
scaleX
00 00
scaleY
ax, ay                  second point; (0,0) for plain text, (88.74, 85) on a text that
                        runs vertically in the sample. Meaning not confirmed.
00
font record (type 00)   header + glyph body with char 0 and position (0,0)
03 00, UInt32 count
glyph records (type 0B) one per non-space character
00 00
```

Glyph body: `03 00 00 00 00 00 00`, UInt16 char, x, y (that character's pen position),
`02 00`, 92-byte Windows `LOGFONTW` (lfHeight -32 for 5 mm text; face name UTF-16), then a
90-byte tail: `00 00`, two doubles (≈ ascent and descent in mm for horizontal text), 12
zero bytes, ax, ay, 28 zero bytes, size, -size.

## Not yet confirmed

- Which header bytes hold the layer. A file with a shape drawn on Layer 2 would settle it.
- What the second point of a text record means, and how text size and rotation are
  really derived (the sample's vertical text has glyph positions running down the page).
- Native arc records, if 2D Design has them (none in the samples).
- Fills and line styles as 2D Design stores them (none in the samples).
- The meaning of the repeated plotter blocks in the prefix.

Saving small test files from 2D Design (one object each: a circle, an arc, a filled shape,
a dashed line, text at 10 mm, rotated text, a shape on Layer 2) and comparing them with
`tools/tsd_reference.py` would answer most of these.
