%% Test fixtures the suite's tests share. Upstream moved its own Erlang test
%% support into Gleam, so the suite keeps these few helpers itself.
-module(albedo_suite_test_support).
-export([fake_mcp_server/0, skills_fixture/0, write/3, cleanup/1, identity/0]).

%% Upstream's Python fake stdio MCP server, run from the daemon's app root.
fake_mcp_server() ->
    {
        unicode:characters_to_binary(os:find_executable("python3")),
        filename:absname(<<"../../e2e/fake_mcp_server.py">>)
    }.

%% A fresh root holding an empty workspace and home.
skills_fixture() ->
    Root = filename:join(
        os:getenv("TMPDIR", "/tmp"),
        "albedo-skills-" ++ integer_to_list(erlang:system_time(nanosecond)) ++ "-" ++
            integer_to_list(erlang:unique_integer([positive]))
    ),
    Workspace = filename:join(Root, "workspace"),
    Home = filename:join(Root, "home"),
    ok = filelib:ensure_dir(filename:join(Workspace, "placeholder")),
    ok = filelib:ensure_dir(filename:join(Home, "placeholder")),
    {bin(Root), bin(Workspace), bin(Home)}.

write(Base0, Relative0, Content) ->
    Path = filename:join(text(Base0), text(Relative0)),
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, Content),
    bin(Path).

cleanup(Root) ->
    _ = file:del_dir_r(Root),
    nil.

%% A UUIDv7, as a login id.
identity() ->
    <<Timestamp:48>> = <<(erlang:system_time(millisecond)):48>>,
    <<RandomA:12, RandomB:62, _:6>> = crypto:strong_rand_bytes(10),
    Hex = binary:encode_hex(<<Timestamp:48, 7:4, RandomA:12, 2:2, RandomB:62>>, lowercase),
    <<A:8/binary, B:4/binary, C:4/binary, D:4/binary, E:12/binary>> = Hex,
    <<A/binary, "-", B/binary, "-", C/binary, "-", D/binary, "-", E/binary>>.

text(Value) -> unicode:characters_to_list(Value).
bin(Value) -> unicode:characters_to_binary(Value).
