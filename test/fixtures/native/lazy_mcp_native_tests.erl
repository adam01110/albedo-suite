%% Run in an isolated Erlang VM with the suite test beams on its path:
%% erl -noshell -pa TEST_BEAMS -eval 'lazy_mcp_native_tests:run(), halt().'
%% These fakes exercise native lifecycle/state behavior; real stdio transport
%% coverage is separate. They must never be loaded in a running daemon.
-module(lazy_mcp_native_tests).
-export([run/0]).

run() ->
    ets:new(lazy_mcp_test, [named_table, public]),
    ets:insert(lazy_mcp_test, [{starts, 0}, {credentials, 0}, {calls, 0}, {tools, 1}]),
    Config = #{<<"type">> => <<"http">>, <<"url">> => <<"https://example.invalid/mcp">>},
    {ok, nil} = albedo_mcp:validate_settings(<<"a">>, {some, Config}, #{}),
    {ok, nil} = albedo_mcp:validate_settings(<<"a">>, none, #{}),
    {error, _} = albedo_mcp:validate_settings(<<"a">>, {some, enc(Config)}, #{}),
    {error, _} = albedo_mcp:validate_settings(<<"a">>, {some, Config}, <<"{}">>),
    Missing = Config#{<<"headers">> => #{<<"X-Test">> => #{<<"env">> => <<"ALBEDO_LAZY_TEST_MISSING_981">>}}},
    C = #{<<"servers">> => #{<<"a">> => Config, <<"b">> => Config,
          <<"c">> => Config, <<"missing">> => Missing,
          <<"disabled">> => Config#{<<"enabled">> => false}, <<"blocked">> => Config}},
    Cache = fun(_, _) -> error(cache_must_not_be_read) end,
    Save = fun(_, _, _) -> error(cache_must_not_be_written) end,
    {ok, Manager} = albedo_mcp:prepare_lazy(enc(C), nil, nil, Cache, Save),
    assert_startup_has_no_effects(Manager),
    Tool = assert_concurrent_load_starts_once(Manager),
    assert_calls_are_not_replayed(Manager, Tool),
    assert_unload_and_reload(Manager, Tool),
    assert_operation_cap(Manager),
    assert_close_stops_loading(Manager),
    assert_manager_death_closes_client(Config, Cache, Save),
    assert_eager_compatibility(),
    assert_idle_cleanup(Config, Cache, Save),
    assert_dead_client_and_catalogue_drift(Config, Cache, Save),
    io:format("lazy native tests passed~n"),
    ok.

assert_startup_has_no_effects(Manager) ->
    0 = count(starts),
    0 = count(credentials),
    <<"[]">> = albedo_mcp:definitions(Manager),
    <<>> = albedo_mcp:context(Manager),
    [] = albedo_mcp:offline(Manager),
    nil = albedo_mcp:observe(Manager, true, fun(_) -> error(refresh) end),
    [#{<<"loaded">> := false, <<"name">> := <<"a">>}, _, _, _] = json:decode(albedo_mcp:servers(Manager)),
    {error, _} = albedo_mcp:load(Manager, <<"disabled">>),
    {error, _} = albedo_mcp:load(Manager, <<"blocked">>),
    0 = count(credentials).

assert_concurrent_load_starts_once(Manager) ->
    Parent = self(),
    [spawn(fun() -> Parent ! {loaded, albedo_mcp:load(Manager, <<"a">>)} end) || _ <- lists:seq(1, 8)],
    Results = [receive {loaded, R} -> R after 5000 -> error(load_timeout) end || _ <- lists:seq(1, 8)],
    [{ok, Definitions}] = lists:usort(Results),
    1 = count(starts),
    1 = count(credentials),
    [#{<<"name">> := Tool}] = json:decode(Definitions),
    <<>> = albedo_mcp:context(Manager),
    Tool.

assert_calls_are_not_replayed(Manager, Tool) ->
    {ok, _} = albedo_mcp:call(Manager, Tool, <<"{}">>),
    1 = count(calls),
    ets:insert(lazy_mcp_test, {fail_call, true}),
    {error, Unknown} = albedo_mcp:call(Manager, Tool, <<"{}">>),
    true = binary:match(Unknown, <<"outcome unknown">>) =/= nomatch,
    2 = count(calls),
    1 = count(starts),
    ets:delete(lazy_mcp_test, fail_call).

assert_unload_and_reload(Manager, Tool) ->
    {ok, nil} = albedo_mcp:unload(Manager, <<"a">>),
    {error, _} = albedo_mcp:call(Manager, Tool, <<"{}">>),
    2 = count(calls),
    {ok, _} = albedo_mcp:load(Manager, <<"a">>),
    2 = count(starts),
    {error, _} = albedo_mcp:load(Manager, <<"missing">>),
    2 = count(starts),
    {ok, nil} = albedo_mcp:unload(Manager, <<"a">>).

assert_operation_cap(Manager) ->
    ets:insert(lazy_mcp_test, {tools, 256}),
    {ok, _} = albedo_mcp:load(Manager, <<"a">>),
    {ok, _} = albedo_mcp:load(Manager, <<"b">>),
    ets:insert(lazy_mcp_test, {tools, 1}),
    {error, _} = albedo_mcp:load(Manager, <<"c">>),
    512 = length(json:decode(albedo_mcp:definitions(Manager))).

assert_close_stops_loading(Manager) ->
    nil = albedo_mcp:close(albedo_mcp:closer(Manager)),
    nil = albedo_mcp:close(Manager),
    {error, _} = albedo_mcp:load(Manager, <<"a">>).

assert_manager_death_closes_client(Config, Cache, Save) ->
    %% Independent guards close even when the manager is killed.
    {ok, KilledManager} = albedo_mcp:prepare_lazy(enc(#{<<"servers">> => #{<<"a">> => Config}}), nil, nil, Cache, Save),
    {ok, _} = albedo_mcp:load(KilledManager, <<"a">>),
    [{last_client, Client}] = ets:lookup(lazy_mcp_test, last_client),
    Monitor = monitor(process, Client),
    exit(maps:get(lazy_manager, KilledManager), kill),
    receive {'DOWN', Monitor, process, Client, _} -> ok after 5000 -> error(client_leaked) end,
    {error, _} = albedo_mcp:prepare_lazy(enc(#{<<"servers">> => #{<<"bad name">> => Config}}), nil, nil, Cache, Save).

assert_eager_compatibility() ->
    %% Existing eager snapshots stay compatible without transport work.
    Eager = #{servers => [#{name => <<"eager">>}], operations => []},
    [#{<<"name">> := <<"eager">>, <<"loaded">> := true}] = json:decode(albedo_mcp:servers(Eager)),
    {ok, <<"[]">>} = albedo_mcp:load(Eager, <<"eager">>),
    {error, _} = albedo_mcp:unload(Eager, <<"eager">>).

assert_idle_cleanup(Config, Cache, Save) ->
    ets:insert(lazy_mcp_test, {tools, 1}),
    C = #{<<"idleTimeoutMs">> => 40, <<"servers">> => #{<<"idle">> => Config}},
    {ok, Manager} = albedo_mcp:prepare_lazy(enc(C), nil, nil, Cache, Save),
    {ok, Definitions} = albedo_mcp:load(Manager, <<"idle">>),
    [#{<<"name">> := Tool}] = json:decode(Definitions),
    [{last_client, Client}] = ets:lookup(lazy_mcp_test, last_client),
    M = monitor(process, Client),
    receive {'DOWN', M, process, Client, _} -> ok after 5000 -> error(idle_client_leaked) end,
    %% Catalogue reads are passive and retain discovered schemas.
    Definitions = albedo_mcp:definitions(Manager),
    [#{<<"loaded">> := true, <<"connected">> := false}] = json:decode(albedo_mcp:servers(Manager)),
    Before = count(starts),
    BeforeCalls = count(calls),
    {ok, _} = albedo_mcp:call(Manager, Tool, <<"{}">>),
    After = Before + 1, After = count(starts),
    AfterCalls = BeforeCalls + 1, AfterCalls = count(calls),
    assert_idle_does_not_interrupt_call(Manager, Tool),
    nil = albedo_mcp:close(Manager),
    {error, _} = albedo_mcp:prepare_lazy(enc(C#{<<"idleTimeoutMs">> => -1}), nil, nil, Cache, Save),
    {error, _} = albedo_mcp:prepare_lazy(enc(C#{<<"idleTimeoutMs">> => 1.5}), nil, nil, Cache, Save).

assert_dead_client_and_catalogue_drift(Config, Cache, Save) ->
    ets:insert(lazy_mcp_test, {tools, 1}),
    C = #{<<"idleTimeoutMs">> => 40, <<"servers">> => #{<<"drift">> => Config}},
    {ok, Manager} = albedo_mcp:prepare_lazy(enc(C), nil, nil, Cache, Save),
    {ok, Definitions} = albedo_mcp:load(Manager, <<"drift">>),
    [#{<<"name">> := Tool}] = json:decode(Definitions),
    [{last_client, Client}] = ets:lookup(lazy_mcp_test, last_client),
    M = monitor(process, Client),
    receive {'DOWN', M, process, Client, _} -> ok after 5000 -> error(idle_client_leaked) end,
    ets:insert(lazy_mcp_test, {tools, 2}),
    Calls = count(calls),
    {error, Reason} = albedo_mcp:call(Manager, Tool, <<"{}">>),
    true = binary:match(Reason, <<"catalogue changed">>) =/= nomatch,
    Calls = count(calls),
    [_, _] = json:decode(albedo_mcp:definitions(Manager)),
    nil = albedo_mcp:close(Manager),
    ets:insert(lazy_mcp_test, {tools, 1}),
    {ok, Dead} = albedo_mcp:prepare_lazy(enc(C#{<<"idleTimeoutMs">> => 0}), nil, nil, Cache, Save),
    {ok, D} = albedo_mcp:load(Dead, <<"drift">>),
    [#{<<"name">> := DeadTool}] = json:decode(D),
    [{last_client, DeadClient}] = ets:lookup(lazy_mcp_test, last_client),
    DM = monitor(process, DeadClient),
    exit(DeadClient, kill),
    receive {'DOWN', DM, process, DeadClient, _} -> ok after 5000 -> error(client_not_dead) end,
    Starts = count(starts),
    [#{<<"connected">> := false}] = json:decode(albedo_mcp:servers(Dead)),
    {error, _} = albedo_mcp:load(Dead, <<"drift">>),
    {error, _} = albedo_mcp:call(Dead, DeadTool, <<"{}">>),
    Starts = count(starts),
    Calls = count(calls),
    nil = albedo_mcp:close(Dead).

assert_idle_does_not_interrupt_call(Manager, Tool) ->
    ets:insert(lazy_mcp_test, {call_pause, self()}),
    Parent = self(),
    spawn(fun() -> Parent ! {called, albedo_mcp:call(Manager, Tool, <<"{}">>)} end),
    receive {call_started, Worker} ->
        [{last_client, Client}] = ets:lookup(lazy_mcp_test, last_client),
        M = monitor(process, Client),
        receive {'DOWN', M, process, Client, _} -> error(in_flight_call_closed)
        after 100 -> ok end,
        Worker ! resume_call,
        receive {called, {ok, _}} -> ok after 5000 -> error(call_did_not_finish) end,
        receive {'DOWN', M, process, Client, _} -> ok
        after 5000 -> error(idle_after_call_leaked) end
    after 5000 -> error(call_not_started) end,
    ets:delete(lazy_mcp_test, call_pause).

enc(Value) -> iolist_to_binary(json:encode(Value)).
count(Key) -> ets:lookup_element(lazy_mcp_test, Key, 2).
