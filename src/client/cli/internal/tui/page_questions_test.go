package tui

import (
	"albedo/cli/internal/daemon"
	"albedo/cli/internal/daemon/protocol"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

func questionPage(t *testing.T, options []string, status int) (PageViewModel, *[]string) {
	t.Helper()
	if options == nil {
		options = []string{}
	}
	answers := []string{}
	literal := func(value string) any { return map[string]any{"source": "literal", "value": value} }
	rowBinding := func(pointer string) any { return map[string]any{"source": "row", "pointer": pointer} }
	operation := func(action, id string) map[string]any {
		return map[string]any{
			"operation_id": id, "method": "POST", "path_template": "/extensions/questions/items/{id}/" + action,
			"path":    map[string]any{"id": rowBinding("/resource/value/id")},
			"query":   map[string]any{"session_id": literal("s")},
			"headers": map[string]any{"If-Match": rowBinding("/resource/etag")},
			"body":    map[string]any{}, "result_schema": map[string]any{}, "success_status": 200,
		}
	}
	answerOp := operation("answer", "answerQuestion")
	answerOp["body"] = map[string]any{"/answer": map[string]string{"source": "form", "pointer": "/answer"}}
	resource := map[string]any{"url": "/extensions/questions/items/1?session_id=s", "etag": `"question-1-1"`, "value": map[string]any{
		"id": "1", "session_id": "s", "question": "Where should this deploy?", "options": options, "status": "pending", "revision": 1,
	}}
	field := map[string]any{"name": "answer", "label": "answer", "type": "text", "required": true, "default": nil, "choices": []any{}, "minimum": nil, "maximum": nil, "description": ""}
	payload := map[string]any{"page": map[string]any{
		"title": "questions", "summary": "Answer to resume", "empty_state": "no pending questions", "glance": nil,
		"rows": []any{map[string]any{"id": "1", "text": "Where should this deploy?", "badge": "pending", "tone": "warning", "detail": "Where should this deploy?", "resource": resource}},
		"actions": []any{
			map[string]any{"id": "answer", "label": "answer", "keyboard_hint": "ctrl+e", "confirmation": nil, "fields": []any{field}, "operation": answerOp},
			map[string]any{"id": "cancel", "label": "dismiss", "keyboard_hint": "ctrl+d", "confirmation": "Dismiss this question?", "fields": []any{}, "operation": operation("cancel", "dismissQuestion")},
		},
	}}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.Method == "GET" {
			_ = json.NewEncoder(w).Encode(payload)
			return
		}
		if r.URL.Path != "/extensions/questions/items/1/answer" && r.URL.Path != "/extensions/questions/items/1/cancel" {
			t.Errorf("wrong target: %s", r.URL)
		}
		if r.URL.Query().Get("session_id") != "s" || r.Header.Get("If-Match") != `"question-1-1"` {
			t.Errorf("lost session or ETag: %s %v", r.URL, r.Header)
		}
		if strings.HasSuffix(r.URL.Path, "/answer") {
			var body struct {
				Answer string `json:"answer"`
			}
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
				t.Error(err)
			}
			answers = append(answers, body.Answer)
		} else {
			answers = append(answers, "dismissed")
		}
		if status != 200 {
			w.WriteHeader(status)
			_, _ = fmt.Fprint(w, `{"title":"Changed","code":"question_conflict","detail":"refresh first"}`)
			return
		}
		_, _ = fmt.Fprint(w, `{"notification":{"state":"queued"}}`)
	}))
	t.Cleanup(server.Close)
	conn := daemon.NewConnection(daemon.ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil)
	t.Cleanup(conn.HTTPClient().CloseIdleConnections)
	// Use the existing page decoder so displayed wire resources and action bindings are real.
	read := daemon.PageAction{Label: "questions", Operation: protocol.ActionOperation{OperationID: "readQuestions", Method: "GET", PathTemplate: "/extensions/questions/items"}}
	result, err := daemon.ExecutePageAction(t.Context(), conn, daemon.PageActionRequest{Action: read})
	if err != nil {
		t.Fatal(err)
	}
	m := NewPageViewModel(conn, "s", "/questions")
	m.SetSize(100, 30)
	m.setDoc(result.Page)
	m.Busy = false
	return m, &answers
}

func questionPageKey(m *PageViewModel, code rune, mod tea.KeyMod) tea.Cmd {
	var cmd tea.Cmd
	msg := tea.KeyPressMsg{Code: code, Mod: mod}
	if code >= 32 && code < 127 && mod == 0 {
		msg.Text = string(code)
	}
	*m, cmd = m.Update(msg)
	return cmd
}

func TestQuestionsPagePickSuggestedAnswer(t *testing.T) {
	m, answers := questionPage(t, []string{"staging", "production"}, 200)
	questionPageKey(&m, tea.KeyEnter, 0)
	if m.Mode != modeQuestionAnswers || len(m.questionAnswers.rows) != 3 {
		t.Fatal("suggestions not offered")
	}
	if !strings.Contains(ansi.Strip(m.View()), "Type your own answer") {
		t.Fatal("custom answer missing")
	}
	questionPageKey(&m, tea.KeyDown, 0)
	if m.Cursor != 0 {
		t.Fatal("answer navigation moved selected question")
	}
	cmd := questionPageKey(&m, tea.KeyEnter, 0)
	if !m.Busy || cmd == nil {
		t.Fatal("answer not dispatched")
	}
	result := cmd().(pageActionExecutedMsg)
	if result.Err != nil || len(*answers) != 1 || (*answers)[0] != "production" {
		t.Fatalf("answer=%v err=%v", *answers, result.Err)
	}
	if cmd := questionPageKey(&m, tea.KeyEnter, 0); cmd != nil {
		t.Fatal("duplicate submission while busy")
	}
	m, _ = m.Update(result)
	if !m.Busy {
		t.Fatal("successful action did not refresh pending list")
	}
}

func TestQuestionsPageCustomAnswerAndBack(t *testing.T) {
	m, answers := questionPage(t, []string{"staging", "production"}, 200)
	questionPageKey(&m, 'e', tea.ModCtrl)
	questionPageKey(&m, tea.KeyEnd, 0)
	questionPageKey(&m, tea.KeyEnter, 0)
	if m.Mode != modeText {
		t.Fatal("custom entry not opened")
	}
	m, _ = m.Update(tea.PasteMsg{Content: "custom deployment"})
	questionPageKey(&m, tea.KeyEscape, 0)
	if m.Mode != modeQuestionAnswers || m.TextInput.Value() != "custom deployment" {
		t.Fatal("back lost custom draft")
	}
	questionPageKey(&m, 'e', tea.ModCtrl)
	if m.TextInput.Value() != "custom deployment" {
		t.Fatal("custom draft not restored")
	}
	result := questionPageKey(&m, tea.KeyEnter, 0)().(pageActionExecutedMsg)
	if result.Err != nil || len(*answers) != 1 || (*answers)[0] != "custom deployment" {
		t.Fatalf("custom answer: %v %v", *answers, result.Err)
	}
}

func TestQuestionsPageNoOptionsAndDismiss(t *testing.T) {
	m, answers := questionPage(t, nil, 200)
	questionPageKey(&m, tea.KeyEnter, 0)
	if m.Mode != modeText || m.questionAnswers != nil {
		t.Fatal("no-options question did not open text entry")
	}
	questionPageKey(&m, tea.KeyEscape, 0)
	questionPageKey(&m, 'd', tea.ModCtrl)
	if m.Mode != modeConfirm || len(*answers) != 0 {
		t.Fatal("dismiss requires confirmation")
	}
	questionPageKey(&m, tea.KeyEscape, 0)
	if m.Mode != modeBrowse || len(*answers) != 0 {
		t.Fatal("escape dismissed question")
	}
	questionPageKey(&m, 'd', tea.ModCtrl)
	result := questionPageKey(&m, tea.KeyEnter, 0)().(pageActionExecutedMsg)
	if result.Err != nil || len(*answers) != 1 || (*answers)[0] != "dismissed" {
		t.Fatalf("dismiss: %v %v", *answers, result.Err)
	}
}

func TestQuestionsPageConflictRetainsQuestionAndDoesNotRetry(t *testing.T) {
	m, answers := questionPage(t, []string{"staging"}, 412)
	questionPageKey(&m, tea.KeyEnter, 0)
	result := questionPageKey(&m, tea.KeyEnter, 0)().(pageActionExecutedMsg)
	m, cmd := m.Update(result)
	if result.Err == nil || cmd != nil || len(*answers) != 1 || len(m.Doc.Rows) != 1 || m.Error == "" || m.Busy {
		t.Fatalf("conflict: %+v %v", m, result.Err)
	}
}

func TestQuestionsPageLongOptionsScrollAndResize(t *testing.T) {
	options := []string{}
	for i := range 16 {
		options = append(options, fmt.Sprintf("Answer %d %s", i, strings.Repeat("界", 100)))
	}
	m, _ := questionPage(t, options, 200)
	questionPageKey(&m, tea.KeyEnter, 0)
	questionPageKey(&m, tea.KeyEnd, 0)
	m, _ = m.Update(tea.PasteMsg{Content: "must not filter the question list"})
	if m.input.Value() != "" || m.Cursor != 0 {
		t.Fatal("answer picker paste changed question selection")
	}
	for _, size := range [][2]int{{20, 10}, {40, 12}, {80, 24}, {120, 40}} {
		m.SetSize(size[0], size[1])
		view := ansi.Strip(m.View())
		rows := strings.Split(view, "\n")
		if len(rows) > size[1] {
			t.Fatalf("height overflow: %dx%d %d", size[0], size[1], len(rows))
		}
		for _, row := range rows {
			if ansi.StringWidth(row) > size[0] {
				t.Fatalf("width overflow: %q", row)
			}
		}
		if !strings.Contains(view, "Type your") {
			t.Fatal("last selected choice did not scroll into view")
		}
	}
	questionPageKey(&m, tea.KeyEscape, 0)
	if m.Mode != modeBrowse || m.questionAnswers != nil {
		t.Fatal("back failed")
	}
}

func TestQuestionsPagePreservesRawOptionsAndCapturedQuestion(t *testing.T) {
	wanted := "  production\n界  "
	m, answers := questionPage(t, []string{"staging", wanted}, 200)
	questionPageKey(&m, tea.KeyEnter, 0)
	questionPageKey(&m, '2', 0)
	if m.questionAnswers.Cursor != 1 {
		t.Fatal("number key did not select option")
	}
	// A refreshed question list cannot redirect an already opened answer prompt.
	next := m.Doc.Rows[0]
	next.ID, next.Text = "2", "Another question"
	m.Doc.Rows = append(m.Doc.Rows, next)
	m.setDoc(m.Doc)
	m.Cursor = 1
	result := questionPageKey(&m, tea.KeyEnter, 0)().(pageActionExecutedMsg)
	if result.Err != nil || len(*answers) != 1 || (*answers)[0] != wanted {
		t.Fatalf("raw option lost or redirected: %v %v", *answers, result.Err)
	}
}

func TestQuestionsPageDoesNotAlterOtherTextForms(t *testing.T) {
	m, _ := questionPage(t, []string{"staging"}, 200)
	m.Command = "/work"
	questionPageKey(&m, 'e', tea.ModCtrl)
	if m.Mode != modeText || m.questionAnswers != nil {
		t.Fatal("question picker leaked into generic text action")
	}
}
