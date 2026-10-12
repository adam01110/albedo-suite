package daemon

import (
	"context"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"

	"albedo/cli/internal/daemon/protocol"
)

const MaxPreviewImageBytes = 5 * 1024 * 1024

var imageResourceField = regexp.MustCompile(`^image-[0-9]+$`)

// ReadImage reads only a durable image resource belonging to this session.
// Using the shared request path retains authentication, recovery and read limits.
func (c *ChatClient) ReadImage(ctx context.Context, image ImageMetadata) ([]byte, error) {
	parsed, err := url.Parse(image.Reference)
	if err != nil || parsed.IsAbs() || parsed.Host != "" || parsed.RawQuery != "" || parsed.Fragment != "" || parsed.RawPath != "" {
		return nil, fieldError("image reference")
	}
	prefix := "/sessions/" + url.PathEscape(c.agentID) + "/history/"
	if !strings.HasPrefix(parsed.Path, prefix) {
		return nil, fieldError("image session")
	}
	parts := strings.Split(strings.TrimPrefix(parsed.Path, prefix), "/")
	if len(parts) != 2 || parts[0] == "" || parts[0] == "." || parts[0] == ".." || !imageResourceField.MatchString(parts[1]) {
		return nil, fieldError("image resource")
	}
	if image.Bytes <= 0 || image.Bytes > MaxPreviewImageBytes {
		return nil, fieldError("image size")
	}
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	data, err := requestBytes(ctx, c.conn, operation{Name: "read tool image", Policy: readRecovery,
		Headers: http.Header{"Accept": {"image/png, image/jpeg, image/webp"}},
		BuildRequest: func(base string, _ io.Reader) (*http.Request, error) {
			return protocol.NewGetHistoryImageRequest(base, c.agentID, parts[0], parts[1])
		}}, responseLimits{successStatus: http.StatusOK, bodyBytes: MaxPreviewImageBytes, errorBytes: 64 * 1024})
	if err != nil {
		return nil, err
	}
	if len(data) != image.Bytes {
		return nil, fieldError("image byte count")
	}
	return data, nil
}
