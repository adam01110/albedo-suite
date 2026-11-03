-module(albedo_zed_budget).
-export([read/0, decode/1]).

-define(URL, <<"https://cloud.zed.dev/frontend/billing/usage">>).
-define(PATH, <<"/frontend/billing/usage">>).
-define(CAP, 65536).

read() ->
    Result = case os:getenv("ZED_BILLING_SESSION") of
        false -> unavailable(<<"unconfigured">>, <<"Set ZED_BILLING_SESSION in the daemon environment to the zed.session cookie value, not an inference token">>);
        "" -> unavailable(<<"unconfigured">>, <<"Set ZED_BILLING_SESSION in the daemon environment to the zed.session cookie value, not an inference token">>);
        Text ->
            Cookie = unicode:characters_to_binary(Text),
            case valid_cookie(Cookie) of
                true -> cached(Cookie);
                false -> unavailable(<<"invalid_configuration">>, <<"ZED_BILLING_SESSION must contain only the zed.session cookie value (no Cookie header, whitespace or separators)">>)
            end
    end,
    iolist_to_binary(json:encode(Result)).

valid_cookie(Cookie) ->
    byte_size(Cookie) > 0 andalso byte_size(Cookie) =< 8192 andalso
    string:prefix(Cookie, <<"zed.session=">>) =:= nomatch andalso
    lists:all(fun(C) -> C >= 33 andalso C =< 126 andalso
        not lists:member(C, [$;, $,, $", 92]) end, binary_to_list(Cookie)).

%% One sanitized memory-only slot, keyed by credential hash, never a profile.
cached(Cookie) ->
    case albedo_lock:trans(?MODULE, fun() ->
        Key = crypto:hash(sha256, Cookie),
        Now = erlang:monotonic_time(second),
        case persistent_term:get(?MODULE, none) of
            {Key, Until, Value} when Until > Now -> Value;
            _ ->
                Value = bounded_fetch(Cookie),
                TTL = case maps:get(<<"status">>, Value) of
                    <<"unavailable">> -> 15;
                    <<"expired">> -> 15;
                    <<"schema_error">> -> 15;
                    _ -> 60
                end,
                persistent_term:put(?MODULE, {Key, Now + TTL, Value}),
                Value
        end
    end, 12000) of
        {ok, Value} -> Value;
        busy -> unavailable(<<"unavailable">>, <<"Zed budget request is busy; retry later">>)
    end.

%% The dedicated connection dies with its owner if the whole-call deadline wins.
bounded_fetch(Cookie) ->
    {Pid, Ref} = spawn_monitor(fun() ->
        Value = try fetch(Cookie) catch _:_ -> network_error() end,
        exit({budget, Value})
    end),
    receive
        {'DOWN', Ref, process, Pid, {budget, Value}} -> Value;
        {'DOWN', Ref, process, Pid, _} -> network_error()
    after 10000 ->
        exit(Pid, kill),
        receive {'DOWN', Ref, process, Pid, _} -> ok end,
        unavailable(<<"unavailable">>, <<"Zed budget request timed out">>)
    end.

fetch(Cookie) ->
    {ok, _} = application:ensure_all_started(hackney),
    Options = [{pool, false}, {follow_redirect, false}, {connect_timeout, 3000},
        {recv_timeout, 5000}, {send_timeout, 5000},
        {ssl_options, albedo_http:tls_options("cloud.zed.dev")}],
    case hackney:connect(?URL, Options) of
        {ok, Connection} ->
            try
                Headers = [{<<"cookie">>, <<"zed.session=", Cookie/binary>>},
                    {<<"accept">>, <<"application/json">>}, {<<"accept-encoding">>, <<"identity">>}],
                %% send_request does not follow redirects; no inference endpoint is read.
                case hackney:send_request(Connection, {get, ?PATH, Headers, <<>>}) of
                    {ok, 200, _, Connection} -> body(Connection, [], 0);
                    {ok, Status, _, Connection} -> status_error(Status);
                    _ -> network_error()
                end
            after hackney:close(Connection) end;
        _ -> network_error()
    end.

body(Connection, Acc, Size) ->
    case hackney:stream_body(Connection) of
        {ok, Chunk} when byte_size(Chunk) + Size =< ?CAP ->
            body(Connection, [Chunk | Acc], Size + byte_size(Chunk));
        {ok, _} -> unavailable(<<"schema_error">>, <<"Zed billing response exceeds 64 KiB">>);
        done -> decode(iolist_to_binary(lists:reverse(Acc)));
        _ -> network_error()
    end.

status_error(Status) when Status =:= 401; Status =:= 403 ->
    unavailable(<<"expired">>, <<"Zed billing session was rejected or expired; supply a fresh zed.session cookie value">>);
status_error(Status) when Status >= 300, Status < 400 ->
    unavailable(<<"unavailable">>, <<"Zed billing redirected; redirects are not followed. The session may have expired">>);
status_error(_) -> unavailable(<<"unavailable">>, <<"Zed billing is unavailable; retry later">>).

network_error() -> unavailable(<<"unavailable">>, <<"Could not reach Zed billing securely">>).

base() -> #{
    <<"source">> => <<"Zed browser billing session (ZED_BILLING_SESSION)">>,
    <<"scope">> => <<"Hosted model token spend only; edit predictions are separate">>,
    <<"account_association">> => <<"Unverified: browser billing identity is not linked to any inference profile or selected account">>,
    <<"currency">> => <<"USD">>,
    <<"reset">> => <<"Unknown; not reported by this integration">>
}.

unavailable(Status, Message) -> (base())#{<<"status">> => Status, <<"message">> => Message}.

decode(Body) when is_binary(Body), byte_size(Body) =< ?CAP ->
    try json:decode(Body) of
        #{<<"current_usage">> := #{<<"token_spend">> := Spend}} when is_map(Spend) ->
            case {amount(Spend, <<"spend_in_cents">>), amount(Spend, <<"limit_in_cents">>)} of
                {invalid, _} -> schema_error();
                {_, invalid} -> schema_error();
                {Used, Limit} -> budget(Used, Limit)
            end;
        _ -> schema_error()
    catch _:_ -> schema_error() end;
decode(_) -> schema_error().

schema_error() -> unavailable(<<"schema_error">>, <<"Zed billing returned an unsupported budget schema; no budget is inferred">>).

amount(Map, Key) ->
    case maps:get(Key, Map, null) of
        null -> null;
        N when is_number(N), N >= 0, N =< 9007199254740991 -> N;
        _ -> invalid
    end.

budget(Used, Limit) ->
    Remaining = case {Used, Limit} of
        {null, _} -> null;
        {_, null} -> null;
        _ -> Limit - Used
    end,
    Status = case Remaining of
        null -> <<"unknown">>;
        N when N < 0 -> <<"over_limit">>;
        _ -> <<"available">>
    end,
    (base())#{<<"status">> => Status,
        <<"spend_in_cents">> => Used, <<"limit_in_cents">> => Limit,
        <<"remaining_in_cents">> => Remaining,
        <<"spend">> => dollars(Used), <<"limit">> => dollars(Limit),
        <<"remaining">> => dollars(Remaining),
        <<"observed_at_unix_seconds">> => erlang:system_time(second)}.

dollars(null) -> <<"Unknown">>;
dollars(N) when is_integer(N) ->
    Sign = case N < 0 of true -> <<"-">>; false -> <<>> end,
    Abs = abs(N),
    iolist_to_binary(io_lib:format("~sUSD ~B.~2..0B", [Sign, Abs div 100, Abs rem 100]));
dollars(N) -> iolist_to_binary(io_lib:format("USD ~.2f", [N / 100])).
