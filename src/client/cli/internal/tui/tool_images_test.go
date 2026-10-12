package tui

import (
	"albedo/cli/internal/daemon"
	"bytes"
	"encoding/binary"
	"fmt"
	"hash/crc32"
	"image"
	"image/png"
	"net"
	"net/http"
	"net/http/httptest"
	"reflect"
	"slices"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/charmbracelet/x/ansi/kitty"
)

func toolPreviewPNG(t *testing.T) []byte {
	t.Helper()
	var out bytes.Buffer
	if err := png.Encode(&out, image.NewRGBA(image.Rect(0, 0, 120, 80))); err != nil {
		t.Fatal(err)
	}
	return out.Bytes()
}

func mockToolGraphics(t *testing.T, supported bool) {
	t.Helper()
	saved := terminalGraphics
	terminalGraphics = func() graphics { return graphics{supported: supported} }
	t.Cleanup(func() { terminalGraphics = saved })
}

func TestToolImagesEncodeSafeDistinctPlaceholdersAndTmux(t *testing.T) {
	data := toolPreviewPNG(t)
	for _, wrapped := range []bool{false, true} {
		preview, seq := prepareToolPreview(data, graphics{supported: true, wrapped: wrapped}, 60)
		if preview.small == nil || preview.large == nil || preview.small.id == preview.large.id || seq == "" {
			t.Fatal("no distinct small and enlarged previews")
		}
		if preview.small.cols > 32 || preview.small.rows > 8 || preview.large.cols > 60 || preview.large.rows > 22 {
			t.Fatal("preview exceeds layout bounds")
		}
		rows := placeholderRows(*preview.small)
		if !strings.Contains(rows[0], "\x1b[38;2;") || !strings.ContainsRune(rows[0], kitty.Placeholder) || ansi.StringWidth(rows[0]) != preview.small.cols {
			t.Fatalf("incorrect placeholder row %q", rows[0])
		}
		if wrapped != strings.Contains(seq, "\x1bPtmux;") {
			t.Fatal("wrong passthrough")
		}
		deleted := deleteToolPreview(preview, graphics{supported: true, wrapped: wrapped})
		if !strings.Contains(deleted, fmt.Sprintf("d=I,i=%d", preview.small.id)) || !strings.Contains(deleted, fmt.Sprintf("d=I,i=%d", preview.large.id)) {
			t.Fatal("does not free both owned images")
		}
	}
	if preview, seq := prepareToolPreview(data, graphics{}, 60); preview.small != nil || seq != "" {
		t.Fatal("unsupported terminal received graphics")
	}
	if preview, seq := prepareToolPreview([]byte("invalid image"), graphics{supported: true}, 60); preview.small != nil || seq != "" {
		t.Fatal("invalid image received graphics")
	}
	// A valid header with a huge pixel area must fail before full decoding.
	huge := bytes.Clone(data)
	binary.BigEndian.PutUint32(huge[16:20], 100000)
	binary.BigEndian.PutUint32(huge[29:33], crc32.ChecksumIEEE(huge[12:29]))
	if preview, seq := prepareToolPreview(huge, graphics{supported: true}, 60); preview.small != nil || seq != "" {
		t.Fatal("huge pixel area accepted")
	}
	ids := map[int]bool{}
	for range 300 {
		id := nextThumbnailID()
		if ids[id] {
			t.Fatal("image IDs wrap after 240 uploads")
		}
		ids[id] = true
	}
}

func TestToolImagesInlineFoldWidthAndCopy(t *testing.T) {
	mockToolGraphics(t, true)
	preview, _ := prepareToolPreview(toolPreviewPNG(t), graphics{supported: true}, 72)
	entry := HistoryEntry{Kind: EntryTool, ID: "42", ToolName: "python", Timestamp: 42, ToolResult: "attached image",
		Images: []daemon.ImageMetadata{{Reference: "/sessions/s/history/42/image-0", Width: 120, Height: 80, MimeType: daemon.ImagePNG}}}
	for _, flags := range []DisplayFlags{{}, {Tools: true}} {
		m := newTestChatModel(t, &daemon.Session{ID: "s"})
		m.SetSize(90, 40)
		m.Flags = flags
		m.Renderer.ToolImages = map[string]toolImagePreview{entry.Images[0].Reference: preview}
		m.appendSettledEntry(entry)
		m.appendSettledEntry(HistoryEntry{Kind: EntryAssistant, Text: "I see the image.", Timestamp: 43})
		m.refreshViewportContent()
		if Compact(entry, flags) {
			t.Fatal("image hidden in tool burst")
		}
		row := rowWith(t, m.frameLines, "click to expand")
		before := len(m.frameLines)
		m.actAt(row)
		if !m.Renderer.Open[entryKey(entry)] || len(m.frameLines) <= before {
			t.Fatal("click did not enlarge inline image")
		}
		row = rowWith(t, m.frameLines, "show less")
		m.actAt(row)
		if m.Renderer.Open[entryKey(entry)] || len(m.frameLines) != before {
			t.Fatal("click did not restore compact preview")
		}
		copied := SelectedText(m.frameLines, Selection{Anchor: Point{Row: 0, Col: 0}, Head: Point{Row: len(m.frameLines) - 1, Col: 90}, Gutter: railWidth})
		if strings.ContainsRune(copied, kitty.Placeholder) || strings.Contains(copied, "click to expand") {
			t.Fatalf("graphics leaked into text copy: %s", copied)
		}
		m.SetSize(20, 18)
		for _, row := range m.frameLines {
			if ansi.StringWidth(row) > m.Renderer.BodyWidth {
				t.Fatalf("narrow row overflows: %d > %d", ansi.StringWidth(row), m.Renderer.BodyWidth)
			}
		}
		shot(t, "tool-images-inline", m.View())
	}
}

func TestToolImagesUnsupportedTerminalShowsMetadataWithoutFetch(t *testing.T) {
	mockToolGraphics(t, false)
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(80, 30)
	m.appendSettledEntry(HistoryEntry{Kind: EntryTool, ToolName: "python", Images: []daemon.ImageMetadata{{Width: 120, Height: 80, MimeType: daemon.ImageWEBP, Reference: "/sessions/s/history/42/image-0"}}})
	m.refreshViewportContent()
	if m.loadToolImage() != nil || !strings.Contains(ansi.Strip(m.View()), "120×80") || strings.ContainsRune(m.View(), kitty.Placeholder) {
		t.Fatal("unsupported terminal did not stay text-only")
	}
}

func TestToolImagesFetchSeriallyCacheBoundReplayAndStaleResults(t *testing.T) {
	mockToolGraphics(t, true)
	data := toolPreviewPNG(t)
	reads := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		reads++
		if r.Header.Get("Authorization") != "Bearer token" {
			t.Error("unauthenticated image")
		}
		_, _ = w.Write(data)
	}))
	t.Cleanup(server.Close)
	client := daemon.NewChatClient(daemon.NewConnection(daemon.ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port, Token: "token"}, nil), "s")
	m := NewChatModel(&daemon.Session{ID: "s"}, client)
	t.Cleanup(m.Close)
	m.SetSize(90, 40)
	for i := 0; i < 30; i++ {
		m.appendSettledEntry(HistoryEntry{Kind: EntryTool, ID: fmt.Sprint(i), Timestamp: int64(i + 1), ToolName: "python", Images: []daemon.ImageMetadata{{Reference: fmt.Sprintf("/sessions/s/history/%d/image-0", i), Bytes: len(data), Width: 120, Height: 80, MimeType: daemon.ImagePNG}}})
	}
	queue := []tea.Cmd{m.loadToolImage()}
	steps := 0
	for len(queue) > 0 {
		steps++
		if steps > 200 {
			t.Fatal("preview command loop did not settle")
		}
		cmd := queue[0]
		queue = queue[1:]
		if cmd == nil {
			continue
		}
		msg := cmd()
		if loaded, ok := msg.(toolImageLoadedMsg); ok {
			if m.loadToolImage() != nil {
				t.Fatal("parallel image fetches")
			}
			var next tea.Cmd
			m, next = m.acceptToolImage(loaded)
			queue = append(queue, next)
			continue
		}
		commands := reflect.ValueOf(msg)
		if commands.Kind() == reflect.Slice {
			for i := 0; i < commands.Len(); i++ {
				queue = append(queue, commands.Index(i).Interface().(tea.Cmd))
			}
		}
	}
	if len(m.Renderer.ToolImages) != maxToolImagePreviews || reads != maxToolImagePreviews {
		t.Fatalf("unbounded cache or fetches: %d %d", len(m.Renderer.ToolImages), reads)
	}
	for ref, state := range m.Renderer.ToolImages {
		if state.small == nil {
			t.Fatal("missing thumbnail")
		}
		if strings.HasSuffix(ref, "/0/image-0") {
			t.Fatal("old image displaced latest previews")
		}
	}
	if m.loadToolImage() != nil {
		t.Fatal("replay re-fetched cached previews")
	}
	if next, cmd := m.acceptToolImage(toolImageLoadedMsg{SessionID: "other", Generation: m.Generation, Reference: "x"}); cmd != nil || len(next.Renderer.ToolImages) != 24 {
		t.Fatal("stale image changed session")
	}
	// A resized cache frees old placements and starts one bounded replacement.
	m.SetSize(35, 25)
	if m.loadToolImage() == nil || len(m.Renderer.ToolImages) > 1 {
		t.Fatal("resize retained stale image placements")
	}
}

func TestToolImagesReplayReplacesLiveWithoutLosingAttachments(t *testing.T) {
	mockToolGraphics(t, false)
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(80, 30)
	event := daemon.StreamEvent{Type: daemon.EventTool, EntryID: "42", ToolName: "python", ToolResult: "attached", Images: []daemon.ImageMetadata{{Width: 120, Height: 80, Reference: "/sessions/s/history/42/image-0"}}}
	m.handleStreamEvent(event)
	event.Replayed = true
	m.handleStreamEvent(event)
	images := slices.DeleteFunc(slices.Clone(m.History.Entries()), func(e HistoryEntry) bool { return len(e.Images) == 0 })
	if len(images) != 1 {
		t.Fatalf("replay duplicated or lost live images: %+v", images)
	}
}

func TestToolImagesAsyncResultForwardedWhileModalOpen(t *testing.T) {
	mockToolGraphics(t, false)
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(80, 30)
	ref := "/sessions/s/history/42/image-0"
	m.Renderer.ToolImages = map[string]toolImagePreview{ref: {pending: true}}
	app := &AppModel{Chat: m, ActiveSession: &daemon.Session{ID: "s"}, State: AppStateContextInspector}
	_, handled := app.handleChatLifecycle(toolImageLoadedMsg{SessionID: "s", Generation: m.Generation, Reference: ref, Preview: toolImagePreview{failed: true}})
	if !handled || !app.Chat.Renderer.ToolImages[ref].failed {
		t.Fatal("modal swallowed preview completion")
	}
}

var _ tea.Msg = toolImageLoadedMsg{}

func TestToolImagesCloseFreesPlacementsBeforeQuit(t *testing.T) {
	mockToolGraphics(t, true)
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	preview, _ := prepareToolPreview(toolPreviewPNG(t), graphics{supported: true}, 60)
	m.Renderer.ToolImages = map[string]toolImagePreview{"image": preview}
	app := &AppModel{Chat: m, ActiveSession: &daemon.Session{ID: "s"}, State: AppStateChat}
	_, cmd := app.Update(ChatQuitMsg{})
	if cmd == nil || m.streamCtx.Err() == nil || len(app.Chat.Renderer.ToolImages) != 0 {
		t.Fatal("quit retained images or live fetch context")
	}
	commands := reflect.ValueOf(cmd())
	if commands.Kind() != reflect.Slice || commands.Len() != 2 {
		t.Fatal("quit does not sequence cleanup before shutdown")
	}
	cleanup := commands.Index(0).Interface().(tea.Cmd)()
	if !strings.Contains(fmt.Sprint(cleanup), fmt.Sprintf("d=I,i=%d", preview.small.id)) {
		t.Fatal("quit did not free owned image data")
	}
	late := toolImageLoadedMsg{SessionID: "s", Generation: m.Generation, Reference: "image", Preview: preview, transmit: "do not write"}
	_, cmd = app.Chat.acceptToolImage(late)
	if cmd != nil {
		t.Fatal("closed session accepted late image upload")
	}
}
