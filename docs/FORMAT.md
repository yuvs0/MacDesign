# TechSoft 2D Design V3 file format (.3vs / .tsd)

Working notes from reverse engineering files written by V3.28, including a test sheet with
one feature per shape (line types, widths, colours, every fill type, layers, arcs, a
dimension and an arrow). Nothing here is official. The structured reader
(`TSDReader.swift`) and writer (`TSDWriter.swift`) implement exactly this;
`tools/tsd_reference.py` is a Python version for experiments. All sample files round-trip
byte for byte.

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

Every object is laid out as

```
UInt16 type             omitted for "untyped" records, whose parent implies the type
header
line block
fill block
body                    depends on the type
```

### Header

```
03 00
UInt16 layer            1-based layer index (FFFF inside pattern tiles)
UInt16 number           object number; parts of a group or text share their parent's
00 x6, FF x8            the same in every file
00
CString ";"  CString ";"
```

### Line block

```
03 00
UInt16 line type        0 none, 1 solid, 2 dashed, 3 dotted, 4 dash-dot
type 1:   double width (mm, 0 = hairline), COLORREF colour
type 2+:  UInt16 0, double dash scale (1), double width, COLORREF colour
```

Which broken pattern is 2, 3 or 4 is a guess; the test sheet uses them in that order.

### Fill block

```
05 00
UInt16 fill type        0 none, 1 solid, 2 hatch, 3 gradient, 4 character pattern,
                        5 pattern from shapes
```

- **Solid**: `01 00`, COLORREF, 4 zero bytes, 4 zero bytes, `01 00 00`.
- **Hatch**: UInt16, UInt8 0, `01 00` + six doubles (an identity matrix), a line block
  (the hatch line colour and width), doubles scale (1), spacing (40, apparently tenths of
  a mm) and angle (45), two flag bytes (the first is 1 for cross-hatch), UInt16 n and n
  pairs of doubles (10, -10 in the test sheet, possibly a dash pattern).
- **Types 3 to 5** share a 199-byte block: UInt16, UInt8 1 + 4 bytes, `01 00` + matrix,
  15 bytes, six doubles (20, 20, 40, 4, 4, 2), 74 zero bytes, UInt8 + COLORREF background.
  Then:
  - **Gradient**: 6 zero bytes, `06 00`, UInt8, UInt16 n + n float32 pairs, UInt16 n +
    n float32 pairs + float32, UInt16 n + n stops (COLORREF, float32 position), 17 bytes.
    The direction is not decoded; MacDesign draws it top to bottom.
  - **Character pattern**: an untyped record (header, line block, fill block) followed by
    `06 00` and a table of characters and colours that isn't decoded, then `01 00` +
    matrix, `01 00 01 00` and 55 bytes of (flag, double) pairs (scale 2, 2; angle 160°
    in radians; offset 50, 50 in the test sheet). The reader finds the end by looking for
    that transform.
  - **Pattern from shapes**: one typed record (type `0E`) holding the tile's shapes, which
    can have line and fill blocks of their own, including gradients.

The old notes (and MacDesign builds before this change) took the solid fill block for a
"pen block" and its colour for the stroke colour. Shapes saved by those builds read back
as filled with their stroke colour.

### Bodies

| type | object | body |
|---|---|---|
| `09` | path | `03 00 01 00`, UInt32 count, then per vertex `03 00`, x, y, UInt16 flag |
| `05` | line | `01 00`, x1, y1, x2, y2 |
| `06` | circle | `01 00`, cx, cy, px, py (a point on the circumference), UInt8 |
| `07` | arc | `01 00`, centre, start point, end point, 3 bytes; the first is 1 for clockwise |
| `08` | Bézier | `01 00`, UInt16, UInt16 degree (3), degree + 1 points |
| `02` | point | x, y, `01`. Preceded by an extra `04 00` in the sample. |
| `0A` | group | `04 00 00 00 03 00`, UInt32 count, then the member records |
| `0E` | container | `04 00 00 00`, 3 bytes, `03 00`, UInt32 count, member records |
| `0C` | text | see below |
| `0D` | dimension | see below |
| `17` | arrow | `01 00`, 49 bytes (head length and width, 5 mm, for each end), then an untyped group: header, line block, fill block, `04 00 00 00 03 00`, count, lines |
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
ax, ay                  second point; (0,0) for plain text. Meaning not confirmed.
3 bytes                 00 00 00, or 01 00 01 for a dimension's label
font record             untyped: header, line block, fill block, glyph body with char 0
03 00, UInt32 count
glyph records (type 0B) one per non-space character
00 00
```

Glyph body: `03 00 00 00 00 00 00`, UInt16 char, x, y (that character's pen position),
`02 00`, 92-byte Windows `LOGFONTW` (lfHeight -32 for 5 mm text; face name UTF-16), then a
90-byte tail: `00 00`, two doubles (≈ ascent and descent in mm for horizontal text; 10 and
1 on the test sheet's letter-spaced labels), 12 zero bytes, ax, ay, 28 zero bytes, size,
-size. Glyphs carry a solid fill (the text colour).

### Dimension

```
05 00, 7 bytes
p1, p2                  the measured points
p3                      a point the dimension line passes through
6 doubles               4 (label height), 20, 2, 10, 0, 0
3 bytes, 2 doubles (1, 1), 1 byte
CString "Ø", CString "R"    diameter and radius prefixes
10 bytes
untyped text record     the label ("70")
```

MacDesign draws extension lines, the dimension line and arrowheads from p1, p2 and p3;
the arrowhead size and the meaning of the other values are guesses.

## Not yet confirmed

- How the gradient's direction, the hatch dash pairs and the pattern repeat are stored.
- The character pattern's table.
- Which arrow ends have heads (MacDesign draws both).
- Text size: the tail's two doubles vs the size field.

`3VS_test.3vs` (the test sheet, also `TSDKit/Tests/TSDKitTests/Fixtures/features.3vs`)
has one feature per shape. Small files that vary one of the above would settle them;
compare with `python3 tools/tsd_reference.py FILE`.
