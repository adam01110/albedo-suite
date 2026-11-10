package daemon

import (
	"encoding/json"
	"errors"
	"fmt"
	"unicode/utf8"

	"albedo/cli/internal/daemon/protocol"
)

// ArtifactActivity identifies an artifact version shown by a tool.
type ArtifactActivity struct {
	ID      string `json:"id"`
	Version int64  `json:"version"`
}

// SkillActivity is where the skill a "skill" activity loaded was found.
type SkillActivity struct {
	Scope  string `json:"scope"` // "workspace" | "user" | "built-in"
	Source string `json:"source"`
}

// SkillLoad is the skill a user's slash activation loaded.
type SkillLoad struct {
	Name   string `json:"name"`
	Scope  string `json:"scope"`
	Source string `json:"source"`
}

// ToolActivity records display-only execution evidence, not model-facing tool output.
type ToolActivity struct {
	Kind     string            `json:"kind"` // "read" | "search" | "list" | "run" | "web" | "display" | "mcp" | "cua" | "artifact" | "skill"
	Target   string            `json:"target"`
	Artifact *ArtifactActivity `json:"artifact,omitempty"`
	Skill    *SkillActivity    `json:"skill,omitempty"`
	// Detail is the markdown a web search answered with or display() showed; empty otherwise.
	Detail string `json:"detail,omitempty"`
	// MS and OK are how long the call took and whether it worked, when it
	// ended before its cell did; nil otherwise.
	MS *int64 `json:"ms,omitempty"`
	OK *bool  `json:"ok,omitempty"`
}

type FileChange struct {
	OldText *string `json:"old_text,omitempty"`
	NewText *string `json:"new_text,omitempty"`
	Path    string  `json:"path"`
	Kind    string  `json:"kind"` // "diff" | "unavailable"
	Diff    string  `json:"diff,omitempty"`
	Reason  string  `json:"reason,omitempty"`
	Added   int     `json:"added,omitempty"`
	Removed int     `json:"removed,omitempty"`
}

type ToolTrace struct {
	Activities []ToolActivity `json:"activities"`
	Changes    []FileChange   `json:"changes"`
	Truncated  bool           `json:"truncated,omitempty"`
}

// ParseToolTrace validates the display evidence encoded in a history or tool event.
func ParseToolTrace(data json.RawMessage) *ToolTrace {
	if len(data) == 0 {
		return nil
	}

	var trace ToolTrace
	if err := json.Unmarshal(data, &trace); err != nil {
		return nil
	}

	if len(trace.Activities) > 64 || len(trace.Changes) > 16 {
		return nil
	}

	for _, act := range trace.Activities {
		switch act.Kind {
		case "read", "search", "list", "run", "web", "display", "mcp", "cua":
		case "artifact":
			if act.Artifact == nil || act.Artifact.ID == "" || act.Artifact.Version < 1 {
				return nil
			}
		case "skill":
			if act.Skill == nil || act.Target == "" {
				return nil
			}
		default:
			return nil
		}
		// Python bounds these strings by Unicode characters, not UTF-8 bytes.
		if utf8.RuneCountInString(act.Target) > 1000 || utf8.RuneCountInString(act.Detail) > 16000 || act.MS != nil && *act.MS < 0 {
			return nil
		}
	}

	snapshotBytes := 0
	for _, ch := range trace.Changes {
		if ch.OldText != nil {
			if len(*ch.OldText) > 128*1024 {
				return nil
			}
			snapshotBytes += len(*ch.OldText)
		}
		if ch.NewText != nil {
			if len(*ch.NewText) > 128*1024 {
				return nil
			}
			snapshotBytes += len(*ch.NewText)
		}
		if snapshotBytes > 256*1024 {
			return nil
		}
		if utf8.RuneCountInString(ch.Path) > 1000 {
			return nil
		}
		switch ch.Kind {
		case "unavailable":
			if utf8.RuneCountInString(ch.Reason) > 1000 {
				return nil
			}
		case "diff":
			if utf8.RuneCountInString(ch.Diff) > 16000 || ch.Added < 0 || ch.Removed < 0 {
				return nil
			}
		default:
			return nil
		}
	}

	return &trace
}

// ToolCodePreview contains the latest bounded window of decoded source code.
type ToolCodePreview struct {
	Text   string `json:"text"`
	Offset int    `json:"offset"`
}

type ToolProgress struct {
	Code       *ToolCodePreview `json:"code,omitempty"`
	ToolCallID string           `json:"tool_call_id,omitempty"`
	CallID     string           `json:"call_id"`
	Name       string           `json:"name"`
	Phase      string           `json:"phase"` // "generating" | "running"
	Title      string           `json:"title,omitempty"`
}

const maxActiveToolProgress = 32

type EventType string

const (
	EventReset          EventType = "reset"
	EventRetry          EventType = "retry"
	EventText           EventType = "text"
	EventError          EventType = "error"
	EventInterrupted    EventType = "interrupted"
	EventMessage        EventType = "message"
	EventUser           EventType = "user"
	EventTurnMembership EventType = "turn_membership"
	EventTurnCompleted  EventType = "turn_completed"
	EventThinking       EventType = "thinking"
	EventNote           EventType = "note"
	EventCompacted      EventType = "compacted"
	EventToolProgress   EventType = "tool_progress"
	EventTool           EventType = "tool"
	EventUsage          EventType = "usage"
	// EventKernel carries the kernel's job facts after a change; EventGlances
	// carries the extension sidebars. A watching client needs no status read.
	EventKernel     EventType = "kernel"
	EventGlances    EventType = "glances"
	EventInvalidate EventType = "invalidate"
	// EventCommitted says transcript rows up to Seq now cover what was shown.
	EventCommitted    EventType = "committed"
	EventShellCommand EventType = "shell_command"
)

type Usage struct {
	SessionCostUSD     *float64 `json:"sessionCostUSD,omitempty"`
	Model              string   `json:"model,omitempty"`
	RecordedAt         *int64   `json:"recordedAt,omitempty"`
	PromptTokens       *int     `json:"promptTokens,omitempty"`
	CachedPromptTokens *int     `json:"cachedPromptTokens,omitempty"`
	CacheWriteTokens   *int     `json:"cacheWriteTokens,omitempty"`
	CompletionTokens   *int     `json:"completionTokens,omitempty"`
	TotalTokens        *int     `json:"totalTokens,omitempty"`
	ElapsedMs          *float64 `json:"elapsedMs,omitempty"`
	TokensPerSecond    *float64 `json:"tokensPerSecond,omitempty"`
	// CacheMissTokens is how much of the previous call's cache this call read
	// uncached, when that was more than the provider's rounding explains.
	CacheMissTokens *int `json:"cacheMissTokens,omitempty"`
	// CacheDriftTokens is the same loss when albedo caused it: the call did not
	// repeat the history the previous call sent.
	CacheDriftTokens *int `json:"cacheDriftTokens,omitempty"`
	// Spent is the total cost of every call the session made, added up per
	// statement. The figure for one call stays in the request ledger.
	Spent *Cost `json:"spent,omitempty"`
	// CacheFade is how CachedPromptTokens fades once the session goes quiet,
	// in time order.
	CacheFade []CacheStep `json:"cacheFade,omitempty"`
}

// CacheStep says that from At (unix ms) on, a request would read Cached
// tokens from the provider's cache; nil when that is no longer known.
type CacheStep struct {
	Cached *int  `json:"cached,omitempty"`
	At     int64 `json:"at"`
}

type StreamEvent struct {
	MessageID       string
	ReplacesAllLive bool
	ReplacesLiveIDs []string
	EntryID         string
	Position        int64
	TurnType        string
	Speaker         string
	MailKind        string
	SenderSessionID string
	Invalidation    *ResourceInvalidation
	Status          *AgentStatus
	// Kernel is the kernel object a kernel event carried, and Glances the
	// sidebar values a glances event carried.
	Kernel        *protocol.Kernel
	Glances       []PageGlance
	Snapshot      *Session
	ShellCommand  *ShellCommand
	ShellCommands []ShellCommand
	Receipt       *InputReceipt
	OperationID   string
	Images        []ImageMetadata
	Usage         *Usage
	ToolTrace     *ToolTrace
	// Skill is the skill a user's slash activation loaded.
	Skill          *SkillLoad
	Timestamp      *int64
	ToolArgs       map[string]any
	Progress       *ToolProgress
	TurnID         string
	Type           EventType
	Text           string
	Source         string
	Summary        string
	Strategy       string
	ToolName       string
	ToolResult     string
	ToolStatus     string
	ToolTitle      string
	ProgressCallID string
	SubmissionIDs  []string
	Evicted        int
	// ElapsedMs is how long a replayed thought took, when the daemon timed it.
	ElapsedMs       int64
	ElapsedObserved bool
	// Seq is the newest transcript row an EventCommitted covers.
	Seq      int64
	Sequence int64
	// Before and More describe the history a reset or page carried: Before is
	// its first row (the cursor for the next older page), More whether one exists.
	Before int64
	More   bool
	// Reason is the failure code or the reason a reset replaced the history:
	// initial, generation_changed, replay_unavailable, or recovery.
	Reason string
	// Replayed marks an event from the transcript snapshot that follows a
	// reset: history, which says nothing about what the session does now.
	Replayed       bool
	SnapshotOrigin bool
}

type ResourceInvalidation struct {
	Session, Settings, Catalog, Context, Extension bool
}

// decodeToolProgress validates the normalized progress object before delivery.
// A null value clears the current live progress.
func decodeToolProgress(raw json.RawMessage) (*ToolProgress, error) {
	if string(raw) == "null" {
		return nil, nil
	}
	if len(raw) > 8192 {
		return nil, errors.New("tool progress exceeds 8 KiB")
	}
	var wire protocol.ToolProgress
	if err := decodeRequired(raw, &wire); err != nil {
		return nil, err
	}
	return validateToolProgress(wire)
}

func validateToolProgress(wire protocol.ToolProgress) (*ToolProgress, error) {
	if wire.CallID == "" || wire.Name == "" || len(wire.Name) > 100 || (wire.Phase != "generating" && wire.Phase != "running") {
		return nil, fieldError("tool progress")
	}
	if wire.Title != nil && (utf8.RuneCountInString(*wire.Title) > 160 || len(*wire.Title) > 400) {
		return nil, fieldError("tool progress title")
	}
	preview := value(wire.Preview)
	if preview.OffsetScalars < 0 || utf8.RuneCountInString(preview.Text) > 512 || len(preview.Text) > 2048 {
		return nil, fieldError("tool progress preview")
	}
	return progressValue(wire), nil
}
func progressValue(wire protocol.ToolProgress) *ToolProgress {
	progress := &ToolProgress{CallID: wire.CallID, ToolCallID: value(wire.ToolCallID), Name: wire.Name, Phase: wire.Phase, Title: value(wire.Title)}
	preview := value(wire.Preview)
	if preview.Text != "" || preview.OffsetScalars > 0 {
		progress.Code = &ToolCodePreview{Text: preview.Text, Offset: int(preview.OffsetScalars)}
	}
	return progress
}

// Cost is the amount a provider reported for one call: Usd, and the statement
// that the amount belongs to. The daemon derives both values, so all clients
// show the same amount for the same reason.
type Cost struct {
	Usd   float64 `json:"usd"`
	Basis string  `json:"basis"`
}

// The statements an amount can belong to: money charged, a plan allowance
// drawn down, or the list price of a call that cost nothing.
const (
	BasisCharged = "charged"
	BasisCounted = "counted"
	BasisListed  = "listed"
)

// FormatCharge writes an amount in the smallest form that keeps its meaning.
// From one dollar up it shows two decimals, from one cent up three decimals,
// and from a ten-thousandth of a dollar up four. An amount below that shows as
// "<$0.0001", so a small amount never shows as $0.00.
func FormatCharge(usd float64) string {
	switch {
	case usd >= 1:
		return fmt.Sprintf("$%.2f", usd)
	case usd >= 0.01:
		return fmt.Sprintf("$%.3f", usd)
	case usd >= 0.0001:
		return fmt.Sprintf("$%.4f", usd)
	case usd > 0:
		return "<$0.0001"
	default:
		return "$0"
	}
}

func costValue(wire *protocol.Cost) *Cost {
	if wire == nil {
		return nil
	}
	return &Cost{Usd: wire.Usd, Basis: wire.Basis}
}

func usageValue(wire protocol.Usage) *Usage {
	usage := &Usage{SessionCostUSD: wire.SessionCostUsd, Model: value(wire.Model), PromptTokens: intPointer(wire.PromptTokens), CachedPromptTokens: intPointer(wire.CachedPromptTokens), CacheWriteTokens: intPointer(wire.CacheWriteTokens), CompletionTokens: intPointer(wire.CompletionTokens), TotalTokens: intPointer(wire.TotalTokens), ElapsedMs: wire.ElapsedMs, TokensPerSecond: wire.TokensPerSecond, CacheMissTokens: intPointer(wire.CacheMissTokens), CacheDriftTokens: intPointer(wire.CacheDriftTokens), Spent: costValue(wire.Spent)}
	if wire.ObservedAt != nil {
		usage.RecordedAt = timestampMilliseconds(*wire.ObservedAt)
	}
	for _, step := range wire.CacheFade {
		if at := timestampMilliseconds(step.At); at != nil {
			usage.CacheFade = append(usage.CacheFade, CacheStep{At: *at, Cached: intPointer(step.CachedTokens)})
		}
	}
	return usage
}
