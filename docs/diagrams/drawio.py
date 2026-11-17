"""drawio.py — emit a draw.io-editable SVG: plain SVG shapes, plus the same diagram as an mxfile
in the root's `content` attribute (the shape draw.io's "Editable SVG" export uses, html=0 labels).
GitHub renders the SVG; draw.io opens it for editing. Each diagram is a script beside this file
that builds one `Diagram` and writes it into the folder it is given:

    python3 docs/diagrams/<name>.py docs

and scripts/diagrams_check.sh regenerates every diagram and fails when a committed one differs."""
import html

FONT = 'Helvetica, Arial, sans-serif'
LINE_H = {9: 12, 10: 13, 11: 14, 12: 16, 13: 17, 14: 18}

PAL = {
    'plain': ('#ffffff', '#666666'),
    'grey': ('#f5f5f5', '#666666'),
    'blue': ('#dae8fc', '#6c8ebf'),
    'green': ('#d5e8d4', '#82b366'),
    'red': ('#f8cecc', '#b85450'),
    'yellow': ('#fff2cc', '#d6b656'),
    'orange': ('#ffe6cc', '#d79b00'),
}


def esc(s):
    return html.escape(s, quote=True)


class Diagram:
    def __init__(self, did, name, w, h):
        self.did, self.name, self.w, self.h = did, name, w, h
        self.cells = []  # mxCell xml
        self.svg = []
        self.n = 0

    def _id(self, hint):
        self.n += 1
        return f'{hint}{self.n}'

    def _text_svg(self, lines, cx, x, top, h, fs, color, anchor, bold, valign='middle'):
        lh = LINE_H.get(fs, round(fs * 1.3))
        if valign == 'middle':
            y0 = top + h / 2 - lh * len(lines) / 2 + lh / 2
        else:
            y0 = top + 2 + lh / 2
        tx = cx if anchor == 'middle' else x
        fw = ' font-weight="bold"' if bold else ''
        for i, ln in enumerate(lines):
            y = y0 + i * lh + 0.35 * fs
            self.svg.append(f'<text x="{tx:g}" y="{y:.1f}" font-family="{FONT}" font-size="{fs}" '
                            f'text-anchor="{anchor}" fill="{color}"{fw}>{esc(ln)}</text>')

    def box(self, x, y, w, h, text, pal='plain', fs=12, bold=False, valign='middle', dashed=False,
            align='center', hint='b'):
        fill, stroke = PAL[pal]
        lines = text.split('\n') if text else []
        st = (f'rounded=1;absoluteArcSize=1;arcSize=12;html=0;whiteSpace=wrap;fillColor={fill};'
              f'strokeColor={stroke};fontSize={fs};fontColor=#000000;')
        if bold:
            st += 'fontStyle=1;'
        if valign == 'top':
            st += 'verticalAlign=top;spacingTop=2;'
        if align == 'left':
            st += 'align=left;spacingLeft=6;'
        if dashed:
            st += 'dashed=1;'
        self._vertex(hint, text, st, x, y, w, h)
        da = ' stroke-dasharray="4 3"' if dashed else ''
        self.svg.append(f'<rect x="{x:g}" y="{y:g}" width="{w:g}" height="{h:g}" rx="6" '
                        f'fill="{fill}" stroke="{stroke}"{da}/>')
        anchor = 'middle' if align == 'center' else 'start'
        self._text_svg(lines, x + w / 2, x + 6, y, h, fs, '#000000', anchor, bold, valign)

    def bar(self, x, y, w, h, pal='yellow'):
        fill, stroke = PAL[pal]
        st = f'rounded=0;html=0;fillColor={fill};strokeColor={stroke};'
        self._vertex('bar', '', st, x, y, w, h)
        self.svg.append(f'<rect x="{x:g}" y="{y:g}" width="{w:g}" height="{h:g}" fill="{fill}" '
                        f'stroke="{stroke}"/>')

    def text(self, x, y, w, h, text, fs=10, color='#555555', align='left', bold=False,
             valign='middle'):
        lines = text.split('\n')
        st = (f'text;html=0;strokeColor=none;fillColor=none;align={align};verticalAlign={valign};'
              f'fontSize={fs};fontColor={color};spacingLeft=0;spacingTop=0;')
        if bold:
            st += 'fontStyle=1;'
        self._vertex('t', text, st, x, y, w, h)
        anchor = {'left': 'start', 'center': 'middle', 'right': 'end'}[align]
        tx = {'left': x, 'center': x + w / 2, 'right': x + w}[align]
        self._text_svg(lines, tx, tx, y, h, fs, color, anchor, bold, valign)

    def _vertex(self, hint, value, style, x, y, w, h):
        cid = self._id(hint)
        self.cells.append(f'<mxCell id="{cid}" value="{esc(value).replace(chr(10), "&#xa;")}" '
                          f'style="{style}" vertex="1" parent="1"><mxGeometry x="{x:g}" y="{y:g}" '
                          f'width="{w:g}" height="{h:g}" as="geometry"/></mxCell>')

    def line(self, pts, color='#333333', arrow=True, dashed=False, width=1, both=False):
        st = (f'edgeStyle=none;html=0;rounded=0;strokeColor={color};'
              + ('endArrow=block;endFill=1;endSize=8;' if arrow else 'endArrow=none;'))
        if both:
            st += 'startArrow=block;startFill=1;startSize=8;'
        if dashed:
            st += 'dashed=1;'
        if width != 1:
            st += f'strokeWidth={width};'
        (sx, sy), (ex, ey) = pts[0], pts[-1]
        mids = ''.join(f'<mxPoint x="{px:g}" y="{py:g}"/>' for px, py in pts[1:-1])
        arr = f'<Array as="points">{mids}</Array>' if mids else ''
        self.cells.append(f'<mxCell id="{self._id("e")}" value="" style="{st}" edge="1" parent="1">'
                          f'<mxGeometry relative="1" as="geometry"><mxPoint x="{sx:g}" y="{sy:g}" '
                          f'as="sourcePoint"/><mxPoint x="{ex:g}" y="{ey:g}" as="targetPoint"/>{arr}'
                          f'</mxGeometry></mxCell>')
        draw = list(pts)
        heads = []

        def head(a, b):
            (ax, ay), (bx, by) = a, b
            dx, dy = bx - ax, by - ay
            ln = (dx * dx + dy * dy) ** 0.5
            if ln == 0:
                raise ValueError(f'a line ends in a segment of no length at {b}')
            ux, uy = dx / ln, dy / ln
            cx, cy = bx - 10 * ux, by - 10 * uy
            px, py = -uy * 4.5, ux * 4.5
            heads.append(f'<path d="M{bx:.1f},{by:.1f} L{cx + px:.1f},{cy + py:.1f} '
                         f'L{cx - px:.1f},{cy - py:.1f} Z" fill="{color}"/>')
            return (cx, cy)

        if both:
            draw[0] = head(pts[1], pts[0])
            self.svg.extend(heads)
            heads.clear()
        if arrow:
            draw[-1] = head(pts[-2], pts[-1])
        da = ' stroke-dasharray="4 4"' if dashed else ''
        sw = f' stroke-width="{width}"'
        self.svg.append('<polyline points="' + ' '.join(f'{px:.1f},{py:.1f}' for px, py in draw)
                        + f'" fill="none" stroke="{color}"{sw}{da}/>')
        self.svg.extend(heads)

    def write(self, path):
        model = (f'<mxfile host="drawio"><diagram id="{self.did}" name="{esc(self.name)}">'
                 f'<mxGraphModel dx="1000" dy="800" grid="1" gridSize="5" guides="1" tooltips="1" '
                 f'connect="1" arrows="1" fold="1" page="0" pageScale="1" background="#ffffff" '
                 f'math="0" shadow="0"><root><mxCell id="0"/><mxCell id="1" parent="0"/>'
                 + ''.join(self.cells) + '</root></mxGraphModel></diagram></mxfile>')
        out = (f'<svg xmlns="http://www.w3.org/2000/svg" version="1.1" width="{self.w}px" '
               f'height="{self.h}px" viewBox="0 0 {self.w} {self.h}" content="{esc(model)}">'
               f'<rect x="0" y="0" width="{self.w}" height="{self.h}" fill="#ffffff"/>'
               + ''.join(self.svg) + '</svg>\n')
        with open(path, 'w', encoding='utf-8', newline='\n') as f:
            f.write(out)
