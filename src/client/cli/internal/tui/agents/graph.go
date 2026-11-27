package agents

import (
	"albedo/cli/internal/terminalui"
	"fmt"
	"math"
	"slices"
	"strings"
	"time"

	"albedo/cli/internal/tui/chrome"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

type agentPacket struct {
	to     string
	edge   string
	path   [][2]int
	hue    chrome.RGB
	pos    float64
	blocks int
	bytes  int
}

type agentFloat struct {
	text string
	hue  chrome.RGB
	x, y int
	t    float64
}

func (m *Model) dagWidth() int {
	width, _ := terminalui.GraphColumns(m.Width)
	return width
}

func (m *Model) paneWidth() int {
	_, width := terminalui.GraphColumns(m.Width)
	return width
}

// layout places dots by depth, each depth wrapped into rows that fit the
// pane, parents before their children so a family stays together. Siblings
// go in agentRank order, and a parent's closed leaves fold into one dot.
func (m *Model) layout() {
	// The app sizes every screen, including this one before it first opens.
	if m.nodes == nil {
		return
	}
	you := m.node(agentsYou, agentsYou)
	you.x, you.y = 2, 2
	// Roots and peers sit apart under keys no agent id takes.
	const rootsKey, peersKey = "", "\x00peers"
	children := map[string][]*agentNode{}
	for id, n := range m.nodes {
		n.fold = ""
		switch {
		case id == agentsYou:
		case n.peer:
			children[peersKey] = append(children[peersKey], n)
		case n.parent == "" || m.nodes[n.parent] == nil:
			children[rootsKey] = append(children[rootsKey], n)
		default:
			children[n.parent] = append(children[n.parent], n)
		}
	}
	rankChildren(children, m.ranks())
	matches := m.find.matches(m)
	selectedFold := m.folds[m.selected]
	m.folds = map[string]*agentFold{}
	var levels [][]string
	level := ids(append(children[rootsKey], children[peersKey]...))
	for len(level) > 0 {
		levels = append(levels, level)
		var next []string
		for _, id := range level {
			if f := m.folds[id]; f != nil {
				if f.open {
					next = append(next, f.members...)
				}
				continue
			}
			shown, folded := closedLeaves(children[id], children)
			next = append(next, ids(shown)...)
			if len(folded) == 0 {
				continue
			}
			f := &agentFold{id: agentsFoldPrefix + id, parent: id, members: ids(folded)}
			m.folds[f.id] = f
			if !m.find.active() && slices.Contains(f.members, m.selected) {
				m.expanded[id] = true
			}
			f.open = m.expanded[id] || slices.ContainsFunc(f.members, func(id string) bool { return matches[id] })
			next = append(next, f.id)
		}
		level = next
	}
	width := max(agentsSlotW, m.dagWidth()-4)
	perRow := max(1, width/agentsSlotW)
	y := 5
	m.order = m.order[:0]
	for _, level := range levels {
		for start := 0; start < len(level); start += perRow {
			row := level[start:min(len(level), start+perRow)]
			used := len(row) * agentsSlotW
			x := 2 + max(0, (width-used)/2)
			for i, id := range row {
				if f := m.folds[id]; f != nil {
					f.x, f.y = x+i*agentsSlotW, y
				} else {
					n := m.nodes[id]
					n.x, n.y = x+i*agentsSlotW, y
				}
				m.order = append(m.order, id)
			}
			y += 3
		}
		y += agentsLevelGp
	}
	// A folded agent sits on its fold's dot, so mail to it lands there.
	for _, f := range m.folds {
		for _, id := range f.members {
			n := m.nodes[id]
			n.fold = f.id
			if !f.open {
				n.x, n.y = f.x, f.y
			}
		}
	}
	switch {
	case m.nodes[m.selected] != nil || m.folds[m.selected] != nil:
	case selectedFold != nil && m.nodes[selectedFold.parent] != nil:
		// The fold went (one closed agent is left, or none): stay where it was.
		m.selected = selectedFold.parent
		for _, id := range selectedFold.members {
			if m.nodes[id] != nil {
				m.selected = id
				break
			}
		}
	case len(m.order) > 0:
		m.selected = m.order[0]
	}
}

func ids(nodes []*agentNode) []string {
	out := make([]string, len(nodes))
	for i, n := range nodes {
		out[i] = n.id
	}
	return out
}

// ranks is every agent's rank; while the view holds still an agent keeps the
// rank it had, and one that joined since takes its own.
func (m *Model) ranks() map[string]agentRank {
	if !m.holding() {
		m.held = nil
	}
	ranks := make(map[string]agentRank, len(m.nodes))
	for id, n := range m.nodes {
		if r, ok := m.held[id]; ok {
			ranks[id] = r
		} else {
			ranks[id] = rankOf(n)
		}
	}
	return ranks
}

func (m *Model) holding() bool {
	return m.find.active() || time.Now().Before(m.holdUntil)
}

// hold keeps the order as it is for agentsHold after the selection moves,
// so the next key lands where the reader looked; agentsSettleMsg lets it go.
func (m *Model) hold() tea.Cmd {
	if m.held == nil || !m.holding() {
		m.held = m.ranks()
	}
	m.holdUntil = time.Now().Add(agentsHold)
	gen, until := m.Gen, m.holdUntil
	return tea.Tick(agentsHold, func(time.Time) tea.Msg { return agentsSettleMsg{Gen: gen, Until: until} })
}

// at is where the dot for id (an agent or a fold) is.
func (m *Model) at(id string) (x, y int, ok bool) {
	if f := m.folds[id]; f != nil {
		return f.x, f.y, true
	}
	if n := m.nodes[id]; n != nil {
		return n.x, n.y, true
	}
	return 0, 0, false
}

// route runs from a to b: down from a, across the row above b, into b. A
// route upward is the same route reversed.
func route(a, b *agentNode) [][2]int {
	if b.y < a.y {
		cells := route(b, a)
		slices.Reverse(cells)
		return cells
	}
	var cells [][2]int
	channel := b.y - 1
	if b.y == a.y {
		channel = a.y - 1
		cells = append(cells, [2]int{a.x, a.y - 1})
	}
	for r := a.y + 1; r <= channel; r++ {
		cells = append(cells, [2]int{a.x, r})
	}
	step := 1
	if b.x < a.x {
		step = -1
	}
	for c := a.x + step; c != b.x+step; c += step {
		cells = append(cells, [2]int{c, channel})
	}
	return cells
}

func edgeKey(a, b string) string { return a + ">" + b }

// send starts a packet from one dot to another. Its weight is the bytes the
// letter or message carried, which the daemon counted; nothing here estimates
// tokens, because no provider measured them.
func (m *Model) send(from, to string, bytes int) {
	a, b := m.nodes[from], m.nodes[to]
	if a == nil || b == nil || from == to {
		return
	}
	path := route(a, b)
	if len(path) == 0 {
		return
	}
	blocks := max(1, min(5, int(math.Round(math.Log2(float64(bytes)/800+1)))))
	var key string
	if a.parent == to {
		key = edgeKey(to, from)
	} else {
		key = edgeKey(from, to)
	}
	m.packets = append(m.packets, agentPacket{path: path, pos: -float64(blocks), blocks: blocks, hue: a.hue, to: to, bytes: bytes, edge: key})
	m.heat[key] = 1
}

// step advances one frame of animation.
func (m *Model) step() {
	now := time.Now()
	dt := math.Min(0.2, now.Sub(m.last).Seconds())
	m.last = now
	m.clock += dt
	m.noticeT = math.Max(0, m.noticeT-dt)
	live := m.packets[:0]
	for _, p := range m.packets {
		p.pos += 30 * dt
		m.heat[p.edge] = 1
		if p.pos-float64(p.blocks) >= float64(len(p.path)-1) {
			if n := m.nodes[p.to]; n != nil {
				n.flash = 1
				m.floats = append(m.floats, agentFloat{x: n.x + 2, y: n.y - 1, text: "▴" + compactBytes(p.bytes), hue: p.hue})
			}
			continue
		}
		live = append(live, p)
	}
	m.packets = live
	for key, h := range m.heat {
		if h -= dt * 0.8; h <= 0 {
			delete(m.heat, key)
		} else {
			m.heat[key] = h
		}
	}
	// an edge still carrying a packet stays hot
	for _, p := range m.packets {
		m.heat[p.edge] = 1
	}
	floats := m.floats[:0]
	for _, f := range m.floats {
		f.t += dt
		if f.t < 1.4 {
			floats = append(floats, f)
		}
	}
	m.floats = floats
	for _, n := range m.nodes {
		n.flash = math.Max(0, n.flash-dt*2.5)
		n.rate *= math.Exp(-dt * 1.5)
	}
}

// moving is whether the next frame can differ from this one: running agents
// pulse, and packets, heat, floats, flashes, and notices play out.
func (m Model) moving() bool {
	if len(m.packets) > 0 || len(m.heat) > 0 || len(m.floats) > 0 || m.noticeT > 0 {
		return true
	}
	for _, n := range m.nodes {
		if n.running || n.flash > 0 {
			return true
		}
	}
	return false
}

func compactCount(n int) string {
	if n >= 1000 {
		return fmt.Sprintf("%.1fk", float64(n)/1000)
	}
	return fmt.Sprintf("%d", n)
}

// compactBytes is a byte count with its unit: 340B, 12.3kB, 1.5MB.
func compactBytes(n int) string {
	switch {
	case n >= 1_000_000:
		return fmt.Sprintf("%.1fMB", float64(n)/1_000_000)
	case n >= 1000:
		return fmt.Sprintf("%.1fkB", float64(n)/1000)
	default:
		return fmt.Sprintf("%dB", n)
	}
}

var agentGlyphs = map[int]rune{5: '│', 10: '─', 6: '╭', 12: '╮', 3: '╰', 9: '╯', 7: '├', 13: '┤', 14: '┬', 11: '┴', 15: '┼', 1: '│', 4: '│', 2: '─', 8: '─'}

func (m *Model) drawEdges(c *agentCanvas) {
	type mark struct {
		mask   int
		heat   float64
		hue    chrome.RGB
		dotted bool
	}
	marks := map[[2]int]*mark{}
	// dir is one bit per compass direction; a cell's mask names the arms meeting in it.
	dir := func(dx, dy int) int {
		switch {
		case dy < 0:
			return 1
		case dy > 0:
			return 4
		case dx > 0:
			return 2
		default:
			return 8
		}
	}
	draw := func(from, to *agentNode, heat float64, dotted bool) {
		cells := append([][2]int{{from.x, from.y}}, route(from, to)...)
		for i := 1; i < len(cells); i++ {
			cell, prev := cells[i], cells[i-1]
			if !c.visible(cell[1]) {
				continue
			}
			mk := marks[cell]
			if mk == nil {
				mk = &mark{hue: from.hue}
				marks[cell] = mk
			}
			next := [2]int{to.x, to.y}
			if i+1 < len(cells) {
				next = cells[i+1]
			}
			mk.mask |= dir(prev[0]-cell[0], prev[1]-cell[1]) | dir(next[0]-cell[0], next[1]-cell[1])
			if heat >= mk.heat {
				mk.heat, mk.hue = heat, from.hue
			}
			mk.dotted = mk.dotted || dotted
		}
	}
	crowded := len(m.nodes) > 24
	for _, n := range m.nodes {
		parent := m.nodes[n.parent]
		if f := m.folds[n.fold]; f != nil {
			if !f.open {
				continue
			}
			// A shown closed agent hangs from its fold.
			parent = &agentNode{x: f.x, y: f.y, hue: n.hue}
		}
		if parent == nil || n.peer {
			continue
		}
		heat := m.heat[edgeKey(n.parent, n.id)]
		if crowded && heat == 0 {
			continue
		}
		draw(parent, n, heat, false)
	}
	for _, f := range m.folds {
		if parent := m.nodes[f.parent]; parent != nil {
			draw(parent, &agentNode{x: f.x, y: f.y}, m.heat[edgeKey(f.parent, f.id)], false)
		}
	}
	if root := m.nodes[m.root]; root != nil {
		draw(m.nodes[agentsYou], root, m.heat[edgeKey(agentsYou, m.root)]+m.heat[edgeKey(m.root, agentsYou)], false)
	}
	for key, heat := range m.heat {
		from, to, _ := strings.Cut(key, ">")
		a, b := m.nodes[from], m.nodes[to]
		if a == nil || b == nil || b.parent == from || (from == agentsYou && to == m.root) || (to == agentsYou && from == m.root) {
			continue
		}
		draw(a, b, heat, true)
	}
	decor := chrome.AgentColors().Decor
	for cell, mk := range marks {
		g := agentGlyphs[mk.mask]
		if g == 0 {
			g = '·'
		}
		if mk.dotted {
			switch {
			case mk.mask&5 != 0 && mk.mask&10 == 0:
				g = '┆'
			case mk.mask&10 != 0 && mk.mask&5 == 0:
				g = '┄'
			}
		}
		c.put(cell[0], cell[1], string(g), decor.Mix(mk.hue, math.Min(1, mk.heat*1.1)))
	}
}

func (m *Model) drawNodes(c *agentCanvas) {
	t, colors := m.clock, chrome.AgentColors()
	matches := m.find.matches(m)
	for _, f := range m.folds {
		glyph := "▸"
		if f.open {
			glyph = "▾"
		}
		label := fmt.Sprintf("%d closed", len(f.members))
		hue := colors.Faint
		c.put(f.x, f.y, glyph, hue)
		if f.id == m.selected {
			c.put(f.x-1, f.y, "[", hue)
			c.put(f.x+2+ansi.StringWidth(label), f.y, "]", hue)
			hue = colors.Hi
		}
		c.put(f.x+2, f.y, label, hue)
	}
	for id, n := range m.nodes {
		if f := m.folds[n.fold]; f != nil && !f.open {
			continue
		}
		glyph := chrome.Icon.AgentRunning
		var hue chrome.RGB
		switch {
		case id == agentsYou:
			glyph, hue = chrome.Icon.AgentYou, colors.You
		case n.running:
			p := 0.5 + 0.5*math.Sin(t*5+n.phase)
			if p > 0.55 {
				glyph = chrome.Icon.AgentPulse
			}
			hue = n.hue.Mix(colors.Faint, 0.2).Mix(n.hue, p)
		case n.closed:
			glyph, hue = chrome.Icon.AgentDone, n.hue.Mix(colors.Faint, 0.5)
		default:
			glyph = chrome.Icon.AgentIdle
			if n.peer {
				glyph = chrome.Icon.AgentPeer
			}
			hue = n.hue.Mix(colors.Faint, 0.3)
		}
		if n.flash > 0 {
			hue = hue.Mix(colors.Hi, n.flash*0.7)
		}
		label := n.hue.Mix(colors.Hi, 0.35)
		// A search dims the agents it does not find.
		if matches != nil && !matches[id] && id != agentsYou {
			label, hue = colors.Faint, colors.Faint
		}
		c.put(n.x, n.y, glyph, hue)
		name := ansi.Truncate(n.name, agentsSlotW-4, "…")
		if id == m.selected {
			label = colors.Hi
			c.put(n.x-1, n.y, "[", n.hue)
			c.put(n.x+2+ansi.StringWidth(name), n.y, "]", n.hue)
		}
		c.put(n.x+2, n.y, name, label)
		if id == agentsYou {
			switch {
			case m.root != "":
			case m.err != nil:
				c.put(n.x, n.y+2, "could not load agents", colors.Faint)
			default:
				c.put(n.x, n.y+2, "loading agents…", colors.Faint)
			}
			continue
		}
		// The jam: five bars riding the output rate.
		var bars strings.Builder
		level := math.Min(1, n.rate/400)
		for i := range 5 {
			v := 0.0
			if n.running {
				v = 0.15 + level*(0.5+0.35*math.Sin(t*(6+float64(i)*1.7)+n.phase*float64(i+1))) + 0.15*math.Sin(t*2.3+float64(i))
			}
			bars.WriteRune(agentsBars[max(0, min(7, int(math.Round(v*7))))])
		}
		barHue := colors.Decor
		if n.running && (matches == nil || matches[id]) {
			barHue = n.hue
		}
		c.put(n.x+2, n.y+1, bars.String(), barHue)
		if n.outputBytes > 0 {
			c.put(n.x+8, n.y+1, compactBytes(n.outputBytes), colors.Faint)
		}
	}
	for _, p := range m.packets {
		head := int(math.Floor(p.pos))
		for i := range p.blocks {
			idx := head - i
			if idx < 0 || idx >= len(p.path) {
				continue
			}
			glyph, hue := "▪", p.hue
			if i == 0 {
				glyph, hue = "■", p.hue.Mix(colors.Hi, 0.35)
			}
			c.put(p.path[idx][0], p.path[idx][1], glyph, hue)
		}
	}
	for _, f := range m.floats {
		rise := min(2, int(f.t*2.2))
		c.put(f.x, f.y-rise, f.text, f.hue.Mix(colors.Decor, math.Min(1, f.t/1.4)))
	}
}
