package tui

import (
	"albedo/cli/internal/daemon"
	"bytes"
	"fmt"
	"image"
	"maps"
	"strings"
	"sync/atomic"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/charmbracelet/x/ansi/kitty"
)

const maxToolImagePreviews = 24
const maxToolImagePixels = 16 * 1024 * 1024

type toolImagePreview struct {
	small, large *thumbnail
	width        int
	pending      bool
	failed       bool
}

type toolImageLoadedMsg struct {
	SessionID  string
	Generation int64
	Reference  string
	Preview    toolImagePreview
	transmit   string
}

// Tool IDs occupy a separate namespace from the composer's indexed IDs.
var toolImageIDs atomic.Uint32

func nextThumbnailID() int { return 256 + int(toolImageIDs.Add(1)-1)%0xffff00 }

// Image rows use the same fold action as pastes. They remain separate from
// compact tool bursts even when code and textual tool output are hidden.
// Sent user attachments use the same durable references and previews.
func (r TranscriptRenderer) renderToolImages(entry HistoryEntry, width int) []string {
	if len(entry.Images) == 0 {
		return nil
	}
	var rows []string
	expanded := r.Open[entryKey(entry)]
	for i, attachment := range entry.Images {
		preview, cached := r.ToolImages[attachment.Reference]
		thumb := preview.small
		if expanded {
			thumb = preview.large
		}
		label := fmt.Sprintf("image #%d · %d×%d", i+1, attachment.Width, attachment.Height)
		switch {
		case thumb != nil:
			label += " · " + string(attachment.MimeType)
		case preview.failed:
			label += " · preview unavailable"
		case cached && preview.pending:
			label += " · loading preview"
		default:
			label += " · " + string(attachment.MimeType)
		}
		rows = append(rows, markChrome+DefaultStyles.Faint.Render(ansi.Truncate(label, width, "…")))
		if thumb != nil {
			// Clipping columns keeps their original coordinates and image aspect.
			clipped := *thumb
			clipped.cols = min(clipped.cols, max(1, width))
			for _, row := range placeholderRows(clipped) {
				rows = append(rows, markChrome+row)
			}
		}
	}
	label := toggleClosed + "enlarge images · click to expand"
	if expanded {
		label = toggleOpen + "show less"
	}
	if !terminalGraphics().supported {
		return rows
	}
	// Keep the fold row last so existing paste anchoring also applies to images.
	rows = append(rows, r.foldRow(entryKey(entry), ansi.Truncate(label, width, "…")))
	return rows
}

// loadToolImage fetches one preview at a time, retaining only the latest 24.
// Expanded older entries take priority. Bytes never enter the text-row cache.
func (m *ChatModel) loadToolImage() tea.Cmd {
	if m.History == nil || m.client == nil || m.streamCtx == nil || m.streamCtx.Err() != nil || !terminalGraphics().supported {
		return nil
	}
	selection := m.selectToolImages()
	wanted, order := selection.wanted, selection.order
	if m.Renderer.ToolImages == nil {
		m.Renderer.ToolImages = make(map[string]toolImagePreview)
	}
	var cleanup strings.Builder
	changed := false
	for ref, preview := range m.Renderer.ToolImages {
		if _, keep := wanted[ref]; (!keep || preview.width != max(1, m.Renderer.BodyWidth-railWidth)) && !preview.pending {
			cleanup.WriteString(deleteToolPreview(preview, terminalGraphics()))
			delete(m.Renderer.ToolImages, ref)
			changed = true
		}
	}
	if changed {
		m.settled = nil
		m.burstEpoch++
		m.rebuildSettledLines()
		m.refreshViewportContent()
	}
	var fetch tea.Cmd
	busy := false
	for _, preview := range m.Renderer.ToolImages {
		busy = busy || preview.pending
	}
	if !busy {
		for _, ref := range order {
			if _, exists := m.Renderer.ToolImages[ref]; exists {
				continue
			}
			width := max(1, m.Renderer.BodyWidth-railWidth)
			m.Renderer.ToolImages[ref] = toolImagePreview{pending: true, width: width}
			client, ctx, sid, gen, attachment := m.client, m.streamCtx, m.SessionID, m.Generation, wanted[ref]
			fetch = func() tea.Msg {
				msg := toolImageLoadedMsg{SessionID: sid, Generation: gen, Reference: attachment.Reference}
				data, err := client.ReadImage(ctx, attachment)
				if err == nil {
					msg.Preview, msg.transmit = prepareToolPreview(data, terminalGraphics(), width)
				}
				msg.Preview.width = width
				msg.Preview.failed = msg.Preview.small == nil
				return msg
			}
			break
		}
	}
	if cleanup.Len() > 0 {
		return tea.Sequence(tea.Raw(cleanup.String()), fetch)
	}
	return fetch
}

func (m ChatModel) acceptToolImage(msg toolImageLoadedMsg) (ChatModel, tea.Cmd) {
	if msg.SessionID != m.SessionID || msg.Generation != m.Generation || m.streamCtx == nil || m.streamCtx.Err() != nil {
		return m, nil
	}
	if preview, exists := m.Renderer.ToolImages[msg.Reference]; !exists || !preview.pending {
		return m, nil
	}
	m.Renderer.ToolImages[msg.Reference] = msg.Preview
	m.settled = nil
	m.burstEpoch++
	m.rebuildSettledLines()
	m.refreshViewportContent()
	next := m.loadToolImage()
	// Deleted/unretained previews must never be uploaded after cleanup.
	if preview, retained := m.Renderer.ToolImages[msg.Reference]; retained && !preview.pending && msg.transmit != "" {
		return m, tea.Sequence(tea.Raw(msg.transmit), next)
	}
	return m, next
}

// DecodeConfig bounds allocation before a full decode of untrusted tool bytes.
func prepareToolPreview(data []byte, g graphics, width int) (toolImagePreview, string) {
	if !g.supported || len(data) > daemon.MaxPreviewImageBytes {
		return toolImagePreview{}, ""
	}
	config, _, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil || config.Width <= 0 || config.Height <= 0 || config.Width > maxToolImagePixels/config.Height {
		return toolImagePreview{}, ""
	}
	decoded, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return toolImagePreview{}, ""
	}
	decoded = shrink(decoded, 960)
	var seq strings.Builder
	thumbs := make([]thumbnail, 2)
	for i, area := range [][2]int{{32, 8}, {72, 22}} {
		cols, rows := toolImageCells(config.Width, config.Height, min(area[0], max(1, width)), area[1])
		thumb := thumbnail{id: nextThumbnailID(), cols: cols, rows: rows}
		options := &kitty.Options{Action: kitty.TransmitAndPut, Transmission: kitty.Direct, Format: kitty.PNG, Quiet: 2,
			ID: thumb.id, VirtualPlacement: true, Columns: cols, Rows: rows, Chunk: true}
		if g.wrapped {
			options.ChunkFormatter = ansi.TmuxPassthrough
		}
		if err := kitty.EncodeGraphics(&seq, decoded, options); err != nil {
			return toolImagePreview{}, ""
		}
		thumbs[i] = thumb
	}
	return toolImagePreview{small: &thumbs[0], large: &thumbs[1]}, seq.String()
}

func toolImageCells(width, height, cols, rows int) (int, int) {
	if width <= 0 || height <= 0 {
		return 1, 1
	}
	fittedRows := max(1, (cols*height+width)/(2*width))
	if fittedRows <= rows {
		return cols, fittedRows
	}
	return max(1, min(cols, (2*rows*width+height/2)/height)), rows
}

func deleteToolPreview(preview toolImagePreview, g graphics) string {
	var seq strings.Builder
	for _, thumb := range []*thumbnail{preview.small, preview.large} {
		if thumb == nil {
			continue
		}
		delete := fmt.Sprintf("\x1b_Ga=d,d=I,i=%d,q=2;\x1b\\", thumb.id)
		if g.wrapped {
			delete = ansi.TmuxPassthrough(delete)
		}
		seq.WriteString(delete)
	}
	return seq.String()
}

// Selection is independent of preview completion and width. Keep it until
// history or fold state changes, including replacement and bounded eviction.
type toolImageSelection struct {
	history  *BoundedHistory
	revision uint64
	open     map[string]bool
	wanted   map[string]daemon.ImageMetadata
	order    []string
}

func (m *ChatModel) selectToolImages() *toolImageSelection {
	if cached := m.toolImageSelection; cached != nil && cached.history == m.History && cached.revision == m.History.revision && maps.Equal(cached.open, m.Renderer.Open) {
		return cached
	}
	wanted := make(map[string]daemon.ImageMetadata)
	var order []string
	entries := m.History.Entries()
	add := func(entry HistoryEntry) {
		if entry.Kind != EntryTool && entry.Kind != EntryUser {
			return
		}
		for _, attachment := range entry.Images {
			ref := attachment.Reference
			if ref == "" || len(wanted) >= maxToolImagePreviews {
				continue
			}
			if _, exists := wanted[ref]; exists {
				continue
			}
			wanted[ref] = attachment
			order = append(order, ref)
		}
	}
	for i := len(entries) - 1; i >= 0 && len(wanted) < maxToolImagePreviews; i-- {
		if len(entries[i].Images) > 0 && m.Renderer.Open[entryKey(entries[i])] {
			add(entries[i])
		}
	}
	for i := len(entries) - 1; i >= 0 && len(wanted) < maxToolImagePreviews; i-- {
		add(entries[i])
	}

	m.toolImageSelection = &toolImageSelection{history: m.History, revision: m.History.revision, open: maps.Clone(m.Renderer.Open), wanted: wanted, order: order}
	return m.toolImageSelection
}
