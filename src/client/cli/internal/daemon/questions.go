package daemon

import "fmt"

type QuestionPrompt struct {
	Text    string
	Options []string
}

// QuestionPromptForRow reads the displayed resource, not truncated preview text.
// The existing page action retains that row's ETag and handles answer delivery.
func QuestionPromptForRow(row *PageRow, session string) (QuestionPrompt, error) {
	if row == nil || row.wire.Resource == nil {
		return QuestionPrompt{}, fmt.Errorf("question resource unavailable")
	}
	resource := row.wire.Resource
	var question struct {
		ID        string   `json:"id"`
		SessionID string   `json:"session_id"`
		Question  string   `json:"question"`
		Options   []string `json:"options"`
		Status    string   `json:"status"`
	}
	if err := decodeRequired(resource.Value, &question, "id", "session_id", "question", "options", "status"); err != nil {
		return QuestionPrompt{}, err
	}
	if resource.ETag == "" || question.ID != row.ID || question.SessionID != session || question.Status != "pending" || question.Question == "" || len(question.Question) > 4096 || question.Options == nil || len(question.Options) > 16 {
		return QuestionPrompt{}, fmt.Errorf("invalid pending question resource")
	}
	for _, option := range question.Options {
		if len(option) > 512 {
			return QuestionPrompt{}, fmt.Errorf("question option exceeds 512 bytes")
		}
	}
	return QuestionPrompt{Text: question.Question, Options: question.Options}, nil
}
