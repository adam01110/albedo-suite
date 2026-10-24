package tui

import (
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"

	"albedo/cli/internal/daemon"
	tea "charm.land/bubbletea/v2"
)

func TestSuiteEscapeModalPriority(t *testing.T) {
	for _, state := range []string{"running", "sending", "queued"} {
		t.Run(state, func(t *testing.T) {
			m := newTestChatModel(t, &daemon.Session{ID: "s"})
			m.SetSize(80, 24)
			m.Status.Running = state == "running"
			m.isSending = state == "sending"
			if state == "queued" {
				m.pendingUsers = []PendingUserTurn{{OperationID: "q"}}
			}
			vimKeys(&m, "i", "a")
			m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEscape})
			if !m.vim.normal || m.Stopping || m.interruptPending || m.interruptDeferred {
				t.Fatal("Insert Escape must only enter Normal")
			}
			for _, prefix := range [][]string{{"2"}, {"d"}, {"d", "2"}, {"f"}, {"d", "i"}} {
				vimKeys(&m, prefix...)
				m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEscape})
				if m.Stopping || m.interruptPending || m.interruptDeferred || m.vim.pending != "" || m.vim.argument != nil || m.vim.count != 0 {
					t.Fatalf("prefix %v was not cancelled locally", prefix)
				}
			}
			vimKeys(&m, "a", "z")
			if m.vim.normal || m.TextArea.Value() != "az" {
				t.Fatalf("typing while active: %q", m.TextArea.Value())
			}
		})
	}
}

func suiteInterruptResult(t *testing.T, cmd tea.Cmd) ChatInterruptMsg {
	t.Helper()
	if cmd == nil {
		t.Fatal("missing interrupt command")
	}
	switch msg := cmd().(type) {
	case ChatInterruptMsg:
		return msg
	case tea.BatchMsg:
		for _, child := range msg {
			if child == nil {
				continue
			}
			if result, ok := child().(ChatInterruptMsg); ok {
				return result
			}
		}
	}
	t.Fatal("no interrupt result")
	return ChatInterruptMsg{}
}

func TestSuiteEscapeRestoresOnlyCancelledInputs(t *testing.T) {
	for _, state := range []string{"requested", "already_ended"} {
		t.Run(state, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/sessions/s/interrupt" {
					t.Errorf("unexpected request %s", r.URL.Path)
				}
				var request struct {
					RunID   string `json:"run_id"`
					Through int64  `json:"through_input_order"`
				}
				if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
					t.Error(err)
				}
				if request.RunID != "run" || request.Through != 7 {
					t.Errorf("wrong captured boundary: %+v", request)
				}
				w.Header().Set("Content-Type", "application/json")
				_ = json.NewEncoder(w).Encode(map[string]any{"state": state, "run_id": "run", "cancelled_input_ids": []string{"q", "q2"}, "warnings": []string{}})
			}))
			defer server.Close()
			conn := daemon.NewConnection(daemon.ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil)
			defer conn.HTTPClient().CloseIdleConnections()
			m := NewChatModel(&daemon.Session{ID: "s"}, daemon.NewChatClient(conn, "s"))
			defer m.Close()
			m.SetSize(80, 24)
			run := "run"
			m.Status.Running, m.Status.RunID, m.Status.InputOrder = true, &run, 7
			queuedImage := daemon.ImageAttachment{Data: "queued"}
			m.pendingUsers = []PendingUserTurn{
				{OperationID: "admitted", Text: "not recoverable"},
				{OperationID: "q", Text: "queued [Image #1] [Paste #1]", Images: []daemon.ImageAttachment{queuedImage}, Pastes: []string{"queued paste"}},
				{OperationID: "q2", Text: "second"},
				{OperationID: "newer", Text: "keep queued"},
			}
			m, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyEscape})
			if !m.interruptPending {
				t.Fatal("plain Normal Escape did not interrupt")
			}
			// A pushed receipt can remove cancelled items before the HTTP result arrives.
			cancelled := "cancelled"
			for _, id := range []string{"q", "q2"} {
				m, _ = m.Update(ChatStreamEventMsg{SessionID: m.SessionID, Generation: m.Generation, Event: daemon.StreamEvent{Type: "input", Receipt: &daemon.InputReceipt{ID: id, Delivery: &cancelled}}})
			}
			m, _ = m.Update(ChatStreamEventMsg{SessionID: m.SessionID, Generation: m.Generation, Event: daemon.StreamEvent{Type: daemon.EventUser, OperationID: "admitted", Text: "not recoverable"}})
			if len(m.pendingUsers) != 1 {
				t.Fatal("stream receipts did not retire pending inputs")
			}
			liveImage := daemon.ImageAttachment{Data: "live"}
			m.TextArea.SetValue("draft " + m.Images.add(pastedImage{ImageAttachment: liveImage}) + " " + m.Pastes.add("live paste"))
			result := suiteInterruptResult(t, cmd)
			if result.Err != nil {
				t.Fatal(result.Err)
			}
			m, _ = m.Update(result)
			text, images := m.Images.resolve(m.TextArea.Value())
			_, pastes := m.Pastes.resolve(text)
			if text != "draft [Image #1] [Paste #1, 10 chars]\nqueued [Image #2] [Paste #2, 12 chars]\nsecond" {
				t.Fatalf("draft recovery: %q", text)
			}
			if len(images) != 2 || images[0].Data != "live" || images[1].Data != "queued" || !reflect.DeepEqual(pastes, []string{"live paste", "queued paste"}) {
				t.Fatalf("attachments lost: %+v %v", images, pastes)
			}
			if len(m.pendingUsers) != 1 || m.pendingUsers[0].OperationID != "newer" || m.vim.normal {
				t.Fatal("new input removed or recovered draft not editable")
			}
			before := m.TextArea.Value()
			m, _ = m.Update(result)
			if m.TextArea.Value() != before {
				t.Fatal("duplicate result restored twice")
			}
		})
	}
}

func TestSuiteEscapeRejectsFailedOrStaleRecovery(t *testing.T) {
	for _, mode := range []string{"error", "session", "generation"} {
		t.Run(mode, func(t *testing.T) {
			m := newTestChatModel(t, &daemon.Session{ID: "s"})
			m.SetSize(80, 24)
			m.interruptPending = true
			msg := ChatInterruptMsg{SessionID: m.SessionID, Generation: m.Generation, Cancelled: []PendingUserTurn{{Text: "do not restore"}}}
			switch mode {
			case "error":
				msg.Err = errors.New("failed")
			case "session":
				msg.SessionID = "other"
			case "generation":
				msg.Generation++
			}
			m, _ = m.Update(msg)
			if m.TextArea.Value() != "" {
				t.Fatal("unsafe recovery")
			}
		})
	}
}

func TestSuiteEscapeDeferredUntilSendAccepted(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(80, 24)
	m.isSending = true
	m.pendingUsers = []PendingUserTurn{{OperationID: "q", Text: "queued"}}
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEscape})
	if !m.interruptDeferred || m.interruptPending {
		t.Fatal("interrupt must wait for send acceptance")
	}
	m, _ = m.Update(ChatTurnSentMsg{SessionID: m.SessionID, Generation: m.Generation, OperationID: "q", Queued: true, AcceptanceOrder: 9})
	if m.interruptDeferred || !m.interruptPending || m.Status.InputOrder != 9 {
		t.Fatal("accepted send did not dispatch captured interrupt")
	}
}

func TestSuiteEscapeEffortVimKeys(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(80, 24)
	m.Status.Running = true
	m.effortOptions = []string{"low", "medium", "high"}
	vimKeys(&m, "j", "l", "l")
	if m.effortSelected != 2 {
		t.Fatal("j/l must move right with clamping")
	}
	vimKeys(&m, "h", "k", "k")
	if m.effortSelected != 0 {
		t.Fatal("h/k must move left with clamping")
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEscape})
	if len(m.effortOptions) != 0 || m.Stopping {
		t.Fatal("selector Escape must not stop reply")
	}
}
