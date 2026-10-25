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
	for _, line := range strings.Split(content, "\n") {
		next := fenceAfter(fence, line)
		if fence != "" || next != "" {
			out.WriteString(line + "\n")
			fence = next
			continue
		}
		trimmed := strings.TrimSpace(line)
		switch {
		case strings.HasPrefix(trimmed, "<") && strings.HasSuffix(trimmed, ">"):
			// Keep wrapper tags visible; Markdown otherwise treats them as HTML.
			out.WriteString("\n" + contextCode(line, "text") + "\n")
		default:
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
	}
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
