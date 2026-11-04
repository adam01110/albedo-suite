package tui

func keyboardReference() []PickerItem {
	sections := []struct {
		scope    string
		bindings []hint
	}{
		{"Chat / sessions NORMAL", []hint{
			{"space s", "Sessions"}, {"space n", "New session"}, {"space a", "Agents (active session)"},
			{"space m", "Model (active session)"}, {"space w", "Workspace destinations"},
			{"space ?", "Keyboard reference"},
		}},
		{"Chat NORMAL", []hint{
			{"space v d", "Toggle diffs"}, {"space v c", "Toggle compaction"}, {"space v o", "Toggle shell output"},
		}},
		{"Space menu", []hint{
			{"Esc / Backspace", "Parent group, then close"}, {"ctrl+c / F2", "Close menu without quitting"},
		}},
		{"Composer NORMAL", []hint{
			{"i / a", "Insert before / after cursor"}, {"I / A", "Insert at first nonblank / line end"},
			{"o / O", "Open line below / above; INSERT"}, {"h j k l", "Move cursor"},
			{"w / b / e", "Word forward / back / end"}, {"0 / ^ / $", "Line start / first nonblank / end"},
			{"gg / G", "First / last line"}, {"f / F", "Find character forward / backward"},
			{"t / T", "Till character forward / backward"}, {"; / ,", "Repeat / reverse character find"},
			{"d / c / y", "Delete / change / yank + motion"}, {"dd / cc / yy", "Delete / change / yank whole line"},
			{"iw / aw", "Inner / around word after operator"}, {"p / P", "Paste after / before"},
			{"u / ctrl+r", "Undo / redo"}, {"Tab", "Focus transcript; keep draft"},
			{"/", "Workspace destinations; keep draft"}, {"Esc", "Cancel prefix, otherwise stop response"},
		}},
		{"Composer INSERT", []hint{
			{"Esc", "Dismiss menu, then return to NORMAL"}, {"Type / Space", "Literal draft text"},
		}},
		{"Composer (either mode)", []hint{
			{"Enter", "Send draft"}, {"Shift+Enter", "Insert newline"}, {"ctrl+g", "External editor"},
			{"ctrl+v", "Paste image"}, {"ctrl+k", "Toggle compaction"}, {"ctrl+shift+o", "Toggle shell output"},
			{"ctrl+shift+x", "Stop running shell"}, {"ctrl+n", "New session"},
			{"pgup / pgdown", "Page transcript up / down"}, {"shift+up / shift+down", "Previous / next user message"},
			{"ctrl+home / ctrl+end", "Transcript start / follow latest"}, {"ctrl+l", "Sign in when host authentication is available"},
		}},
		{"Transcript NORMAL", []hint{
			{"j / k", "Move down / up"}, {"gg / G", "First row / follow latest"},
			{"ctrl+u / ctrl+d", "Half-page up / down"}, {"[ / ]", "Previous / next action"},
			{"Enter / l", "Activate selected row"}, {"y", "Copy selected row"}, {"o", "Open file reference"},
			{"/", "Start FIND"}, {"n / N", "Next / previous match"}, {"i / a / I / A", "Return to composer INSERT"},
			{"Tab", "Return to composer NORMAL"}, {"h / q", "Sessions"}, {"Esc", "Cancel prefix, otherwise stop response"},
		}},
		{"Transcript FIND", []hint{
			{"Type / Space", "Literal query text, never draft text"}, {"Enter", "Find query"}, {"Esc", "Close FIND; keep draft"},
		}},
		{"Lists NORMAL", []hint{
			{"j / k", "Next / previous row"}, {"[count]j / k", "Move multiple rows"}, {"gg / G", "First / last row"},
			{"ctrl+u / ctrl+d", "Half-page up / down"}, {"l / Enter", "Open selected item"},
			{"h / q / Esc", "Back (cancel prefix first)"}, {"/", "Enter SEARCH"},
		}},
		{"Lists SEARCH", []hint{
			{"Type / Space", "Literal filter text"}, {"Esc", "Keep filter; return to NORMAL"}, {"Enter", "Open highlighted search result"},
		}},
		{"Sessions NORMAL", []hint{
			{"n", "New session"}, {"r", "Rename"}, {"p", "Pin / unpin"}, {"a", "Archive / restore"},
			{"f", "Browse folders"}, {"x", "Delete in archive; confirmation required"},
		}},
		{"Pages NORMAL", []hint{
			{"a / Enter", "Open action menu (questions: answer flow)"}, {"r", "Refresh page"},
		}},
		{"Forms and choices", []hint{
			{"Type / Space", "Literal text in text fields"}, {"j / k", "Choose option"}, {"Enter", "Apply"}, {"Esc", "Cancel"},
		}},
		{"Agents NORMAL", []hint{
			{"h j k l", "Navigate agents"}, {"i", "Compose a message"}, {"Enter", "Open agent, never send retained draft"},
		}},
		{"Agents INSERT", []hint{
			{"Enter", "Send message"}, {"Esc", "Return to NORMAL; keep draft"},
		}},
		{"Keyboard reference", []hint{
			{"Enter / l", "Inspect only; bindings are never executed here"},
		}},
		{"Application", []hint{
			{"F1", "Toggle keyboard reference"}, {"F2", "Workspace from chat or sessions"}, {"ctrl+c", "Quit (open menus close first)"},
		}},
	}
	var items []PickerItem
	for _, section := range sections {
		for _, binding := range section.bindings {
			items = append(items, PickerItem{ID: section.scope + ":" + binding.key, Label: binding.key, Detail: binding.does + " · " + section.scope, Note: section.scope + "\n\n" + binding.key + "\n" + binding.does})
		}
	}
	return items
}
