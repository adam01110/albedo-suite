-module(files_fff_ffi).
-export([read_file/1, same_json/2]).

%% The whole file's bytes, or an error when it does not exist yet.
read_file(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> {ok, Bin};
        {error, _} -> {error, nil}
    end.

%% Whether two JSON texts decode to the same value, ignoring member order
%% and of how each encoder spelled it.
same_json(Left, Right) ->
    try json:decode(Left) =:= json:decode(Right)
    catch _:_ -> false
    end.
