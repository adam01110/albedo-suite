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
      // Upstream's refusal decoder reads a nested message first, and a message
      // beats the suite's code fallback.
      #(
        "{\"type\":\"error\",\"message\":\"flat\",\"error\":{\"message\":\"nested\",\"code\":\"usage_limit_reached\"}}",
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
        "{\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"server_error\"}}}",
        "server_error",
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
  io.println("Codex error decoding passed")
}
