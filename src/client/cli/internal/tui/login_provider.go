package tui

import (
	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	"cmp"
	"context"
	"slices"

	tea "charm.land/bubbletea/v2"
)

type customProvider struct {
	ID            string
	Label         string
	Detail        string
	Extension     string
	DefaultName   string
	DefaultURL    string
	FixedProtocol string
	// FixedAPI selects an extension-owned API without changing replay protocol.
	FixedAPI string
	// DefaultProtocol preselects a protocol the person can still change, for
	// a row that shares its extension with the generic OpenAI-compatible one.
	DefaultProtocol string
	// FixedEndpoint skips the base url: the extension knows where it sends.
	FixedEndpoint bool
	// Scoped asks for a cloud project and location instead of a base url and
	// api key: the extension signs in with credentials the daemon host holds.
	Scoped bool
	// Optional lets the base url and api key stay blank, so the extension
	// falls back to the daemon host's own environment.
	Optional bool
}

var customProviders = []customProvider{
	{
		ID:              "add-alibaba",
		Label:           "Alibaba",
		Detail:          "api key · token plan · Qwen, DeepSeek, GLM",
		Extension:       "openai",
		DefaultName:     "alibaba",
		DefaultURL:      "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1",
		DefaultProtocol: "chat_completions",
	},
	{
		ID:            "add-opencode-go",
		Label:         "OpenCode Go",
		Detail:        "api key · subscription · Qwen, GLM, Kimi, DeepSeek, MiMo",
		Extension:     "opencode-go",
		DefaultName:   "opencode-go",
		DefaultURL:    "https://opencode.ai/inference/go/v1",
		FixedProtocol: "chat_completions",
	},
	{
		ID:            "add-opencode-zen",
		Label:         "OpenCode Zen",
		Detail:        "pay per token · free models need no key",
		Extension:     "opencode-zen",
		DefaultName:   "opencode-zen",
		DefaultURL:    "https://opencode.ai/zen/v1",
		FixedProtocol: "chat_completions",
		Optional:      true,
	},
	{
		ID:            "add-zed",
		Label:         "Zed",
		Detail:        "subscription · Zed JWT",
		Extension:     "zed",
		DefaultName:   "zed",
		DefaultURL:    "https://cloud.zed.dev",
		FixedProtocol: "chat_completions",
		Optional:      true,
	},
	{
		ID:            "add-anthropic",
		Label:         "Anthropic",
		Detail:        "api key · console billing · Claude models",
		Extension:     "claude",
		DefaultName:   "anthropic",
		FixedProtocol: "chat_completions",
		FixedEndpoint: true,
	},
	{
		ID:            "add-bedrock",
		Label:         "Amazon Bedrock",
		Detail:        "aws credentials · Claude models",
		Extension:     "bedrock",
		DefaultName:   "bedrock",
		FixedProtocol: "chat_completions",
		Optional:      true,
	},
	{
		ID:            "add-bedrock-converse",
		Label:         "Amazon Bedrock Converse",
		Detail:        "aws credentials · Converse streaming · Bedrock models",
		Extension:     "bedrock",
		DefaultName:   "bedrock-converse",
		FixedProtocol: "chat_completions",
		FixedAPI:      "converse",
		Optional:      true,
	},
	{
		ID:            "add-vertex",
		Label:         "Google Vertex AI",
		Detail:        "application default credentials · Gemini models",
		Extension:     "vertex",
		DefaultName:   "vertex",
		FixedProtocol: "chat_completions",
		Scoped:        true,
	},
	{
		ID:              "add-ollama",
		Label:           "Ollama Cloud",
		Detail:          "api key · ollama.com cloud models",
		Extension:       "openai",
		DefaultName:     "ollama-cloud",
		DefaultURL:      "https://ollama.com/v1",
		DefaultProtocol: "chat_completions",
	},
	{
		ID:              "add-openrouter",
		Label:           "OpenRouter",
		Detail:          "api key · models from many providers",
		Extension:       "openai",
		DefaultName:     "openrouter",
		DefaultURL:      "https://openrouter.ai/api/v1",
		DefaultProtocol: "chat_completions",
	},
	{
		ID:         "add-openai",
		Label:      "OpenAI-compatible",
		Detail:     "your own base URL and api key",
		Extension:  "openai",
		DefaultURL: "https://api.openai.com/v1",
	},
}

// facts are what an add row's pane says: which extension it configures, where
// it sends by default, and what it will ask for.
func (p customProvider) facts() []loginFact {
	facts := []loginFact{{"extension", p.Extension}}
	switch {
	case p.DefaultURL != "":
		facts = append(facts, loginFact{"endpoint", p.DefaultURL})
	case p.FixedEndpoint:
		facts = append(facts, loginFact{"endpoint", "the extension's own"})
	}
	if p.FixedAPI != "" {
		facts = append(facts, loginFact{"api", p.FixedAPI})
	}
	if p.FixedProtocol != "" {
		facts = append(facts, loginFact{"protocol", p.FixedProtocol})
	}
	switch {
	case p.Scoped:
		facts = append(facts, loginFact{"auth", "application default credentials"}, loginFact{"asks for", "project and location"})
	case p.Optional:
		facts = append(facts, loginFact{"auth", "api key, or none"})
	default:
		facts = append(facts, loginFact{"auth", "api key"})
	}
	return facts
}

func customProviderByID(id string) (customProvider, bool) {
	for _, p := range customProviders {
		if p.ID == id {
			return p, true
		}
	}
	return customProvider{}, false
}

// custom finds the api-key provider by the draft's extension, the first row with
// it, since a draft does not remember which row began it. Rows that share an
// extension must agree on the flags read through here.
func (m LoginModel) custom() (customProvider, bool) {
	i := slices.IndexFunc(customProviders, func(p customProvider) bool { return p.Extension == m.Draft.Extension })
	if i < 0 {
		return customProvider{}, false
	}
	return customProviders[i], true
}

func (m LoginModel) optionalKey() bool {
	p, _ := m.custom()
	return p.Optional
}

func (m LoginModel) isFixedProtocol() bool {
	p, ok := m.custom()
	return ok && p.FixedProtocol != ""
}

// askEndpoint asks for the base url, or straight for the api key when the
// extension has a fixed endpoint.
func (m *LoginModel) askEndpoint() tea.Cmd {
	p, _ := m.custom()
	switch {
	case p.Scoped:
		return m.askProject()
	case p.FixedEndpoint:
		return m.askAPIKey()
	}
	m.Step = StepBaseURL
	m.TextInput.Placeholder = ""
	if p.Optional {
		m.TextInput.Placeholder = "blank: your AWS region"
	}
	return m.promptInput(m.Draft.BaseURL, false)
}

func (m *LoginModel) askAPIKey() tea.Cmd {
	m.Step = StepAPIKey
	m.TextInput.Placeholder = ""
	if p, _ := m.custom(); p.Optional {
		m.TextInput.Placeholder = "blank: your AWS credentials"
	}
	return m.promptInput("", true)
}

func (m *LoginModel) askProject() tea.Cmd {
	m.Step = StepProject
	m.TextInput.Placeholder = "blank: GOOGLE_VERTEX_PROJECT"
	return m.promptInput(deref(m.Draft.Project), false)
}

func (m *LoginModel) askLocation() tea.Cmd {
	m.Step = StepLocation
	m.TextInput.Placeholder = "blank: GOOGLE_VERTEX_LOCATION"
	return m.promptInput(deref(m.Draft.Location), false)
}

// optionalText is the pointer a profile stores for a field left blank or set.
func optionalText(value string) *string {
	if value == "" {
		return nil
	}
	return &value
}

func deref(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}

func (m *LoginModel) advanceToModels() tea.Cmd {
	m.Catalog = nil
	m.CatalogNote = ""
	m.Step = StepModels
	m.Generation = nextPageGeneration()
	return m.fetchCatalogCmd(m.Draft.Extension, m.Draft.BaseURL, m.Generation)
}

func (m *LoginModel) startCustomProvider(p customProvider) tea.Cmd {
	m.Name = p.DefaultName
	m.Draft = config.Settings{Extension: p.Extension, API: p.FixedAPI, BaseURL: p.DefaultURL, Protocol: cmp.Or(p.FixedProtocol, p.DefaultProtocol, "responses")}
	m.Step = StepName
	m.TextInput.Placeholder = p.DefaultName
	return m.promptInput("", false)
}

// useProfile re-selects a saved profile: a sign-in provider with no accounts
// left cannot run without an api key, so it signs in first.
func (m *LoginModel) useProfile(name string, settings config.Settings) tea.Cmd {
	if login, ok := m.signInFor(settings.Extension); ok && !hasKey(settings) && m.signedOut(settings.Extension) {
		m.Name, m.Draft = name, settings
		return m.startSignIn(login)
	}
	m.Step = StepSaving
	return m.saveProviderCmd(name, settings)
}

// applyHint routes a name given to `/login <name>`: a saved profile is chosen as
// it stands, a sign-in provider starts its sign-in, anything else is a new
// openai-compatible provider.
func (m *LoginModel) applyHint() tea.Cmd {
	hint := m.Hint
	m.Hint = ""
	name, err := config.ValidateProviderName(hint)
	if err != nil {
		m.Error = err.Error()
		m.Step = StepChoose
		return m.ChoosePicker.Init()
	}
	m.Name = name
	if saved, ok := m.Profiles.Providers[name]; ok {
		m.Draft = saved
		return m.useProfile(name, saved)
	}
	if login, ok := m.signInFor(name); ok {
		m.Draft = signInDraft(name)
		return m.startSignIn(login)
	}
	m.useNamedGoProvider(name)
	return m.askEndpoint()
}

func (m *LoginModel) useNamedGoProvider(name string) {
	if name != "opencode-go" || m.Draft.Extension != "openai" {
		return
	}
	p, _ := customProviderByID("add-opencode-go")
	m.Draft = config.Settings{Extension: p.Extension, BaseURL: p.DefaultURL, Protocol: p.FixedProtocol}
}

func (m *LoginModel) buildProtocolPicker() {
	items := []loginItem{
		{ID: "responses", Label: "responses", Detail: "OpenAI Responses API", note: "the newer API; the endpoint has to support it"},
		{ID: "chat_completions", Label: "chat completions", Detail: "widely supported by compatible endpoints", note: "the safe choice for a compatible endpoint"},
	}
	m.ProtocolPicker = newLoginPick("api protocol", items, m.Draft.Protocol, m.Width, m.Height)
}

func (m *LoginModel) buildModelPicker() {
	items := make([]loginItem, 0, len(m.Catalog)+1)
	for _, name := range m.Catalog {
		items = append(items, loginItem{ID: "model:" + name, Label: name, note: "from the models.dev catalog"})
	}
	items = append(items, loginItem{ID: "manual", Label: "enter a model ID manually", note: "type a model ID yourself"})
	m.ModelPicker = newLoginPick("model", items, "model:"+m.Draft.Model, m.Width, m.Height)
}

// hasKey reports a profile with an api key, entered now or held by the daemon.
func hasKey(settings config.Settings) bool {
	return settings.APIKey != "" || settings.HasKey
}

func (m LoginModel) fetchCatalogCmd(ext, endpoint string, gen int) tea.Cmd {
	return func() tea.Msg {
		note := ""
		if m.Conn == nil {
			return loginModelsLoadedMsg{Note: "Could not load the models.dev catalog. Enter a model ID manually.", Gen: gen}
		}
		models, err := daemon.ListModels(m.readCtx, m.Conn, ext, endpoint)
		names := make([]string, len(models))
		for i, model := range models {
			names[i] = model.ID
		}
		if err != nil {
			return loginModelsLoadedMsg{Err: err, Note: "Could not load the models.dev catalog. Enter a model ID manually.", Gen: gen}
		}
		if len(names) == 0 {
			note = "No matching models in models.dev. Enter a model ID manually."
		}
		return loginModelsLoadedMsg{Models: names, Note: note, Gen: gen}
	}
}

// saveProviderCmd saves the profile and optional key through the daemon and
// makes it the default, or, editing, saves it as it is and lists again.
func (m LoginModel) saveProviderCmd(name string, settings config.Settings) tea.Cmd {
	if m.Editing {
		return m.reloadCmd(func(ctx context.Context) error {
			validated, err := settings.Validate()
			if err != nil {
				return err
			}
			return daemon.SaveProvider(ctx, m.Conn, name, validated, m.Profiles.ETag)
		})
	}
	return func() tea.Msg {
		validated, err := settings.Validate()
		if err != nil {
			return providerSavedMsg{Gen: m.Generation, Name: name, Settings: settings, Err: err}
		}
		if validated.APIKey != "" && (validated.Extension == "openai" || validated.Extension == "opencode-go") {
			account, saveErr := daemon.PutKeyAccount(context.Background(), m.Conn, validated.Extension, validated.BaseURL, validated.APIKey, name)
			if saveErr != nil {
				return providerSavedMsg{Gen: m.Generation, Name: name, Settings: validated, Err: saveErr}
			}
			validated.AccountID = &account.ID
			validated.APIKey = ""
		}
		err = daemon.SaveAndSelectProvider(context.Background(), m.Conn, name, validated, m.Profiles.ETag)
		return providerSavedMsg{Gen: m.Generation, Name: name, Settings: validated, Err: err}
	}
}
