//// The Zed callback property cases (test/albedo_zed_callback_prop.erl) check
//// the listener's decryption gate against the PKCS#1 v1.5 and OAEP-SHA256
//// formats it must accept or refuse.
import gleam/io

@external(erlang, "albedo_zed_callback_prop", "run")
fn native() -> Nil

pub fn main() {
  native()
  io.println("Zed callback properties passed")
}
