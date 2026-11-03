-module(hackney).
-export([connect/2, send_request/2, stream_body/1, close/1]).

connect(Url, Options) ->
    persistent_term:put(budget_calls, persistent_term:get(budget_calls, 0) + 1),
    persistent_term:put(budget_connection, {Url, Options}),
    case persistent_term:get(budget_fixture) of
        network_error -> {error, fixture_failure};
        _ -> {ok, self()}
    end.

send_request(Connection, Request) ->
    persistent_term:put(budget_request, Request),
    {Status, Chunks} = persistent_term:get(budget_fixture),
    put(chunks, Chunks),
    Headers = case Status of
        302 -> [{<<"location">>, <<"https://credential-sink.invalid/billing">>}];
        _ -> []
    end,
    {ok, Status, Headers, Connection}.

stream_body(_) ->
    persistent_term:put(budget_body_reads, persistent_term:get(budget_body_reads, 0) + 1),
    case get(chunks) of
        [wait | _] -> receive after 20000 -> done end;
        [Head | Tail] -> put(chunks, Tail), {ok, Head};
        [] -> done
    end.

close(_) -> persistent_term:put(budget_closed, true), ok.
