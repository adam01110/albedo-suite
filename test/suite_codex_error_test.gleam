// Error envelope variants are wire-parser regressions, independent of daemon lifecycle.
import albedo/openai_api/responses
import albedo/openai_api/types
import gleam/io
import gleam/list
import gleam/string

pub fn main() -> Nil {
  list.each(
    [
      #("{\"type\":\"error\",\"message\":\"capacity\"}", "capacity"),
      #(
        "{\"type\":\"error\",\"error\":{\"message\":\"quota exceeded\",\"code\":\"usage_limit_reached\"}}",
        "quota exceeded",
      ),
      #(
        "{\"type\":\"error\",\"message\":null,\"error\":{\"message\":\"nested\"}}",
        "nested",
      ),
      #(
        "{\"type\":\"error\",\"message\":\"flat\",\"error\":{\"message\":\"nested\"}}",
        "flat",
      ),
      #(
        "{\"type\":\"error\",\"error\":\"upstream unavailable\"}",
        "upstream unavailable",
      ),
      #(
        "{\"type\":\"error\",\"error\":{\"code\":\"usage_limit_reached\"}}",
        "usage_limit_reached",
      ),
      #("{\"type\":\"error\",\"code\":\"server_error\"}", "server_error"),
      #(
        "{\"type\":\"response.failed\",\"response\":{\"error\":{\"message\":\"failed\"}}}",
        "failed",
      ),
    ],
    fn(entry) {
      assert responses.feed(responses.new(), entry.0)
        == Error(types.ProviderError(entry.1))
    },
  )
  list.each(
    [
      "{\"type\":\"error\"}",
      "{\"type\":\"error\",\"message\":42,\"error\":{\"message\":false,\"code\":null}}",
    ],
    fn(data) {
      let assert Error(types.ProviderError(message)) =
        responses.feed(responses.new(), data)
      assert string.starts_with(message, "malformed error:")
      assert !string.contains(message, data)
    },
  )
  io.println("Codex error decoding: 10 cases passed")
}
