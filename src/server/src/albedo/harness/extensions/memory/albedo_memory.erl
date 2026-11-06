%% Project memory on the daemon's disk: one directory per workspace under
%% $ALBEDO_HOME/memories, `memory.md` plus `journal/<date>.md`. The kernel
%% reaches it through the memory host route wherever the kernel runs, so a
%% remote session's memory lives here too. Writes to one workspace are
%% serialized through a global lock; reads span a workspace's link group.
-module(albedo_memory).
-export([load/1, linked/1, read/1, save/2, append/2, journal/3, documents/1, export_snapshot/1, import_snapshot/5]).
-include_lib("kernel/include/file.hrl").

-define(MAX_FILE, 1048576).
-define(DOCUMENTS, 16777216).  %% bytes one documents answer carries

root(Workspace) ->
    Slug = re:replace(Workspace, <<"[^A-Za-z0-9]">>, <<"-">>, [global, unicode, {return, binary}]),
    filename:join([albedo_extension_settings:home(), <<"memories">>, Slug]).

memory(Workspace) -> filename:join(root(Workspace), <<"memory.md">>).

%% Keep topic discovery in startup context; full notes remain in read/documents.
load(Workspaces) ->
    case Workspaces of
        [Own | _] ->
            case text(memory(Own)) of
                {error, Reason} -> {error, Reason};
                {ok, Mine} -> {ok, render_index([{Own, Mine} | parts(tl(Workspaces))])}
            end;
        [] -> {ok, <<>>}
    end.

linked(Workspaces) -> index(Workspaces).

index(Workspaces) -> render_index(parts(Workspaces)).

parts(Workspaces) ->
    [{W, T} || W <- Workspaces, {ok, T} <- [text(memory(W))], T =/= <<>>].

render_index(Parts0) ->
    Parts = [{W, T} || {W, T} <- Parts0, T =/= <<>>],
    case Parts of
        [] -> <<>>;
        _ -> iolist_to_binary([
            <<"# Project memory topic index (untrusted, incomplete)\n",
              "Use memory.search(query) or memory.grep(term) for relevant full notes; ",
              "memory.read() reads this workspace. No notes have been deleted.\n">>,
            index_parts(Parts, 1600)
        ])
    end.

index_parts([], _) -> [];
index_parts(_, Budget) when Budget =< 0 ->
    <<"\n[more topics omitted; search spans all linked workspaces]">>;
index_parts([{Where, Text} | Rest], Budget) ->
    Paragraphs = re:split(Text, <<"\n[\t\r ]*\n">>, [{return, binary}, unicode]),
    Topics = lists:sublist(lists:reverse([P || P <- Paragraphs, P =/= <<>>]), 12),
    Lines = [[<<"- ">>, string:slice(hd(binary:split(P, <<"\n">>)), 0, 120), <<"\n">>] || P <- Topics],
    Body = unicode:characters_to_binary(Lines),
    Shown = string:slice(Body, 0, Budget),
    [<<"\n## ">>, Where, <<"\n">>, Shown, index_parts(Rest, Budget - string:length(Shown))].

%% One file as UTF-8 text, empty when it does not exist.
text(Path) ->
    case file:read_file_info(Path) of
        {error, enoent} -> {ok, <<>>};
        {ok, #file_info{type = regular, size = Size}} when Size =< ?MAX_FILE ->
            case file:read_file(Path) of
                {ok, Bytes} ->
                    case unicode:characters_to_binary(Bytes) of
                        Text when is_binary(Text) -> {ok, Text};
                        _ -> {error, <<(filename:basename(Path))/binary, " is not UTF-8">>}
                    end;
                {error, Reason} -> {error, reason(Reason)}
            end;
        {ok, _} -> {error, <<(filename:basename(Path))/binary, " must be a regular UTF-8 file of at most 1 MiB">>};
        {error, Reason} -> {error, reason(Reason)}
    end.

read(Workspace) -> text(memory(Workspace)).

%% Replace the curated memory atomically.
save(_, Text) when byte_size(Text) > ?MAX_FILE -> {error, <<"memory.md cannot exceed 1 MiB">>};
save(Workspace, Text) ->
    Path = memory(Workspace),
    locked(Workspace, fun() ->
        case recover_import(Path) of
            {ok, _} -> atomic_write(Path, Text);
            {error, _} = Error -> Error
        end
    end).

append(Workspace, Text) ->
    Path = memory(Workspace),
    locked(Workspace, fun() ->
        case recover_import(Path) of
            {ok, _} ->
                case text(Path) of
                    {ok, Before} ->
                        Entry = entry(byte_size(Before), Text),
                        case byte_size(Before) + byte_size(Entry) > ?MAX_FILE of
                            true -> {error, <<"memory.md cannot exceed 1 MiB">>};
                            false -> write(Path, Entry)
                        end;
                    {error, _} = Error -> Error
                end;
            {error, _} = Error -> Error
        end
    end).

journal(Workspace, Date, Text) ->
    case re:run(Date, <<"^[0-9]{4}-[0-9]{2}-[0-9]{2}$">>, [{capture, none}]) of
        nomatch -> {error, <<"journal date must be YYYY-MM-DD">>};
        match ->
            Path = filename:join([root(Workspace), <<"journal">>, <<Date/binary, ".md">>]),
            locked(Workspace, fun() ->
                case recover_import(Path) of
                    {ok, _} ->
                        Size = case file:read_file_info(Path) of {ok, #file_info{size = S}} -> S; _ -> 0 end,
                        write(Path, entry(Size, Text));
                    {error, _} = Error -> Error
                end
            end)
    end.

%% A note on its own line, a blank line from the one before it.
entry(Size, Text) ->
    Body = string:trim(Text, trailing, "\n"),
    Gap = case Size > 0 of true -> <<"\n">>; false -> <<>> end,
    iolist_to_binary([Gap, Body, <<"\n">>]).

write(Path, Entry) ->
    case file:write_file(Path, Entry, [append]) of
        ok -> {ok, Path};
        {error, Reason} -> {error, reason(Reason)}
    end.

locked(Workspace, Fun) ->
    case filelib:ensure_path(filename:join(root(Workspace), <<"journal">>)) of
        ok -> with_lock(Workspace, Fun);
        {error, Reason} -> {error, reason(Reason)}
    end.

with_lock(Workspace, Fun) ->
    case global:trans({{?MODULE, root(Workspace)}, self()}, Fun) of
        aborted -> {error, <<"memory workspace lock unavailable">>};
        Result -> Result
    end.

%% Every memory and journal file of the given workspaces, for grep and
%% search: [{Workspace, Relative, Text}] and whether the byte budget cut the
%% list short. Unreadable files are left out.
documents(Workspaces) -> documents(Workspaces, ?DOCUMENTS, []).

documents([], _, Acc) -> {lists:reverse(Acc), false};
documents([Workspace | Rest], Budget, Acc) ->
    Root = root(Workspace),
    Journals = lists:sort(filelib:wildcard("journal/*.md", binary_to_list(Root))),
    Files = [<<"memory.md">> | [unicode:characters_to_binary(J) || J <- Journals]],
    case collect(Workspace, Root, Files, Budget, Acc) of
        {full, Acc1} -> {lists:reverse(Acc1), true};
        {Left, Acc1} -> documents(Rest, Left, Acc1)
    end.

collect(_, _, [], Budget, Acc) -> {Budget, Acc};
collect(Workspace, Root, [Relative | Rest], Budget, Acc) ->
    case text(filename:join(Root, Relative)) of
        {ok, <<>>} -> collect(Workspace, Root, Rest, Budget, Acc);
        {ok, Text} when byte_size(Text) > Budget -> {full, Acc};
        {ok, Text} -> collect(Workspace, Root, Rest, Budget - byte_size(Text), [{Workspace, Relative, Text} | Acc]);
        {error, _} -> collect(Workspace, Root, Rest, Budget, Acc)
    end.

reason(Reason) -> unicode:characters_to_binary(file:format_error(Reason)).

%% Snapshot export and import never hold two workspace locks together.
export_snapshot(Workspace) ->
    case source_files(Workspace) of
        {ok, Files} -> {ok, {snapshot, Workspace, Files}};
        {error, _} = Error -> Error
    end.

import_snapshot(Target, Origin, Transfer, {snapshot, Source, Files}, Seconds) ->
    case validate_snapshot(Files, ?DOCUMENTS, #{}) of
        ok ->
            Key = crypto:hash(sha256, term_to_binary({Origin, Transfer, Source})),
            {{Year, Month, Day}, _} = calendar:system_time_to_universal_time(Seconds, second),
            Date = io_lib:format("~4..0B-~2..0B-~2..0B", [Year, Month, Day]),
            Heading = iolist_to_binary([<<"\n\n## imported from ">>, Source, <<" on ">>, Date, <<"\n\n">>]),
            locked(Target, fun() ->
                case transfer_manifest(root(Target), Origin, Transfer, Source, Files) of
                    {ok, _} -> import_files(root(Target), Key, Heading, Files);
                    {error, _} = Error -> Error
                end
            end);
        {error, _} = Error -> Error
    end.

transfer_manifest(Root, Origin, Transfer, Source, Files) ->
    Key = binary:encode_hex(crypto:hash(sha256, term_to_binary({Origin, Transfer})), lowercase),
    Path = filename:join([Root, <<".transfers">>, Key]),
    Digest = crypto:hash(sha256, term_to_binary({Source, lists:sort(Files)})),
    case file:read_file(Path) of
        {ok, Digest} -> {ok, Path};
        {ok, _} -> {error, <<"memory snapshot changed for an existing transfer">>};
        {error, enoent} ->
            case filelib:ensure_dir(Path) of
                ok -> atomic_write(Path, Digest);
                {error, Reason} -> {error, reason(Reason)}
            end;
        {error, Reason} -> {error, reason(Reason)}
    end.

validate_snapshot([], _, _) -> ok;
validate_snapshot([{Relative, Bytes} | Rest], Budget, Seen) when is_binary(Relative), is_binary(Bytes) ->
    ValidPath = Relative =:= <<"memory.md">> orelse
        re:run(Relative, <<"^journal/[0-9]{4}-[0-9]{2}-[0-9]{2}\\.md\\z">>, [{capture, none}]) =:= match,
    ValidText = unicode:characters_to_binary(Bytes) =:= Bytes,
    case ValidPath andalso ValidText andalso byte_size(Bytes) =< ?MAX_FILE andalso
        byte_size(Bytes) =< Budget andalso not maps:is_key(Relative, Seen) of
        true -> validate_snapshot(Rest, Budget - byte_size(Bytes), Seen#{Relative => true});
        false -> {error, <<"invalid memory snapshot path, text, duplicate, or size (1 MiB/file, 16 MiB total)">>}
    end;
validate_snapshot(_, _, _) -> {error, <<"invalid memory snapshot files">>}.

source_files(Workspace) ->
    with_lock(Workspace, fun() ->
        case file:list_dir(filename:join(root(Workspace), <<"journal">>)) of
            {error, enoent} -> snapshot_files(Workspace, [<<"memory.md">>], ?DOCUMENTS, []);
            {ok, Names} ->
                Days = lists:usort([filename:join(<<"journal">>, journal_name(N)) || N <- Names,
                    re:run(N, <<"^[0-9]{4}-[0-9]{2}-[0-9]{2}\\.md(\\.imports)?\\z">>, [{capture, none}]) =:= match]),
                snapshot_files(Workspace, [<<"memory.md">> | Days], ?DOCUMENTS, []);
            {error, Reason} -> {error, reason(Reason)}
        end
    end).

journal_name(Name) ->
    binary:replace(unicode:characters_to_binary(Name), <<".imports">>, <<>>).

snapshot_files(_, [], _, Acc) -> {ok, lists:reverse(Acc)};
snapshot_files(Workspace, [Relative | Rest], Budget, Acc) ->
    Path = filename:join(root(Workspace), Relative),
    case recover_import(Path) of
        {ok, _} ->
            case text(Path) of
                {ok, <<>>} when Relative =:= <<"memory.md">> ->
                    snapshot_files(Workspace, Rest, Budget, Acc);
                {ok, Bytes} when byte_size(Bytes) =< Budget ->
                    snapshot_files(Workspace, Rest, Budget - byte_size(Bytes), [{Relative, Bytes} | Acc]);
                {ok, _} -> {error, <<"source memory and journal exceed 16 MiB">>};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

import_files(_, _, _, []) -> {ok, nil};
import_files(Root, Source, Heading, [{<<"memory.md">>, <<>>} | Rest]) ->
    import_files(Root, Source, Heading, Rest);
import_files(Root, Source, Heading, [{Relative, Bytes} | Rest]) ->
    Path = filename:join(Root, Relative),
    case import_file(Path, Source, Heading, Bytes) of
        {ok, _} -> import_files(Root, Source, Heading, Rest);
        {error, _} = Error -> Error
    end.

import_file(Path, Source, Heading, Bytes) ->
    case recover_import(Path) of
        {ok, Sources} ->
            Digest = crypto:hash(sha256, Bytes),
            case lists:keyfind(Source, 1, Sources) of
                {Source, Digest} -> {ok, Path};
                {Source, _} -> {error, <<"memory transfer file changed for an existing receipt">>};
                false -> merge_import(Path, Sources, {Source, Digest}, Heading, Bytes)
            end;
        {error, _} = Error -> Error
    end.

merge_import(Path, Sources, Source, Heading, Bytes) ->
    case text(Path) of
        {ok, Before} ->
            After = case Before of
                <<>> -> Bytes;
                _ -> <<Before/binary, Heading/binary, Bytes/binary>>
            end,
            case byte_size(After) =< ?MAX_FILE of
                true -> begin_import(Path, Sources, Source, Before, After);
                false -> {error, <<"imported memory file cannot exceed 1 MiB">>}
            end;
        {error, _} = Error -> Error
    end.

%% A write-ahead receipt makes a payload rename and its provenance recoverable
%% as one operation. Never guess after an external edit or a corrupt receipt.
begin_import(Path, Sources, Source, Before, After) ->
    Pending = {pending, [Source | Sources], Before, After},
    case receipt(Path, Pending) of
        {ok, _} -> recover_import(Path);
        {error, _} = Error -> Error
    end.

recover_import(Path) ->
    case read_import(Path) of
        {ok, {done, Sources}} -> {ok, Sources};
        {ok, {pending, Sources, Before, After}} -> finish_import(Path, Sources, Before, After);
        {error, _} = Error -> Error
    end.

read_import(Path) ->
    case file:read_file(<<Path/binary, ".imports">>) of
        {error, enoent} -> {ok, {done, []}};
        {ok, Bytes} ->
            try binary_to_term(Bytes, [safe]) of
                {1, {done, Sources} = State} when is_list(Sources) ->
                    validate_import(State, Sources);
                {1, {pending, Sources, Before, After} = State}
                    when is_list(Sources), is_binary(Before), is_binary(After) ->
                    validate_import(State, Sources);
                _ -> {error, <<"invalid memory import receipt">>}
            catch
                error:badarg -> {error, <<"invalid memory import receipt">>}
            end;
        {error, Reason} -> {error, reason(Reason)}
    end.

validate_import(State, Sources) ->
    Valid = fun
        ({Key, Digest}) -> is_binary(Key) andalso is_binary(Digest);
        (_) -> false
    end,
    case lists:all(Valid, Sources) of
        true -> {ok, State};
        false -> {error, <<"invalid memory import sources">>}
    end.

finish_import(Path, Sources, Before, After) ->
    case text(Path) of
        {ok, After} ->
            case file:read_file_info(Path) of
                {error, enoent} -> apply_import(Path, Sources, After);
                {ok, _} -> commit_import(Path, Sources);
                {error, Reason} -> {error, reason(Reason)}
            end;
        {ok, Before} -> apply_import(Path, Sources, After);
        {ok, _} -> {error, <<"memory changed outside the daemon during an import; receipt retained">>};
        {error, _} = Error -> Error
    end.

apply_import(Path, Sources, After) ->
    case atomic_write(Path, After) of
        {ok, _} -> commit_import(Path, Sources);
        {error, _} = Error -> Error
    end.

commit_import(Path, Sources) ->
    case receipt(Path, {done, Sources}) of
        {ok, _} -> {ok, Sources};
        {error, _} = Error -> Error
    end.

receipt(Path, State) ->
    atomic_write(<<Path/binary, ".imports">>, term_to_binary({1, State})).

atomic_write(Path, Bytes) ->
    Temp = <<Path/binary, ".", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    Result = case file:open(Temp, [write, binary, exclusive, raw]) of
        {ok, Handle} ->
            Written = case file:write(Handle, Bytes) of
                ok -> file:sync(Handle);
                {error, _} = Error -> Error
            end,
            Closed = file:close(Handle),
            case {Written, Closed} of
                {ok, ok} -> file:rename(Temp, Path);
                {{error, Reason}, _} -> {error, Reason};
                {_, {error, Reason}} -> {error, Reason}
            end;
        {error, Reason} -> {error, Reason}
    end,
    case Result of
        ok -> {ok, Path};
        {error, Failure} -> _ = file:delete(Temp), {error, reason(Failure)}
    end.
