// Error envelope variants are wire-parser regressions, independent of daemon lifecycle.
import albedo/openai_api/responses
import albedo_model as types
import albedo_model/cost
import gleam/io
import gleam/list
import gleam/option.{None}
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
      // Upstream's refusal decoder reads a nested error object first.
      #(
        "{\"type\":\"error\",\"message\":\"flat\",\"error\":{\"message\":\"nested\"}}",
        "nested",
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
      let assert Error(types.Refused(_, None, message)) =
        responses.feed(responses.new(cost.none), entry.0)
      assert message == entry.1
    },
  )
  list.each(
    [
      "{\"type\":\"error\"}",
      "{\"type\":\"error\",\"message\":42,\"error\":{\"message\":false,\"code\":null}}",
    ],
    fn(data) {
      let assert Error(types.Refused(_, None, message)) =
        responses.feed(responses.new(cost.none), data)
      assert string.starts_with(message, "malformed error:")
      assert !string.contains(message, data)
    },
  )
  io.println("Codex error decoding: 10 cases passed")
}
