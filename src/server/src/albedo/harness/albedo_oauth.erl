-module(albedo_oauth).
-include_lib("kernel/include/file.hrl").
%% Browser OAuth sign-ins run by the daemon for its clients. One owner process
%% tracks the flows; each flow owns its loopback callback listener and ends by
%% storing the credential in creds.json's accounts under the provider's key.

-export([
    confirm/1,
    callback_issuer/0,
    parse_input/1,
    start_identified/5,
    get_identified/3,
    input_identified/5,
    cancel_identified/3
]).

-define(OWNER, albedo_oauth).
-define(FLOW_TIMEOUT_MS, 300000).
-define(CALL_MS, 60000).
-define(ISSUER, albedo_oauth_issuer).

%% Login is the Gleam oauth.Login record:
%% {login, Provider, Label, Detail, Kind, Store, {callback, Host, Port, Path, Fixed}, Authorize, Exchange, Account}
start_identified(Home, Id, Provider, Login, Intent) ->
    http_call({create_identified, Home, Id, Provider, Login, Intent}).
get_identified(Home, Id, Logins) -> http_call({get_identified, Home, Id, Logins}).
input_identified(Home, Id, Match, Text, Logins) ->
    http_call({input_identified, Home, Id, Match, Text, Logins}).
cancel_identified(Home, Id, Logins) -> http_call({cancel_identified, Home, Id, Logins}).

http_call(Message) ->
    case call(Message) of
        {error, Reason} when is_binary(Reason) ->
            {error,
                {503, <<"auth_unavailable">>,
                    <<"Provider sign-in service is unavailable: ", Reason/binary>>}};
        Reply ->
            Reply
    end.

call(Message) ->
    Owner = owner(),
    Ref = erlang:monitor(process, Owner),
    Owner ! {self(), Ref, Message},
    %% The owner serializes durable writes, so on a slow disk a request may
    %% queue behind them; the bound only keeps a stuck owner from hanging it.
    receive
        {Ref, Reply} ->
            erlang:demonitor(Ref, [flush]),
            Reply;
        {'DOWN', Ref, process, _, _} ->
            {error, <<"sign-in service stopped">>}
    after ?CALL_MS ->
        erlang:demonitor(Ref, [flush]),
        {error, <<"it did not answer within 60 s">>}
    end.

owner() ->
    case whereis(?OWNER) of
        undefined ->
            Pid = spawn(fun() -> owner_loop(#{}) end),
            try register(?OWNER, Pid) of
                true -> Pid
            catch
                error:badarg ->
                    exit(Pid, kill),
                    whereis(?OWNER)
            end;
        Pid ->
            Pid
    end.

%% ---- owner --------------------------------------------------------------

confirm(Identity) ->
    case get({?MODULE, flow}) of
        {Owner, Id} ->
            Ref = make_ref(),
            Owner ! {self(), Ref, {confirm_identity, Id, Identity}},
            receive
                {Ref, ok} ->
                    receive
                        {input, <<"confirm">>} -> {ok, nil}
                    after ?FLOW_TIMEOUT_MS -> {error, <<"Confirmation expired">>}
                    end;
                {Ref, error} ->
                    {error, <<"Sign-in ended">>}
            after ?CALL_MS -> {error, <<"Confirmation unavailable">>}
            end;
        _ ->
            {error, <<"Confirmation requires a sign-in flow">>}
    end.

owner_loop(Flows) ->
    receive
        {From, Ref, {confirm_identity, Id, Identity}} ->
            case maps:find(Id, Flows) of
                {ok, #{pid := From, home := Home, record := Record} = Flow} ->
                    NextRecord = Record#{
                        <<"state">> => <<"confirming">>,
                        <<"progress">> => bounded(Identity, 1024),
                        <<"instructions">> =>
                            <<"Verify this is your Zed account. Type confirm to save it, or cancel. Nothing is saved before confirmation.">>,
                        <<"confirmation_revision">> => token(16)
                    },
                    case
                        not terminal(Record) andalso
                            maps:get(<<"expires">>, Record) > erlang:system_time(millisecond)
                    of
                        true ->
                            case persisted(Home, Id, NextRecord) of
                                {ok, Stored} ->
                                    From ! {Ref, ok},
                                    owner_loop(Flows#{Id := Flow#{record := Stored}});
                                error ->
                                    From ! {Ref, error},
                                    owner_loop(Flows)
                            end;
                        false ->
                            From ! {Ref, error},
                            owner_loop(Flows)
                    end;
                _ ->
                    From ! {Ref, error},
                    owner_loop(Flows)
            end;
        {From, Ref, {create_identified, Home, Id, Provider, Login, Intent}} ->
            {Reply, Next} = http_guard(
                fun() -> create_identified(Home, Id, Provider, Login, Intent, Flows) end, Flows
            ),
            From ! {Ref, Reply},
            owner_loop(Next);
        {From, Ref, {get_identified, Home, Id, Logins}} ->
            {Reply, Next} = http_guard(
                fun() ->
                    {Flow, Current} = identified_flow(Home, Id, Logins, Flows),
                    {{ok, encode_login(Home, Flow, Logins)}, Current}
                end,
                Flows
            ),
            From ! {Ref, Reply},
            owner_loop(Next);
        {From, Ref, {input_identified, Home, Id, Match, Text, Logins}} ->
            {Reply, Next} = http_guard(
                fun() ->
                    {Flow, Current} = identified_flow(Home, Id, Logins, Flows),
                    Value = encode_login(Home, Flow, Logins),
                    ensure(
                        Match =/= <<>>, 428, <<"precondition_required">>, <<"If-Match is required">>
                    ),
                    ensure(
                        Match =:= albedo_http_api:etag(Value),
                        412,
                        <<"precondition_failed">>,
                        <<"login flow changed">>
                    ),
                    State = maps:get(<<"state">>, Flow),
                    Confirmation = State =:= <<"confirming">>,
                    ensure(
                        (State =:= <<"waiting">> andalso maps:get(<<"accept_input">>, Flow, true)) orelse
                            Confirmation,
                        409,
                        <<"login_not_waiting">>,
                        <<"login flow is not waiting for input">>
                    ),
                    #{Id := #{pid := Pid}} = Current,
                    case Confirmation of
                        true ->
                            ensure(
                                Text =:= <<"confirm">>,
                                400,
                                <<"confirmation_required">>,
                                <<"Type confirm to save this account">>
                            ),
                            Consumed = persist_flow(Home, Id, Flow#{<<"state">> => <<"exchanging">>}),
                            Active = maps:get(Id, Current),
                            Pid ! {input, Text},
                            {{ok, encode_login(Home, Consumed, Logins)}, Current#{
                                Id := Active#{record := Consumed, confirmed => true}
                            }};
                        false ->
                            Pid ! {input, Text},
                            {{ok, Value}, Current}
                    end
                end,
                Flows
            ),
            From ! {Ref, Reply},
            owner_loop(Next);
        {From, Ref, {cancel_identified, Home, Id, Logins}} ->
            {Reply, Next} = http_guard(
                fun() ->
                    {Flow, Current} = identified_flow(Home, Id, Logins, Flows),
                    case terminal(Flow) of
                        true ->
                            {{ok, encode_login(Home, Flow, Logins)}, Current};
                        false ->
                            Cancelled = finish(Flow#{
                                <<"state">> => <<"cancelled">>,
                                <<"progress">> => <<>>,
                                <<"failure">> => null
                            }),
                            persist_flow(Home, Id, Cancelled),
                            case maps:get(Id, Current, #{}) of
                                #{pid := Pid} -> exit(Pid, kill);
                                _ -> ok
                            end,
                            {{ok, encode_login(Home, Cancelled, Logins)}, maps:remove(Id, Current)}
                    end
                end,
                Flows
            ),
            From ! {Ref, Reply},
            owner_loop(Next);
        {From, Ref, {identified_store, Id, Home, Store, Credential, Account}} ->
            {Reply, Next} = http_guard(
                fun() -> store_identified(Id, Home, Store, Credential, Account, Flows) end, Flows
            ),
            From ! {Ref, Reply},
            owner_loop(Next);
        {From, Ref, {identified_terminal, Id, Status}} ->
            Next = update(Flows, Id, Status),
            Reply =
                case maps:find(Id, Next) of
                    {ok, #{record := Record}} ->
                        case terminal(Record) of
                            true -> {ok, nil};
                            false -> {error, storage_failed}
                        end;
                    error ->
                        {error, flow_ended}
                end,
            From ! {Ref, Reply},
            owner_loop(Next);
        {Id, update, Status} ->
            owner_loop(update(Flows, Id, Status));
        {expire_identified, Home, Id, Intent, Expires, Deadline} = Expiry ->
            case maps:find(Id, Flows) of
                {ok, #{
                    home := Home,
                    pid := Pid,
                    deadline := Deadline,
                    record := #{<<"intent">> := Intent, <<"expires">> := Expires}
                }} ->
                    Remaining = Deadline - erlang:monotonic_time(millisecond),
                    case Remaining > 0 of
                        true ->
                            %% The monotonic budget already includes clock scaling.
                            erlang:send_after(Remaining, self(), Expiry),
                            owner_loop(Flows);
                        false ->
                            exit(Pid, kill),
                            Removed = maps:remove(Id, Flows),
                            {_, Next} = http_guard(
                                fun() ->
                                    expire_record(Home, Id, Intent, Expires),
                                    {{ok, nil}, Removed}
                                end,
                                Removed
                            ),
                            owner_loop(Next)
                    end;
                _ ->
                    owner_loop(Flows)
            end;
        {forget, Id} ->
            owner_loop(maps:remove(Id, Flows));
        {'DOWN', _, process, Pid, _Reason} ->
            owner_loop(stopped(Flows, Pid));
        _ ->
            owner_loop(Flows)
    end.

update(Flows, Id, {State, _} = Status) ->
    case Flows of
        #{Id := #{home := Home, record := Record} = Flow} ->
            NextRecord =
                case State of
                    %% Completion and credential publish share one commit.
                    done ->
                        Record;
                    failed ->
                        log_failure(Record, element(2, Status)),
                        failed_record(Record, <<"Provider authorization failed.">>);
                    _ ->
                        Record#{
                            <<"state">> => atom_to_binary(State),
                            <<"progress">> => bounded(element(2, Status), 4096)
                        }
                end,
            case terminal(Record) of
                true ->
                    Flows;
                false ->
                    case persisted(Home, Id, NextRecord) of
                        {ok, Stored} ->
                            Flows#{Id := Flow#{record => Stored}};
                        error ->
                            exit(maps:get(pid, Flow), kill),
                            Flows
                    end
            end;
        _ ->
            Flows
    end.

%% ---- one flow -----------------------------------------------------------

watch_owner(Owner) ->
    Self = self(),
    spawn_link(fun() ->
        ParentRef = erlang:monitor(process, Owner),
        FlowRef = erlang:monitor(process, Self),
        receive
            {'DOWN', ParentRef, process, _, _} -> exit(Self, kill);
            {'DOWN', FlowRef, process, _, _} -> ok
        end
    end).

settle_fn(Owner, Id) ->
    fun
        ({Terminal, _} = Status) when Terminal =:= done; Terminal =:= failed ->
            %% Keep the flow alive until the owner has published its
            %% terminal fact. A read must not mistake mailbox delay for
            %% an expired or unexpectedly stopped sign-in.
            Ref = erlang:monitor(process, Owner),
            Owner ! {self(), Ref, {identified_terminal, Id, Status}},
            receive
                {Ref, Reply} ->
                    erlang:demonitor(Ref, [flush]),
                    Reply;
                {'DOWN', Ref, process, _, _} ->
                    {error, owner_stopped}
            end;
        (Status) ->
            Owner ! {Id, update, Status}
    end.

run_flow(Owner, Id, {login, _, _, _, _, Store, {device, Start}, _, _, Account}, Save) ->
    watch_owner(Owner),
    Settle = settle_fn(Owner, Id),
    put({?MODULE, flow}, {Owner, Id}),
    try Start() of
        {ok, {Url, Instructions, Complete}} ->
            Owner ! {Id, ready, Url, Instructions},
            Progress = fun(Text) ->
                Settle({waiting, Text}),
                nil
            end,
            try Complete(Progress) of
                {ok, Credential} ->
                    case Save(Store, Credential, Account) of
                        {ok, Label} -> Settle({done, Label});
                        {error, Reason} -> Settle({failed, Reason})
                    end;
                {error, Reason} ->
                    Settle({failed, Reason})
            catch
                Class:Reason ->
                    Settle(
                        {failed,
                            iolist_to_binary(
                                io_lib:format("sign-in failed: ~p:~p", [Class, Reason])
                            )}
                    )
            end;
        {error, Reason} ->
            Owner ! {Id, failed, Reason}
    catch
        Class:Reason ->
            Owner !
                {Id, failed,
                    iolist_to_binary(io_lib:format("sign-in failed: ~p:~p", [Class, Reason]))}
    end;
run_flow(
    Owner,
    Id,
    {login, Provider, _, _, _, Store, {callback, Host, Port, Path, Fixed}, Authorize, Exchange,
        Account},
    Save
) ->
    watch_owner(Owner),
    case listen(Port, Fixed) of
        {error, Reason} ->
            Owner !
                {Id, failed,
                    iolist_to_binary(
                        io_lib:format(
                            "could not listen for the ~s sign-in callback on 127.0.0.1:~B (~p)", [
                                Provider, Port, Reason
                            ]
                        )
                    )};
        {ok, Socket, Bound} ->
            State = token(16),
            Verifier = base64url(crypto:strong_rand_bytes(64)),
            Challenge = base64url(crypto:hash(sha256, Verifier)),
            Redirect = iolist_to_binary(["http://", Host, ":", integer_to_binary(Bound), Path]),
            Grant = {grant, Redirect, State, Verifier, Challenge},
            case Authorize(Grant) of
                {ok, Url} ->
                    callback_flow(
                        Owner, Id, Socket, Path, Grant, Url, Exchange, Store, Account, Save
                    );
                {error, Reason} ->
                    gen_tcp:close(Socket),
                    Owner ! {Id, refused, Reason}
            end
    end.

%% Waits for the browser's callback or a pasted code, then trades the code.
callback_flow(
    Owner, Id, Socket, Path, {grant, _, State, _, _} = Grant, Url, Exchange, Store, Account, Save
) ->
    Self = self(),
    spawn_link(fun() -> accept(Socket, Path, Self) end),
    Owner ! {Id, ready, Url},
    albedo_clock:send_after(?FLOW_TIMEOUT_MS, self(), timeout),
    Settle = settle_fn(Owner, Id),
    Outcome = wait(State),
    gen_tcp:close(Socket),
    case Outcome of
        {ok, Code} ->
            Settle({exchanging, <<"exchanging authorization code">>}),
            Progress = fun(Text) ->
                Settle({exchanging, Text}),
                nil
            end,
            try Exchange(Grant, Code, Progress) of
                {ok, Credential} ->
                    case Save(Store, Credential, Account) of
                        {ok, Label} -> Settle({done, Label});
                        {error, Reason} -> Settle({failed, Reason})
                    end;
                {error, Reason} ->
                    Settle({failed, Reason})
            catch
                Class:Reason ->
                    Settle(
                        {failed,
                            iolist_to_binary(
                                io_lib:format("sign-in failed: ~p:~p", [Class, Reason])
                            )}
                    )
            end;
        {error, Reason} ->
            Settle({failed, Reason})
    end.

listen(Port, Fixed) ->
    Options = [
        binary, {active, false}, {ip, {127, 0, 0, 1}}, {reuseaddr, true}, {packet, http_bin}
    ],
    Result =
        case gen_tcp:listen(Port, Options) of
            {error, eaddrinuse} when not Fixed -> gen_tcp:listen(0, Options);
            Other -> Other
        end,
    case Result of
        {ok, Socket} -> {ok, Socket, bound(Socket)};
        Error -> Error
    end.

bound(Socket) ->
    {ok, {_, Port}} = inet:sockname(Socket),
    Port.

%% The browser callback and a pasted code race; the first valid one wins.
wait(State) ->
    receive
        {callback, #{<<"error">> := Error} = Query} ->
            case maps:get(<<"state">>, Query, State) of
                State ->
                    {error,
                        <<"authorization failed: ",
                            (maps:get(<<"error_description">>, Query, Error))/binary>>};
                _ ->
                    wait(State)
            end;
        {callback, #{<<"code">> := <<_, _/binary>> = Code, <<"state">> := State} = Query} ->
            put(?ISSUER, maps:get(<<"iss">>, Query, none)),
            {ok, Code};
        {callback, _} ->
            wait(State);
        {input, Text} ->
            put(?ISSUER, input_issuer(Text)),
            case parse_input(Text) of
                {<<>>, _} -> {error, <<"missing authorization code">>};
                {Code, <<>>} -> {ok, Code};
                {Code, State} -> {ok, Code};
                {_, _} -> {error, <<"oauth state mismatch">>}
            end;
        timeout ->
            {error, <<"sign-in timed out waiting for the browser">>}
    end.

accept(Listen, Path, Flow) ->
    case gen_tcp:accept(Listen) of
        {ok, Socket} ->
            _ = serve(Socket, Path, Flow),
            gen_tcp:close(Socket),
            accept(Listen, Path, Flow);
        {error, _} ->
            ok
    end.

serve(Socket, Path, Flow) ->
    case gen_tcp:recv(Socket, 0, 10000) of
        {ok, {http_request, 'GET', {abs_path, Target}, _}} ->
            drain_headers(Socket),
            {RequestPath, Query} = split_target(Target),
            case RequestPath =:= iolist_to_binary(Path) of
                true ->
                    Flow ! {callback, Query},
                    page(
                        Socket,
                        200,
                        case Query of
                            #{<<"code">> := _} ->
                                <<"Authentication completed. You can close this window and return to albedo.">>;
                            _ ->
                                <<"Authentication failed. Return to albedo for details.">>
                        end
                    );
                false ->
                    page(Socket, 404, <<"Not found.">>)
            end;
        _ ->
            page(Socket, 400, <<"Bad request.">>)
    end.

drain_headers(Socket) ->
    case gen_tcp:recv(Socket, 0, 10000) of
        {ok, http_eoh} -> ok;
        {ok, _} -> drain_headers(Socket);
        _ -> ok
    end.

split_target(Target) ->
    case binary:split(Target, <<"?">>) of
        [P, Q] -> {P, maps:from_list(uri_string:dissect_query(Q))};
        [P] -> {P, #{}}
    end.

page(Socket, Status, Text) ->
    Body = <<"<!doctype html><meta charset=utf-8><title>albedo</title><p>", Text/binary, "</p>">>,
    gen_tcp:send(Socket, [
        <<"HTTP/1.1 ">>,
        integer_to_binary(Status),
        <<" OK\r\ncontent-type: text/html; charset=utf-8\r\ncontent-length: ">>,
        integer_to_binary(byte_size(Body)),
        <<"\r\nconnection: close\r\n\r\n">>,
        Body
    ]).

%% A pasted redirect url, `code#state`, a query string, or a bare code.
parse_input(Text0) ->
    Text = string:trim(unicode:characters_to_binary(Text0)),
    case uri_string:parse(Text) of
        #{scheme := _, host := _, query := Q} ->
            query_pair(Q);
        _ ->
            case binary:split(Text, <<"#">>) of
                [Code, State] ->
                    {Code, State};
                [_] ->
                    case binary:match(Text, <<"code=">>) of
                        nomatch -> {Text, <<>>};
                        _ -> query_pair(string:trim(Text, leading, "?#"))
                    end
            end
    end.

query_pair(Q) ->
    Query = maps:from_list(uri_string:dissect_query(Q)),
    {maps:get(<<"code">>, Query, <<>>), maps:get(<<"state">>, Query, <<>>)}.

%% The `iss` a pasted callback url or query string carries (RFC 9207), or none.
input_issuer(Text0) ->
    Text = string:trim(unicode:characters_to_binary(Text0)),
    Query =
        case uri_string:parse(Text) of
            #{scheme := _, host := _, query := Q} -> Q;
            _ -> string:trim(Text, leading, "?#")
        end,
    try
        maps:get(<<"iss">>, maps:from_list(uri_string:dissect_query(Query)), none)
    catch
        _:_ -> none
    end.

%% The `iss` the authorization response carried, for an `exchange` that
%% checks it (RFC 9207); none when it carried none. Exchange runs in the flow
%% process that received the response.
callback_issuer() ->
    case get(?ISSUER) of
        Issuer when is_binary(Issuer) -> {some, Issuer};
        _ -> none
    end.

id(Account, Credential) -> element(2, Account(Credential)).

%% ---- helpers ------------------------------------------------------------

token(Bytes) -> binary:encode_hex(crypto:strong_rand_bytes(Bytes), lowercase).

base64url(Bytes) -> base64:encode(Bytes, #{mode => urlsafe, padding => false}).

%% Identified HTTP flows store only metadata and a keyed intent digest. The
%% owner serializes admission, callback input, cancellation and completion.
http_guard(Run, Flows) ->
    try
        Run()
    catch
        throw:{http, Status, Code, Detail} ->
            {{error, {Status, Code, Detail}}, Flows};
        _:_ ->
            {
                {error,
                    {503, <<"auth_unavailable">>, <<"Provider sign-in storage is unavailable.">>}},
                Flows
            }
    end.

ensure(true, _, _, _) -> ok;
ensure(false, Status, Code, Detail) -> throw({http, Status, Code, Detail}).

locked(Home, Run) ->
    case
        albedo_settings_lock:with_lock(
            Home,
            fun() -> {ok, Run()} end,
            fun() -> {error, busy} end
        )
    of
        {ok, Value} ->
            Value;
        _ ->
            throw(
                {http, 503, <<"auth_unavailable">>, <<"Provider sign-in storage is unavailable.">>}
            )
    end.

records(Home) ->
    Path = filename:join(Home, <<"oauth-logins.json">>),
    case file:read_link_info(Path) of
        {error, enoent} ->
            #{};
        {ok, #file_info{type = regular, size = Size, mode = Mode}} when
            Size =< 2097152, Mode band 8#077 =:= 0
        ->
            {ok, Bytes} = file:read_file(Path),
            {ok, Value} = albedo_http_api:parse(Bytes),
            true = is_map(Value),
            Value;
        _ ->
            throw(
                {http, 503, <<"auth_unavailable">>, <<"Provider sign-in storage is unavailable.">>}
            )
    end.

write_records(Home, Records) ->
    albedo_settings_store:commit_group(Home, #{<<"oauth-logins.json">> => Records}).

persist_flow(Home, Id, Flow) ->
    locked(Home, fun() ->
        Records = records(Home),
        %% Recovery can publish a committed terminal record before a failed caller
        %% observes it. A late progress/DOWN notification cannot reverse that fact.
        case maps:find(Id, Records) of
            {ok, Stored} ->
                case terminal(Stored) of
                    true ->
                        Stored;
                    false ->
                        write_records(Home, Records#{Id => Flow}),
                        Flow
                end;
            error ->
                write_records(Home, Records#{Id => Flow}),
                Flow
        end
    end).

%% persist_flow's record, or error when the login file is unavailable.
persisted(Home, Id, Flow) ->
    try
        {ok, persist_flow(Home, Id, Flow)}
    catch
        _:_ -> error
    end.

terminal(Flow) ->
    lists:member(
        maps:get(<<"state">>, Flow),
        [<<"complete">>, <<"failed">>, <<"cancelled">>, <<"expired">>]
    ).

failed_record(Flow, Reason) ->
    Expired = maps:get(<<"expires">>, Flow) =< erlang:system_time(millisecond),
    finish(Flow#{
        <<"state">> =>
            case Expired of
                true -> <<"expired">>;
                false -> <<"failed">>
            end,
        <<"failure">> =>
            case Expired of
                true -> <<"Provider sign-in expired.">>;
                false -> Reason
            end,
        <<"progress">> => <<>>
    }).

finish(Flow) ->
    albedo_clock:send_after(900000, self(), {forget, maps:get(<<"id">>, Flow)}),
    Flow#{
        <<"terminal_at">> => erlang:system_time(millisecond),
        <<"retain_until">> => erlang:system_time(millisecond) + 900000
    }.

fresh_identity(Id) ->
    Now = erlang:system_time(millisecond),
    case albedo_operations:validate_id(Id, Now) of
        {ok, nil} ->
            ok;
        {error, <<"operation_expired">>} ->
            throw({http, 410, <<"identity_expired">>, <<"Login identity has expired.">>});
        _ ->
            throw(
                {http, 400, <<"identity_invalid">>, <<"Login identity must be a current UUIDv7.">>}
            )
    end,
    <<First:8/binary, "-", Second:4/binary, _/binary>> = Id,
    ensure(
        binary_to_integer(<<First/binary, Second/binary>>, 16) >= Now - 900000,
        410,
        <<"identity_expired">>,
        <<"Login identity has expired.">>
    ).

intent_key(Home) ->
    Path = filename:join(Home, <<".oauth-intent-key">>),
    case file:read_link_info(Path) of
        {error, enoent} ->
            Key = crypto:strong_rand_bytes(32),
            ok = albedo_credentials:write(Path, Key),
            {ok, Dir} = file:open(Home, [read, raw, directory]),
            try
                ok = file:sync(Dir)
            after
                file:close(Dir)
            end,
            Key;
        {ok, #file_info{type = regular, size = 32, mode = Mode}} when Mode band 8#077 =:= 0 ->
            {ok, Key} = file:read_file(Path),
            Key;
        _ ->
            throw(
                {http, 503, <<"auth_unavailable">>, <<"Provider sign-in storage is unavailable.">>}
            )
    end.

intent_digest(Home, Intent) ->
    binary:encode_hex(crypto:mac(hmac, sha256, intent_key(Home), Intent), lowercase).

prune_records(Records) ->
    Now = erlang:system_time(millisecond),
    maps:filter(
        fun(_, Flow) -> not terminal(Flow) orelse maps:get(<<"retain_until">>, Flow) > Now end,
        Records
    ).

create_identified(Home, Id, Provider, Login0, Intent, Flows) ->
    Decision = locked(Home, fun() ->
        All = records(Home),
        Current = prune_records(All),
        Digest = intent_digest(Home, Intent),
        case maps:find(Id, Current) of
            {ok, Flow} ->
                ensure(
                    maps:get(<<"intent">>, Flow) =:= Digest,
                    409,
                    <<"id_conflict">>,
                    <<"Login identity has another intent.">>
                ),
                {existing, Flow};
            error ->
                fresh_identity(Id),
                ensure(
                    not maps:is_key(Id, All),
                    410,
                    <<"identity_expired">>,
                    <<"Login identity has expired.">>
                ),
                ensure(
                    length([F || {_, F} <- maps:to_list(Current), not terminal(F)]) < 8,
                    429,
                    <<"login_capacity">>,
                    <<"Too many provider sign-ins are active.">>
                ),
                Login =
                    case Login0 of
                        {some, L} ->
                            L;
                        none ->
                            throw(
                                {http, 400, <<"provider_unknown">>, <<"Unknown sign-in provider.">>}
                            )
                    end,
                ensure(
                    element(2, Login) =:= Provider,
                    400,
                    <<"provider_unknown">>,
                    <<"Unknown sign-in provider.">>
                ),
                Timeout = albedo_clock:delay(?FLOW_TIMEOUT_MS),
                Deadline = erlang:monotonic_time(millisecond) + Timeout,
                Flow = #{
                    <<"id">> => Id,
                    <<"provider">> => Provider,
                    <<"intent">> => Digest,
                    <<"url">> => null,
                    <<"state">> => <<"waiting">>,
                    <<"progress">> => <<"Waiting for authorization.">>,
                    <<"instructions">> =>
                        <<"Paste the callback URL if the browser cannot reach the daemon.">>,
                    <<"expires">> => erlang:system_time(millisecond) + Timeout,
                    <<"accept_input">> =>
                        case element(7, Login) of
                            {device, _} -> false;
                            _ -> true
                        end,
                    <<"account_ids">> => [],
                    <<"failure">> => null
                },
                albedo_clock:send_after(
                    ?FLOW_TIMEOUT_MS,
                    self(),
                    {expire_identified, Home, Id, Digest, maps:get(<<"expires">>, Flow), Deadline}
                ),
                write_records(Home, Current#{Id => Flow}),
                {new, Flow, Login, Deadline}
        end
    end),
    case Decision of
        {existing, _} ->
            Logins =
                case Login0 of
                    {some, L} -> [L];
                    none -> []
                end,
            {Flow, Next} = identified_flow(Home, Id, Logins, Flows),
            {{ok, {false, encode_login(Home, Flow, Logins)}}, Next};
        {new, Flow, Login, Deadline} ->
            Owner = self(),
            Save = fun(Store, Credential, Account) ->
                owner_store(Owner, Id, Home, Store, Credential, Account)
            end,
            Pid = spawn(fun() -> run_flow(Owner, Id, Login, Save) end),
            erlang:monitor(process, Pid),
            Started =
                receive
                    {Id, ready, Url, Instructions} when is_binary(Instructions) ->
                        case is_binary(Url) andalso byte_size(Url) =< 4096 of
                            true ->
                                Flow#{
                                    <<"url">> => Url,
                                    <<"instructions">> => bounded(Instructions, 4096)
                                };
                            false ->
                                exit(Pid, kill),
                                failed_record(Flow, <<"Provider authorization URL is invalid.">>)
                        end;
                    {Id, ready, Url} ->
                        case is_binary(Url) andalso byte_size(Url) =< 4096 of
                            true ->
                                Flow#{<<"url">> => Url};
                            false ->
                                exit(Pid, kill),
                                failed_record(Flow, <<"Provider authorization URL is invalid.">>)
                        end;
                    {Id, refused, Reason} ->
                        finish(Flow#{
                            <<"state">> => <<"failed">>, <<"failure">> => bounded(Reason, 4096)
                        });
                    {Id, failed, Reason} ->
                        Failure =
                            case element(7, Login) of
                                {device, _} when is_binary(Reason), Reason =/= <<>> ->
                                    bounded(Reason, 4096);
                                _ ->
                                    <<"Could not open the provider callback listener.">>
                            end,
                        finish(Flow#{<<"state">> => <<"failed">>, <<"failure">> => Failure})
                after 10000 ->
                    exit(Pid, kill),
                    finish(Flow#{
                        <<"state">> => <<"failed">>,
                        <<"failure">> => <<"Provider sign-in did not start.">>
                    })
                end,
            Published =
                case persisted(Home, Id, Started) of
                    {ok, Stored} ->
                        Stored;
                    error ->
                        exit(Pid, kill),
                        throw(
                            {http, 503, <<"auth_unavailable">>,
                                <<"Provider sign-in storage is unavailable.">>}
                        )
                end,
            Next = Flows#{
                Id => #{home => Home, pid => Pid, record => Published, deadline => Deadline}
            },
            {{ok, {true, encode_login(Home, Published, [Login])}}, Next}
    end.

expire_record(Home, Id, Intent, Expires) ->
    locked(Home, fun() ->
        Records = records(Home),
        case maps:find(Id, Records) of
            {ok, #{<<"intent">> := Intent, <<"expires">> := Expires} = Stored} ->
                case terminal(Stored) of
                    true ->
                        ok;
                    false ->
                        Expired = finish(Stored#{
                            <<"state">> => <<"expired">>,
                            <<"failure">> => <<"Provider sign-in expired.">>,
                            <<"progress">> => <<>>
                        }),
                        write_records(Home, Records#{Id => Expired})
                end;
            _ ->
                ok
        end
    end).

identified_flow(Home, Id, _Logins, Flows) ->
    Flow = locked(Home, fun() ->
        All = records(Home),
        case maps:find(Id, All) of
            error ->
                fresh_identity(Id),
                throw({http, 404, <<"login_unknown">>, <<"Unknown provider sign-in.">>});
            {ok, Stored} ->
                case terminal(Stored) of
                    true ->
                        ensure(
                            maps:get(<<"retain_until">>, Stored) > erlang:system_time(millisecond),
                            410,
                            <<"identity_expired">>,
                            <<"Login identity has expired.">>
                        ),
                        Stored;
                    false ->
                        Next =
                            case maps:find(Id, Flows) of
                                {ok, #{home := Home, pid := Pid}} ->
                                    case
                                        maps:get(<<"expires">>, Stored) >
                                            erlang:system_time(millisecond)
                                    of
                                        false ->
                                            exit(Pid, kill),
                                            finish(Stored#{
                                                <<"state">> => <<"expired">>,
                                                <<"failure">> => <<"Provider sign-in expired.">>,
                                                <<"progress">> => <<>>
                                            });
                                        true ->
                                            case is_process_alive(Pid) of
                                                true ->
                                                    Stored;
                                                false ->
                                                    failed_record(
                                                        Stored, <<"Provider sign-in stopped.">>
                                                    )
                                            end
                                    end;
                                _ ->
                                    finish(Stored#{
                                        <<"state">> => <<"failed">>,
                                        <<"failure">> => <<"daemon_restarted">>,
                                        <<"progress">> => <<>>
                                    })
                            end,
                        case Next =:= Stored of
                            true -> ok;
                            false -> write_records(Home, All#{Id => Next})
                        end,
                        Next
                end
        end
    end),
    {Flow,
        case terminal(Flow) of
            true -> maps:remove(Id, Flows);
            false -> Flows
        end}.

owner_store(Owner, Id, Home, Store, Credential, Account) ->
    Ref = erlang:monitor(process, Owner),
    Owner ! {self(), Ref, {identified_store, Id, Home, Store, Credential, Account}},
    receive
        {Ref, {ok, Value}} ->
            erlang:demonitor(Ref, [flush]),
            {ok, Value};
        {Ref, {error, _}} ->
            erlang:demonitor(Ref, [flush]),
            {error, <<"Could not store provider account.">>};
        {'DOWN', Ref, process, _, _} ->
            {error, <<"Sign-in owner stopped.">>}
    after ?CALL_MS ->
        erlang:demonitor(Ref, [flush]),
        {error, <<"Provider account storage timed out.">>}
    end.

store_identified(Id, Home, Store, Credential0, Account, Flows) ->
    #{Id := #{home := Home} = Active} = Flows,
    Completed = locked(Home, fun() ->
        Records = records(Home),
        Flow = maps:get(Id, Records),
        ensure(
            not terminal(Flow) andalso
                maps:get(<<"expires">>, Flow) > erlang:system_time(millisecond),
            409,
            <<"login_ended">>,
            <<"Provider sign-in has ended.">>
        ),
        ensure(
            not maps:is_key(<<"confirmation_revision">>, Flow) orelse
                maps:get(confirmed, Active, false),
            409,
            <<"confirmation_required">>,
            <<"Account confirmation is required">>
        ),
        true = is_map(Credential0),
        RawId = id(Account, Credential0),
        true = is_binary(RawId) andalso byte_size(RawId) > 0,
        Creds = albedo_settings_store:read(Home, <<"creds.json">>),
        {PublicId, NextCreds} = stored_credential(
            Creds, Store, Credential0, Account, RawId, maps:get(<<"provider">>, Flow)
        ),
        Next = finish(Flow#{
            <<"state">> => <<"complete">>,
            <<"progress">> => <<>>,
            <<"failure">> => null,
            <<"account_ids">> => [PublicId]
        }),
        albedo_settings_store:commit_group(Home, #{
            <<"creds.json">> => NextCreds, <<"oauth-logins.json">> => Records#{Id => Next}
        }),
        Next
    end),
    {{ok, hd(maps:get(<<"account_ids">>, Completed))}, Flows#{Id := Active#{record => Completed}}}.

%% Creds with a signed-in credential in place, and the id it is known by.
stored_credential(Creds, <<"mcp:", Server/binary>> = Store, Credential, _, _, _) ->
    {Store, albedo_mcp_oauth:signed_in(Creds, Server, Credential)};
stored_credential(Creds, Store, Credential, Account, RawId, Provider) ->
    albedo_auth_accounts:signed_in(Creds, Store, Credential, Account, RawId, Provider).

stopped(Flows, Pid) ->
    maps:map(
        fun
            (Id, #{pid := P, home := Home, record := Record} = F) when P =:= Pid ->
                case terminal(Record) of
                    true ->
                        F;
                    false ->
                        Next = failed_record(Record, <<"Provider sign-in stopped.">>),
                        case persisted(Home, Id, Next) of
                            {ok, Stored} -> F#{record => Stored};
                            error -> F
                        end
                end;
            (_, F) ->
                F
        end,
        Flows
    ).

bounded(Text, Max) ->
    unicode:characters_to_binary(lists:sublist(unicode:characters_to_list(Text), Max)).

%% Kept out of the API, which only says the sign-in failed.
log_failure(Record, Reason) ->
    logger:warning(
        "provider sign-in ~ts (~ts) failed: ~tp",
        [maps:get(<<"id">>, Record, <<>>), maps:get(<<"provider">>, Record, <<>>), Reason]
    ).

failure_reason(#{<<"failure">> := Detail, <<"state">> := State}) when is_binary(Detail) ->
    #{<<"code">> => <<"sign_in_", State/binary>>, <<"detail">> => Detail};
failure_reason(_) ->
    null.

encode_login(Home, Flow, Logins) ->
    Accounts = locked(Home, fun() -> albedo_auth_accounts:account_projection(Home, Logins) end),
    Value = maps:with(
        [
            <<"id">>,
            <<"provider">>,
            <<"url">>,
            <<"state">>,
            <<"instructions">>,
            <<"progress">>,
            <<"confirmation_revision">>
        ],
        Flow
    ),
    iolist_to_binary(
        json:encode(Value#{
            <<"failure">> => failure_reason(Flow),
            <<"expires_at">> => albedo_http_api:timestamp(maps:get(<<"expires">>, Flow)),
            <<"accounts">> => [
                A
             || A <- Accounts,
                lists:member(maps:get(<<"id">>, A), maps:get(<<"account_ids">>, Flow))
            ]
        })
    ).
