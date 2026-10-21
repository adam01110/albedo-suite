-module(barrel_mcp_client).
-export([start/1, close/1, server_capabilities/1, list_tools/2, call_tool/4]).

start(_) ->
    ets:update_counter(lazy_mcp_test, starts, 1),
    Client = spawn(fun() -> receive stop -> ok end end),
    ets:insert(lazy_mcp_test, {last_client, Client}),
    {ok, Client}.

close(Client) -> Client ! stop, ok.
server_capabilities(_) -> {ok, #{}}.

list_tools(_, _) ->
    case ets:lookup(lazy_mcp_test, discovery_pause) of
        [{discovery_pause, Parent}] ->
            Parent ! {discovery_started, self()},
            receive resume_discovery -> ok after 5000 -> error(discovery_not_resumed) end;
        [] -> ok
    end,
    Count = ets:lookup_element(lazy_mcp_test, tools, 2),
    Tools = [#{
        <<"name">> => integer_to_binary(Index),
        <<"inputSchema">> => #{<<"type">> => <<"object">>}
    } || Index <- lists:seq(1, Count)],
    {ok, Tools, undefined}.

call_tool(_, _, _, _) ->
    ets:update_counter(lazy_mcp_test, calls, 1),
    case ets:lookup(lazy_mcp_test, call_pause) of
        [{call_pause, Parent}] ->
            Parent ! {call_started, self()},
            receive resume_call -> ok after 5000 -> error(call_not_resumed) end;
        [] -> ok
    end,
    case ets:lookup(lazy_mcp_test, fail_call) of
        [] -> {ok, #{}};
        _ -> {error, transport_lost}
    end.
