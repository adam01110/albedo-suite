-module('albedo@harness@extensions@mcp@client').
-export([start/3, pid/1, close/1, capabilities/1, description/1, list/4, request/4, request_with/5, on_change/2]).

start(Transport, _, Owner) ->
    ets:insert(lazy_mcp_test, {last_transport, Transport}),
    ets:update_counter(lazy_mcp_test, starts, 1),
    Client = spawn(fun() ->
        M = monitor(process, Owner),
        receive stop -> ok; {'DOWN', M, process, _, _} -> ok end
    end),
    ets:insert(lazy_mcp_test, {last_client, Client}),
    {ok, Client}.

close(Client) -> Client ! stop, ok.
pid(Client) -> Client.
capabilities(_) -> #{<<"tools">> => #{}}.
description(_) -> <<>>.
on_change(_, _) -> nil.

list(_, <<"tools/list">>, <<"tools">>, _) ->
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
    {ok, Tools};
list(_, _, _, _) -> {ok, []}.

request(Client, Method, Params, Timeout) -> request_with(Client, Method, Params, [], Timeout).

request_with(_, _, _, _, _) ->
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
