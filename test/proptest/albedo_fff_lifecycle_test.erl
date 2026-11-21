%% Lifecycle properties for the shared FFF worker (`albedo_fff`): every
%% request is answered once within its deadline, a worker that dies or stalls
%% is replaced, a late answer is never delivered to a later request, and reuse
%% never crosses keys. The worker is a scripted escript this module writes, so
%% a case can make it answer, stall, die, or write more than the bound.
-module(albedo_fff_lifecycle_test).
-export([run/0, stop/0, scenario/1]).

%% The response bound and the module's own refusals.
-define(BOUND, 8388608).
-define(EXCEEDS, <<"FFF response exceeds 8 MiB bound">>).
-define(EXPIRED, <<"FFF request expired in queue">>).
-define(TIMED_OUT, <<"FFF request timed out">>).
-define(DIED, <<"FFF worker died">>).
-define(INVALID, <<"FFF worker returned invalid JSON">>).
-define(DEADLINE, 30000).

run() ->
    Workers = install(),
    reuse(Workers),
    death(Workers),
    partial(Workers),
    bounded(Workers),
    expiry(Workers),
    late(Workers),
    concurrent(Workers),
    queued_expiry(Workers),
    deadline(Workers),
    remote_map(),
    io:format("FFF worker lifecycle: reuse, death, expiry, late answers, concurrency and the 30 s deadline passed~n"),
    nil.

%% The fixture stays for the generated cases that follow; this removes it.
stop() ->
    case persistent_term:get(albedo_fff_lifecycle, undefined) of
        undefined -> ok;
        #{dir := Dir} ->
            persistent_term:erase(albedo_fff_lifecycle),
            cleanup(Dir)
    end,
    nil.

%% A generated request sequence through the production entry point: the reply
%% to each probe the caller built, in order.
scenario(Probes) ->
    _ = install(),
    [albedo_fff:search(<<"local">>, [], none, #{<<"probe">> => json:decode(Probe)}) || Probe <- Probes].

%% Reuse is per key: the local worker, a remote host and a remote host named
%% like the local key never answer for one another.
reuse(W) ->
    Local = pid(),
    expect("a live worker answers again", pid(), Local),
    Remote = identity(<<"h1">>, maps:get(w2, W)),
    expect("a remote key uses its own worker", tag(Remote), <<"w2">>),
    expect("a remote search leaves the local worker", pid(), Local),
    Named = identity(<<"local">>, maps:get(w2, W)),
    expect("a remote key named local is not the local worker", tag(Named), <<"w2">>),
    expect("the local worker is still the local one", tag(identity()), <<"w1">>),
    expect("a remote worker is reused by key", pid(identity(<<"h1">>, maps:get(w2, W))), pid(Remote)),
    One = identity(<<"h3">>, maps:get(w1, W)),
    Two = identity(<<"h4">>, maps:get(w1, W)),
    expect("two keys on one worker file are separate workers", pid(Two) =:= pid(One), false),
    expect("each key keeps its own worker", pid(identity(<<"h3">>, maps:get(w1, W))), pid(One)),
    expect("another key's worker is untouched", pid(identity(<<"h1">>, maps:get(w2, W))), pid(Remote)),
    nil.

%% A worker that dies before answering is reported, and the next request is
%% answered by a replacement.
death(_W) ->
    Before = pid(),
    expect("a dying worker is reported", local(#{<<"mode">> => <<"die">>}), {error, ?DIED}),
    After = pid(),
    case After of
        Before -> erlang:error({"a dead worker is replaced", Before});
        _ -> ok
    end,
    expect("the replacement answers again", tag(identity()), <<"w1">>),
    nil.

%% A worker that dies mid reply leaves half a line behind.
partial(_W) ->
    Got = local(#{<<"mode">> => <<"partial">>, <<"raw">> => <<"{\"protocol\":1,">>}),
    case Got of
        {error, ?DIED} -> ok;
        {error, ?INVALID} -> ok;
        _ -> erlang:error({"a partial reply before a death", Got})
    end,
    expect("a worker after a partial reply answers", tag(identity()), <<"w1">>),
    nil.

%% A reply past the bound is refused and the worker is replaced.
bounded(_W) ->
    expect(
      "a reply past the bound is refused",
      error_of(local(#{<<"mode">> => <<"oversize">>, <<"len">> => ?BOUND + 2})),
      ?EXCEEDS),
    expect(
      "a reply at the bound plus one is refused",
      error_of(local(#{<<"mode">> => <<"oversize">>, <<"len">> => ?BOUND + 1})),
      ?EXCEEDS),
    expect("the worker after an oversized reply answers", tag(identity()), <<"w1">>),
    nil.

%% A request whose deadline has passed in the queue is refused without
%% reaching the worker.
expiry(W) ->
    Worker = worker(),
    Log = filename:join(maps:get(dir, W), "expired.log"),
    Logged = #{<<"mode">> => <<"value">>, <<"v">> => <<"never">>, <<"log">> => list_to_binary(Log)},
    {Got, Elapsed} = timed(fun() ->
        gen_server:call(Worker, {search, payload(Logged), monotonic() - 1}, 5000)
    end),
    expect("an expired request is refused", Got, {error, ?EXPIRED}),
    case Elapsed =< 1000 of
        true -> ok;
        false -> erlang:error({"an expired request is refused at once", Elapsed})
    end,
    expect("an expired request never reaches the worker", filelib:is_file(Log), false),
    nil.

%% An answer that arrives after its request's deadline is never delivered to
%% a later request: the request after it is still waiting when it arrives.
late(_W) ->
    Worker = worker(),
    Slow = #{<<"mode">> => <<"stall">>, <<"ms">> => 500, <<"then">> => <<"value">>, <<"v">> => <<"late">>},
    {Got, Elapsed} = timed(fun() ->
        gen_server:call(Worker, {search, payload(Slow), monotonic() + 150}, 5000)
    end),
    expect("a stalled request times out", Got, {error, ?TIMED_OUT}),
    case Elapsed =< 2000 of
        true -> ok;
        false -> erlang:error({"a stalled request gives up at its deadline", Elapsed})
    end,
    Next = #{<<"mode">> => <<"stall">>, <<"ms">> => 700, <<"then">> => <<"value">>, <<"v">> => <<"fresh">>},
    Fresh = gen_server:call(Worker, {search, payload(Next), monotonic() + 5000}, 10000),
    expect_json("a late answer is never a later request's answer", Fresh, <<"fresh">>),
    expect("the next request is answered again", tag(identity()), <<"w1">>),
    nil.

%% Two callers share one worker: each gets its own answer.
concurrent(_W) ->
    Worker = worker(),
    Self = self(),
    Slow = #{<<"mode">> => <<"stall">>, <<"ms">> => 400, <<"then">> => <<"value">>, <<"v">> => <<"first">>},
    spawn(fun() ->
        Self ! {a, gen_server:call(Worker, {search, payload(Slow), monotonic() + 10000}, 20000)}
    end),
    timer:sleep(50),
    spawn(fun() ->
        Self ! {b, gen_server:call(Worker, {search, payload(#{<<"mode">> => <<"value">>, <<"v">> => <<"second">>}), monotonic() + 10000}, 20000)}
    end),
    [First, Second] = await(2),
    expect_json("a stalled caller gets its own answer", First, <<"first">>),
    expect_json("a queued caller gets its own answer", Second, <<"second">>),
    nil.

%% A request that expires while another waits: the waiter is answered by a
%% replacement worker, not by the stalled one.
queued_expiry(_W) ->
    Worker = worker(),
    Before = pid(),
    Self = self(),
    Slow = #{<<"mode">> => <<"stall">>, <<"ms">> => 500, <<"then">> => <<"value">>, <<"v">> => <<"late">>},
    spawn(fun() ->
        Self ! {expiring, gen_server:call(Worker, {search, payload(Slow), monotonic() + 150}, 5000)}
    end),
    timer:sleep(20),
    spawn(fun() ->
        Waiter = #{<<"mode">> => <<"stall">>, <<"ms">> => 200, <<"then">> => <<"value">>, <<"v">> => <<"waiter">>},
        Self ! {waiter, gen_server:call(Worker, {search, payload(Waiter), monotonic() + 5000}, 10000)}
    end),
    [Expiring, Waiter] = await(2),
    expect("the request in flight times out", Expiring, {error, ?TIMED_OUT}),
    expect_json("the waiting request is answered by a replacement", Waiter, <<"waiter">>),
    case pid() of
        Before -> erlang:error({"the stalled worker is replaced", Before});
        _ -> ok
    end,
    nil.

%% The real deadline: a worker that never answers is given up on within the
%% module's 30 s, and the request after it succeeds.
deadline(_W) ->
    Before = pid(),
    Stall = #{<<"mode">> => <<"stall">>, <<"ms">> => ?DEADLINE + 3000, <<"then">> => <<"die">>},
    {Got, Elapsed} = timed(fun() -> local(Stall) end),
    io:format("  a stalled request gave up after ~B ms~n", [Elapsed]),
    expect("a stalled request times out at the deadline", Got, {error, ?TIMED_OUT}),
    case Elapsed >= ?DEADLINE andalso Elapsed =< ?DEADLINE + 3000 of
        true -> ok;
        false -> erlang:error({"the deadline is 30 s", Elapsed})
    end,
    After = pid(),
    case After of
        Before -> erlang:error({"a stalled worker is replaced", Before});
        _ -> ok
    end,
    nil.

%% The ssh hop: `remote/1` maps a ready host to the worker's key, ssh argv and
%% agent socket, and passes a hosts failure through untouched.
remote_map() ->
    Module = 'albedo@workspace@ssh',
    Fake = "-module('albedo@workspace@ssh').\n"
        "-export([ready/2]).\n"
        "ready(Target, Wait) ->\n"
        "    persistent_term:put(albedo_fff_ssh_call, {Target, Wait}),\n"
        "    persistent_term:get({albedo_fff_ssh, Target}).\n",
    Path = filename:join("/tmp",
        "fff-ssh-fake-" ++ os:getpid() ++ "-" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".erl"),
    ok = file:write_file(Path, Fake),
    {ok, Module, Binary} = compile:file(Path, [binary, report_errors]),
    code:purge(Module),
    {module, Module} = code:load_binary(Module, Path, Binary),
    file:delete(Path),
    Argv = [<<"ssh">>, <<"-o">>, <<"BatchMode=yes">>, <<"host">>],
    ok = expect("a ready host maps to its worker key, argv and socket",
        albedo_fff:remote(answer(<<"a">>, {ok, host(<<"a">>, {some, <<"/sock">>})})),
        {ok, {<<"host">>, Argv, {some, <<"/sock">>}}}),
    expect("a host without an agent socket maps to none",
        albedo_fff:remote(answer(<<"b">>, {ok, host(<<"b">>, none)})),
        {ok, {<<"host">>, Argv, none}}),
    expect("a probe asks the ssh module with the module's timeout",
        persistent_term:get(albedo_fff_ssh_call), {<<"b">>, 30000}),
    expect("an authentication failure passes through untouched",
        albedo_fff:remote(answer(<<"c">>, {error, {needs_auth, <<"detail">>, <<"/control">>}})),
        {error, {needs_auth, <<"detail">>, <<"/control">>}}),
    expect("a warming host passes through untouched",
        albedo_fff:remote(answer(<<"d">>, {error, warming})),
        {error, warming}),
    nil.

host(_, {some, Sock}) ->
    {host, <<"host">>, <<"linux">>, <<"x86_64">>, <<"/home/h">>, 8,
        {commands, [<<"ssh">>, <<"-o">>, <<"BatchMode=yes">>, <<"host">>], <<"bridge">>, <<"signal">>, <<"remove">>, <<"gather">>, <<"relay">>, {some, Sock}}};
host(_, none) ->
    {host, <<"host">>, <<"linux">>, <<"x86_64">>, <<"/home/h">>, 8,
        {commands, [<<"ssh">>, <<"-o">>, <<"BatchMode=yes">>, <<"host">>], <<"bridge">>, <<"signal">>, <<"remove">>, <<"gather">>, <<"relay">>, none}}.

answer(Target, Answer) ->
    persistent_term:put({albedo_fff_ssh, Target}, Answer),
    Target.

%% Fixture

directory() ->
    %% Unique across VMs too: two runs of this module must not share a fixture.
    Path = filename:join("/tmp",
        "fff-lifecycle-" ++ os:getpid() ++ "-" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_dir(filename:join(Path, "placeholder")),
    Path.

%% One fixture per VM: the stand-in workers it writes and the PATH entry that
%% makes them the local `albedo-fff`.
install() ->
    case persistent_term:get(albedo_fff_lifecycle, undefined) of
        undefined -> install(directory());
        Workers -> Workers
    end.

install(Dir) ->
    Local = filename:join(Dir, "albedo-fff"),
    write_worker(Local, <<"w1">>),
    W1 = write_worker(filename:join(Dir, "worker-w1.escript"), <<"w1">>),
    W2 = write_worker(filename:join(Dir, "worker-w2.escript"), <<"w2">>),
    true = os:putenv("PATH", Dir ++ ":" ++ os:getenv("PATH")),
    Workers = #{dir => Dir, w1 => W1, w2 => W2, escript => executable("escript")},
    persistent_term:put(albedo_fff_lifecycle, Workers),
    Workers.

%% The argv a remote search carries is a list of binaries, as the Gleam
%% caller passes it.
executable(Name) ->
    case os:find_executable(Name) of
        false -> erlang:error({missing_executable, Name});
        Path -> list_to_binary(Path)
    end.

%% Writes the stand-in under `Path` and answers the binary path an argv holds.
write_worker(Path, Default) ->
    Source = binary:replace(iolist_to_binary(template()), <<"__DEFAULT__">>, Default),
    ok = file:write_file(Path, Source),
    ok = file:change_mode(Path, 8#755),
    list_to_binary(Path).

cleanup(Dir) ->
    _ = file:del_dir_r(Dir),
    nil.

%% The scripted stand-in: one request per line, answering by `probe.mode`, so
%% a case can make it answer, stall, die, or write past the bound. It also
%% appends the request it read to `probe.log` when one is named.
template() ->
    lists:join("\n", [
      "#!/usr/bin/env escript",
      "%%! +S 2:2",
      "-mode(compile).",
      "main(_Args) -> loop().",
      "",
      "loop() ->",
      "    case io:get_line(\"\") of",
      "        eof -> halt(0);",
      "        Line -> respond(Line), loop()",
      "    end.",
      "",
      "respond(Read) ->",
      "    Line = unicode:characters_to_binary(Read),",
      "    Request = json:decode(Line),",
      "    Probe = case maps:get(<<\"probe\">>, Request, #{}) of",
      "        Map when is_map(Map) -> Map;",
      "        _ -> #{}",
      "    end,",
      "    case maps:get(<<\"log\">>, Probe, none) of",
      "        none -> ok;",
      "        Path ->",
      "            ok = filelib:ensure_dir(Path),",
      "            ok = file:write_file(Path, Line, [append])",
      "    end,",
      "    act(maps:get(<<\"mode\">>, Probe, <<\"echo\">>), Probe, Request).",
      "",
      "act(<<\"echo\">>, _, Request) ->",
      "    reply(#{<<\"protocol\">> => 1, <<\"ok\">> => true, <<\"value\">> => Request});",
      "act(<<\"value\">>, Probe, _) ->",
      "    reply(#{<<\"protocol\">> => 1, <<\"ok\">> => true, <<\"value\">> => maps:get(<<\"v\">>, Probe, null)});",
      "act(<<\"identity\">>, _, _) ->",
      "    reply(#{<<\"protocol\">> => 1, <<\"ok\">> => true, <<\"value\">> => identity()});",
      "act(<<\"error\">>, Probe, _) ->",
      "    reply(#{<<\"protocol\">> => 1, <<\"ok\">> => false, <<\"error\">> => maps:get(<<\"e\">>, Probe, <<\"boom\">>)});",
      "act(<<\"proto\">>, _, _) ->",
      "    reply(#{<<\"protocol\">> => 2, <<\"ok\">> => true, <<\"value\">> => null});",
      "act(<<\"raw\">>, Probe, _) ->",
      "    send(maps:get(<<\"raw\">>, Probe, <<\"nope\">>));",
      "act(<<\"partial\">>, Probe, _) ->",
      "    send_raw(maps:get(<<\"raw\">>, Probe, <<\"{\\\"protocol\\\":1,\">>)),",
      "    halt(0);",
      "act(<<\"oversize\">>, Probe, _) ->",
      "    send(maps:get(<<\"raw\">>, Probe, binary:copy(<<\"x\">>, maps:get(<<\"len\">>, Probe, 1048576))));",
      "act(<<\"twice\">>, Probe, _) ->",
      "    act(<<\"value\">>, Probe, #{}),",
      "    reply(#{<<\"protocol\">> => 1, <<\"ok\">> => true, <<\"value\">> => maps:get(<<\"v\">>, Probe, null)});",
      "act(<<\"die\">>, _, _) ->",
      "    halt(0);",
      "act(<<\"stall\">>, Probe, Request) ->",
      "    timer:sleep(maps:get(<<\"ms\">>, Probe, 1000)),",
      "    act(maps:get(<<\"then\">>, Probe, <<\"value\">>), Probe, Request);",
      "act(Other, _, _) ->",
      "    reply(#{<<\"protocol\">> => 1, <<\"ok\">> => false, <<\"error\">> => <<\"unknown mode \", Other/binary>>}).",
      "",
      "identity() ->",
      "    iolist_to_binary([default(), \"-\", os:getpid(), \"-\", integer_to_list(count())]).",
      "",
      "count() ->",
      "    N = case get(counter) of",
      "        undefined -> 1;",
      "        Earlier -> Earlier + 1",
      "    end,",
      "    put(counter, N),",
      "    N.",
      "",
      "reply(Term) -> send(json:encode(Term)).",
      "",
      "send_raw(Bin) ->",
      "    try io:put_chars(Bin) catch _:_ -> halt(0) end,",
      "    ok.",
      "",
      "send(Bin) ->",
      "    send_raw([Bin, \"\\n\"]).",
      "",
      "default() -> <<\"__DEFAULT__\">>.",
      ""
    ]).

local(Probe) ->
    albedo_fff:search(<<"local">>, [], none, #{<<"probe">> => Probe}).

identity() ->
    value(albedo_fff:search(<<"local">>, [], none, #{<<"probe">> => #{<<"mode">> => <<"identity">>}})).

identity(Key, Worker) ->
    Albedo = persistent_term:get(albedo_fff_lifecycle),
    Argv = [maps:get(escript, Albedo), Worker],
    value(albedo_fff:search(Key, Argv, none, #{<<"probe">> => #{<<"mode">> => <<"identity">>}})).

pid() -> pid(identity()).

pid(Value) -> field(Value, 1).

%% The worker file that answered: its baked-in default tag.
tag(Value) -> field(Value, 0).

%% The search answers JSON text; an identity is a JSON string.
value({ok, Encoded}) -> json:decode(Encoded);
value(Other) -> erlang:error({no_answer, Other}).

field(Value, Index) ->
    lists:nth(Index + 1, binary:split(Value, <<"-">>, [global])).

worker() ->
    gen_server:call(whereis(albedo_fff), {worker, local, [], none}).

payload(Probe) ->
    iolist_to_binary(json:encode(#{<<"probe">> => Probe, <<"protocol">> => 1})).

monotonic() -> erlang:monotonic_time(millisecond).

timed(Fun) ->
    Start = monotonic(),
    Result = Fun(),
    {Result, monotonic() - Start}.

expect(Label, Got, Want) ->
    case Got of
        Want -> ok;
        _ -> erlang:error({Label, got, Got, want, Want})
    end.

%% A reply's value, decoded from the JSON text the search carries.
expect_json(Label, {ok, Encoded}, Want) -> expect(Label, json:decode(Encoded), Want);
expect_json(Label, Got, _Want) -> erlang:error({Label, got, Got}).

error_of({error, Message}) -> Message;
error_of(Other) -> erlang:error({expected_an_error, Other}).

await(0) -> [];
await(N) ->
    receive {_, Result} -> [Result | await(N - 1)] end.
