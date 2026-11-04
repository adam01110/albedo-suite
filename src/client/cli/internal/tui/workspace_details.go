package tui

func workspaceGroup(id string) string {
	switch id {
	case "chat", "model", "agents", "tree", "context", "extensions", "questions":
		return "Active session"
	case "sessions", "folders", "new":
		return "Workspace"
	case "login", "config", "quota":
		return "Application"
	default:
		return "Session pages"
	}
}

func workspaceDetail(item PickerItem) string {
	details := map[string]string{
		"chat":       "Return to the active conversation.\n\nYour draft, attachments, cursor and undo history are retained.",
		"sessions":   "Browse sessions in this workspace.\n\nj/k select · Enter open\nn new · r rename · p pin\na archive / restore · f folders\n\nDirect: space s in NORMAL",
		"folders":    "Browse local and remote workspaces and their sessions.\n\nh parent · l open folder\n/ search folders\nEnter choose workspace",
		"new":        "Start a new session in the current workspace.\n\nThe existing session and its draft remain available from Sessions.\n\nDirect: space n in NORMAL",
		"model":      "Choose a provider and model for this session; adjust effort and context window.\n\n/ filter models\nj/k select · Enter apply\n\nDirect: space m in NORMAL",
		"agents":     "Inspect related sessions and agent activity.\n\nh/j/k/l navigate\nEnter open selected agent\ni compose a message · Esc navigate\n\nDirect: space a in NORMAL",
		"tree":       "Inspect conversation history and branches.\n\nSelect an entry to branch or rewind. Existing confirmation steps still apply.",
		"context":    "Inspect the model request, prompt sections and context usage without sending a message.",
		"questions":  "Review pending questions and saved answers.\n\nEnter opens the answer flow. Revision checks and cancellation stay in effect.",
		"extensions": "Inspect available tools, skills and extension capabilities for this session.",
		"login":      "Manage provider accounts, authentication and availability through the existing login flow.",
		"config":     "Inspect and edit extension configuration. Changes use the existing validation and apply flow.",
		"quota":      "Inspect provider usage, limits and remaining quota. This view does not change the selected model.",
	}
	if text, ok := details[item.ID]; ok {
		return text
	}
	return item.Detail + "\n\nOpen " + item.ID + " as a page without submitting the draft. Its own forms and confirmations apply."
}
