import albedo/daemon/http_api as api
import albedo/harness/extension
import gleam/http.{Get}
import gleam/http/request
import gleam/http/response
import gleam/option.{None}
import mist

@external(erlang, "albedo_zed_budget", "read")
pub fn read() -> String

pub fn handle(
  _daemon: extension.Daemon,
  path: List(String),
  req: request.Request(BitArray),
  _live: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  case req.method, path, req.query {
    Get, ["budget"], None -> api.raw(200, read())
    _, ["budget"], _ ->
      api.fail(api.invalid("Zed budget accepts GET without query parameters"))
    _, _, _ -> api.fail(api.Failure(404, "not_found", "unknown Zed resource"))
  }
}
