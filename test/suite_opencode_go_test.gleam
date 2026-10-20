import gleam/io
import harness/rotation_test

pub fn main() -> Nil {
  rotation_test.opencode_go_rotates_and_sends_session_header_test()
  rotation_test.opencode_go_oauth_account_sends_org_header_test()
  rotation_test.opencode_go_dispatches_each_model_family_to_its_wire_route_test()
  io.println(
    "Native OpenCode Go rotation, OAuth and wire routes: 3 cases passed",
  )
}
