import albedo_env
import albedo_ext_opencode_go/routing
import albedo_ext_opencode_go/wire
import gleam/io
import gleam/option
import gleeunit/should

const metadata_catalog =
  "{\"opencode-go\":{\"name\":\"OpenCode Go\",\"npm\":\"@ai-sdk/openai-compatible\",\"models\":{\"catalog-inherit\":{},\"catalog-openai\":{\"provider\":{\"npm\":\"@ai-sdk/openai\"}},\"catalog-anthropic\":{\"provider\":{\"npm\":\"@ai-sdk/anthropic\"}},\"catalog-google\":{\"provider\":{\"npm\":\"@ai-sdk/google\"}},\"catalog-unknown\":{\"provider\":{\"npm\":\"unknown-sdk\"}}}}}"

@external(erlang, "albedo_skills_test_support", "fixture")
fn fixture() -> #(String, String, String)

@external(erlang, "albedo_skills_test_support", "write")
fn write(base: String, relative: String, content: String) -> String

@external(erlang, "albedo_skills_test_support", "cleanup")
fn cleanup(root: String) -> Nil

/// A catalog entry for the model may inherit the provider's default SDK, but an
/// absent entry must keep the documented family routing instead.
fn catalog_route_test() -> Nil {
  let #(root, _, home) = fixture()
  let _ = write(home, "models.json", metadata_catalog)
  routing.metadata_route(home, "gpt-5.7-unlisted") |> should.equal("")
  routing.metadata_route(home, "claude-5-unlisted") |> should.equal("")
  routing.metadata_route(home, "gemini-5-unlisted") |> should.equal("")
  routing.metadata_route(home, "catalog-inherit")
  |> should.equal("chat_completions")
  routing.metadata_route(home, "catalog-openai") |> should.equal("responses")
  routing.metadata_route(home, "catalog-anthropic") |> should.equal("messages")
  routing.metadata_route(home, "catalog-google") |> should.equal("gemini")
  routing.metadata_route(home, "catalog-unknown") |> should.equal("")
  cleanup(root)

  let #(bare_root, _, bare_home) = fixture()
  routing.metadata_route(bare_home, "gpt-5.7-unlisted") |> should.equal("")
  cleanup(bare_root)
}

/// `wire.route` maps catalog metadata to its route and keeps the documented
/// family routing for a model the catalog does not name.
fn wire_route_test() -> Nil {
  let #(root, _, home) = fixture()
  let _ = write(home, "models.json", metadata_catalog)
  let previous = albedo_env.lookup("ALBEDO_HOME")
  albedo_env.set("ALBEDO_HOME", home)
  wire.route("catalog-inherit") |> should.equal(wire.ChatRoute)
  wire.route("catalog-openai") |> should.equal(wire.ResponsesRoute)
  wire.route("catalog-anthropic") |> should.equal(wire.MessagesRoute)
  wire.route("catalog-google") |> should.equal(wire.GeminiRoute)
  wire.route("gpt-5.7-unlisted") |> should.equal(wire.ResponsesRoute)
  wire.route("claude-5-unlisted") |> should.equal(wire.MessagesRoute)
  wire.route("gemini-5-unlisted") |> should.equal(wire.GeminiRoute)
  case previous {
    option.Some(previous) -> albedo_env.set("ALBEDO_HOME", previous)
    option.None -> albedo_env.unset("ALBEDO_HOME")
  }
  cleanup(root)
}

pub fn main() -> Nil {
  catalog_route_test()
  wire_route_test()
  io.println("OpenCode Go catalog and wire routes passed")
}
