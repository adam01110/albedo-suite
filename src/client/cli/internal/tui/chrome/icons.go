package chrome

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"

	"github.com/charmbracelet/x/ansi"
)

// Icons are the marks screens draw beside rows, calls, hosts and agents
// (albedo-suite). Each is one terminal cell wide, because the layouts
// around them count it as one. Box drawing, arrows in key hints, bars and
// ellipses are structure, not icons, and stay fixed.
type Icons struct {
	Brand     string `json:"brand"`
	Prompt    string `json:"prompt"`
	Selection string `json:"selection"`

	NewSession string `json:"newSession"`
	Settings   string `json:"settings"`
	Archive    string `json:"archive"`
	Accounts   string `json:"accounts"`

	Item         string `json:"item"`
	ItemSelected string `json:"itemSelected"`
	ItemActive   string `json:"itemActive"`
	ItemEditing  string `json:"itemEditing"`
	ItemPinned   string `json:"itemPinned"`
	ItemMoved    string `json:"itemMoved"`

	CallSucceeded string `json:"callSucceeded"`
	CallFailed    string `json:"callFailed"`
	CallPending   string `json:"callPending"`

	HostConnected  string `json:"hostConnected"`
	HostConnecting string `json:"hostConnecting"`
	HostLost       string `json:"hostLost"`
	Bookmark       string `json:"bookmark"`
	Branch         string `json:"branch"`

	AgentYou     string `json:"agentYou"`
	AgentRunning string `json:"agentRunning"`
	AgentPulse   string `json:"agentPulse"`
	AgentDone    string `json:"agentDone"`
	AgentIdle    string `json:"agentIdle"`
	AgentPeer    string `json:"agentPeer"`
}

// DefaultIcons are upstream's marks.
var DefaultIcons = Icons{
	Brand: "✦", Prompt: "›", Selection: "▌",
	NewSession: "✦", Settings: "◇", Archive: "▤", Accounts: "◇",
	Item: "·", ItemSelected: "◆", ItemActive: "●", ItemEditing: "✎", ItemPinned: "★", ItemMoved: "↗",
	CallSucceeded: "✓", CallFailed: "✗", CallPending: "·",
	HostConnected: "●", HostConnecting: "◌", HostLost: "○", Bookmark: "⚑", Branch: "⎇",
	AgentYou: "◆", AgentRunning: "●", AgentPulse: "◉", AgentDone: "✓", AgentIdle: "○", AgentPeer: "◇",
}

// Icon is the set in use.
var Icon = DefaultIcons

// UseIcons draws every screen with icons.
func UseIcons(icons Icons) {
	Icon = icons
	PromptMark = icons.Prompt + " "
}

// loadIcons reads $ALBEDO_ICONS_FILE, else the config directory's
// albedo/icons.json when it exists, over the defaults.
func loadIcons() error {
	path := os.Getenv("ALBEDO_ICONS_FILE")
	explicit := path != ""
	if !explicit {
		dir, err := os.UserConfigDir()
		if err != nil {
			return nil
		}
		path = filepath.Join(dir, "albedo", "icons.json")
	}
	data, err := os.ReadFile(path)
	if !explicit && errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("read Albedo icons %s: %w", path, err)
	}
	icons, err := parseIcons(data)
	if err != nil {
		return fmt.Errorf("Albedo icons %s: %w", path, err)
	}
	UseIcons(icons)
	return nil
}

// parseIcons overrides the defaults with a JSON object of named icons.
// Unknown names are refused so a misspelt one does not pass silently.
func parseIcons(data []byte) (Icons, error) {
	icons := DefaultIcons
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&icons); err != nil {
		return icons, err
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		return icons, errors.New("expected one JSON object")
	}
	v, t := reflect.ValueOf(icons), reflect.TypeOf(icons)
	for i := range t.NumField() {
		value := v.Field(i).String()
		if ansi.Strip(value) != value || ansi.StringWidth(value) != 1 {
			return icons, fmt.Errorf("%s must be one terminal cell wide, got %q", t.Field(i).Tag.Get("json"), value)
		}
	}
	return icons, nil
}
