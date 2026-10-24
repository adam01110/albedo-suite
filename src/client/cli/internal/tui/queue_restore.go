package tui

import (
	"slices"
	"strconv"
)

// importDraftAttachments renumbers recovered markers without replacing live attachments.
func importDraftAttachments[T any, K markerKind[T]](dst *attachments[T, K], text string, items []T) string {
	var source attachments[T, K]
	source.restore(items)
	markers := make(map[int]string)
	for _, n := range source.referenced(text) {
		markers[n] = dst.add(source.byNumber[n])
	}
	pattern := source.kind.pattern()
	return pattern.ReplaceAllStringFunc(text, func(marker string) string {
		n, _ := strconv.Atoi(pattern.FindStringSubmatch(marker)[1])
		if replacement, ok := markers[n]; ok {
			return replacement
		}
		return marker
	})
}

func (m *ChatModel) restoreCancelledInputs(cancelled []PendingUserTurn) {
	if len(cancelled) == 0 {
		return
	}
	defer m.trackComposerEdit()()
	text := m.TextArea.Value()
	for _, turn := range cancelled {
		recovered := importDraftAttachments(&m.Images, turn.Text, unseen(turn.Images))
		recovered = importDraftAttachments(&m.Pastes, recovered, turn.Pastes)
		if text != "" {
			text += "\n"
		}
		text += recovered
		m.pendingUsers = slices.DeleteFunc(m.pendingUsers, func(p PendingUserTurn) bool { return p.OperationID == turn.OperationID })
	}
	m.TextArea.SetValue(text)
	m.TextArea.CursorEnd()
	m.vimBeginInsert(m.vimSnapshot())
	m.syncLayout()
	m.refreshViewportContent()
}
