package terminal

import (
	"strings"
)

// A small VT100 model, written for these tests: it says what a reader sees
// after a byte stream, independently of the renderer that wrote the stream. It
// covers what Bubble Tea emits in inline mode: text with autowrap, cursor
// movement, erasing, line insertion and deletion, scrolling, the alternate
// screen and the window resizes Ghostty performs by rewrapping its buffer. SGR
// and every other private mode are ignored, since they do not move a cell.
//
// Cells are kept per column: a wide rune owns two slots, the second of which is
// a continuation. Combining marks join the slot to their left. A row only grows
// when something is written at or past its old end, so an untouched row is
// exactly as wide as what was written to it.
type suiteVTSlot struct {
	text string
	// width is 2 for a wide rune's first slot, 0 for its continuation and 1
	// otherwise.
	width int
	cont  bool
}

type suiteVTRow struct {
	slots []suiteVTSlot
}

type suiteVTCursor struct {
	row     int
	col     int
	pending bool // an autowrap is due before the next printed cell
}

type suiteVTScreen struct {
	rows []suiteVTRow
	cur  suiteVTCursor
}

// suiteVT is a terminal. offset is the buffer row shown on the top visible
// row, so content above the viewport stays available to a later scroll.
type suiteVT struct {
	width, height int
	main, alt     suiteVTScreen
	inAlt         bool
	offset        int
	savedRow      int
	savedCol      int
	// mapNL is the terminal's ONLCR translation: the program leaves the
	// terminal's line discipline alone when it reads no input, so a bare
	// newline returns the carriage as well.
	mapNL bool
}

func newSuiteVT(width, height int) *suiteVT {
	return &suiteVT{width: width, height: height, mapNL: true}
}

func (v *suiteVT) scr() *suiteVTScreen {
	if v.inAlt {
		return &v.alt
	}
	return &v.main
}

func blankSlot() suiteVTSlot { return suiteVTSlot{text: " ", width: 1} }

func (v *suiteVT) rowAt(i int) *suiteVTRow {
	s := v.scr()
	for len(s.rows) <= i {
		s.rows = append(s.rows, suiteVTRow{})
	}
	return &s.rows[i]
}

// extent is the row's width in cells without trailing blanks: a terminal
// rewrapping its screen does not carry whitespace it cannot distinguish from an
// untouched cell onto the next row.
func (r *suiteVTRow) extent() int {
	n := len(r.slots)
	for n > 0 && !r.slots[n-1].cont && (r.slots[n-1].text == " " || r.slots[n-1].text == "") {
		n--
	}
	return n
}

func (r *suiteVTRow) text() string {
	var sb strings.Builder
	for _, s := range r.slots {
		if !s.cont {
			sb.WriteString(s.text)
		}
	}
	return sb.String()
}

// put writes one cell at the cursor, wrapping first when it does not fit.
func (v *suiteVT) put(c suiteVTSlot) {
	s := v.scr()
	if s.cur.pending {
		v.newline()
		s = v.scr()
	}
	if v.width > 0 && s.cur.col+c.width > v.width && c.width > 0 {
		v.newline()
		s = v.scr()
	}
	if v.width > 0 && c.width > v.width {
		return
	}
	r := v.rowAt(s.cur.row)
	col := s.cur.col
	for len(r.slots) < col+c.width {
		r.slots = append(r.slots, blankSlot())
	}
	// Erase whatever a wide rune had put beside the target column.
	if col > 0 && r.slots[col].cont {
		r.slots[col-1] = blankSlot()
	}
	if r.slots[col].width == 2 && col+1 < len(r.slots) {
		r.slots[col+1] = blankSlot()
	}
	if c.width == 2 && col+1 < len(r.slots) && r.slots[col+1].width == 2 {
		r.slots[col+2-1] = blankSlot()
	}
	r.slots[col] = c
	if c.width == 2 {
		r.slots[col+1] = suiteVTSlot{width: 0, cont: true}
	}
	s.cur.col += max(c.width, 1)
	if v.width > 0 && s.cur.col >= v.width {
		s.cur.col = v.width
		s.cur.pending = true
	}
}

// newline moves down one row, scrolling when the cursor leaves the screen.
func (v *suiteVT) newline() {
	s := v.scr()
	s.cur.pending = false
	s.cur.row++
	v.rowAt(s.cur.row)
	v.follow()
}

// follow keeps the viewport on the cursor.
func (v *suiteVT) follow() {
	s := v.scr()
	if s.cur.row < v.offset {
		v.offset = max(0, s.cur.row)
	}
	if v.height > 0 && s.cur.row > v.offset+v.height-1 {
		v.offset = s.cur.row - v.height + 1
	}
}

func (v *suiteVT) moveTo(row, col int) {
	s := v.scr()
	s.cur.row = max(0, row)
	s.cur.col = max(0, col)
	s.cur.pending = false
	v.follow()
}

func (v *suiteVT) visible() []string {
	out := make([]string, 0, v.height)
	s := v.scr()
	for i := 0; i < v.height; i++ {
		j := v.offset + i
		if j < 0 || j >= len(s.rows) {
			out = append(out, "")
			continue
		}
		out = append(out, s.rows[j].text())
	}
	return out
}

// cursorRow is the cursor's row on the visible screen, or -1 when it is not
// visible.
func (v *suiteVT) cursorRow() int {
	s := v.scr()
	if s.cur.row < v.offset || s.cur.row >= v.offset+v.height {
		return -1
	}
	return s.cur.row - v.offset
}

// resize reflows the buffer the way a terminal that wraps rather than
// truncates does: every row is re-split at the new width, and the cursor keeps
// its place on the screen while the buffer above it scrolls.
func (v *suiteVT) resize(width, height int) {
	if width == v.width {
		v.height = height
		v.follow()
		return
	}
	for _, s := range []*suiteVTScreen{&v.main, &v.alt} {
		if len(s.rows) == 0 {
			continue
		}
		wasVisible := s == v.scr()
		var newRows []suiteVTRow
		newRowOf := make([]int, len(s.rows))
		for i := range s.rows {
			newRowOf[i] = len(newRows)
			ext := s.rows[i].extent()
			cells := s.rows[i].slots[:ext]
			if len(cells) == 0 {
				newRows = append(newRows, suiteVTRow{})
				continue
			}
			for len(cells) > 0 {
				var chunk []suiteVTSlot
				used := 0
				for len(cells) > 0 && used+max(cells[0].width, 1) <= width {
					w := max(cells[0].width, 1)
					chunk = append(chunk, cells[0])
					if cells[0].width == 2 {
						chunk = append(chunk, suiteVTSlot{width: 0, cont: true})
						cells = cells[1:]
					} else {
						cells = cells[1:]
					}
					used += w
				}
				if len(chunk) == 0 {
					// A wide rune that cannot fit the new width is dropped
					// rather than split.
					cells = cells[1:]
					continue
				}
				newRows = append(newRows, suiteVTRow{slots: chunk})
			}
		}
		if wasVisible {
			screenRow := s.cur.row - v.offset
			nrow := newRowOf[min(s.cur.row, len(s.rows)-1)]
			nrow += s.cur.col / max(width, 1)
			s.cur.row = nrow
			s.cur.col = min(s.cur.col%max(width, 1), max(width-1, 0))
			s.cur.pending = false
			v.offset = s.cur.row - screenRow
			if v.offset < 0 {
				v.offset = 0
			}
		}
		s.rows = newRows
	}
	v.width = width
	v.height = height
	v.follow()
}

// Write feeds terminal output to the model.
func (v *suiteVT) Write(p []byte) (int, error) {
	for i := 0; i < len(p); {
		c := p[i]
		switch {
		case c == 0x1b:
			n := v.escape(p[i:])
			if n <= 0 {
				n = 1
			}
			i += n
		case c == '\n':
			if v.mapNL {
				s := v.scr()
				s.cur.col = 0
				s.cur.pending = false
			}
			v.newline()
			i++
		case c == '\r':
			s := v.scr()
			s.cur.col = 0
			s.cur.pending = false
			i++
		case c == '\b':
			s := v.scr()
			if s.cur.col > 0 {
				s.cur.col--
			}
			i++
		case c == '\t':
			s := v.scr()
			s.cur.col = min((s.cur.col/8+1)*8, max(v.width-1, 0))
			i++
		case c == 0x07:
			i++
		case c < 0x20:
			i++
		default:
			r, size := decodeRune(p[i:])
			if r == 0 && size <= 1 {
				i++
				continue
			}
			v.putRune(string(r), size)
			i += size
		}
	}
	return len(p), nil
}

func decodeRune(p []byte) (rune, int) {
	rs := []rune(string(p))
	if len(rs) == 0 {
		return 0, 0
	}
	return rs[0], len(string(rs[0]))
}

// putRune writes one printable rune: a combining mark joins the slot to its
// left, a wide rune owns two slots.
func (v *suiteVT) putRune(text string, _ int) {
	w := suiteRuneWidth(text)
	if w == 0 {
		s := v.scr()
		r := v.rowAt(s.cur.row)
		col := s.cur.col
		if s.cur.pending {
			col = v.width - 1
		}
		// A combining mark joins the character to its left, which is the rune
		// a wide rune's continuation slot belongs to.
		for i := min(col, len(r.slots)) - 1; i >= 0; i-- {
			if !r.slots[i].cont {
				r.slots[i].text += text
				break
			}
		}
		return
	}
	v.put(suiteVTSlot{text: text, width: w})
}

// suiteRuneWidth is the display width these tests generate: East Asian wide
// runes take two cells, combining marks none.
func suiteRuneWidth(s string) int {
	for _, r := range s {
		switch {
		case r >= 0x0300 && r <= 0x036f:
			return 0
		case r >= 0x1100 && r <= 0x115f, r >= 0x2e80 && r <= 0xa4cf,
			r >= 0xac00 && r <= 0xd7a3, r >= 0xf900 && r <= 0xfaff,
			r >= 0xfe30 && r <= 0xfe4f, r >= 0xff00 && r <= 0xff60, r >= 0xffe0 && r <= 0xffe6:
			return 2
		}
	}
	return 1
}

// escape consumes one escape sequence and reports its length.
func (v *suiteVT) escape(p []byte) int {
	if len(p) < 2 {
		return len(p)
	}
	switch p[1] {
	case '[':
		i := 2
		priv := byte(0)
		if i < len(p) && (p[i] == '?' || p[i] == '>' || p[i] == '<' || p[i] == '=') {
			priv = p[i]
			i++
		}
		start := i
		for i < len(p) && (p[i] >= 0x30 && p[i] <= 0x3f) {
			i++
		}
		paramEnd := i
		for i < len(p) && (p[i] >= 0x20 && p[i] <= 0x2f) {
			i++
		}
		if i >= len(p) {
			return len(p)
		}
		final := p[i]
		v.csi(priv, string(p[start:paramEnd]), final)
		return i + 1
	case ']', 'P', 'X', '^', '_':
		// String sequences end at BEL or ST.
		for i := 2; i < len(p); i++ {
			if p[i] == 0x07 {
				return i + 1
			}
			if p[i] == 0x1b && i+1 < len(p) && p[i+1] == '\\' {
				return i + 2
			}
		}
		return len(p)
	case 'M':
		// Reverse index: one row up, or the screen scrolls down at the top.
		v.reverseIndex()
		return 2
	default:
		return 2
	}
}

func (v *suiteVT) reverseIndex() {
	s := v.scr()
	if s.cur.row > v.offset {
		v.moveTo(s.cur.row-1, s.cur.col)
		return
	}
	for i := 0; i < 1; i++ {
		s.rows = append(s.rows, suiteVTRow{})
		copy(s.rows[v.offset+1:], s.rows[v.offset:])
		s.rows[v.offset] = suiteVTRow{}
	}
}

func suiteParams(s string) []int {
	if s == "" {
		return nil
	}
	parts := strings.Split(s, ";")
	out := make([]int, len(parts))
	for i, part := range parts {
		n := 0
		for _, c := range part {
			if c >= '0' && c <= '9' {
				n = n*10 + int(c-'0')
			}
		}
		out[i] = n
	}
	return out
}

func suiteParam(ps []int, i, def int) int {
	if i < len(ps) && ps[i] != 0 {
		return ps[i]
	}
	return def
}

func (v *suiteVT) csi(priv byte, params string, final byte) {
	ps := suiteParams(params)
	s := v.scr()
	switch final {
	case 'A':
		v.moveTo(s.cur.row-suiteParam(ps, 0, 1), s.cur.col)
	case 'B', 'e':
		v.moveTo(s.cur.row+suiteParam(ps, 0, 1), s.cur.col)
	case 'C', 'a':
		v.moveTo(s.cur.row, s.cur.col+suiteParam(ps, 0, 1))
	case 'D':
		v.moveTo(s.cur.row, s.cur.col-suiteParam(ps, 0, 1))
	case 'E':
		v.moveTo(s.cur.row+suiteParam(ps, 0, 1), 0)
	case 'F':
		v.moveTo(s.cur.row-suiteParam(ps, 0, 1), 0)
	case 'G', '`':
		v.moveTo(s.cur.row, suiteParam(ps, 0, 1)-1)
	case 'd':
		v.moveTo(suiteParam(ps, 0, 1)-1+v.offset, s.cur.col)
	case 'H', 'f':
		v.moveTo(suiteParam(ps, 0, 1)-1+v.offset, suiteParam(ps, 1, 1)-1)
	case 'J':
		v.eraseDisplay(suiteParam(ps, 0, 0))
	case 'K':
		v.eraseLine(suiteParam(ps, 0, 0))
	case 'L':
		v.insertLines(suiteParam(ps, 0, 1))
	case 'M':
		v.deleteLines(suiteParam(ps, 0, 1))
	case 'P':
		v.deleteCells(suiteParam(ps, 0, 1))
	case 'X':
		v.eraseCells(suiteParam(ps, 0, 1))
	case 'S':
		v.scrollUp(suiteParam(ps, 0, 1))
	case 'T':
		v.scrollDown(suiteParam(ps, 0, 1))
	case 'h', 'l':
		if priv == '?' {
			v.setMode(ps, final == 'h')
		}
	case 's':
		v.savedRow, v.savedCol = s.cur.row, s.cur.col
	case 'u':
		v.moveTo(v.savedRow, v.savedCol)
	}
}

func (v *suiteVT) setMode(ps []int, on bool) {
	for _, p := range ps {
		switch p {
		case 1049, 1047, 47:
			v.setAlt(on)
		}
	}
}

func (v *suiteVT) setAlt(on bool) {
	if on == v.inAlt {
		return
	}
	if on {
		v.savedRow, v.savedCol = v.main.cur.row, v.main.cur.col
		v.inAlt = true
		v.alt = suiteVTScreen{}
		v.offset = 0
	} else {
		v.inAlt = false
		v.offset = 0
		v.main.cur.row, v.main.cur.col = v.savedRow, v.savedCol
		v.follow()
	}
}

func (v *suiteVT) eraseDisplay(mode int) {
	s := v.scr()
	blank := func(row int) {
		r := v.rowAt(row)
		r.slots = nil
	}
	switch mode {
	case 0:
		r := v.rowAt(s.cur.row)
		if s.cur.col < len(r.slots) {
			r.slots = r.slots[:s.cur.col]
		}
		for i := s.cur.row + 1; i < len(s.rows); i++ {
			blank(i)
		}
	case 1:
		for i := 0; i < s.cur.row; i++ {
			blank(i)
		}
		r := v.rowAt(s.cur.row)
		for i := 0; i <= s.cur.col && i < len(r.slots); i++ {
			r.slots[i] = blankSlot()
		}
	case 2:
		for i := 0; i < len(s.rows); i++ {
			blank(i)
		}
	}
}

func (v *suiteVT) eraseLine(mode int) {
	s := v.scr()
	r := v.rowAt(s.cur.row)
	switch mode {
	case 0:
		if s.cur.col < len(r.slots) {
			r.slots = r.slots[:s.cur.col]
		}
	case 1:
		for i := 0; i <= s.cur.col && i < len(r.slots); i++ {
			r.slots[i] = blankSlot()
		}
	case 2:
		r.slots = nil
	}
}

func (v *suiteVT) eraseCells(n int) {
	s := v.scr()
	r := v.rowAt(s.cur.row)
	for i := s.cur.col; i < s.cur.col+n && i < len(r.slots); i++ {
		r.slots[i] = blankSlot()
	}
}

func (v *suiteVT) deleteCells(n int) {
	s := v.scr()
	r := v.rowAt(s.cur.row)
	if s.cur.col >= len(r.slots) {
		return
	}
	end := min(s.cur.col+n, len(r.slots))
	r.slots = append(r.slots[:s.cur.col], r.slots[end:]...)
}

func (v *suiteVT) insertLines(n int) {
	s := v.scr()
	at := s.cur.row
	for len(s.rows) < at {
		s.rows = append(s.rows, suiteVTRow{})
	}
	for i := 0; i < n; i++ {
		s.rows = append(s.rows, suiteVTRow{})
		copy(s.rows[at+1:], s.rows[at:])
		s.rows[at] = suiteVTRow{}
	}
}

func (v *suiteVT) deleteLines(n int) {
	s := v.scr()
	at := s.cur.row
	if at >= len(s.rows) {
		return
	}
	end := min(at+n, len(s.rows))
	s.rows = append(s.rows[:at], s.rows[end:]...)
}

func (v *suiteVT) scrollUp(n int) {
	s := v.scr()
	if s.cur.row < len(s.rows) {
		end := min(s.cur.row+n, len(s.rows))
		s.rows = append(s.rows[:s.cur.row], s.rows[end:]...)
	}
}

func (v *suiteVT) scrollDown(n int) {
	s := v.scr()
	at := s.cur.row
	for i := 0; i < n; i++ {
		s.rows = append(s.rows, suiteVTRow{})
		copy(s.rows[at+1:], s.rows[at:])
		s.rows[at] = suiteVTRow{}
	}
}
