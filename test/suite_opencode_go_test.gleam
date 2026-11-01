import gleam/io
import gleeunit/should
import harness/rotation_test

const metadata_catalog =
  "{\"opencode-go\":{\"name\":\"OpenCode Go\",\"npm\":\"@ai-sdk/openai-compatible\",\"models\":{\"catalog-inherit\":{},\"catalog-openai\":{\"provider\":{\"npm\":\"@ai-sdk/openai\"}},\"catalog-anthropic\":{\"provider\":{\"npm\":\"@ai-sdk/anthropic\"}},\"catalog-google\":{\"provider\":{\"npm\":\"@ai-sdk/google\"}},\"catalog-unknown\":{\"provider\":{\"npm\":\"unknown-sdk\"}}}}}"

@external(erlang, "albedo_opencode_go", "metadata_route")
fn metadata_route(home: String, model: String) -> String

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
  metadata_route(home, "gpt-5.7-unlisted") |> should.equal("")
  metadata_route(home, "claude-5-unlisted") |> should.equal("")
  metadata_route(home, "gemini-5-unlisted") |> should.equal("")
  metadata_route(home, "catalog-inherit") |> should.equal("chat_completions")
  metadata_route(home, "catalog-openai") |> should.equal("responses")
  metadata_route(home, "catalog-anthropic") |> should.equal("messages")
  metadata_route(home, "catalog-google") |> should.equal("gemini")
  metadata_route(home, "catalog-unknown") |> should.equal("")
  cleanup(root)

  let #(bare_root, _, bare_home) = fixture()
  metadata_route(bare_home, "gpt-5.7-unlisted") |> should.equal("")
  cleanup(bare_root)
}

pub fn main() -> Nil {
  rotation_test.opencode_go_rotates_and_sends_session_header_test()
  rotation_test.opencode_go_oauth_account_sends_org_header_test()
  rotation_test.opencode_go_dispatches_each_model_family_to_its_wire_route_test()
  catalog_route_test()
  io.println(
    "Native OpenCode Go rotation, OAuth, catalog routes and wire routes: 4 cases passed",
  )
}
