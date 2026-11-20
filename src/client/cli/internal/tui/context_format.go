package tui

import (
	"bytes"
	"encoding/json"
	"strings"
)

func formattedContextRows(content string, width int) []string {
	rendered := RenderMarkdownAnsi(contextMarkdown(content), max(1, width))
	return wrapContextContent(rendered, width)
}

// contextMarkdown adapts discovery catalogs without changing the request snapshot.
// Incomplete JSON at page boundaries stays literal rather than being repaired.
func contextMarkdown(content string) string {
	if pretty, ok := contextJSON(content); ok {
		return contextCode(pretty, "json")
	}
	var out strings.Builder
	var fence string
	// tags is a run of wrapper-tag lines, kept as one code block so a catalog
	// of tags reads as one listing rather than a frame per line
	// (albedo-suite). A line that leaves a tag's text open continues it.
	var tags []string
	flush := func() {
		if len(tags) > 0 {
			out.WriteString("\n" + contextCode(strings.Join(tags, "\n"), "text") + "\n")
			tags = nil
		}
	}
	for _, line := range strings.Split(content, "\n") {
		trimmed := strings.TrimSpace(line)
		open := len(tags) > 0 && trimmed != "" && !strings.HasSuffix(strings.TrimSpace(tags[len(tags)-1]), ">")
		if fence == "" && (open || strings.HasPrefix(trimmed, "<") && strings.Contains(trimmed, ">")) {
			tags = append(tags, line)
			continue
		}
		flush()
		next := fenceAfter(fence, line)
		if fence != "" || next != "" {
			out.WriteString(line + "\n")
			fence = next
			continue
		}
		if pretty, ok := contextJSON(line); ok {
			out.WriteString("\n" + contextCode(pretty, "json") + "\n")
			continue
		}
		out.WriteString(line)
		if trimmed != "" && line == strings.TrimLeft(line, " \t") {
			out.WriteString("  ")
		}
		out.WriteByte('\n')
		// Generated instructions put independent rules on long physical lines.
		// Separate those rules without splitting soft-wrapped Markdown prose.
		if len(line) > 160 && opensBlock(line) {
			out.WriteByte('\n')
		}
	}
	flush()
	return strings.TrimSuffix(out.String(), "\n")
}

func contextJSON(content string) (string, bool) {
	trimmed := strings.TrimSpace(content)
	if !strings.HasPrefix(trimmed, "{") && !strings.HasPrefix(trimmed, "[") {
		return "", false
	}
	var out bytes.Buffer
	if json.Indent(&out, []byte(trimmed), "", "  ") != nil {
		return "", false
	}
	return out.String(), true
}

func contextCode(content, language string) string {
	fence := "```"
	for strings.Contains(content, fence) {
		fence += "`"
	}
	return fence + language + "\n" + content + "\n" + fence + "\n"
}
