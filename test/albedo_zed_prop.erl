-module(albedo_zed_prop).
-export([run/0]).

%% Property suite for the suite-owned Zed Erlang state machines: the stream
%% envelope decoder, the pre-output credential retry, the catalog cache, and
%% organizational selection during sign-in. OTP ships no property library, so
%% each section pairs seeded generators with an independent oracle that is
%% written from the documented contract rather than from the implementation.

-define(FIXTURE, zed_prop_fixture).
-define(CREDS, 'albedo_sdk@credential_store').
-define(ENDPOINT, <<"https://cloud.zed.dev">>).
-define(SEEDS, [1, 2, 3, 5, 8, 13, 21, 34]).

run() ->
    application:ensure_all_started(crypto),
    {Port, Server, Listen} = fixture_start(),
    persistent_term:put(zed_prop_port, Port),
    install_transport(),
    try
        Counts = {unwrap_cases(), organization_cases(), catalog_cases(), retry_cases()},
        {U, O, C, R} = Counts,
        io:format("Zed properties passed: ~B unwrap, ~B organization, ~B catalog groups, ~B retry cases~n",
                  [U, O, C, R])
    after unlink(Server), exit(Server, kill), gen_tcp:close(Listen), ets:delete(?FIXTURE) end,
    nil.

%% Transport
%% Gleam-built modules ship no Erlang source, so the real client is copied from
%% its abstract code and a same-named wrapper sends its cloud.zed.dev calls to
%% the local fixture. Unlike production, an unexpected origin answers an error
%% instead of raising, so a property can observe the refusal.

install_transport() ->
    {ok, {albedo_http, [{abstract_code, {raw_abstract_v1, Forms}}]}} =
        beam_lib:chunks(code:which(albedo_http), [abstract_code]),
    Renamed = [case F of
        {attribute, A, module, albedo_http} -> {attribute, A, module, albedo_zed_prop_transport};
        _ -> F
    end || F <- Forms],
    {ok, albedo_zed_prop_transport, Binary} = compile:forms(Renamed, [binary, report_errors]),
    {module, _} = code:load_binary(albedo_zed_prop_transport, "albedo_zed_prop_transport.erl", Binary),
    Exports = [E || E = {Name, _} <- albedo_http:module_info(exports), Name =/= module_info],
    Temp = filename:join("/tmp", "zed-prop-transport-" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".erl"),
    Head = ["-module(albedo_http).\n-export([",
        lists:join(",", [io_lib:format("~p/~B", [N, A]) || {N, A} <- Exports]), "]).\n"],
    Special = "open_method(O, M, <<\"https://cloud.zed.dev\", Path/binary>>, H, B, T) -> "
        "P = persistent_term:get(zed_prop_port), "
        "U = iolist_to_binary([\"http://127.0.0.1:\", integer_to_binary(P), Path]), "
        "albedo_zed_prop_transport:open_method(O, M, U, H, B, T);\n"
        "open_method(O, M, <<\"http://127.0.0.1:\", _/binary>> = U, H, B, T) -> "
        "albedo_zed_prop_transport:open_method(O, M, U, H, B, T);\n"
        "open_method(_, _, _, _, _, _) -> {error, untrusted_origin}.\n",
    Open = "open(O, U, H, B, T) -> open_method(O, <<\"POST\">>, U, H, B, T).\n",
    Rest = [begin
        Vars = lists:join(",", ["A" ++ integer_to_list(I) || I <- lists:seq(1, A)]),
        io_lib:format("~p(~s) -> albedo_zed_prop_transport:~p(~s).~n", [N, Vars, N, Vars])
    end || {N, A} <- Exports, N =/= open, N =/= open_method],
    ok = file:write_file(Temp, [Head, Special, Open, Rest]),
    {ok, albedo_http, Wrapper} = compile:file(Temp, [binary, report_errors]),
    code:purge(albedo_http),
    {module, _} = code:load_binary(albedo_http, Temp, Wrapper),
    file:delete(Temp).

%% Fixture
%% Serves the two endpoints the properties need: a catalog whose model ids name
%% the bearer token, so a cache read served to the wrong token is observable,
%% and one fresh inference token per exchange.

fixture_start() ->
    ets:new(?FIXTURE, [named_table, public, set]),
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {ip, {127, 0, 0, 1}}, {packet, http_bin}]),
    {ok, {_, Port}} = inet:sockname(Listen),
    {Port, spawn_link(fun() -> fixture(Listen) end), Listen}.

fixture(Listen) ->
    case gen_tcp:accept(Listen) of
        {ok, Socket} ->
            try fixture_request(Socket) catch Class:Reason -> io:format("fixture ~p ~p~n", [Class, Reason]) end,
            gen_tcp:close(Socket),
            fixture(Listen);
        _ -> ok
    end.

fixture_request(Socket) ->
    {ok, {http_request, Method, {abs_path, Path}, _}} = gen_tcp:recv(Socket, 0, 5000),
    Headers = fixture_headers(Socket, #{}),
    inet:setopts(Socket, [{packet, raw}]),
    Length = binary_to_integer(maps:get(<<"content-length">>, Headers, <<"0">>)),
    Body = case Length of 0 -> <<>>; _ -> {ok, B} = gen_tcp:recv(Socket, Length, 5000), B end,
    Auth = maps:get(<<"authorization">>, Headers, <<>>),
    ets:update_counter(?FIXTURE, requests, {2, 1}, {requests, 0}),
    ets:insert(?FIXTURE, {last, {Method, Path, Auth, Body}}),
    {Status, Response} = fixture_response(Method, Path, Auth),
    Bytes = iolist_to_binary(Response),
    gen_tcp:send(Socket, ["HTTP/1.1 ", integer_to_binary(Status), " Fixture\r\nConnection: close\r\nContent-Length: ",
        integer_to_binary(byte_size(Bytes)), "\r\n\r\n", Bytes]).

fixture_headers(Socket, Acc) ->
    case gen_tcp:recv(Socket, 0, 5000) of
        {ok, http_eoh} -> Acc;
        {ok, {http_header, _, Name, _, Value}} ->
            Key = string:lowercase(case is_atom(Name) of true -> atom_to_binary(Name); false -> Name end),
            fixture_headers(Socket, Acc#{Key => Value})
    end.

fixture_response(_M, <<"/models">>, Auth) ->
    Token = case binary:split(Auth, <<" ">>) of [_, T] -> T; _ -> <<>> end,
    Models = [#{<<"id">> => catalog_model(Token), <<"provider">> => <<"anthropic">>,
                <<"max_token_count">> => 1000, <<"supports_thinking">> => false}],
    {200, json:encode(#{<<"models">> => Models})};
fixture_response(_M, <<"/client/llm_tokens">>, Auth) ->
    case auth_id(Auth) of
        <<>> -> {401, <<"denied">>};
        Id ->
            N = ets:update_counter(?FIXTURE, {llm_tokens, Id}, {2, 1}, {{llm_tokens, Id}, 0}),
            {200, json:encode(#{<<"token">> => jwt(erlang:system_time(second) + 3600, N, Id)})}
    end;
fixture_response(_, _, _) ->
    {404, <<"missing">>}.

auth_id(Auth) ->
    case binary:split(Auth, <<" ">>) of [Id, _] -> Id; _ -> <<>> end.

%% The catalog names the token it was fetched with, so a cache entry served to
%% another token shows up as the wrong model.
catalog_model(Token) -> <<"model:", Token/binary>>.

jwt(Exp, Count, Id) ->
    Payload = base64:encode(iolist_to_binary(json:encode(
        #{<<"exp">> => Exp, <<"n">> => Count, <<"id">> => Id})), #{mode => urlsafe, padding => false}),
    <<"header.", Payload/binary, ".signature">>.

fixture_requests() -> case ets:lookup(?FIXTURE, requests) of [{requests, N}] -> N; [] -> 0 end.
fixture_reset() -> ets:insert(?FIXTURE, {requests, 0}).

%% Small deterministic generator: a seeded xorshift keeps every case
%% reproducible from the printed seed.
seed(S) -> rand:seed(exsss, {S, S * 7 + 1, S * 13 + 3}).

pick(List) -> lists:nth(rand:uniform(length(List)), List).

%% unwrap/1
%% The envelope decoder is the boundary between untrusted Zed JSON and the
%% typed Gleam events. Its declared type is Result(String, String): an event
%% envelope decodes to the same JSON value, a failure status never disappears,
%% every error detail is a binary, and no input raises.

unwrap_cases() ->
    Generated = lists:flatmap(fun(Seed) ->
        seed(Seed),
        Values = [json_value(2) || _ <- lists:seq(1, 40)],
        Envelopes = [{event_value, V} || V <- Values, is_map(V)]
            ++ [{event_value, V} || V <- Values, not is_map(V)]
            ++ [{bad_json, bad_json(N)} || N <- lists:seq(1, 6)],
        [unwrap_case(C) || C <- Envelopes]
    end, ?SEEDS),
    Status = unwrap_status_cases(),
    Shape = failed_message_shape(),
    Violations = [V || V <- Generated ++ Status ++ Shape, V =/= ok],
    Violations =:= [] orelse fail(unwrap_properties, Violations),
    length(Generated) + length(Status) + length(Shape).

bad_json(N) ->
    Pool = [<<"not json">>, <<"{">>, <<"[1,2]">>, <<"">>, binary:copy(<<"{">>, N), <<"{\"event\":">>],
    pick(Pool).

json_value(0) -> scalar();
json_value(Depth) ->
    case rand:uniform(3) of
        1 -> scalar();
        2 -> [json_value(Depth - 1) || _ <- lists:seq(1, rand:uniform(3))];
        3 -> maps:from_list([{pick([<<"type">>, <<"index">>, <<"delta">>, <<"text">>, <<"usage">>, unicode_key()]),
                              json_value(Depth - 1)} || _ <- lists:seq(1, rand:uniform(3))])
    end.

scalar() ->
    pick([null, true, false, 0, 1, -7, 1234567890123456789, 1.5, <<>>, <<"text">>, unicode_text(),
          <<"line\nbreak">>, <<"\"quoted\"">>, <<"back\\slash">>]).

%% Non-ASCII text is built from codepoints: this suite is compiled as Latin-1,
%% so a literal non-ASCII string in the source would carry invalid UTF-8 bytes.
unicode_text() ->
    unicode:characters_to_binary([16#e9, 32, 16#fc, 16#6e, 16#ef, 16#63, 16#6f, 16#64, 16#65]).

unicode_key() -> unicode:characters_to_binary([16#e9]).

%% A decoder reading untrusted bytes may reject them, never raise.
unwrap_safe(Envelope) ->
    try albedo_zed:unwrap(Envelope)
    catch Class:Reason -> {raised, Class, Reason} end.

unwrap_case({event_value, V}) when is_map(V) ->
    Envelope = iolist_to_binary(json:encode(#{<<"event">> => V})),
    case unwrap_safe(Envelope) of
        {ok, Out} when is_binary(Out) ->
            case json:decode(Out) of
                V -> ok;
                Decoded -> violation(unwrap_event_changed, #{envelope => Envelope, decoded => Decoded, expected => V})
            end;
        Other -> violation(unwrap_event_not_decoded, #{envelope => Envelope, result => Other})
    end;
unwrap_case({event_value, V}) ->
    Envelope = iolist_to_binary(json:encode(#{<<"event">> => V})),
    case unwrap_safe(Envelope) of
        {error, Reason} when is_binary(Reason) -> ok;
        Other -> violation(unwrap_non_object_event, #{envelope => Envelope, result => Other})
    end;
unwrap_case({bad_json, Bytes}) ->
    case unwrap_safe(Bytes) of
        {error, Reason} when is_binary(Reason) -> ok;
        Other -> violation(unwrap_invalid_json, #{input => Bytes, result => Other})
    end.

%% Every status the editor's enum can carry, and the statuses a later protocol
%% revision may add. A failed status carries its message; everything else is
%% progress, which the editor renders as no event.
unwrap_status_cases() ->
    Statuses = [
        {<<"stream_ended">>, {ok, <<"stream_ended">>}},
        {<<"started">>, {ok, <<>>}},
        {<<"queued">>, {ok, <<>>}},
        {<<"a_later_status_name">>, {ok, <<>>}},
        {<<"">>, {ok, <<>>}},
        {42, {ok, <<>>}},
        {null, {ok, <<>>}},
        {true, {ok, <<>>}},
        {[], {ok, <<>>}},
        {#{}, {ok, <<>>}},
        {#{<<"queued">> => #{<<"position">> => 1}}, {ok, <<>>}},
        {#{<<"a_later_status">> => #{<<"detail">> => 1}}, {ok, <<>>}},
        {#{<<"failed">> => #{<<"message">> => <<"quota exhausted">>}}, {error, <<"quota exhausted">>}},
        {#{<<"failed">> => #{<<"message">> => <<"">>}}, {error, <<"">>}},
        {#{<<"failed">> => #{<<"message">> => unicode_text()}}, {error, unicode_text()}},
        {#{<<"failed">> => #{}}, failure_any},
        {#{<<"failed">> => <<"boom">>}, failure_any},
        {#{<<"failed">> => null}, failure_any},
        {#{<<"failed">> => []}, failure_any}
    ],
    [begin
        Envelope = iolist_to_binary(json:encode(#{<<"status">> => Status})),
        Result = unwrap_safe(Envelope),
        case {Expected, Result} of
            {{ok, Event}, {ok, Event}} -> ok;
            {{error, Message}, {error, Message}} -> ok;
            {failure_any, {error, Reason}} when is_binary(Reason) -> ok;
            _ -> violation(unwrap_status, #{envelope => Envelope, expected => Expected, result => Result})
        end
     end || {Status, Expected} <- Statuses].

%% A failed status whose message is not text must still read as a text failure:
%% the envelope decoder is declared Result(String, String), and the daemon
%% concatenates the detail into its error text.
failed_message_shape() ->
    [begin
        Envelope = iolist_to_binary(json:encode(#{<<"status">> => #{<<"failed">> => #{<<"message">> => Message}}})),
        case unwrap_safe(Envelope) of
            {error, Detail} when is_binary(Detail) -> ok;
            {error, Detail} ->
                %% What the daemon's error text does with the detail.
                Described = try 'albedo_model@refusal':describe({refused, failed, none, Detail}) of
                    Text -> {ok, Text}
                catch Class:Reason -> {raised, Class, Reason} end,
                violation(unwrap_failed_message_not_text, #{envelope => Envelope, detail => Detail,
                                                            describe => Described});
            Other -> violation(unwrap_failed_status, #{envelope => Envelope, result => Other})
        end
     end || Message <- [42, null, [<<"a">>], #{<<"nested">> => 1}, -1.5, true]].

%% organization/2, reached through the sign-in identity check
%% The editor's account carries a default organization and a list. Sign-in uses
%% the default when the list confirms it, else the account's only personal
%% organization, else its only organization; anything else must fail closed
%% with a binary reason rather than pick one.

organization_cases() ->
    Organisations = [
        [],
        [org(<<"a">>, true)],
        [org(<<"a">>, false)],
        [org(<<"a">>, true), org(<<"b">>, false)],
        [org(<<"a">>, true), org(<<"b">>, true)],
        [org(<<"a">>, false), org(<<"b">>, false)],
        [org(<<"a">>, true), org(<<"b">>, false), org(<<"c">>, false)],
        [org(<<"a">>, false), org(<<"b">>, true), org(<<"c">>, true)],
        [#{<<"name">> => <<"nameless">>}],
        [org(<<"a">>, true), #{<<"name">> => <<"nameless">>}],
        [#{<<"id">> => 7, <<"is_personal">> => true}],
        [org(<<"a">>, <<"true">>)]
    ],
    %% The same organization listed twice is not an account document the API
    %% produces; the decoder's choice is recorded, not asserted.
    Duplicates = [[org(<<"a">>, true), org(<<"a">>, true)],
                  [org(<<"a">>, false), org(<<"a">>, false)],
                  [org(<<"a">>, true), org(<<"b">>, true), org(<<"b">>, true)]],
    Defaults = [absent, null, <<>>, <<"a">>, <<"b">>, <<"c">>, <<"missing">>, 7],
    Cases = [{Default, Orgs} || Default <- Defaults, Orgs <- Organisations],
    [organization_case(Default, Orgs) || {Default, Orgs} <- Cases],
    %% The identity check keeps the credential's ids printable ASCII, so an
    %% organization id outside that alphabet is refused there, not chosen here.
    unconstrained(non_ascii_organization,
        #{result => albedo_zed_auth:identity(<<"42">>, <<"identity-token">>,
              response(<<>>, [org(unicode_key(), true)]))}),
    [unconstrained(duplicate_organizations,
        #{default => Default, organizations => Orgs,
          result => albedo_zed_auth:identity(<<"42">>, <<"identity-token">>,
              response(Default, Orgs))})
     || Default <- [absent, <<"c">>], Orgs <- Duplicates],
    length(Cases).

org(Id, Personal) -> #{<<"id">> => Id, <<"is_personal">> => Personal}.

response(Default, Orgs) ->
    Response = #{<<"user">> => #{<<"github_login">> => <<"user">>, <<"legacy_user_id">> => 42},
                 <<"organizations">> => Orgs},
    case Default of absent -> Response; _ -> Response#{<<"default_organization_id">> => Default} end.

organization_case(Default, Orgs) ->
    Result = albedo_zed_auth:identity(<<"42">>, <<"identity-token">>, response(Default, Orgs)),
    Expected = organization_expected(Default, Orgs),
    case {Expected, Result} of
        {{ok, Id}, {ok, Credential}} ->
            Id =:= maps:get(<<"organization_id">>, Credential)
                orelse fail(organization_chosen, #{default => Default, organizations => Orgs,
                                                   expected => Id, result => Result});
        {error, {ok, _}} -> fail(organization_chosen, #{default => Default, organizations => Orgs, result => Result});
        {error, {error, Reason}} when is_binary(Reason) -> ok;
        {error, Other} -> fail(organization_failure_not_binary, #{default => Default, organizations => Orgs, result => Other});
        _ -> fail(organization_choice, #{default => Default, organizations => Orgs,
                                        expected => Expected, result => Result})
    end,
    ok.

%% An independent reading of the sign-in contract, over distinct organization
%% ids: the list is the account's set, not a sequence.
organization_expected(Default, Orgs) ->
    Ids = lists:usort([Id || #{<<"id">> := Id} <- Orgs, is_binary(Id)]),
    Personal = lists:usort([Id || #{<<"id">> := Id, <<"is_personal">> := true} <- Orgs, is_binary(Id)]),
    case is_binary(Default) andalso Default =/= <<>> of
        true -> case Ids =:= [] orelse lists:member(Default, Ids) of
                    true -> {ok, Default};
                    false -> error
                end;
        false -> case Personal of
                     [Only] -> {ok, Only};
                     [] -> case Ids of [Only] -> {ok, Only}; _ -> error end;
                     _ -> error
                 end
    end.


%% catalog_token cache: keying and expiry
%% The catalog cache is a file per (endpoint, token) with an hour's validity.
%% The oracles are the fixture's request count, an independently computed cache
%% path, and the invariant that a cache file's name and its contents name the
%% same credential.

catalog_cases() ->
    Home = home(),
    Sections = [{fetch_and_reuse, fun fetch_and_reuse/1},
                {token_isolation, fun token_isolation/1},
                {endpoint_isolation, fun endpoint_isolation/1},
                {expiry, fun expiry/1},
                {unusable_entries, fun unusable_entries/1},
                {cache_file_invariant, fun cache_file_invariant/1},
                {forced_reload, fun forced_reload/1}],
    try
        %% Each section either passes or raises; either way the others still
        %% run, so one defect reports on its own.
        Violations = lists:flatmap(fun({Name, Section}) ->
            try Section(Home) of ok -> []; Other -> [{Name, Other}]
            catch Class:Reason -> [{Name, {Class, Reason}}] end
        end, Sections),
        Violations =:= [] orelse fail(catalog_properties, Violations),
        length(Sections)
    after file:del_dir_r(Home) end.

fetch_and_reuse(Home) ->
    Token = <<"fetch-token">>,
    fixture_reset(),
    {ok, <<"anthropic">>} = albedo_zed:route(Home, ?ENDPOINT, Token, catalog_model(Token)),
    1 = fixture_requests(),
    {ok, <<"anthropic">>} = albedo_zed:route(Home, ?ENDPOINT, Token, catalog_model(Token)),
    1 = fixture_requests(),
    ok.

token_isolation(Home) ->
    First = <<"token-one">>,
    Second = <<"token-two">>,
    {ok, <<"anthropic">>} = albedo_zed:route(Home, ?ENDPOINT, First, catalog_model(First)),
    fixture_reset(),
    %% The second token's own catalog names itself, and the first token's entry
    %% is not a hit for it.
    {ok, <<"anthropic">>} = albedo_zed:route(Home, ?ENDPOINT, Second, catalog_model(Second)),
    1 = fixture_requests(),
    {error, Missing} = albedo_zed:route(Home, ?ENDPOINT, Second, catalog_model(First)),
    true = is_binary(Missing),
    ok.

endpoint_isolation(Home) ->
    Token = <<"shared-token">>,
    Local = <<"http://127.0.0.1:1">>,
    Seeded = #{<<"at">> => erlang:system_time(second), <<"models">> =>
        [#{<<"id">> => <<"seeded-only">>, <<"provider">> => <<"anthropic">>}]},
    ok = write_cache(Home, Local, Token, Seeded),
    %% The seeded entry answers for its own endpoint...
    {ok, <<"anthropic">>} = albedo_zed:route(Home, Local, Token, <<"seeded-only">>),
    %% ... and never for another endpoint's catalog.
    fixture_reset(),
    {error, Other} = albedo_zed:route(Home, ?ENDPOINT, Token, <<"seeded-only">>),
    true = is_binary(Other),
    1 = fixture_requests(),
    ok.

%% An entry written an hour ago is stale, one written a minute ago is not. The
%% boundary is a whole second, so the cases stay away from it.
expiry(Home) ->
    Now = erlang:system_time(second),
    Fresh = <<"fresh-token">>,
    Stale = <<"stale-token">>,
    Seeded = fun(At) -> #{<<"at">> => At, <<"models">> =>
        [#{<<"id">> => <<"seeded-only">>, <<"provider">> => <<"anthropic">>}]} end,
    ok = write_cache(Home, ?ENDPOINT, Fresh, Seeded(Now - 60)),
    fixture_reset(),
    {ok, <<"anthropic">>} = albedo_zed:route(Home, ?ENDPOINT, Fresh, <<"seeded-only">>),
    0 = fixture_requests(),
    ok = write_cache(Home, ?ENDPOINT, Stale, Seeded(Now - 3700)),
    fixture_reset(),
    {error, _} = albedo_zed:route(Home, ?ENDPOINT, Stale, <<"seeded-only">>),
    1 = fixture_requests(),
    ok.

%% A cache file that is not a usable entry is a miss, never a crash or a hit.
unusable_entries(Home) ->
    Cases = [
        <<"not json">>,
        <<"{}">>,
        <<"[]">>,
        <<"null">>,
        iolist_to_binary(json:encode(#{<<"models">> => [#{<<"id">> => <<"seeded-only">>}]})),
        iolist_to_binary(json:encode(#{<<"at">> => <<"soon">>, <<"models">> => [#{<<"id">> => <<"seeded-only">>}]})),
        iolist_to_binary(json:encode(#{<<"at">> => erlang:system_time(second), <<"models">> => #{}})),
        iolist_to_binary(json:encode(#{<<"at">> => erlang:system_time(second), <<"models">> => <<"none">>}))
    ],
    lists:foldl(fun({Bytes, N}, _) ->
        Token = <<"unusable-", (integer_to_binary(N))/binary>>,
        Path = cache_path(Home, ?ENDPOINT, Token),
        ok = filelib:ensure_dir(Path),
        ok = file:write_file(Path, Bytes),
        fixture_reset(),
        {error, Reason} = albedo_zed:route(Home, ?ENDPOINT, Token, <<"seeded-only">>),
        true = is_binary(Reason),
        1 = fixture_requests(),
        N + 1
    end, 0, lists:zip(Cases, lists:seq(1, length(Cases)))),
    ok.

%% Every cache file names, in its own contents, the credential in its name, so
%% no write can land under a key that does not own it.
cache_file_invariant(Home) ->
    Token = <<"invariant-token">>,
    {ok, _} = albedo_zed:route(Home, ?ENDPOINT, Token, catalog_model(Token)),
    {ok, Names} = file:list_dir_all(binary_to_list(Home)),
    Files = [list_to_binary(Name) || Name <- Names],
    Entries = [F || F <- Files, binary:match(F, <<"zed-models-">>) =/= nomatch],
    true = Entries =/= [],
    %% Entries this suite seeded by hand do not name a token; the ones a fetch
    %% wrote do, and each must sit under its own key.
    Named = lists:flatmap(fun(File) ->
        Path = filename:join(Home, File),
        {ok, Bytes} = file:read_file(Path),
        #{<<"at">> := At, <<"models">> := Models} = json:decode(Bytes),
        true = is_integer(At),
        true = is_list(Models),
        [{File, T} || #{<<"id">> := <<"model:", T/binary>>, <<"provider">> := <<"anthropic">>} <- Models]
    end, Entries),
    true = Named =/= [],
    lists:foreach(fun({File, T}) ->
        File =:= cache_file(Home, ?ENDPOINT, T)
            orelse fail(cache_file_names_other_token, #{file => File, token => T})
    end, Named),
    ok.

%% reload refetches even while an entry is valid.
forced_reload(Home) ->
    Account = cred(<<"77">>, <<"reload-account">>),
    ok = configure(Home, [Account], #{<<"r">> => profile(<<"reload-account">>)}),
    {ok, [Model]} = albedo_zed:models(Home, <<"albedo:zed:profile:r">>),
    <<"model:", Token/binary>> = Model,
    fixture_reset(),
    {ok, _} = albedo_zed:reload(Home),
    1 = fixture_requests(),
    {ok, [Model]} = albedo_zed:models(Home, <<"albedo:zed:profile:r">>),
    1 = fixture_requests(),
    %% A reload after the entry was written stores the same catalog for the
    %% same token, so the earlier entry is still valid for this token.
    #{<<"at">> := _, <<"models">> := [_]} = read_cache(Home, ?ENDPOINT, Token),
    ok.

cache_file(_Home, Endpoint, Token) ->
    Hash = binary:encode_hex(crypto:hash(sha256, <<Endpoint/binary, 0, Token/binary>>), lowercase),
    <<"zed-models-", Hash/binary, ".json">>.

cache_path(Home, Endpoint, Token) -> filename:join(Home, cache_file(Home, Endpoint, Token)).

write_cache(Home, Endpoint, Token, Value) ->
    Path = cache_path(Home, Endpoint, Token),
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, json:encode(Value)).

read_cache(Home, Endpoint, Token) ->
    {ok, Bytes} = file:read_file(cache_path(Home, Endpoint, Token)),
    json:decode(Bytes).


%% exchange/4: retry a rejected credential once, only before model output
%% The contract: a credential rejection is retried exactly once, and only when
%% no model output had been forwarded to the caller yet, so a partial turn is
%% never replayed. The oracle below is written from that sentence alone.

retry_cases() ->
    Home = home(),
    Account = cred(<<"42">>, <<"prop-account">>),
    ok = configure(Home, [Account], #{<<"p">> => profile(<<"prop-account">>)}),
    try
        Scenarios = lists:flatmap(fun(Seed) ->
            seed(Seed),
            [{Seed, scenario()} || _ <- lists:seq(1, 20)]
        end, ?SEEDS),
        put(retry_coverage, #{scenarios => 0, retried => 0, rejected_after_output => 0,
                              rejected_before_output => 0, other_failures => 0}),
        lists:foreach(fun({Seed, Scenario}) -> retry_case(Home, Seed, Scenario) end, Scenarios),
        io:format("retry coverage: ~p~n", [get(retry_coverage)]),
        erase(retry_coverage),
        double_rejection(Home),
        length(Scenarios)
    after file:del_dir_r(Home) end.

%% Model output: what a retry would replay.
output_pool() ->
    [{started, <<"response">>},
     {text_delta, 0, 0, <<"hello">>},
     {thinking_delta, <<"thinking">>},
     {arguments_delta, 0, <<"call">>, <<"{}">>},
     {served, none, none}].

%% What the response reports about itself, before any output.
progress_pool() ->
    [{responded, 200}, {responded, 401}, {responded, 500},
     {refusal_headers, 401, [{<<"x">>, <<"y">>}]},
     {refusal_headers, 429, []}].

scenario() ->
    {events(0, 4, progress_pool() ++ output_pool()), outcome(),
     events(0, 3, output_pool() ++ progress_pool() -- [{responded, 401}]), outcome()}.

events(Min, Max, Pool) ->
    N = Min + rand:uniform(Max - Min + 1) - 1,
    [pick(Pool) || _ <- lists:seq(1, N)].

outcome() ->
    pick([{error, {refused, credential_rejected, {some, 401}, <<"expired">>}},
          {error, {refused, credential_rejected, {some, 401}, <<"expired">>}},
          {error, {refused, rate_limited, {some, 429}, <<"slow down">>}},
          {error, {refused, failed, none, <<"boom">>}},
          {error, cancelled},
          {ok, turn} ]).

retry_case(Home, Seed, {Events1, Outcome1, Events2, Outcome2}) ->
    put(attempts, []), put(forwarded, []),
    Run = fun(_Endpoint, Token, Emit) ->
        N = length(get(attempts)) + 1,
        put(attempts, get(attempts) ++ [{N, Token}]),
        {Events, Outcome} = case N of
            1 -> {Events1, Outcome1};
            2 -> {Events2, Outcome2};
            _ -> {[], {error, third_attempt}}
        end,
        _ = [Emit(E) || E <- Events],
        Outcome
    end,
    OnEvent = fun(Event) -> put(forwarded, get(forwarded) ++ [Event]), continue end,
    Result = albedo_zed:exchange(Home, <<"p">>, Run, OnEvent),
    cover(length(get(attempts)), Events1, Outcome1),
    Attempts = get(attempts),
    Forwarded = get(forwarded),
    erase(attempts), erase(forwarded),
    {Runs, Events, Expected} = retry_expected(Events1, Outcome1, Events2, Outcome2),
    Context = #{seed => Seed, first => Events1, first_outcome => Outcome1,
                second => Events2, second_outcome => Outcome2,
                runs => Attempts, forwarded => Forwarded, result => Result},
    [N || {N, _} <- Attempts] =:= Runs orelse fail(retry_attempts, Context),
    Forwarded =:= Events orelse fail(retry_forwarded, Context#{expected_events => Events}),
    Result =:= Expected orelse fail(retry_result, Context#{expected_result => Expected}),
    case Attempts of
        [{1, First}, {2, Second}] -> First =/= Second orelse fail(retry_token_not_refreshed, Context);
        _ -> ok
    end,
    ok.

%% Behavioral coverage: which shapes the generated histories reached.
cover(Runs, Events1, Outcome1) ->
    Stats = get(retry_coverage),
    Output = lists:any(fun is_output/1, Events1),
    Category = case {rejected(Outcome1), Output} of
        {true, true} -> rejected_after_output;
        {true, false} -> rejected_before_output;
        {false, _} -> other_failures
    end,
    put(retry_coverage, Stats#{
        scenarios := maps:get(scenarios, Stats) + 1,
        retried := maps:get(retried, Stats) + case Runs > 1 of true -> 1; false -> 0 end,
        Category := maps:get(Category, Stats) + 1}).

%% Model output is anything but a status or refusal header: those describe the
%% response, and a refusal's headers precede its error. A 401 status is not an
%% answer to the user's request, so the caller never sees it.
retry_expected(Events1, Outcome1, Events2, Outcome2) ->
    Forwarded = [E || E <- Events1, E =/= {responded, 401}],
    case rejected(Outcome1) andalso not lists:any(fun is_output/1, Events1) of
        true -> {[1, 2], Forwarded ++ Events2, Outcome2};
        false -> {[1], Forwarded, Outcome1}
    end.

is_output({responded, _}) -> false;
is_output({refusal_headers, _, _}) -> false;
is_output(_) -> true.

rejected({error, {refused, credential_rejected, _, _}}) -> true;
rejected(_) -> false.

%% A second rejection ends the exchange: retry once, never twice.
double_rejection(Home) ->
    Rejection = {error, {refused, credential_rejected, {some, 401}, <<"expired">>}},
    put(attempts, []), put(forwarded, []),
    Run = fun(_Endpoint, Token, Emit) ->
        put(attempts, get(attempts) ++ [{length(get(attempts)) + 1, Token}]),
        Emit({responded, 401}),
        Rejection
    end,
    OnEvent = fun(Event) -> put(forwarded, get(forwarded) ++ [Event]), continue end,
    Rejection = albedo_zed:exchange(Home, <<"p">>, Run, OnEvent),
    Attempts = get(attempts), Forwarded = get(forwarded),
    erase(attempts), erase(forwarded),
    2 = length(Attempts),
    [{1, First}, {2, Second}] = Attempts,
    true = First =/= Second,
    %% The first attempt's 401 status is withheld from the caller; the retried
    %% attempt's is not. Recorded, not asserted: which of the two is intended is
    %% the provider stream's business, not the retry's.
    unconstrained(double_401_forwarded, #{forwarded => Forwarded}),
    ok.

%% Helpers

home() ->
    Home = list_to_binary(filename:join("/tmp", "zed-prop-home-" ++
        integer_to_list(erlang:unique_integer([positive])))),
    ok = filelib:ensure_dir(filename:join(Home, <<"dummy">>)),
    Home.

cred(Id, Public) ->
    Response = #{<<"user">> => #{<<"github_login">> => <<"user-", Id/binary>>,
                                <<"legacy_user_id">> => binary_to_integer(Id)},
                 <<"organizations">> => [#{<<"id">> => <<"org-", Id/binary>>, <<"is_personal">> => true}]},
    {ok, Credential} = albedo_zed_auth:identity(Id, <<"access-token-", Id/binary>>, Response),
    Expiry = erlang:system_time(second) + 3600,
    %% The signed-in token names itself, so a refreshed one can never look
    %% like it by accident.
    Credential#{<<"jwt">> => jwt(Expiry, <<"signed-in">>, Id), <<"jwt_expires">> => Expiry,
                <<"_albedo_account_id">> => Public}.

profile(Public) ->
    #{<<"extension">> => <<"zed">>, <<"accountId">> => Public, <<"baseUrl">> => ?ENDPOINT}.

configure(Home, Values, Profiles) ->
    {ok, nil} = ?CREDS:write(filename:join(Home, <<"creds.json">>),
        #{<<"accounts">> => #{<<"zed">> => Values}}),
    {ok, nil} = ?CREDS:write(filename:join(Home, <<"config.json">>),
        #{<<"active">> => <<"p">>, <<"providers">> => Profiles}),
    ok.

violation(Tag, Context) -> {Tag, Context}.

fail(Tag, Context) -> error({property_failed, Tag, Context}).

%% A behaviour the contract does not decide; recorded for the report.
unconstrained(Tag, Context) -> io:format("observation ~p: ~p~n", [Tag, Context]).
