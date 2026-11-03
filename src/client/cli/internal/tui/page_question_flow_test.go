package tui

import (
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

func TestQuestionsFlowDraftsSurviveSwitchingAndBack(t *testing.T) {
	m, requests := questionPageWithCount(t, []string{"staging", "production"}, 200, 3)
	questionPageKey(&m, tea.KeyEnter, 0)
	questionPageKey(&m, 'e', tea.ModCtrl)
	m, _ = m.Update(tea.PasteMsg{Content: "first draft\nwith detail"})
	questionPageKey(&m, tea.KeyTab, 0)
	if m.questionAnswers.row.ID != "2" || m.Mode != modeQuestionAnswers {
		t.Fatal("next question did not open")
	}
	questionPageKey(&m, tea.KeyDown, 0)
	questionPageKey(&m, 'e', 0)
	if m.Mode != modeText || m.questionAnswers.editor.Value() != "production" {
		t.Fatal("edit suggestion did not prefill the selected answer")
	}
	m, _ = m.Update(tea.PasteMsg{Content: " plus verification"})
	second := m.questionAnswers.editor.Value()
	questionPageKey(&m, tea.KeyTab, tea.ModShift)
	questionPageKey(&m, 'e', tea.ModCtrl)
	if m.questionAnswers.row.ID != "1" || m.questionAnswers.editor.Value() != "first draft\nwith detail" {
		t.Fatal("question switch lost first draft")
	}
	questionPageKey(&m, tea.KeyEscape, 0)
	questionPageKey(&m, tea.KeyTab, 0)
	if m.questionAnswers.Cursor != 1 {
		t.Fatal("question switch lost selected suggestion")
	}
	questionPageKey(&m, 'e', tea.ModCtrl)
	if m.questionAnswers.editor.Value() != second {
		t.Fatal("second draft lost")
	}
	questionPageKey(&m, tea.KeyEscape, 0)
	questionPageKey(&m, tea.KeyEscape, 0)
	if m.Mode != modeBrowse || m.currentRow().ID != "2" {
		t.Fatal("back did not focus current question in list")
	}
	questionPageKey(&m, tea.KeyEnter, 0)
	questionPageKey(&m, 'e', tea.ModCtrl)
	if m.questionAnswers.editor.Value() != second || len(*requests) != 0 {
		t.Fatal("reopening lost draft or submitted it")
	}
}

func TestQuestionsFlowMultilineRequiresExplicitSubmit(t *testing.T) {
	m, requests := questionPage(t, nil, 200)
	questionPageKey(&m, tea.KeyEnter, 0)
	m, _ = m.Update(tea.PasteMsg{Content: "first line"})
	questionPageKey(&m, tea.KeyEnter, 0)
	m, _ = m.Update(tea.PasteMsg{Content: "second line"})
	if len(*requests) != 0 || m.questionAnswers.editor.Value() != "first line\nsecond line" {
		t.Fatal("Enter submitted instead of adding a newline")
	}
	result := questionPageKey(&m, tea.KeyEnter, tea.ModCtrl)().(pageActionExecutedMsg)
	if result.Err != nil || len(*requests) != 1 || (*requests)[0] != "first line\nsecond line" {
		t.Fatalf("multiline answer: %v %v", *requests, result.Err)
	}
}

func TestQuestionsFlowValidatesWithoutLosingEditor(t *testing.T) {
	m, requests := questionPage(t, nil, 200)
	questionPageKey(&m, tea.KeyEnter, 0)
	if cmd := questionPageKey(&m, 's', tea.ModCtrl); cmd != nil || m.Error == "" || m.Mode != modeText {
		t.Fatal("empty answer was dispatched")
	}
	m, _ = m.Update(tea.PasteMsg{Content: strings.Repeat("界", 3000)})
	draft := m.questionAnswers.editor.Value()
	if cmd := questionPageKey(&m, 's', tea.ModCtrl); cmd != nil || !strings.Contains(m.Error, "8192") || m.questionAnswers.editor.Value() != draft || len(*requests) != 0 {
		t.Fatal("oversized answer dispatched or discarded")
	}
	m.questionAnswers.editor.SetValue("short answer")
	result := questionPageKey(&m, 's', tea.ModCtrl)().(pageActionExecutedMsg)
	if result.Err != nil || len(*requests) != 1 || (*requests)[0] != "short answer" {
		t.Fatal("Ctrl+S fallback did not submit")
	}
}

func TestQuestionsFlowDismissTargetsActiveQuestionAndKeepsCancelledDraft(t *testing.T) {
	m, requests := questionPageWithCount(t, []string{"staging"}, 200, 2)
	questionPageKey(&m, tea.KeyEnter, 0)
	questionPageKey(&m, tea.KeyTab, 0)
	questionPageKey(&m, 'e', tea.ModCtrl)
	m, _ = m.Update(tea.PasteMsg{Content: "keep this draft"})
	questionPageKey(&m, 'd', tea.ModCtrl)
	if m.Mode != modeConfirm || !strings.Contains(ansi.Strip(m.View()), "#2") || len(*requests) != 0 {
		t.Fatal("dismiss did not confirm active question")
	}
	questionPageKey(&m, tea.KeyEscape, 0)
	if m.Mode != modeQuestionAnswers || m.CurrentAction.Operation.OperationID != "answerQuestion" {
		t.Fatal("cancel did not restore answer action")
	}
	questionPageKey(&m, 'e', tea.ModCtrl)
	if m.questionAnswers.editor.Value() != "keep this draft" {
		t.Fatal("cancelled dismissal lost draft")
	}
	questionPageKey(&m, 'd', tea.ModCtrl)
	result := questionPageKey(&m, tea.KeyEnter, 0)().(pageActionExecutedMsg)
	if result.Err != nil || len(*requests) != 1 || (*requests)[0] != "dismissed" {
		t.Fatalf("dismiss failed: %v %v", *requests, result.Err)
	}
}

func TestQuestionsFlowNoOptionsRestoreAndPruneDrafts(t *testing.T) {
	m, _ := questionPageWithCount(t, nil, 200, 2)
	questionPageKey(&m, tea.KeyEnter, 0)
	m, _ = m.Update(tea.PasteMsg{Content: "first"})
	questionPageKey(&m, tea.KeyTab, 0)
	if m.Mode != modeText || m.questionAnswers.row.ID != "2" {
		t.Fatal("no-options next question must start editor")
	}
	m, _ = m.Update(tea.PasteMsg{Content: "second"})
	questionPageKey(&m, tea.KeyTab, tea.ModShift)
	if m.questionAnswers.editor.Value() != "first" {
		t.Fatal("no-options draft lost")
	}
	questionPageKey(&m, tea.KeyEscape, 0)
	m.Doc.Rows = m.Doc.Rows[1:]
	m.setDoc(m.Doc)
	if _, ok := m.questionDrafts["1"]; ok {
		t.Fatal("resolved question draft retained")
	}
	if m.questionDrafts["2"].text != "second" {
		t.Fatal("pruning removed another pending draft")
	}
}

func TestQuestionsFlowResponsiveContextAndQuestionScrolling(t *testing.T) {
	m, _ := questionPageWithCount(t, []string{strings.Repeat("long answer 界 ", 20), "production"}, 200, 3)
	questionPageKey(&m, tea.KeyEnter, 0)
	m.questionAnswers.question = "FIRST LINE\n" + strings.Repeat("A long paragraph of question context.\n", 50) + "LAST LINE"
	for _, size := range [][2]int{{20, 10}, {40, 12}, {60, 20}, {100, 30}, {160, 40}} {
		m.SetSize(size[0], size[1])
		view := ansi.Strip(m.View())
		rows := strings.Split(view, "\n")
		if len(rows) > size[1] {
			t.Fatalf("height overflow %v", size)
		}
		for _, row := range rows {
			if ansi.StringWidth(row) > size[0] {
				t.Fatalf("width overflow %v %q", size, row)
			}
		}
		if !strings.Contains(view, "FIRST LINE") {
			t.Fatalf("question context hidden at %v", size)
		}
		if size[0] >= 100 && !strings.Contains(view, "Pending questions") {
			t.Fatal("wide view lacks question queue")
		}
	}
	for range 100 {
		questionPageKey(&m, tea.KeyDown, tea.ModCtrl)
	}
	if !strings.Contains(ansi.Strip(m.View()), "LAST LINE") {
		t.Fatal("long question cannot scroll to end")
	}
	questionPageKey(&m, 'e', tea.ModCtrl)
	m, _ = m.Update(tea.PasteMsg{Content: "saved draft"})
	if !strings.Contains(ansi.Strip(m.View()), "draft") || !strings.Contains(ansi.Strip(m.View()), "Your answer") {
		t.Fatal("draft state or editor context hidden")
	}
}

func TestQuestionsFlowWideOptionsUseAvailableWidth(t *testing.T) {
	label := "Staging — deploy to the test environment first"
	m, _ := questionPage(t, []string{label, "Production"}, 200)
	questionPageKey(&m, tea.KeyEnter, 0)
	m.SetSize(120, 30)
	// The label must fit in the option row, not only in its preview.
	rows := strings.Split(ansi.Strip(m.View()), "\n")
	found := false
	for _, row := range rows {
		if strings.Contains(row, "1. "+label) {
			found = true
		}
	}
	if !found {
		t.Fatal("option column is truncated despite sufficient terminal width")
	}
}

func TestQuestionsFlowFailedWriteKeepsCustomDraft(t *testing.T) {
	m, requests := questionPage(t, []string{"staging"}, 412)
	questionPageKey(&m, tea.KeyEnter, 0)
	questionPageKey(&m, 'e', tea.ModCtrl)
	m, _ = m.Update(tea.PasteMsg{Content: "do not lose this answer"})
	result := questionPageKey(&m, 's', tea.ModCtrl)().(pageActionExecutedMsg)
	m, cmd := m.Update(result)
	if cmd != nil || m.Error == "" || len(*requests) != 1 {
		t.Fatal("failed write retried or hidden")
	}
	questionPageKey(&m, tea.KeyEnter, 0)
	questionPageKey(&m, 'e', tea.ModCtrl)
	if m.questionAnswers.editor.Value() != "do not lose this answer" {
		t.Fatal("conditional write failure erased draft")
	}
}
