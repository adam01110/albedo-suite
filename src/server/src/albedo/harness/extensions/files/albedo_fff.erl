-module(albedo_fff).
-behaviour(gen_server).
-export([search/4, init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TIMEOUT, 30000).
-define(BOUND, 8388608).

search(Key, Argv, Auth, Args) when is_map(Args) ->
    Deadline = erlang:monotonic_time(millisecond) + ?TIMEOUT,
    try
        Payload = iolist_to_binary(json:encode((maps:remove(<<"_fff_target">>, Args))#{<<"protocol">> => 1})),
        true = byte_size(Payload) =< 1048576,
        HostKey = case Argv of [] -> local; _ -> {remote, Key} end,
        Worker = gen_server:call(ensure(), {worker, HostKey, Argv, Auth}),
        gen_server:call(Worker, {search, Payload, Deadline}, ?TIMEOUT + 2000)
    catch
        error:{badmatch, false} -> {error, <<"FFF request exceeds 1 MiB bound">>};
        exit:{timeout, _} -> {error, <<"FFF request timed out">>};
        _:_ -> {error, <<"FFF worker unavailable">>}
    end;
search(_, _, _, _) -> {error, <<"invalid FFF arguments">>}.

ensure() ->
    case gen_server:start({local, ?MODULE}, ?MODULE, registry, []) of
        {ok, Pid} -> Pid;
        {error, {already_started, Pid}} -> Pid
    end.

init(registry) -> {ok, #{workers => #{}}};
init({worker, Argv, Auth}) ->
    process_flag(trap_exit, true),
    {ok, #{argv => Argv, auth => Auth, port => none}, 60000}.

handle_call({worker, Key, Argv, Auth}, _, S = #{workers := Workers}) ->
    case maps:get(Key, Workers, none) of
        {Pid, _} -> {reply, Pid, S};
        none ->
            {ok, Pid} = gen_server:start(?MODULE, {worker, Argv, Auth}, []),
            Monitor = monitor(process, Pid),
            {reply, Pid, S#{workers => Workers#{Key => {Pid, Monitor}}}}
    end;
handle_call({search, Payload, Deadline}, _, S) ->
    case Deadline > erlang:monotonic_time(millisecond) of
        false -> {reply, {error, <<"FFF request expired in queue">>}, S, 60000};
        true ->
            case worker_port(S) of
                {ok, Port} ->
                    try
                        true = port_command(Port, <<Payload/binary, "\n">>),
                        case collect(Port, <<>>, Deadline) of
                            {ok, Value} -> {reply, {ok, Value}, S#{port => Port}, 60000};
                            {reply_error, Why} -> {reply, {error, Why}, S#{port => Port}, 60000};
                            {error, Why} -> close(Port), {reply, {error, Why}, S#{port => none}, 60000}
                        end
                    catch _:_ ->
                        close(Port), {reply, {error, <<"FFF worker died">>}, S#{port => none}, 60000}
                    end;
                {error, Why} -> {reply, {error, Why}, S, 60000}
            end
    end.

handle_cast(_, S) -> {noreply, S}.
handle_info({'DOWN', Monitor, process, _, _}, S = #{workers := Workers}) ->
    {noreply, S#{workers => maps:filter(fun(_, {_, Ref}) -> Ref =/= Monitor end, Workers)}};
handle_info(timeout, S = #{port := Port}) -> close(Port), {stop, normal, S};
handle_info({Port, {exit_status, _}}, S = #{port := Port}) -> {noreply, S#{port => none}, 60000};
handle_info({'EXIT', Port, _}, S = #{port := Port}) -> {noreply, S#{port => none}, 60000};
handle_info(_, S = #{port := _}) -> {noreply, S, 60000};
handle_info(_, S) -> {noreply, S}.

worker_port(#{port := Port}) when is_port(Port) ->
    case erlang:port_info(Port) of undefined -> {error, <<"FFF worker exited; retry the search">>}; _ -> {ok, Port} end;
worker_port(#{argv := Argv, auth := Auth}) ->
    {Program, Arguments} = case Argv of
        [] -> {"albedo-fff", ["--stdio"]};
        [Ssh | Options] -> {binary_to_list(Ssh), [binary_to_list(A) || A <- Options] ++ ["exec albedo-fff --stdio"]}
    end,
    Env = case Auth of
        {some, Sock} -> [{"SSH_AUTH_SOCK", binary_to_list(Sock)} | albedo_python:clean_environment()];
        none -> albedo_python:clean_environment()
    end,
    case os:find_executable(Program) of
        false -> {error, <<"FFF runtime missing on this host: install albedo-fff">>};
        Executable ->
            try {ok, open_port({spawn_executable, Executable},
                [binary, exit_status, use_stdio, hide, {line, ?BOUND + 1}, {args, Arguments}, {env, Env}])}
            catch _:_ -> {error, <<"FFF worker failed to start">>} end
    end.

collect(Port, Buffer, Deadline) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, {noeol, Data}}} when byte_size(Buffer) + byte_size(Data) =< ?BOUND ->
            collect(Port, <<Buffer/binary, Data/binary>>, Deadline);
        {Port, {data, {eol, Data}}} when byte_size(Buffer) + byte_size(Data) =< ?BOUND ->
            decode(<<Buffer/binary, Data/binary>>);
        {Port, {data, _}} -> {error, <<"FFF response exceeds 8 MiB bound">>};
        {Port, {exit_status, _}} -> {error, <<"FFF worker died">>};
        {'EXIT', Port, _} -> {error, <<"FFF worker died">>}
    after Remaining -> {error, <<"FFF request timed out">>}
    end.

decode(Data) ->
    try json:decode(Data) of
        #{<<"protocol">> := 1, <<"ok">> := true, <<"value">> := Value} ->
            {ok, iolist_to_binary(json:encode(Value))};
        #{<<"protocol">> := 1, <<"ok">> := false, <<"error">> := Error} when is_binary(Error) ->
            {reply_error, Error};
        _ -> {error, <<"FFF protocol mismatch">>}
    catch _:_ -> {error, <<"FFF worker returned invalid JSON">>} end.

close(none) -> ok;
close(Port) -> try port_close(Port) catch _:_ -> ok end.
