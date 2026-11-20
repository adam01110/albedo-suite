-module(proptest_ffi).
-export([getenv/1, putenv/2, bump/1, counts/0, reset/0, undefined/0, write_file/3, unique/0, remove_tree/1]).

-include_lib("kernel/include/file.hrl").

%% Environment knobs for case counts and seeds.
getenv(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.

%% Behavioural coverage counters, kept in the running process.
bump(Key) ->
    Counts = case get(proptest_counts) of undefined -> #{}; C -> C end,
    put(proptest_counts, maps:update_with(Key, fun(N) -> N + 1 end, 1, Counts)),
    nil.

counts() ->
    case get(proptest_counts) of undefined -> []; C -> lists:sort(maps:to_list(C)) end.

reset() -> erase(proptest_counts), nil.

undefined() -> undefined.

putenv(Name, Value) ->
    true = os:putenv(binary_to_list(Name), binary_to_list(Value)), nil.

%% Writes `Bytes` to `Path` with modification time `Mtime` (POSIX seconds),
%% so each catalog rewrite is a new revision however fast it follows.
write_file(Path, Bytes, Mtime) ->
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, Bytes),
    ok = file:write_file_info(Path, #file_info{mtime = Mtime}, [{time, posix}]),
    nil.

%% Unique within this VM and across concurrent ones: a VM number keeps two
%% runs of the same module, which would otherwise count from the same small
%% values, from sharing the /tmp paths they derive from it.
unique() ->
    vm() * 16#80000000 + erlang:unique_integer([positive]).

vm() ->
    Key = {?MODULE, vm},
    case persistent_term:get(Key, undefined) of
        undefined ->
            Number = erlang:phash2({os:getpid(), os:system_time(microsecond), make_ref()}),
            persistent_term:put(Key, Number),
            Number;
        Number ->
            Number
    end.

remove_tree(Path) -> _ = file:del_dir_r(Path), nil.
