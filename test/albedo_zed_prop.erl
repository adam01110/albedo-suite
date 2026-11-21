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
        %% Each group runs on its own, so one defect does not hide the rest.
        Groups = [{unwrap, fun unwrap_cases/0},
                  {organization, fun organization_cases/0},
                  {catalog, fun catalog_cases/0},
                  {retry, fun retry_cases/0}],
        Counts = lists:map(fun({Name, Group}) ->
            try Group() of Count -> {Name, Count}
            catch Class:Reason -> {Name, {Class, Reason}} end
        end, Groups),
        Failures = [F || {_, V} = F <- Counts, not is_integer(V)],
        Failures =:= [] orelse fail(properties, Failures),
        io:format("Zed properties passed: ~p~n", [Counts])
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

%% A staged catalog body answers /models verbatim, so a property can serve a
%% generated payload; otherwise the fixture names the token's own model.
fixture_response(_M, <<"/models">>, Auth) ->
    case ets:lookup(?FIXTURE, catalog) of
        [{catalog, Bytes}] -> {200, Bytes};
        [] -> default_catalog(Auth)
    end;
fixture_response(_M, <<"/client/llm_tokens">>, Auth) ->
    llm_token(Auth);
fixture_response(_, _, _) ->
    {404, <<"missing">>}.

default_catalog(Auth) ->
    Token = case binary:split(Auth, <<" ">>) of [_, T] -> T; _ -> <<>> end,
    Models = [#{<<"id">> => catalog_model(Token), <<"provider">> => <<"anthropic">>,
                <<"max_token_count">> => 1000, <<"supports_thinking">> => false}],
    {200, json:encode(#{<<"models">> => Models})}.

llm_token(Auth) ->
    case auth_id(Auth) of
        <<>> -> {401, <<"denied">>};
        Id ->
            N = ets:update_counter(?FIXTURE, {llm_tokens, Id}, {2, 1}, {{llm_tokens, Id}, 0}),
            {200, json:encode(#{<<"token">> => jwt(erlang:system_time(second) + 3600, N, Id)})}
    end.

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
%% The account document's organization choice is documented as: the default
%% organization stands when it names one of the account's organizations, else
%% the account's only personal organization, else its only organization; any
%% other shape fails closed with a binary reason rather than picking one. The
%% oracle below is an independent reading of that sentence. The payloads are
%% generated: several organizations, missing, null and mistyped fields, non-map
%% entries, and every shape of default_organization_id.

organization_cases() ->
    Family = lists:flatmap(fun(Seed) ->
        seed(Seed),
        [organization_payload() || _ <- lists:seq(1, 24)]
    end, ?SEEDS),
    put(org_coverage, #{generated => 0, default_confirmed => 0, default_stranger => 0,
                        personal_only => 0, sole_organization => 0, no_choice => 0,
                        malformed_list => 0, duplicate_ids => 0}),
    erase(org_violations),
    lists:foreach(fun(Payload) -> organization_case(Payload) end, Family),
    io:format("organization coverage: ~p~n", [get(org_coverage)]),
    erase(org_coverage),
    org_report(),
    %% The identity check keeps the credential's ids printable ASCII, so an
    %% organization id outside that alphabet is refused there, not chosen here.
    unconstrained(non_ascii_organization,
        #{result => albedo_zed_auth:identity(<<"42">>, <<"identity-token">>,
              response(<<>>, [org(unicode_key(), true)]))}),
    %% The same organization listed twice is not an account document the API
    %% produces; the decoder's choice is recorded, not asserted.
    Duplicates = [[org(<<"a">>, true), org(<<"a">>, true)],
                  [org(<<"a">>, false), org(<<"a">>, false)],
                  [org(<<"a">>, true), org(<<"b">>, true), org(<<"b">>, true)]],
    [unconstrained(duplicate_organizations,
        #{default => Default, organizations => Orgs,
          result => albedo_zed_auth:identity(<<"42">>, <<"identity-token">>,
              response(Default, Orgs))})
     || Default <- [absent, <<"c">>], Orgs <- Duplicates],
    account_selection_cases(),
    length(Family).

org(Id, Personal) -> #{<<"id">> => Id, <<"is_personal">> => Personal}.

response(Default, Orgs) ->
    Response = #{<<"user">> => #{<<"github_login">> => <<"user">>, <<"legacy_user_id">> => 42},
                 <<"organizations">> => Orgs},
    case Default of absent -> Response; _ -> Response#{<<"default_organization_id">> => Default} end.

%% A generated account document. `organizations` is absent when the key is
%% missing, which the schema documents as an optional list.
organization_payload() ->
    Orgs = org_entries(),
    #{default => org_default(Orgs), organizations => Orgs}.

org_entries() ->
    case rand:uniform(10) of
        1 -> absent;
        2 -> pick([null, #{}, <<"none">>, 42]);
        _ -> [org_entry() || _ <- lists:seq(1, rand:uniform(5) - 1)]
    end.

org_entry() ->
    Id = pick([<<"a">>, <<"b">>, <<"c">>, <<"org-1">>, <<"">>, unicode_key()]),
    Personal = pick([true, false]),
    case rand:uniform(9) of
        1 -> #{<<"id">> => Id};
        2 -> #{<<"is_personal">> => Personal};
        3 -> #{<<"id">> => pick([null, 7, true, [], #{<<"n">> => 1}]),
               <<"is_personal">> => Personal};
        4 -> #{<<"id">> => Id, <<"is_personal">> => pick([null, <<"true">>, 1, 0, []])};
        5 -> pick([null, 42, <<"not a map">>, [], [1, 2]]);
        6 -> #{<<"id">> => Id, <<"is_personal">> => Personal, <<"name">> => <<"extra">>};
        _ -> #{<<"id">> => Id, <<"is_personal">> => Personal}
    end.

org_default(Orgs) ->
    Present = case Orgs of
                  L when is_list(L) -> [Id || #{<<"id">> := Id} <- L, is_binary(Id), Id =/= <<>>];
                  _ -> []
              end,
    case rand:uniform(10) of
        1 -> null;
        2 -> <<>>;
        3 -> pick([7, [], #{}, true, 1.5]);
        4 when Present =/= [] -> pick(Present);
        5 -> pick([<<"a">>, <<"b">>, <<"stranger">>]);
        _ -> absent
    end.

organization_case(Payload) ->
    Response = case Payload of
                   #{default := absent, organizations := absent} -> response(absent, []);
                   #{default := absent, organizations := Orgs} when Orgs =/= absent ->
                       Base = response(absent, []), Base#{<<"organizations">> => Orgs};
                   #{default := Default, organizations := absent} -> response(Default, []);
                   #{default := Default, organizations := Orgs} ->
                       response(Default, Orgs)
               end,
    Result = safe_call(fun() -> albedo_zed_auth:identity(<<"42">>, <<"identity-token">>, Response) end),
    {Branch, Expected} = organization_expected(Payload),
    Ambiguous = organization_ambiguous(Payload),
    cover_organization(Branch, Ambiguous),
    Context = #{payload => Payload, expected => Expected, result => Result, ambiguous => Ambiguous},
    case {Expected, Result} of
        {{ok, Id}, {ok, Credential}} when is_map(Credential) ->
            case maps:get(<<"organization_id">>, Credential, undefined) of
                Id -> ok;
                Other -> record(org_violations, organization_chosen, Context#{chosen => Other})
            end;
        {{ok, _}, {error, Reason}} when is_binary(Reason) ->
            Ambiguous orelse record(org_violations, organization_refused, Context);
        {error, {error, Reason}} when is_binary(Reason) -> ok;
        {error, {error, Reason}} ->
            record(org_violations, organization_failure_not_binary, Context#{reason => Reason});
        {error, {ok, _}} ->
            Ambiguous orelse record(org_violations, organization_chosen_without_choice, Context);
        _ ->
            record(org_violations, organization_result, Context)
    end.

%% An independent reading of the documented choice chain, over the account's
%% distinct organization ids.
organization_expected(#{organizations := Orgs}) when Orgs =/= absent, not is_list(Orgs) ->
    {malformed_list, error};
organization_expected(#{default := Default, organizations := Orgs}) ->
    Entries = case Orgs of absent -> []; List -> [E || E <- List, is_map(E)] end,
    Ids = [Id || #{<<"id">> := Id} <- Entries, is_binary(Id)],
    Personal = [Id || #{<<"id">> := Id, <<"is_personal">> := true} <- Entries, is_binary(Id)],
    {Branch, Choice} = case is_binary(Default) andalso Default =/= <<>> of
        true ->
            case lists:usort(Ids) of
                [] -> {default_confirmed, Default};
                All -> case lists:member(Default, All) of
                           true -> {default_confirmed, Default};
                           false -> {default_stranger, error}
                       end
            end;
        false ->
            case lists:usort(Personal) of
                [Only] -> {personal_only, Only};
                [] -> case lists:usort(Ids) of
                          [Single] -> {sole_organization, Single};
                          _ -> {no_choice, error}
                      end;
                _ -> {no_choice, error}
            end
    end,
    {Branch, case Choice of
                 error -> error;
                 Id -> case credential_id(Id) of
                           true -> {ok, Id};
                           false -> error
                       end
             end}.

%% The identity check keeps the credential's ids printable ASCII.
credential_id(Id) ->
    is_binary(Id) andalso byte_size(Id) > 0 andalso
        lists:all(fun(C) -> C >= 16#21 andalso C =< 16#7e end, binary_to_list(Id)).

%% Duplicate ids matter only where the chain counts entries rather than testing
%% membership: a default naming a listed id is unaffected.
organization_ambiguous(#{default := Default, organizations := Orgs}) when is_list(Orgs) ->
    case is_binary(Default) andalso Default =/= <<>> of
        true -> false;
        false ->
            Entries = [E || E <- Orgs, is_map(E)],
            Ids = [Id || #{<<"id">> := Id} <- Entries, is_binary(Id)],
            length(Ids) =/= length(lists:usort(Ids))
    end;
organization_ambiguous(_) -> false.

cover_organization(Branch, Ambiguous) ->
    Stats = get(org_coverage),
    Key = case Ambiguous of true -> duplicate_ids; false -> Branch end,
    put(org_coverage, Stats#{generated := maps:get(generated, Stats) + 1,
                             Key := maps:get(Key, Stats) + 1}).

org_report() ->
    case get(org_violations) of
        undefined -> ok;
        [] -> ok;
        Violations -> fail(organization_properties, lists:sublist(lists:reverse(Violations), 30))
    end.

%% Selection by saved account id: the post-login model picker names the public
%% account identity it was saved for, and exactly one stored account carries
%% it; zero or several is unavailable rather than another account's token.
account_selection_cases() ->
    Home = home(),
    try
        Family = lists:flatmap(fun(Seed) ->
            seed(Seed),
            [account_payload() || _ <- lists:seq(1, 12)]
        end, ?SEEDS),
        erase(account_violations),
        lists:foreach(fun(Payload) -> account_selection_case(Home, Payload) end, Family),
        account_report(),
        length(Family)
    after file:del_dir_r(Home) end.

account_payload() ->
    Publics = [pick([<<"p1">>, <<"p2">>, <<"p3">>]) || _ <- lists:seq(1, rand:uniform(4))],
    {[account_value(P) || P <- Publics], pick([<<"p1">>, <<"p2">>, <<"p3">>, <<"nobody">>])}.

account_value(Public) ->
    Expiry = erlang:system_time(second) + 3600,
    Base = #{<<"user_id">> => <<"42">>, <<"access_token">> => <<"access-token">>,
             <<"github_login">> => <<"user">>, <<"organization_id">> => <<"org-42">>,
             <<"jwt">> => jwt(Expiry, Public, <<"42">>), <<"jwt_expires">> => Expiry},
    case rand:uniform(6) of
        1 -> Base;
        2 -> Base#{<<"_albedo_account_id">> => null};
        _ -> Base#{<<"_albedo_account_id">> => Public}
    end.

account_selection_case(Home, {Values, Wanted}) ->
    ok = write_accounts(Home, Values),
    Result = safe_call(fun() -> albedo_zed_auth:access_account(Home, Wanted) end),
    Expected = case [C || C <- Values, maps:get(<<"_albedo_account_id">>, C, null) =:= Wanted] of
                   [C] -> {ok, maps:get(<<"jwt">>, C)};
                   _ -> unavailable
               end,
    Context = #{wanted => Wanted, stored => [maps:get(<<"_albedo_account_id">>, C, null) || C <- Values],
                expected => Expected, result => Result},
    case {Expected, Result} of
        {{ok, Jwt}, {ok, Jwt}} -> ok;
        {unavailable, {error, Reason}} when is_binary(Reason) -> ok;
        _ -> record(account_violations, account_selection, Context)
    end.

account_report() ->
    case get(account_violations) of
        undefined -> ok;
        [] -> ok;
        Violations -> fail(account_selection_properties, lists:sublist(lists:reverse(Violations), 20))
    end.

write_accounts(Home, Values) ->
    {ok, nil} = ?CREDS:write(filename:join(Home, <<"creds.json">>),
        #{<<"accounts">> => #{<<"zed">> => Values}}),
    ok.

%% Violations are collected so one defect does not hide the rest.
record(Key, Tag, Context) ->
    case get(Key) of
        undefined -> put(Key, [{Tag, Context}]);
        Stored -> put(Key, lists:sublist([{Tag, Context} | Stored], 200))
    end.

safe_call(Fun) ->
    try Fun() catch Class:Reason -> {raised, Class, Reason} end.

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
                {forced_reload, fun forced_reload/1},
                {generated_catalogs, fun generated_catalogs/1}],
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


%% A generated /models payload exercises the cache, the model list, lookup and
%% routing. The oracles below are an independent reading of the documented
%% projection: an entry is usable when it is an object with a text id; a
%% disabled entry stays in the cache but is left out of the model list and out
%% of lookup, while routing names the reason it cannot be selected.

generated_catalogs(Home) ->
    Family = lists:flatmap(fun(Seed) ->
        seed(Seed),
        [catalog_payload() || _ <- lists:seq(1, 14)]
    end, ?SEEDS),
    put(catalog_coverage, #{generated => 0, entries => 0, usable_entries => 0,
                            disabled_entries => 0, unknown_providers => 0,
                            duplicate_ids => 0, malformed => 0, empty_catalog => 0}),
    erase(catalog_violations),
    lists:foldl(fun({N, Payload}, _) -> catalog_case(Home, N, Payload) end, 0,
                lists:zip(lists:seq(1, length(Family)), Family)),
    io:format("catalog coverage: ~p~n", [get(catalog_coverage)]),
    erase(catalog_coverage),
    catalog_report(),
    future_dated_case(Home),
    ok.

catalog_payload() ->
    Value = case rand:uniform(8) of
        1 -> pick([[], <<"text">>, 42, null, true]);
        2 -> #{<<"models">> => pick([null, <<"none">>, 42, #{}, []])};
        3 -> #{<<"other">> => <<"field">>};
        _ -> #{<<"models">> => [model_entry() || _ <- lists:seq(1, rand:uniform(5) - 1)]}
    end,
    case rand:uniform(12) of
        1 -> {raw, pick([<<"not json">>, <<"{">>, <<"[]">>, <<"">>, <<"{\"models\":">>])};
        _ -> {json, Value}
    end.

model_entry() ->
    Id = pick([<<"alpha">>, <<"beta">>, <<"gamma">>, <<"">>, unicode_key()]),
    Base = #{<<"id">> => Id,
             <<"provider">> => pick([<<"anthropic">>, <<"open_ai">>, <<"google">>, <<"x_ai">>,
                                     <<"mistral">>, <<"">>])},
    With = case rand:uniform(8) of
        1 -> Base;
        2 -> Base#{<<"max_token_count">> => pick([0, -5, 1000, <<"big">>, 8192.5])};
        3 -> Base#{<<"supports_thinking">> => pick([true, false, <<"true">>, null, 0]),
                    <<"supported_effort_levels">> => pick([[],
                        [#{<<"value">> => pick([<<"low">>, <<"high">>, <<"bogus">>, <<"none">>, <<"max">>])}],
                        [#{<<"value">> => 3}], [#{}]])};
        4 -> Base#{<<"supports_images">> => pick([true, false, <<"yes">>])};
        5 -> Base#{<<"supported_effort_levels">> => pick([[], [#{<<"value">> => <<"low">>}], 7, <<"low">>])};
        6 -> Base#{<<"max_output_tokens">> => pick([4000, 0, -1, <<"x">>]),
                    <<"max_token_count_in_max_mode">> => pick([2000, 0, null])};
        7 -> maps:remove(<<"provider">>, Base);
        _ -> Base
    end,
    case rand:uniform(9) of
        1 -> With#{<<"is_disabled">> => true,
                   <<"disabled_reason">> => pick([<<"plan does not include this model">>, <<"">>, 42])};
        2 -> With#{<<"is_disabled">> => pick([false, <<"true">>, null])};
        3 -> maps:remove(<<"id">>, With);
        4 -> With#{<<"id">> => pick([null, 7, true])};
        5 -> pick([null, 7, <<"flat">>, [1, 2]]);
        _ -> With
    end.

catalog_case(Home, N, Payload) ->
    Tag = integer_to_binary(N),
    Id = <<"cat-", Tag/binary>>,
    Expiry = erlang:system_time(second) + 3600,
    Token = jwt(Expiry, N, Id),
    Account = #{<<"user_id">> => <<"42">>, <<"access_token">> => <<"access-token">>,
                <<"github_login">> => <<"user">>, <<"organization_id">> => <<"org-42">>,
                <<"jwt">> => Token, <<"jwt_expires">> => Expiry,
                <<"_albedo_account_id">> => Id},
    ok = write_accounts(Home, [Account]),
    Endpoint = <<"albedo:zed:account:", Id/binary>>,
    Body = case Payload of
               {json, Value} -> iolist_to_binary(json:encode(Value));
               {raw, Bytes} -> Bytes
           end,
    ets:insert(?FIXTURE, {catalog, Body}),
    try
        {Branch, ExpectedModels, Valid} = catalog_expected(Payload),
        cover_catalog(Branch, Valid),
        fixture_reset(),
        Models = safe_call(fun() -> albedo_zed:models(Home, Endpoint) end),
        Context = #{payload => Payload, expected => ExpectedModels, result => Models},
        case {ExpectedModels, Models} of
            {{ok, Ids}, {ok, Ids}} -> cache_reuse(Home, Endpoint, Ids, Context);
            {{ok, _}, _} -> record(catalog_violations, model_list, Context);
            {error, {error, Reason}} when is_binary(Reason) -> ok;
            {error, _} -> record(catalog_violations, fetch_error, Context)
        end,
        Fetched = case Models of
                      {ok, _} -> listed;
                      {error, FetchReason} -> {failed, FetchReason};
                      _ -> {raised, Models}
                  end,
        Probes = catalog_probes(Valid),
        lists:foreach(fun(Probe) -> lookup_check(Home, Endpoint, Fetched, Valid, Probe) end, Probes),
        lists:foreach(fun(Probe) -> route_check(Home, Token, Fetched, Valid, Probe) end, Probes)
    after ets:delete(?FIXTURE, catalog) end.

catalog_expected({raw, _}) -> {malformed, error, []};
catalog_expected({json, Value}) ->
    case Value of
        #{<<"models">> := Entries} when is_list(Entries) ->
            Valid = catalog_valid(Entries),
            case Valid of
                [] -> {empty_catalog, {ok, []}, []};
                _ -> {catalog, {ok, [maps:get(<<"id">>, E) || E <- Valid, enabled(E)]}, Valid}
            end;
        _ -> {malformed, error, []}
    end.

%% A usable entry is an object with a text id; nothing else is kept.
catalog_valid(Entries) ->
    [E || E <- Entries, is_map(E), is_binary(maps:get(<<"id">>, E, undefined))].

enabled(M) -> maps:get(<<"is_disabled">>, M, false) =/= true.

cover_catalog(malformed, _) ->
    put(catalog_coverage, (get(catalog_coverage))#{generated := 1 +
        maps:get(generated, get(catalog_coverage)), malformed := 1 +
        maps:get(malformed, get(catalog_coverage))});
cover_catalog(Branch, Valid) ->
    Stats = get(catalog_coverage),
    Disabled = length([E || E <- Valid, not enabled(E)]),
    Unknown = length([E || E <- Valid, enabled(E),
                           not lists:member(maps:get(<<"provider">>, E, undefined),
                               [<<"anthropic">>, <<"open_ai">>, <<"google">>, <<"x_ai">>])]),
    Ids = [maps:get(<<"id">>, E) || E <- Valid],
    Extra = case Branch of empty_catalog -> #{empty_catalog => 1}; _ -> #{} end,
    put(catalog_coverage, maps:merge(Stats#{generated := maps:get(generated, Stats) + 1,
                                            entries := maps:get(entries, Stats) + length(Valid),
                                            usable_entries := maps:get(usable_entries, Stats) + length(Valid),
                                            disabled_entries := maps:get(disabled_entries, Stats) + Disabled,
                                            unknown_providers := maps:get(unknown_providers, Stats) + Unknown,
                                            duplicate_ids := maps:get(duplicate_ids, Stats) +
                                                case length(Ids) =/= length(lists:usort(Ids)) of
                                                    true -> 1; false -> 0
                                                end}, Extra)).

%% A second call within the hour answers from the cache with the same list.
cache_reuse(Home, Endpoint, Ids, Context) ->
    fixture_reset(),
    case safe_call(fun() -> albedo_zed:models(Home, Endpoint) end) of
        {ok, Ids} ->
            case fixture_requests() of
                0 -> ok;
                N -> record(catalog_violations, cache_missed, Context#{requests => N})
            end;
        Other -> record(catalog_violations, cache_reuse, Context#{second => Other})
    end.

%% Ids worth asking about: a disabled or unroutable entry first, then the rest
%% of what the payload offers, then a name the catalog does not hold.
catalog_probes(Valid) ->
    All = lists:usort([maps:get(<<"id">>, E) || E <- Valid]),
    Special = lists:usort([maps:get(<<"id">>, E) || E <- Valid,
                           not enabled(E) orelse not maps:is_key(<<"provider">>, E)]),
    Rest = [Id || Id <- All, not lists:member(Id, Special)],
    lists:sublist(Special, 3) ++ lists:sublist(Rest, 2) ++ [<<"absent-model">>].

ambiguous_id(Valid, Id) ->
    length([E || E <- Valid, maps:get(<<"id">>, E) =:= Id]) > 1.

catalog_lookup(Valid, Endpoint, Id) ->
    Matches = [E || E <- Valid, maps:get(<<"id">>, E) =:= Id],
    case Matches of
        [] -> none;
        _ -> case ambiguous_id(Valid, Id) of
                 true -> ambiguous;
                 false -> case [E || E <- Matches, enabled(E)] of
                              [] -> none;
                              [E | _] -> expected_info(Endpoint, E)
                          end
             end
    end.

lookup_check(Home, Endpoint, Fetched, Valid, Id) ->
    Expected = case Fetched of
                   listed -> catalog_lookup(Valid, Endpoint, Id);
                   _ -> none
               end,
    Result = safe_call(fun() -> albedo_zed:lookup(Home, Endpoint, Id) end),
    Context = #{id => Id, expected => Expected, result => Result},
    case Result of
        {raised, _, _} -> record(catalog_violations, lookup_crashed, Context);
        _ when Expected =:= ambiguous -> ok;
        none when Expected =:= none -> ok;
        {some, Info} when Expected =/= none ->
            case lookup_matches(Expected, Info) of
                true -> ok;
                false -> record(catalog_violations, lookup_projection, Context)
            end;
        _ -> record(catalog_violations, lookup_shape, Context)
    end.

%% The documented projection of one catalog entry into the harness's model
%% info: positive limits only, image support adds a modality, a model without
%% thinking offers no effort, and the efforts the entry names are deduplicated
%% and ordered lowest first.
expected_info(Endpoint, E) ->
    Levels = case maps:get(<<"supported_effort_levels">>, E, []) of
                 L when is_list(L) -> L;
                 _ -> []
             end,
    EffortNames = case maps:get(<<"supports_thinking">>, E, true) of
                      false -> [];
                      _ -> effort_names([V || #{<<"value">> := V} <- Levels, is_binary(V)])
                  end,
    {info, #{id => maps:get(<<"id">>, E),
             max_tokens => expect_positive(maps:get(<<"max_token_count">>, E, 0)),
             max_tokens_max => expect_positive(maps:get(<<"max_token_count_in_max_mode">>, E, 0)),
             max_output => expect_positive(maps:get(<<"max_output_tokens">>, E, 0)),
             modalities => case maps:get(<<"supports_images">>, E, false) of
                               true -> [<<"text">>, <<"image">>];
                               _ -> [<<"text">>]
                           end,
             efforts => EffortNames,
             endpoint => Endpoint}}.

expect_positive(N) when is_integer(N), N > 0 -> {some, N};
expect_positive(_) -> none.

%% The names the catalog offers, deduplicated and ordered lowest first. Only the
%% naming is borrowed from the model module; which names survive is the model's
%% own list.
effort_names(Names) ->
    Known = [<<"none">>, <<"minimal">>, <<"low">>, <<"medium">>, <<"high">>, <<"xhigh">>, <<"max">>],
    Unique = lists:usort([N || N <- Names, lists:member(N, Known)]),
    Ranked = lists:sort([{rank(N, Known, 1), N} || N <- Unique]),
    [N || {_, N} <- Ranked].

rank(N, [N | _], I) -> I;
rank(N, [_ | Rest], I) -> rank(N, Rest, I + 1).

lookup_matches({info, Exp}, Info) when is_tuple(Info), tuple_size(Info) =:= 14,
                                       element(1, Info) =:= model_info ->
    element(2, Info) =:= maps:get(id, Exp)
        andalso element(3, Info) =:= <<"zed">>
        andalso element(4, Info) =:= maps:get(max_tokens, Exp)
        andalso element(5, Info) =:= maps:get(max_tokens_max, Exp)
        andalso element(6, Info) =:= maps:get(max_output, Exp)
        andalso element(7, Info) =:= maps:get(modalities, Exp)
        andalso element(8, Info) =:= {some, maps:get(endpoint, Exp)}
        andalso element(9, Info) =:= []
        andalso element(10, Info) =:= <<"Zed /models">>
        andalso effort_names_of(element(11, Info)) =:= maps:get(efforts, Exp)
        andalso element(12, Info) =:= none
        andalso element(13, Info) =:= <<"provider">>
        andalso element(14, Info) =:= none;
lookup_matches(_, _) -> false.

effort_names_of(Efforts) when is_list(Efforts) -> [albedo_model:effort_name(E) || E <- Efforts];
effort_names_of(_) -> invalid.

catalog_route(Valid, Id) ->
    case [E || E <- Valid, maps:get(<<"id">>, E) =:= Id] of
        [] -> {error, absent};
        [First | _] ->
            case ambiguous_id(Valid, Id) of
                true -> ambiguous;
                false -> route_first(First)
            end
    end.

route_first(#{<<"is_disabled">> := true, <<"disabled_reason">> := Reason})
        when is_binary(Reason), Reason =/= <<>> ->
    {error, {disabled, Reason}};
route_first(#{<<"is_disabled">> := true}) -> {error, disabled};
route_first(#{<<"provider">> := Provider}) ->
    case lists:member(Provider, [<<"anthropic">>, <<"open_ai">>, <<"google">>, <<"x_ai">>]) of
        true -> {ok, Provider};
        false -> {error, unsupported_provider}
    end;
route_first(_) -> {error, unroutable}.

route_check(Home, Token, Fetched, Valid, Id) ->
    %% An unavailable catalog is reported as such, whatever model was asked for.
    Expected = case Fetched of
                   listed -> catalog_route(Valid, Id);
                   {failed, Reason} -> {error, {catalog, Reason}};
                   _ -> {error, {catalog, any}}
               end,
    Result = safe_call(fun() -> albedo_zed:route(Home, ?ENDPOINT, Token, Id) end),
    Context = #{id => Id, expected => Expected, result => Result},
    case {Expected, Result} of
        {ambiguous, _} -> ok;
        {_, {raised, _, _}} -> record(catalog_violations, route_crashed, Context);
        {{ok, Provider}, {ok, Provider}} -> ok;
        {{ok, _}, _} -> record(catalog_violations, route_provider, Context);
        {{error, Category}, {error, Message}} when is_binary(Message) ->
            case route_message_matches(Category, Message) of
                true -> ok;
                false -> record(catalog_violations, route_message, Context)
            end;
        _ -> record(catalog_violations, route_shape, Context)
    end.

route_message_matches({disabled, Reason}, Message) ->
    Message =:= <<"model is disabled for this Zed account: ", Reason/binary>>;
route_message_matches(disabled, Message) ->
    Message =:= <<"model is disabled for this Zed account">>;
route_message_matches(unsupported_provider, Message) ->
    Message =:= <<"model uses a provider this integration does not send">>;
route_message_matches(absent, Message) ->
    Message =:= <<"model is not in the Zed catalog for this account">>;
route_message_matches(unroutable, _Message) -> true;
route_message_matches({catalog, Reason}, Message) -> Message =:= Reason;
route_message_matches({catalog, any}, Message) -> is_binary(Message).

%% Known ambiguity, counted rather than reported: a cache entry stamped in the
%% future stays fresh to the current rule for as long as its stamp leads the
%% clock.
future_dated_case(Home) ->
    Token = <<"future-token">>,
    At = erlang:system_time(second) + 86400,
    ok = write_cache(Home, ?ENDPOINT, Token, #{<<"at">> => At, <<"models">> =>
        [#{<<"id">> => <<"future-only">>, <<"provider">> => <<"anthropic">>}]}),
    fixture_reset(),
    Result = safe_call(fun() -> albedo_zed:route(Home, ?ENDPOINT, Token, <<"future-only">>) end),
    unconstrained(future_dated_cache, #{result => Result, requests => fixture_requests()}),
    ok.

catalog_report() ->
    case get(catalog_violations) of
        undefined -> ok;
        [] -> ok;
        Violations -> fail(catalog_properties, lists:sublist(lists:reverse(Violations), 30))
    end.


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
