// Package chrome provides Albedo’s terminal palette and shared screen controls.
package chrome

import (
	"cmp"
	"encoding/json"
	"errors"
	"fmt"
	"hash/fnv"
	"image/color"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"

	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
)

// Styles defines the shared terminal palette. Screens compose these
// Styles and components, so the transcript, the session screen, and the
// pickers cannot drift into their own palettes.
//
// Tokens come in three kinds:
//   - ink, a brightness ramp mixed from the terminal's own colors: prose
//     keeps the terminal foreground, then Muted, Faint and Decor step down
//   - identity: You and Agent, and Busy for albedo working in tools
//   - state: Error, Warning and Success
//
// Without reported terminal colors every token falls back to a palette slot.
type Styles struct {
	// Muted is text worth reading that steps back from prose: keys,
	// metadata, section labels.
	Muted lipgloss.Style
	// Faint is text read at a glance: tool rows, timings, hints.
	Faint lipgloss.Style
	// Decor is structure seen, not read: rules, separators, markers.
	Decor lipgloss.Style
	Bold  lipgloss.Style

	You   lipgloss.Style
	Agent lipgloss.Style
	Busy  lipgloss.Style

	Error   lipgloss.Style
	Warning lipgloss.Style
	Success lipgloss.Style

	// Prompt marks where you type.
	Prompt lipgloss.Style
	// Selected is the surface under a selected row: a tint where the
	// terminal reported its colors, reverse video where it did not.
	Selected lipgloss.Style
	// Effort tiers form a cool-to-warm scale; max is violet.
	// Cursor is the text cursor and a drag selection.
	Cursor lipgloss.Style
}

var DefaultStyles = Styles{
	Muted:    lipgloss.NewStyle().Foreground(lipgloss.Color("7")),
	Faint:    lipgloss.NewStyle().Foreground(lipgloss.Color("8")),
	Decor:    lipgloss.NewStyle().Foreground(lipgloss.Color("8")),
	Bold:     lipgloss.NewStyle().Bold(true),
	You:      lipgloss.NewStyle().Foreground(lipgloss.Color("6")),
	Agent:    lipgloss.NewStyle().Foreground(lipgloss.Color("5")),
	Busy:     lipgloss.NewStyle().Foreground(lipgloss.Color("5")).Faint(true),
	Error:    lipgloss.NewStyle().Foreground(lipgloss.Color("1")),
	Warning:  lipgloss.NewStyle().Foreground(lipgloss.Color("3")),
	Success:  lipgloss.NewStyle().Foreground(lipgloss.Color("2")),
	Prompt:   lipgloss.NewStyle().Foreground(lipgloss.Color("6")),
	Selected: lipgloss.NewStyle().Reverse(true),
	Cursor:   lipgloss.NewStyle().Reverse(true),
}

func UseInk(detected Ink) {
	detected.agents = graphPalette(detected)
	CurrentInk = detected
	fg := func(hex string) lipgloss.Style { return lipgloss.NewStyle().Foreground(lipgloss.Color(hex)) }
	if detected.success != "" {
		DefaultStyles.Success = fg(detected.success)
	}
	if detected.warning != "" {
		DefaultStyles.Warning = fg(detected.warning)
	}
	if detected.failure != "" {
		DefaultStyles.Error = fg(detected.failure)
	}
	if detected.BrandFrom != "" {
		DefaultStyles.Prompt = fg(detected.BrandFrom)
	}
	DefaultStyles.Muted = fg(detected.Code)
	DefaultStyles.Faint = fg(cmp.Or(detected.hint, detected.Secondary))
	DefaultStyles.Decor = fg(detected.Decor)
	if detected.busy != "" {
		DefaultStyles.Busy = fg(detected.busy)
	}
	DefaultStyles.Selected = lipgloss.NewStyle().Background(lipgloss.Color(detected.surface))
}

func Chip(text string, emphasized bool) string {
	style, bg := DefaultStyles.Faint, CurrentInk.codeBg
	if emphasized {
		style, bg = DefaultStyles.Prompt.Bold(true), CurrentInk.surface
	}
	if bg == "" {
		return style.Render("[" + text + "]")
	}
	return style.Background(lipgloss.Color(bg)).Render(" " + text + " ")
}

func PopoverStyle() lipgloss.Style {
	style := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(DefaultStyles.Decor.GetForeground())
	if CurrentInk.bg != "" {
		bg := lipgloss.Color(CurrentInk.bg)
		return style.Background(bg).BorderBackground(bg)
	}
	return style
}

// NewTextInput is a text input in the theme: plain text and prompt whether
// focused or not, and a reverse-video cursor that holds still, so an idle
// input never wakes the program to blink.
func NewTextInput() textinput.Model {
	ti := textinput.New()
	s := ti.Styles()
	s.Focused.Prompt, s.Focused.Text = lipgloss.NewStyle(), lipgloss.NewStyle()
	s.Blurred = s.Focused
	s.Cursor = textinput.CursorStyle{Shape: tea.CursorBlock}
	ti.SetStyles(s)
	return ti
}

const (
	AnsiReset  = "\x1b[0m"
	AnsiItalic = "\x1b[3m"
	ansiGray   = "\x1b[90m"
)

// Sgr is a foreground color as an escape sequence, or fallback when the
// ramp is unknown. Bubble Tea downsamples it to the terminal's profile.
func Sgr(hex, fallback string) string { return sgrLayer(hex, fallback, false) }

func sgrLayer(hex, fallback string, background bool) string {
	if ParseHex(hex) == nil {
		return fallback
	}
	if background {
		return ansi.NewStyle().BackgroundColor(lipgloss.Color(hex)).String()
	}
	return ansi.NewStyle().ForegroundColor(lipgloss.Color(hex)).String()
}

// DecorInk is the Decor token as a raw sequence.
func DecorInk() string { return Sgr(CurrentInk.Decor, ansiGray) }

// DiffPanel supplies the base background for diff rows.
func DiffPanel() string   { return sgrLayer(CurrentInk.surface, "\x1b[48;2;37;40;50m", true) }
func DiffAdded() string   { return sgrLayer(CurrentInk.added, "\x1b[48;2;24;53;39m", true) }
func DiffRemoved() string { return sgrLayer(CurrentInk.removed, "\x1b[48;2;59;35;40m", true) }

// KeepBackground turns full resets into foreground and attribute resets, so
// a styled span inside a tinted row keeps the row's background. Lip Gloss
// spells a full reset "ESC[m"; the raw ink spells it "ESC[0m".
func KeepBackground(s string) string {
	return strings.NewReplacer(AnsiReset, "\x1b[39;22;23m", "\x1b[m", "\x1b[39;22;23m").Replace(s)
}

// gradient is the brand ramp at t in [0, 1], or nil when the terminal did
// not report the colors it is mixed from.
func gradient(t float64) color.Color {
	from, to := ParseHex(CurrentInk.BrandFrom), ParseHex(CurrentInk.BrandTo)
	if from == nil || to == nil {
		return nil
	}
	return lipgloss.Color(from.Mix(*to, min(1, max(0, t))).Hex())
}

func ParseHex(hex string) *RGB {
	var r, g, b int
	if _, err := fmt.Sscanf(hex, "#%02x%02x%02x", &r, &g, &b); err != nil {
		return nil
	}
	return &RGB{float64(r) / 255, float64(g) / 255, float64(b) / 255}
}

// GradientText sweeps the brand ramp across s. Without it s takes the agent
// color.
func GradientText(s string, bold bool) string {
	if gradient(0) == nil {
		return DefaultStyles.Agent.Bold(bold).Render(s)
	}
	return ramp(rampKey{text: s, bold: bold}, func() string {
		runes := []rune(s)
		var b strings.Builder
		st := lipgloss.NewStyle().Bold(bold)
		for i, r := range runes {
			t := float64(i) / float64(max(1, len(runes)-1))
			b.WriteString(st.Foreground(gradient(t)).Render(string(r)))
		}
		return b.String()
	})
}

// rampKey names a rendering of the brand ramp: text swept by it, or a rule
// of rule cells fading from it.
type rampKey struct {
	text string
	bold bool
	rule int
}

// ramps keeps renderings of the brand ramp. They change only with the
// detected ink, and every frame's header asks for the same few again.
var ramps struct {
	byKey map[rampKey]string
	ink   Ink
	sync.Mutex
}

func ramp(key rampKey, render func() string) string {
	ramps.Lock()
	defer ramps.Unlock()
	if ramps.byKey == nil || ramps.ink != CurrentInk || len(ramps.byKey) > 256 {
		ramps.ink, ramps.byKey = CurrentInk, map[rampKey]string{}
	}
	s, ok := ramps.byKey[key]
	if !ok {
		s = render()
		ramps.byKey[key] = s
	}
	return s
}

// BrandInk colors a mark along the brand ramp, or in the agent color.
func BrandInk(t float64) lipgloss.Style {
	if c := gradient(t); c != nil {
		return lipgloss.NewStyle().Foreground(c)
	}
	return DefaultStyles.Agent
}

func Brand(name string) string { return GradientText("✦ "+name, true) }

// TitleRule heads a screen: left, a rule that fades from the brand's end
// into Decor, then right. Without room for one rule cell it is left alone.
func TitleRule(width int, left, right string) string {
	if right != "" {
		right = " " + right
	}
	n := width - ansi.StringWidth(left) - ansi.StringWidth(right) - 1
	if n < 1 {
		return left
	}
	return left + " " + ramp(rampKey{rule: n}, func() string { return fadeRule(n) }) + right
}

// fadeRule is n rule cells fading from the brand's end into Decor.
func fadeRule(n int) string {
	var rule strings.Builder
	from, to := ParseHex(CurrentInk.BrandTo), ParseHex(CurrentInk.Decor)
	for i := range n {
		t := float64(i) / float64(n)
		if from != nil && to != nil && t < 0.35 {
			rule.WriteString(lipgloss.NewStyle().Foreground(lipgloss.Color(from.Mix(*to, t/0.35).Hex())).Render("─"))
			continue
		}
		rule.WriteString(DefaultStyles.Decor.Render("─"))
	}
	return rule.String()
}

// Located is the brand at a place: "✦ albedo on ~/path".
func Located(name, place string) string {
	if place == "" {
		return Brand(name)
	}
	return Brand(name) + DefaultStyles.Faint.Render(" on ") + DefaultStyles.Muted.Render(place)
}

// Hint is a key and what it does.
type Hint struct{ Key, Does string }

// KeyHints lists keys in Muted and what they do in Faint. A hint without a
// key is a plain note.
func KeyHints(hints ...Hint) string {
	parts := make([]string, len(hints))
	for i, h := range hints {
		switch {
		case h.Key == "":
			parts[i] = DefaultStyles.Faint.Render(h.Does)
		case h.Does == "":
			parts[i] = DefaultStyles.Prompt.Bold(true).Render(h.Key)
		default:
			parts[i] = DefaultStyles.Prompt.Bold(true).Render(h.Key) + " " + DefaultStyles.Faint.Render(h.Does)
		}
	}
	return strings.Join(parts, DefaultStyles.Decor.Render(" · "))
}

// SectionRule heads a group in a list: " ─ label count ────".
func SectionRule(label string, count, width int) string {
	head := " " + label + " "
	tail := fmt.Sprintf("%d ", count)
	rule := strings.Repeat("─", max(0, width-2-ansi.StringWidth(head+tail)))
	return DefaultStyles.Decor.Render(" ─") + DefaultStyles.Muted.Bold(true).Render(head) + DefaultStyles.Decor.Render(tail+rule)
}

// GroupHeading heads a group of sections in a list, above their rules.
func GroupHeading(label string, width int) string {
	return DefaultStyles.Bold.Render(ansi.Truncate(" "+label, width, "…"))
}

// PromptMark precedes the focused input.
const PromptMark = "› "
const PromptMarkWidth = 2

func PromptLead() string { return DefaultStyles.Prompt.Render(PromptMark) }

// SelectBar marks the selected row.
func SelectBar() string { return DefaultStyles.Agent.Render("▌") }

// SelectedLine lays the selection surface under a styled line, reopening it
// after every reset inside the line, and fills it out to width.
func SelectedLine(line string, width int) string {
	marked := DefaultStyles.Selected.Render("\x00")
	open := marked[:strings.IndexByte(marked, 0)]
	if pad := width - ansi.StringWidth(line); pad > 0 {
		line += strings.Repeat(" ", pad)
	}
	return open + strings.NewReplacer(AnsiReset, AnsiReset+open, "\x1b[m", "\x1b[m"+open).Replace(line) + AnsiReset
}

// HomePath shortens a path under your home directory to start with ~.
func HomePath(p string) string {
	home, _ := os.UserHomeDir()
	return UnderHome(p, home)
}

// PathFolds shortens a path by folding its middle into "…" one more segment
// at a time, keeping its root and its name: ~/a/b/c, ~/…/b/c, ~/…/c.
func PathFolds(p string) []string {
	sep := string(filepath.Separator)
	parts := strings.Split(p, sep)
	folds := []string{p}
	for keep := len(parts) - 2; keep >= 1; keep-- {
		folds = append(folds, strings.Join(append([]string{parts[0], "…"}, parts[len(parts)-keep:]...), sep))
	}
	return folds
}

// UnderHome shortens p under home to start with ~.
func UnderHome(p, home string) string {
	rest, ok := strings.CutPrefix(p, home)
	if home == "" || !ok || rest != "" && rest[0] != filepath.Separator {
		return p
	}
	return "~" + rest
}

// ScpRelative is a remote path after its host's colon as scp reads it:
// one under ~ relative to the home, which itself stays ~.
func ScpRelative(p string) string {
	if rest, ok := strings.CutPrefix(p, "~/"); ok {
		return rest
	}
	return p
}

// languageHues are our own colors for common languages, by linguist name.
// Each starts from linguist's hue, softened to a pastel and nudged so
// languages that often share a repository stay apart.
var languageHues = map[string]string{
	"Go":         "#6fd1c4",
	"Nix":        "#b9a6f5",
	"TypeScript": "#80aaf9",
	"Gleam":      "#f28fb8",
	"Erlang":     "#ef7a85",
	"Python":     "#f0c674",
	"Markdown":   "#b6e37a",
	"Rust":       "#f5a97f",
	"JavaScript": "#e9e48a",
	"Shell":      "#8fdc9a",
	"C":          "#a3b4c8",
	"Elixir":     "#d4a0d8",
	"Java":       "#dcb68a",
}

// languageLc is the contrast a language's color keeps with the background:
// file names are read, so about what content text gets.
const languageLc = 60

// LanguageStyle colors a language: our hue for it, else linguist's, adapted
// to the terminal. A language with neither steps back like other metadata.
func LanguageStyle(name, linguist string) lipgloss.Style {
	if CurrentInk.Base16() {
		return lipgloss.NewStyle().Foreground(lipgloss.Color(base16Nearest(cmp.Or(languageHues[name], linguist))))
	}
	c := ParseHex(cmp.Or(languageHues[name], linguist))
	if c == nil {
		return DefaultStyles.Muted
	}
	if bg := ParseHex(CurrentInk.bg); bg != nil {
		*c = legible(*c, *bg, languageLc)
	}
	return lipgloss.NewStyle().Foreground(lipgloss.Color(c.Hex()))
}

// identityHues tell things apart that have no meaning of their own to show:
// agents in the orchestrator view, hosts beside their paths.
var identityHues = []string{"#e08cf5", "#6fd1c4", "#b6e37a", "#b9a6f5", "#80aaf9", "#f5a97f"}

// HostStyle colors a host label the same way every time, legible on the
// terminal's background like a language's color.
func HostStyle(host string) lipgloss.Style {
	h := fnv.New32a()
	h.Write([]byte(host))
	if CurrentInk.Base16() {
		hues := base16Hues(CurrentInk.base16)
		return lipgloss.NewStyle().Foreground(lipgloss.Color(hues[h.Sum32()%uint32(len(hues))]))
	}
	c := ParseHex(identityHues[h.Sum32()%uint32(len(identityHues))])
	if bg := ParseHex(CurrentInk.bg); bg != nil {
		*c = legible(*c, *bg, languageLc)
	}
	return lipgloss.NewStyle().Foreground(lipgloss.Color(c.Hex()))
}

// agentPalette colors the orchestrator view. Each agent keeps one identity
// hue wherever it appears; structure and quiet text follow the terminal's
// own ink like every other screen.
type agentPalette struct {
	Hues                        []RGB
	You, Mail, Faint, Decor, Hi RGB
}

var fallbackAgentColors = graphPalette(Ink{})

func AgentColors() *agentPalette {
	if CurrentInk.agents != nil {
		return CurrentInk.agents
	}
	return fallbackAgentColors
}

func graphPalette(colors Ink) *agentPalette {
	hex := func(val, fallback string) RGB {
		if c := ParseHex(val); c != nil {
			return *c
		}
		return *ParseHex(fallback)
	}
	bg := ParseHex(colors.bg)
	readable := func(value string) RGB {
		c := *ParseHex(value)
		if bg != nil {
			return legible(c, *bg, languageLc)
		}
		return c
	}
	hues := make([]RGB, len(identityHues))
	for i, hue := range identityHues {
		hues[i] = readable(hue)
	}
	return &agentPalette{
		Hues:  hues,
		You:   readable("#7fd8e6"),
		Mail:  readable("#f0c674"),
		Faint: hex(colors.Secondary, "#6a6378"),
		Decor: hex(colors.Decor, "#3a3448"),
		Hi:    readable("#ffffff"),
	}
}

// Background is the terminal's background color, empty when unknown.
func (c Ink) Background() string { return c.bg }

// Base16 reports whether the ink came from an explicit Base16 palette.
func (c Ink) Base16() bool { return c.base16[0] != "" }

// base16Hues are a palette's identity hues, in the order identityHues sets.
func base16Hues(p [16]string) []string {
	return []string{p[14], p[12], p[8], p[10], p[11], p[13], p[9], p[15]}
}

// An explicit palette bypasses terminal queries, including unreliable multiplexer replies.
func loadBase16Theme() (bool, error) {
	path := os.Getenv("ALBEDO_THEME_FILE")
	explicit := path != ""
	if !explicit {
		dir, err := os.UserConfigDir()
		if err != nil {
			return false, nil
		}
		path = filepath.Join(dir, "albedo", "theme.json")
	}
	data, err := os.ReadFile(path)
	if !explicit && errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("read Albedo theme %s: %w", path, err)
	}
	palette, err := parseBase16Theme(data)
	if err != nil {
		return false, fmt.Errorf("Albedo theme %s: %w", path, err)
	}
	UseBase16Theme(palette)
	return true, nil
}

func parseBase16Theme(data []byte) ([16]string, error) {
	var values map[string]string
	var palette [16]string
	if err := json.Unmarshal(data, &values); err != nil {
		return palette, err
	}
	valid := regexp.MustCompile(`^#[0-9a-fA-F]{6}$`)
	for i := range palette {
		key := fmt.Sprintf("base%02X", i)
		value := values[key]
		if !valid.MatchString(value) {
			return palette, fmt.Errorf("%s must be #RRGGBB", key)
		}
		palette[i] = strings.ToLower(value)
	}
	if len(values) != len(palette) {
		return palette, fmt.Errorf("expected exactly 16 Base16 colors")
	}
	return palette, nil
}

// UseBase16Theme colors every screen from p alone. The orchestrator's palette
// takes the slots as they are rather than adapting them to the background.
func UseBase16Theme(p [16]string) {
	UseInk(Ink{
		Code: p[5], Secondary: p[4], Decor: p[3], busy: p[14], codeBg: p[1],
		surface: p[2], added: p[1], removed: p[1], BrandFrom: p[12], BrandTo: p[14],
		success: p[11], warning: p[10], failure: p[8],
		bg: p[0], Heading: p[13], Strong: p[10], InlineCode: p[11], Link: p[13], Math: p[12],
		base16: p,
	})
	hues := base16Hues(p)
	agents := &agentPalette{Hues: make([]RGB, len(hues)), You: *ParseHex(p[12]), Mail: *ParseHex(p[10]), Faint: *ParseHex(p[4]), Decor: *ParseHex(p[3]), Hi: *ParseHex(p[5])}
	for i, hue := range hues {
		agents.Hues[i] = *ParseHex(hue)
	}
	CurrentInk.agents = agents
	fg := func(c string) lipgloss.Style { return lipgloss.NewStyle().Foreground(lipgloss.Color(c)) }
	DefaultStyles.You = fg(p[12])
	DefaultStyles.Agent = fg(p[14])
}

// File labels keep their hue family without introducing colors outside the configured palette.
func base16Nearest(hex string) string {
	p := CurrentInk.base16
	c := ParseHex(hex)
	if c == nil {
		return p[5]
	}
	best, distance := p[8], math.Inf(1)
	for _, value := range p[8:] {
		slot := ParseHex(value)
		d := math.Pow(c.r-slot.r, 2) + math.Pow(c.g-slot.g, 2) + math.Pow(c.b-slot.b, 2)
		if d < distance {
			best, distance = value, d
		}
	}
	return best
}
