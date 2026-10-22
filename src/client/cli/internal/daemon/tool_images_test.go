package daemon

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"albedo/cli/internal/daemon/protocol"
)

func TestToolImagesReadAuthenticatedBoundedResource(t *testing.T) {
	for _, failure := range []string{"", "missing", "size", "oversized"} {
		t.Run(failure, func(t *testing.T) {
			conn := controlledConnection(t, func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/sessions/s/history/42/image-0" || r.Header.Get("Authorization") != "Bearer token" || r.Method != "GET" {
					t.Errorf("wrong image request: %s %s auth %q", r.Method, r.URL, r.Header.Get("Authorization"))
				}
				if failure == "missing" {
					http.Error(w, `{"code":"content_unknown"}`, http.StatusNotFound)
					return
				}
				if failure == "oversized" {
					_, _ = w.Write(bytes.Repeat([]byte{'x'}, MaxPreviewImageBytes+1))
					return
				}
				_, _ = w.Write([]byte("png"))
			})
			size := 3
			if failure == "size" {
				size = 4
			}
			data, err := NewChatClient(conn, "s").ReadImage(t.Context(), ImageMetadata{Bytes: size, Reference: "/sessions/s/history/42/image-0"})
			if failure != "" {
				if err == nil {
					t.Fatal("invalid image resource accepted")
				}
				return
			}
			if err != nil || string(data) != "png" {
				t.Fatalf("read image: %q %v", data, err)
			}
		})
	}
}

func TestToolImagesRejectForeignAndMalformedReferencesBeforeRequest(t *testing.T) {
	reads := 0
	conn := controlledConnection(t, func(w http.ResponseWriter, r *http.Request) { reads++; t.Errorf("unexpected read %s", r.URL) })
	for _, ref := range []string{"https://evil.test/x", "//evil.test/x", "/sessions/other/history/e/image-0", "/sessions/s/history/../image-0", "/sessions/s/history/e/result", "/sessions/s/history/e/image-0?x=1", "/sessions/s/history/e/image-0#x", "/sessions/s/history/e%2ff/image-0", "/sessions/s/history/e/image-0/extra"} {
		if _, err := NewChatClient(conn, "s").ReadImage(t.Context(), ImageMetadata{Bytes: 3, Reference: ref}); err == nil {
			t.Errorf("accepted %s", ref)
		}
	}
	for _, size := range []int{0, -1, MaxPreviewImageBytes + 1} {
		if _, err := NewChatClient(conn, "s").ReadImage(t.Context(), ImageMetadata{Bytes: size, Reference: "/sessions/s/history/e/image-0"}); err == nil {
			t.Errorf("accepted size %d", size)
		}
	}
	if reads != 0 {
		t.Fatal("invalid references fetched")
	}
}

func TestToolImagesSurviveLiveAndReplayMetadata(t *testing.T) {
	meta := `{"mime_type":"image/png","width":120,"height":80,"original_bytes":3,"reference":{"url":"/sessions/s/history/42/image-0","field":"image-0","bytes":3}}`
	live := `{"type":"tool","sequence":1,"data":{"entry_id":"42","images":[` + meta + `],"tool_call_id":"call","progress_call_id":"progress","name":"python","arguments":{"code":"show_image(data)"},"result":"attached image","trace":null,"content_complete":true,"reference":null}}`
	event, err := decodeChatEvent(json.RawMessage(live))
	if err != nil || event.EntryID != "42" || len(event.Images) != 1 || event.Images[0].Reference != "/sessions/s/history/42/image-0" {
		t.Fatalf("live metadata lost: %+v %v", event, err)
	}
	var entry protocol.HistoryEntry
	_ = json.Unmarshal([]byte(`{"id":"42","position":42,"kind":"tool_result","content":[{"kind":"image","image":`+meta+`},{"kind":"json","field":"result","value":"attached image"}],"tool":{"name":"python","tool_call_id":"call","progress_call_id":"progress"}}`), &entry)
	decoded, err := decodeHistoryEntries([]protocol.HistoryEntry{entry})
	if err != nil {
		t.Fatal(err)
	}
	replay, err := historyEntryEvents(decoded[0])
	if err != nil || len(replay) != 2 || len(replay[0].Images) != 1 || replay[0].Images[0] != event.Images[0] {
		t.Fatalf("replay metadata lost: %+v %v", replay, err)
	}
	legacy, err := decodeChatEvent(json.RawMessage(strings.ReplaceAll(strings.ReplaceAll(live, `"entry_id":"42",`, ""), `"images":[`+meta+`],`, "")))
	if err != nil || len(legacy.Images) != 0 {
		t.Fatalf("legacy daemon rejected: %v", err)
	}
}
