-module(albedo_mcp_credentials).
-export([server/1]).

server(_) ->
    ets:update_counter(lazy_mcp_test, credentials, 1),
    {ok, #{}}.
