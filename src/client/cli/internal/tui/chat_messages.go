package tui

import (
	"albedo/cli/internal/daemon"
	"time"
)

type ChatBackToSessionsMsg struct{}

type ChatQuitMsg struct{}

// ChatEditorFinishedMsg is sent after the external editor process exits.
type ChatEditorFinishedMsg struct {
	Err        error
	SessionID  string
	Text       string
	Generation int64
	Edited     bool
}

// FileOpenResultMsg is sent after attempting to open a file in an external editor.
type FileOpenResultMsg struct {
	Err       error
	SessionID string
	Target    FileTarget
}

// ChatOlderLoadedMsg carries a page of history from before what is shown.
type ChatOlderLoadedMsg struct {
	Err        error
	Page       *daemon.HistoryPage
	SessionID  string
	Generation int64
}

type ChatNewSessionMsg struct{}

type ChatOpenModelPickerMsg struct{}

type ChatOpenExtensionPickerMsg struct{}

type ChatOpenTreePickerMsg struct{}
type ChatOpenForkPickerMsg struct{}

type ChatOpenQuotaMsg struct{}

type ChatOpenUsageMsg struct{}

type ChatOpenContextInspectorMsg struct{}

type ChatOpenPageMsg struct {
	Command string
}

type ChatOpenLoginMsg struct {
	Name string
}

type ChatExecuteCommandMsg struct {
	Name string
	Args string
}

type ChatShellSubmitMsg struct {
	Err                      error
	SessionID, OriginalInput string
	Command                  daemon.ShellCommand
	Generation               int64
}

type ChatShellOutputMsg struct {
	Err        error
	ID, Text   string
	SessionID  string
	Generation int64
}

type ChatShellCancelMsg struct {
	Err        error
	SessionID  string
	Command    daemon.ShellCommand
	Generation int64
}

type ChatStreamEventMsg struct {
	SessionID  string
	Event      daemon.StreamEvent
	Generation int64
}

// ChatLiveDrawMsg redraws a growing reply whose last tokens waited.
type ChatLiveDrawMsg struct {
	SessionID  string
	Generation int64
}

type ChatProgressTickMsg struct {
	At         time.Time
	SessionID  string
	Generation int64
}

type ChatClearCopyStatusMsg struct {
	SessionID  string
	Generation int64
	Revision   uint64
}

type ChatStatusMsg struct {
	Err        error
	Status     *daemon.AgentStatus
	SessionID  string
	Glances    []PageGlance
	Generation int64
	Revision   uint64
}

// ChatHostMsg is the probe of the host a remote workspace is on.
type ChatHostMsg struct {
	Err        error
	SessionID  string
	Workspace  string
	Status     daemon.HostStatus
	Generation int64
}

// ChatWindowMsg carries the context window for the model a usage event named.
type ChatWindowMsg struct {
	Err        error
	Tokens     *int
	SessionID  string
	Model      string
	Generation int64
}

type chatModelNameMsg struct {
	Err                                               error
	SessionID, Profile, Model, Label                  string
	DefaultEffort, DefaultEffortSource, ProfileEffort string
	Generation                                        int64
}

// ChatCacheFadeMsg arrives when Usage's cached count reaches its next step.
type ChatCacheFadeMsg struct {
	Usage      *daemon.Usage
	SessionID  string
	Generation int64
}

type ChatStatusPollMsg struct {
	SessionID  string
	Generation int64
	Poll       uint64
}

// ChatStreamResultMsg follows all accepted events from the same subscription.
type ChatStreamResultMsg struct {
	Err        error
	SessionID  string
	Generation int64
	Recovering bool
}

type streamDelivery struct {
	Event      *daemon.StreamEvent
	Err        error
	Recovering bool
}

type ChatStreamClosedMsg struct {
	SessionID  string
	Generation int64
}

type ChatOperationResolvedMsg struct {
	Receipt    daemon.InputReceipt
	Err        error
	Handle     *daemon.OperationHandle
	SessionID  string
	Generation int64
}

type ChatTurnSentMsg struct {
	Err             error
	Handle          *daemon.OperationHandle
	OperationID     string
	SessionID       string
	Prompt          string
	Images          []daemon.ImageAttachment
	Pastes          []string
	Generation      int64
	AcceptanceOrder int64
	Continue        bool
	OK              bool
	Queued          bool
}

type ChatInterruptMsg struct {
	Cancelled   []PendingUserTurn
	Err         error
	SessionID   string
	Generation  int64
	Interrupted bool
}

// ChatOpenFolderPickerMsg asks for the folder picker; Retry is the turn a
// missing workspace refused.
type ChatOpenFolderPickerMsg struct{ Retry *WorkspaceRetry }

type ChatOperationPollMsg struct {
	Handle     *daemon.OperationHandle
	SessionID  string
	Generation int64
}

type ChatOpenAgentsMsg struct{}
