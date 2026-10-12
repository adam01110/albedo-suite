# Inline image previews

Images returned to the agent by `show_image()`, browser screenshots and other
image-returning tools appear in their tool-result block, even with verbose tool
output hidden. Pasted attachments also keep an inline preview under the sent user
message after the composer clears, including after reopening the session. Each
block shows image dimensions and a compact inline preview.
Click **enlarge images** to expand it; click **show less** to restore its size.
Image rows are excluded from text selection and copying.

This initial version uses Kitty Unicode placeholders in Kitty and Ghostty,
including tmux with `set -g allow-passthrough on`. Other terminals retain image
metadata without receiving graphics escapes. Sixel is not implemented.
PNG and JPEG previews decode locally; WebP currently retains metadata only.

Only the latest 24 image resources are cached per session. Expanding an older
block prioritizes its images. Fetching is asynchronous and serial, with a
15-second timeout, a 5 MiB resource limit and a 16-megapixel decode limit.
Resizing invalidates cached placements; old resources are freed on eviction or
leaving the session. Live output and history replay use the same durable image
URLs, not local filesystem paths or base64 in transcript rows.

Previews show the original attachment or tool-returned image. Provider-specific
fitting can subsequently resize the image sent to the model; this UI does not
display a separate fitted version.

To try the build from this checkout without changing system configuration:

```console
nix run .#albedo-defaults
```

Live tool-result previews require the new daemon and client together. Sent
attachment previews and history previews work with the pinned upstream daemon.

Checks:

```console
go test ./internal/tui ./internal/daemon -run '^TestToolImages' -count=1 -v
```

Run the real-daemon case `tool_images_e2e_test.py` through
`scripts/test-e2e.py` with the pinned source and built package.
