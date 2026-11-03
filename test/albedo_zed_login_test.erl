-module(albedo_zed_login_test).
-include_lib("public_key/include/public_key.hrl").
-export([run/0]).

run() ->
    application:ensure_all_started(crypto),
    application:ensure_all_started(public_key),
    install_transport(),
    Table = ets:new(zed_login_fixture, [named_table, public, set]),
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {ip, {127,0,0,1}}, {packet, http_bin}]),
    {ok, {_, Port}} = inet:sockname(Listen),
    persistent_term:put(zed_login_fixture_port, Port),
    Server = spawn_link(fun() -> fixture(Listen) end),
    try
        crypto_cases(),
        callback_cases(),
        identity_cases(),
        status_cases(),
        quota_cases(),
        catalog_cases(),
        catalog_account_retry_cases(),
        confirmation_cases(),
        unpolled_expiry_cases(),
        refresh_cases(),
        transport_cases(),
        io:format("Zed login: crypto, callback contract, identity, status envelopes, catalog token refresh, confirmation, persistence/logout, expiry, refresh isolation/concurrency, retry and bounded redirect refusal passed~n")
    after unlink(Server), exit(Server, kill), gen_tcp:close(Listen), ets:delete(Table) end,
    nil.

install_transport() ->
    {ok, Original} = file:read_file("src/albedo/openai_api/albedo_openai_transport.erl"),
    Alias = binary:replace(Original, <<"-module(albedo_openai_transport).">>, <<"-module(albedo_zed_fixture_transport).">>),
    Temp = filename:join("/tmp", "zed-login-transport-" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".erl"),
    ok = file:write_file(Temp, Alias),
    {ok, albedo_zed_fixture_transport, Binary} = compile:file(Temp, [binary, report_errors]),
    {module, _} = code:load_binary(albedo_zed_fixture_transport, Temp, Binary),
    file:delete(Temp),
    Exports = [E || E = {Name, _} <- albedo_openai_transport:module_info(exports), Name =/= module_info],
    Head = ["-module(albedo_openai_transport).\n-export([", lists:join(",", [io_lib:format("~p/~B", [N,A]) || {N,A} <- Exports]), "]).\n"],
    Special = "open(M, <<\"https://cloud.zed.dev\", Path/binary>>, H, B, T) -> P = persistent_term:get(zed_login_fixture_port), U = iolist_to_binary([\"http://127.0.0.1:\", integer_to_binary(P), Path]), albedo_zed_fixture_transport:open(M,U,H,B,T); open(_,_,_,_,_) -> error(untrusted_origin).\n",
    Open = "open(U,H,B,T) -> open(<<\"POST\">>,U,H,B,T).\n",
    Rest = [begin
        Vars = lists:join(",", ["A" ++ integer_to_list(I) || I <- lists:seq(1, A)]),
        io_lib:format("~p(~s) -> albedo_zed_fixture_transport:~p(~s).~n", [N,Vars,N,Vars])
    end || {N,A} <- Exports, N =/= open],
    ok = file:write_file(Temp, [Head, Special, Open, Rest]),
    {ok, albedo_openai_transport, Wrapper} = compile:file(Temp, [binary, report_errors]),
    code:purge(albedo_openai_transport),
    {module, _} = code:load_binary(albedo_openai_transport, Temp, Wrapper),
    file:delete(Temp).

fixture(Listen) ->
    case gen_tcp:accept(Listen) of
        {ok, Socket} ->
            try fixture_request(Socket) catch C:R:S -> io:format("fixture ~p ~p ~p~n",[C,R,S]) end,
            gen_tcp:close(Socket), fixture(Listen);
        _ -> ok
    end.

fixture_request(Socket) ->
    {ok, {http_request, Method, {abs_path, Path}, _}} = gen_tcp:recv(Socket, 0, 5000),
    Headers = request_headers(Socket, #{}),
    inet:setopts(Socket, [{packet, raw}]),
    Length = binary_to_integer(maps:get(<<"content-length">>, Headers, <<"0">>)),
    Body = case Length of 0 -> <<>>; _ -> {ok,B} = gen_tcp:recv(Socket, Length, 5000), B end,
    Auth = maps:get(<<"authorization">>, Headers, <<>>),
    Count = ets:update_counter(zed_login_fixture, {Path, Auth}, {2, 1}, {{Path, Auth}, 0}),
    ets:insert(zed_login_fixture, {last, {Method, Path, Auth, Body}}),
    Mode = mode(),
    {Status, Extra, Response} = case Mode of
        redirect -> {302, <<"Location: https://untrusted.invalid/steal\r\n">>, <<>>};
        oversized -> {200, <<>>, binary:copy(<<"x">>, 1048577)};
        malformed -> {200, <<>>, <<"not-json">>};
        expired_header -> {400, <<"x-zed-expired-token: true\r\n">>, <<"expired">>};
        outdated_header -> {400, <<"x-zed-outdated-token: true\r\n">>, <<"outdated">>};
        quota when Path =:= <<"/client/users/me">> ->
            {200, <<>>, <<"{\"plan\":{\"usage\":{\"edit_predictions\":{\"used\":25,\"limit\":100}}}}">>};
        models_denied when Path =:= <<"/models">> -> {401, <<>>, <<"denied">>};
        models_failing when Path =:= <<"/models">> -> {500, <<>>, <<"catalog unavailable">>};
        models_unauthorized when Path =:= <<"/models">> ->
            case ets:update_counter(zed_login_fixture, models_attempt, {2, 1}, {models_attempt, 0}) of
                1 -> {401, <<>>, <<"stale token">>};
                _ -> {200, <<>>, catalog_response(Auth)}
            end;
        _ ->
            [Id | _] = binary:split(Auth, <<" ">>),
            case Path of
                <<"/client/users/me">> ->
                    N = case Mode of wrong_identity -> 999; _ -> binary_to_integer(Id) end,
                    {200, <<>>, json:encode(identity_response(N))};
                <<"/models">> ->
                    true = binary:match(Auth, <<"Bearer ">>) =:= {0,7},
                    {200, <<>>, catalog_response(Auth)};
                <<"/completions">> ->
                    true = binary:match(Auth, <<"Bearer ">>) =:= {0,7},
                    Attempt = ets:update_counter(zed_login_fixture, inference_attempt, {2,1}, {inference_attempt,0}),
                    case Attempt of
                        1 -> {401, <<"x-zed-expired-token: true\r\n">>, <<"expired">>};
                        _ -> {200, <<"x-zed-server-supports-status-messages: true\r\n">>, inference_body()}
                    end;
                <<"/client/llm_tokens">> ->
                    #{<<"organization_id">> := Org} = json:decode(Body),
                    Expected = <<"org-", Id/binary>>, Expected = Org,
                    Exp = erlang:system_time(second) + case Mode of expired -> -1; _ -> 3600 end,
                    {200, <<>>, json:encode(#{<<"token">> => jwt(Exp, Count, Id)})}
            end
    end,
    Bytes = iolist_to_binary(Response),
    gen_tcp:send(Socket, ["HTTP/1.1 ", integer_to_binary(Status), " Test\r\nConnection: close\r\nContent-Length: ",
                         integer_to_binary(byte_size(Bytes)), "\r\n", Extra, "\r\n", Bytes]).

request_headers(Socket, Acc) ->
    case gen_tcp:recv(Socket, 0, 5000) of
        {ok, http_eoh} -> Acc;
        {ok, {http_header, _, Name, _, Value}} ->
            Key = string:lowercase(case is_atom(Name) of true -> atom_to_binary(Name); false -> Name end),
            request_headers(Socket, Acc#{Key => Value})
    end.

mode() -> case ets:lookup(zed_login_fixture, mode) of [{mode, Mode}] -> Mode; [] -> normal end.
mode(M) -> ets:insert(zed_login_fixture, {mode, M}).

%% The catalog the fixture serves: a selectable model, a disabled one with the
%% account's reason, and a model whose entry does and does not support thinking.
catalog_response(_Auth) ->
    json:encode(#{<<"models">> => [
        #{<<"id">> => <<"browser-fixture-model">>, <<"provider">> => <<"anthropic">>,
          <<"max_token_count">> => 10000, <<"supports_thinking">> => true,
          <<"supported_effort_levels">> => [#{<<"value">> => <<"high">>}]},
        #{<<"id">> => <<"disabled-fixture-model">>, <<"provider">> => <<"anthropic">>,
          <<"is_disabled">> => true, <<"disabled_reason">> => <<"not enabled for this plan">>},
        #{<<"id">> => <<"thinking-off-fixture-model">>, <<"provider">> => <<"open_ai">>,
          <<"supports_thinking">> => false,
          <<"supported_effort_levels">> => [#{<<"value">> => <<"high">>}, #{<<"value">> => <<"low">>}]},
        #{<<"id">> => <<"thinking-on-fixture-model">>, <<"provider">> => <<"open_ai">>,
          <<"supports_thinking">> => true,
          <<"supported_effort_levels">> => [#{<<"value">> => <<"high">>}, #{<<"value">> => <<"low">>}]}
    ]}).

identity_response(N) ->
    Id = integer_to_binary(N), Org = <<"org-", Id/binary>>,
    #{<<"user">> => #{<<"legacy_user_id">> => N, <<"github_login">> => <<"github-", Id/binary>>, <<"username">> => <<"user-", Id/binary>>},
      <<"default_organization_id">> => Org, <<"organizations">> => [#{<<"id">> => Org}]}.

jwt(Exp, Count, Id) ->
    Payload = base64:encode(iolist_to_binary(json:encode(#{<<"exp">> => Exp, <<"n">> => Count, <<"id">> => Id})), #{mode => urlsafe, padding => false}),
    <<"header.", Payload/binary, ".signature">>.

crypto_cases() ->
    K = public_key:generate_key({rsa,2048,65537}),
    Other = public_key:generate_key({rsa,2048,65537}),
    P = #'RSAPublicKey'{modulus=K#'RSAPrivateKey'.modulus, publicExponent=65537},
    Cipher = encrypt(P, <<"editor-test-secret">>),
    {ok, {<<"42">>, <<"editor-test-secret">>}} = albedo_zed_auth:decrypt(K, <<"42">>, Cipher),
    {error, _} = albedo_zed_auth:decrypt(Other, <<"42">>, Cipher),
    {error, _} = albedo_zed_auth:decrypt(K, <<"42">>, <<"malformed">>),
    {error, _} = albedo_zed_auth:decrypt(K, <<"42\r\n">>, Cipher),
    Legacy = base64:encode(public_key:encrypt_public(<<"legacy">>, P, [{rsa_padding,rsa_pkcs1_padding}]), #{mode => urlsafe}),
    {ok, {<<"42">>, <<"legacy">>}} = albedo_zed_auth:decrypt(K, <<"42">>, Legacy),
    Unpadded = base64:encode(public_key:encrypt_public(<<"editor-test-secret">>, P,
        [{rsa_padding,rsa_pkcs1_oaep_padding},{rsa_oaep_md,sha256},{rsa_mgf1_md,sha256}]), #{mode => urlsafe, padding => false}),
    {ok, {<<"42">>, <<"editor-test-secret">>}} = albedo_zed_auth:decrypt(K, <<"42">>, Unpadded).

encrypt(Public, Token) -> base64:encode(public_key:encrypt_public(Token, Public,
    [{rsa_padding,rsa_pkcs1_oaep_padding},{rsa_oaep_md,sha256},{rsa_mgf1_md,sha256}]), #{mode=>urlsafe}).

%% The callback path and its extra parameters are not part of the contract, and
%% the browser is answered with zed.dev's success page, as the editor is.
callback_cases() ->
    Home = home(),
    L = login(),
    try
        {Id, Initial} = start(Home),
        {_, Reply} = callback(Initial, <<"61">>, Initial, <<"127.0.0.1">>, {127,0,0,1}, <<"/native_app_signin">>,
            <<"Origin: https://cloud.zed.dev\r\nSec-Fetch-Site: cross-site\r\n">>),
        <<"HTTP/1.1 302", _/binary>> = Reply,
        nomatch = binary:match(Reply, <<"200 OK">>),
        true = binary:match(Reply, <<"Location: https://zed.dev/native_app_signin_succeeded\r\n">>) =/= nomatch,
        _ = await_state(Home, Id, <<"confirming">>),
        {ok, _} = albedo_oauth:cancel_identified(Home, Id, [L]),
        %% A callback that cannot be decrypted is answered 404 and the attempt stays waiting.
        {Rejected, RejectedInitial} = start(Home),
        {WrongId, WrongInitial} = start(Home),
        {_, NotFound} = callback(RejectedInitial, <<"62">>, WrongInitial, <<"127.0.0.1">>, {127,0,0,1}, <<"/">>, <<>>),
        <<"HTTP/1.1 404", _/binary>> = NotFound,
        <<"waiting">> = state(get(Home, Rejected)), no_accounts(Home),
        {ok, _} = albedo_oauth:cancel_identified(Home, Rejected, [L]),
        {ok, _} = albedo_oauth:cancel_identified(Home, WrongId, [L]),
        %% localhost can resolve to ::1, so both loopback addresses reach the attempt.
        {V6, V6Initial} = start(Home),
        case gen_tcp:connect({0,0,0,0,0,0,0,1}, port_of(V6Initial), [binary, {active, false}, inet6], 1000) of
            {ok, Probe} ->
                gen_tcp:close(Probe),
                {_, V6Reply} = callback(V6Initial, <<"63">>, V6Initial, <<"[::1]">>, {0,0,0,0,0,0,0,1}, <<"/">>, <<>>),
                <<"HTTP/1.1 302", _/binary>> = V6Reply,
                _ = await_state(Home, V6, <<"confirming">>),
                {ok, _} = albedo_oauth:cancel_identified(Home, V6, [L]);
            {error, _} -> ok
        end
    after file:del_dir_r(Home) end.

port_of(Flow) ->
    #{<<"url">> := Url} = json:decode(Flow),
    #{query := Query} = uri_string:parse(Url),
    binary_to_integer(maps:get(<<"native_app_port">>, maps:from_list(uri_string:dissect_query(Query)))).

identity_cases() ->
    R = identity_response(42),
    {ok, #{<<"organization_id">> := <<"org-42">>}} = albedo_zed_auth:identity(<<"42">>, <<"secret">>, R),
    %% Documented GetAuthenticatedUserResponse fields, including is_personal.
    Documented = #{<<"user">> => #{<<"legacy_user_id">> => 42, <<"id_v2">> => <<"user_v2">>,
                                    <<"metrics_id">> => <<"metrics">>, <<"username">> => <<"user-42">>,
                                    <<"github_login">> => <<"github-42">>, <<"avatar_url">> => <<"https://example.invalid/a.png">>,
                                    <<"name">> => null, <<"is_staff">> => false},
                    <<"organizations">> => [#{<<"id">> => <<"org-42">>, <<"name">> => <<"Personal">>,
                                               <<"is_personal">> => true}],
                    <<"feature_flags">> => [], <<"default_organization_id">> => <<"org-42">>},
    {ok, #{<<"organization_id">> := <<"org-42">>}} = albedo_zed_auth:identity(<<"42">>, <<"secret">>, Documented),
    %% default_organization_id is optional: the single personal organization stands in.
    Absent = maps:remove(<<"default_organization_id">>, Documented),
    {ok, #{<<"organization_id">> := <<"org-42">>}} = albedo_zed_auth:identity(<<"42">>, <<"secret">>, Absent),
    {ok, #{<<"organization_id">> := <<"org-42">>}} =
        albedo_zed_auth:identity(<<"42">>, <<"secret">>, Documented#{<<"default_organization_id">> => null}),
    %% `organizations` is `#[serde(default)]`: an omitted list cannot contradict
    %% the account's own default, so the default stands.
    {ok, #{<<"organization_id">> := <<"org-42">>}} =
        albedo_zed_auth:identity(<<"42">>, <<"secret">>, Documented#{<<"organizations">> => []}),
    {ok, #{<<"organization_id">> := <<"org-42">>}} =
        albedo_zed_auth:identity(<<"42">>, <<"secret">>, maps:remove(<<"organizations">>, Documented)),
    %% No default and no organization at all is still refused.
    {error, _} = albedo_zed_auth:identity(<<"42">>, <<"secret">>,
        (maps:remove(<<"default_organization_id">>, Documented))#{<<"organizations">> => []}),
    %% A foreign default is refused.
    {error, _} = albedo_zed_auth:identity(<<"42">>, <<"secret">>, Documented#{<<"default_organization_id">> => <<"foreign-org">>}),
    {error, _} = albedo_zed_auth:identity(<<"42">>, <<"secret">>,
        Absent#{<<"organizations">> => [#{<<"id">> => <<"org-42">>}, #{<<"id">> => <<"org-43">>}]}),
    %% The editor takes the callback's user id as the credential identity
    %% rather than comparing it with the account document.
    {ok, #{<<"user_id">> := <<"43">>}} = albedo_zed_auth:identity(<<"43">>, <<"secret">>, R),
    {error, _} = albedo_zed_auth:identity(<<"42">>, <<"secret">>, R#{<<"default_organization_id">> => <<"foreign-org">>}),
    {error, <<"Zed account identity could not be verified">>} = albedo_zed_auth:identity(<<"42">>, <<"secret">>, #{}),
    {error, _} = albedo_zed_auth:request(<<"GET">>, <<"https://untrusted.invalid">>, [], <<>>).

%% The editor drops a status it does not recognise and keeps reading; a failed
%% status still fails the turn.
status_cases() ->
    {ok, <<>>} = albedo_zed:unwrap(<<"{\"status\":\"unknown\"}">>),
    {ok, <<>>} = albedo_zed:unwrap(<<"{\"status\":{\"a_later_status\":{\"detail\":1}}}">>),
    {ok, <<"stream_ended">>} = albedo_zed:unwrap(<<"{\"status\":\"stream_ended\"}">>),
    {ok, <<>>} = albedo_zed:unwrap(<<"{\"status\":\"started\"}">>),
    {error, <<"quota exhausted">>} =
        albedo_zed:unwrap(<<"{\"status\":{\"failed\":{\"message\":\"quota exhausted\"}}}">>),
    {error, _} = albedo_zed:unwrap(<<"{\"nothing\":true}">>),
    {error, _} = albedo_zed:unwrap(<<"not json">>).

quota_cases() ->
    mode(quota),
    nil = suite_zed_login_test:quota_case(),
    [{_, 1}] = ets:lookup(zed_login_fixture,
        {<<"/client/users/me">>, <<"42 quota-fixture-secret">>}),
    mode(normal).

%% Discovery refreshes a rejected account token once, as the editor's
%% authenticated request path does, and reports a second rejection as the
%% credential problem it is.
catalog_cases() ->
    Home = home(),
    try
        C = (credential(<<"71">>, <<"catalog-account">>))#{
            <<"jwt">> => jwt(erlang:system_time(second)+3600, 1, <<"71">>),
            <<"jwt_expires">> => erlang:system_time(second)+3600},
        configure(Home, [C], #{<<"catalog">> => profile(<<"catalog-account">>)}),
        Key = <<"albedo:zed:account:catalog-account">>,
        ets:insert(zed_login_fixture, {models_attempt, 0}),
        mode(models_unauthorized),
        {ok, Listed} = albedo_zed:models(Home, Key),
        true = lists:member(<<"browser-fixture-model">>, Listed),
        %% One rejection, one refresh through the account's own credential, one retry.
        [{models_attempt, 2}] = ets:lookup(zed_login_fixture, models_attempt),
        [{_, 1}] = ets:lookup(zed_login_fixture, {<<"/client/llm_tokens">>, <<"71 editor-test-secret">>}),
        %% The refreshed token is cached, so discovery does not ask again.
        {ok, _} = albedo_zed:models(Home, Key),
        [{models_attempt, 2}] = ets:lookup(zed_login_fixture, models_attempt),
        %% A disabled entry is not selectable, and routing says why.
        false = lists:member(<<"disabled-fixture-model">>, Listed),
        {ok, {_, Token}} = albedo_zed:access(Home, <<"catalog">>),
        {error, Disabled} = albedo_zed:route(Home, <<"https://cloud.zed.dev">>, Token, <<"disabled-fixture-model">>),
        true = binary:match(Disabled, <<"not enabled for this plan">>) =/= nomatch,
        none = albedo_zed:lookup(Home, <<"https://cloud.zed.dev">>, <<"disabled-fixture-model">>),
        %% A model whose catalog entry has thinking off offers no effort, so no
        %% encoder asks for reasoning it cannot use.
        {some, Off} = albedo_zed:lookup(Home, <<"https://cloud.zed.dev">>, <<"thinking-off-fixture-model">>),
        [] = element(11, Off),
        {some, On} = albedo_zed:lookup(Home, <<"https://cloud.zed.dev">>, <<"thinking-on-fixture-model">>),
        [<<"high">>, <<"low">>] = element(11, On),
        %% A token rejected after its refresh is a credential problem.
        mode(models_denied),
        {error, Denied} = albedo_zed:reload(Home),
        nomatch = binary:match(Denied, <<"could not reach">>),
        true = binary:match(Denied, <<"/login zed">>) =/= nomatch,
        %% A failing catalog reports its status rather than as unreachable.
        mode(models_failing),
        {error, Failing} = albedo_zed:reload(Home),
        true = binary:match(Failing, <<"HTTP 500">>) =/= nomatch,
        mode(normal),
        ets:insert(zed_login_fixture, {models_attempt, 0})
    after mode(normal), file:del_dir_r(Home) end.

catalog_account_retry_cases() ->
    lists:foreach(fun(Kind) ->
        Home = home(),
        try
            Exp = erlang:system_time(second) + 3600,
            OneToken = jwt(Exp, 99, <<"81">>), TwoToken = jwt(Exp, 99, <<"82">>),
            One = (credential(<<"81">>, <<"retry-one">>))#{<<"jwt">> => OneToken, <<"jwt_expires">> => Exp},
            Two = (credential(<<"82">>, <<"retry-two">>))#{<<"jwt">> => TwoToken, <<"jwt_expires">> => Exp},
            configure(Home, [One, Two], #{<<"one">> => profile(<<"retry-one">>), <<"two">> => profile(<<"retry-two">>)}),
            ets:delete(zed_login_fixture, {<<"/client/llm_tokens">>, <<"81 editor-test-secret">>}),
            ets:delete(zed_login_fixture, {<<"/client/llm_tokens">>, <<"82 editor-test-secret">>}),
            ets:insert(zed_login_fixture, {models_attempt, 0}),
            mode(models_unauthorized),
            case Kind of
                account -> {ok, _} = albedo_zed:models(Home, <<"albedo:zed:account:retry-two">>);
                profile -> {ok, _} = albedo_zed:models(Home, <<"albedo:zed:profile:two">>);
                route -> {ok, <<"anthropic">>} = albedo_zed:route(Home, <<"https://cloud.zed.dev">>, TwoToken, <<"browser-fixture-model">>)
            end,
            [{models_attempt, 2}] = ets:lookup(zed_login_fixture, models_attempt),
            [] = ets:lookup(zed_login_fixture, {<<"/client/llm_tokens">>, <<"81 editor-test-secret">>}),
            [{_, 1}] = ets:lookup(zed_login_fixture, {<<"/client/llm_tokens">>, <<"82 editor-test-secret">>}),
            {ok, OneToken} = albedo_zed_auth:access(Home, <<"one">>),
            {ok, Fresh} = albedo_zed_auth:access(Home, <<"two">>),
            true = Fresh =/= TwoToken,
            [{last, {'GET', <<"/models">>, <<"Bearer ", Fresh/binary>>, <<>>}}] = ets:lookup(zed_login_fixture, last)
        after mode(normal), file:del_dir_r(Home) end
    end, [account, profile, route]).

home() ->
    Home = list_to_binary(filename:join("/tmp", "zed-login-home-" ++ integer_to_list(erlang:unique_integer([positive])))),
    ok = filelib:ensure_dir(filename:join(Home, <<"dummy">>)),
    Home.

login() -> {login, <<"zed">>, <<"Zed">>, <<"browser">>, model, <<"zed">>, {device, fun albedo_zed_auth:start/0},
            fun(_) -> <<>> end, fun(_,_,_) -> {error,unused} end, fun albedo_zed_auth:account/1}.

start(Home) -> start(Home, login()).

start(Home, L) ->
    Id = albedo_oauth_test_support:identity(),
    {ok, {true, Flow}} = albedo_oauth:start_identified(Home, Id, <<"zed">>, {some,L}, <<"zed">>),
    {Id, Flow}.

get(Home, Id) -> {ok, F} = albedo_oauth:get_identified(Home,Id,[login()]), F.

state(Flow) -> maps:get(<<"state">>, json:decode(Flow)).

await_state(Home, Id, State) -> await_state(Home, Id, State, 200).
await_state(Home, Id, Expected, N) when N > 0 ->
    F = get(Home, Id),
    case state(F) of Expected -> F; _ -> timer:sleep(10), await_state(Home,Id,Expected,N-1) end;
await_state(Home, Id, Expected, _) -> error({state_timeout, Expected, json:decode(get(Home, Id))}).

%% Observe persistence without calling the API that can expire the flow.
await_stored_state(Home, Id, Expected) ->
    await_stored_state(Home, Id, Expected, erlang:monotonic_time(millisecond) + 2000).

await_stored_state(Home, Id, Expected, Deadline) ->
    {ok, Records} = albedo_credentials:read(filename:join(Home,<<"oauth-logins.json">>)),
    Record = maps:get(Id, Records),
    case maps:get(<<"state">>, Record) of
        Expected -> Record;
        _ ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true -> timer:sleep(10), await_stored_state(Home, Id, Expected, Deadline);
                false -> error({stored_state_timeout, Expected, Record})
            end
    end.

callback(Flow, User) -> callback(Flow, User, Flow, <<"127.0.0.1">>).

callback(Flow, User, KeyFlow, Host) ->
    {Port, _} = callback(Flow, User, KeyFlow, Host, {127,0,0,1}, <<"/">>, <<>>),
    Port.

callback(Flow, User, KeyFlow, Host, Address, Target, Extra) ->
    #{<<"url">> := Url} = json:decode(Flow),
    #{query := Q} = uri_string:parse(Url),
    Params = maps:from_list(uri_string:dissect_query(Q)),
    Port = binary_to_integer(maps:get(<<"native_app_port">>,Params)),
    #{<<"url">> := KeyUrl} = json:decode(KeyFlow),
    #{query := KeyQuery} = uri_string:parse(KeyUrl),
    KeyParams = maps:from_list(uri_string:dissect_query(KeyQuery)),
    Public = public_key:der_decode('RSAPublicKey', base64:decode(maps:get(<<"native_app_public_key">>, KeyParams), #{mode=>urlsafe})),
    Cipher = encrypt(Public, <<"editor-test-secret">>),
    Query = uri_string:compose_query([{<<"user_id">>,User},{<<"access_token">>,Cipher}]),
    {ok, Socket} = gen_tcp:connect(Address,Port,[binary,{active,false}],1000),
    gen_tcp:send(Socket,["GET ",Target,"?",Query," HTTP/1.1\r\nHost: ",Host,":",integer_to_binary(Port),"\r\n",Extra,"\r\n"]),
    Reply = response(Socket, <<>>),
    gen_tcp:close(Socket),
    {Port, Reply}.

response(Socket, Acc) ->
    case gen_tcp:recv(Socket, 0, 3000) of
        {ok, Bytes} -> response(Socket, <<Acc/binary, Bytes/binary>>);
        _ -> Acc
    end.

no_accounts(Home) ->
    case albedo_credentials:accounts(albedo_credentials:creds_path(Home)) of
        {ok,A} -> [] = albedo_credentials:values(A,<<"zed">>);
        {error,enoent} -> ok
    end.

confirmation_cases() ->
    Home = home(),
    try
        L = login(),
        {ok, Snapshot} = albedo_oauth:auth_snapshot(Home,[L]),
        #{<<"providers">> := [#{<<"id">> := <<"zed">>, <<"flows">> := [<<"browser">>]}]} = json:decode(Snapshot),
        {Id, Initial} = start(Home),
        {error, {409,_,_}} = albedo_oauth:input_identified(Home,Id,albedo_http_api:etag(Initial),<<"confirm">>,[L]),
        {WrongAttempt, WrongKey} = start(Home),
        callback(Initial, <<"42">>, WrongKey, <<"127.0.0.1">>),
        <<"waiting">> = state(get(Home, Id)), no_accounts(Home),
        {ok,_} = albedo_oauth:cancel_identified(Home,WrongAttempt,[L]),
        callback(Initial, <<"42">>),
        Confirm = await_state(Home,Id,<<"confirming">>), no_accounts(Home),
        {ok, Records} = file:read_file(filename:join(Home,<<"oauth-logins.json">>)),
        nomatch = binary:match(Records,<<"editor-test-secret">>),
        true = binary:match(Confirm,<<"github-42">>) =/= nomatch,
        {error, {412,_,_}} = albedo_oauth:input_identified(Home,Id,albedo_http_api:etag(Initial),<<"confirm">>,[L]),
        {error, {400,_,_}} = albedo_oauth:input_identified(Home,Id,albedo_http_api:etag(Confirm),<<"yes">>,[L]),
        {Other, OtherInitial} = start(Home),
        {error, {412,_,_}} = albedo_oauth:input_identified(Home,Id,albedo_http_api:etag(OtherInitial),<<"confirm">>,[L]),
        {ok,_} = albedo_oauth:cancel_identified(Home,Other,[L]),
        {ok,_} = albedo_oauth:input_identified(Home,Id,albedo_http_api:etag(Confirm),<<"confirm">>,[L]),
        _ = await_state(Home,Id,<<"complete">>),
        {ok,A} = albedo_credentials:accounts(albedo_credentials:creds_path(Home)),
        [#{<<"access_token">> := <<"editor-test-secret">>, <<"_albedo_account_id">> := PublicId}] = albedo_credentials:values(A,<<"zed">>),
        clean_home_inference(Home, PublicId),
        ok = albedo_credentials:write(filename:join(Home,<<"config.json">>),#{<<"providers">> => #{}}),
        {ok,nil} = albedo_oauth:remove_account(Home,[L],PublicId), no_accounts(Home),
        {Cancelled, CancelInitial} = start(Home),
        callback(CancelInitial, <<"43">>, CancelInitial, <<"localhost">>),
        _ = await_state(Home,Cancelled,<<"confirming">>),
        {ok,_} = albedo_oauth:cancel_identified(Home,Cancelled,[L]), no_accounts(Home),
        {error,{409,_,_}} = albedo_oauth:input_identified(Home,Cancelled,albedo_http_api:etag(get(Home,Cancelled)),<<"confirm">>,[L]),
        {Expired, ExpInitial} = start(Home), callback(ExpInitial,<<"44">>),
        _ = await_state(Home,Expired,<<"confirming">>),
        RecordsPath = filename:join(Home,<<"oauth-logins.json">>),
        {ok, R0} = albedo_credentials:read(RecordsPath),
        ok = albedo_credentials:write(RecordsPath,R0#{Expired := (maps:get(Expired,R0))#{<<"expires">> := 0}}),
        <<"expired">> = state(get(Home,Expired)), no_accounts(Home)
        %% A differing legacy_user_id is no longer refused: the credential keeps
        %% the callback's user id, as the editor's does (identity_cases).

    after file:del_dir_r(Home) end.

credential(Id, Public) ->
    {ok,C} = albedo_zed_auth:identity(Id,<<"editor-test-secret">>,identity_response(binary_to_integer(Id))),
    C#{<<"_albedo_account_id">> => Public}.

configure(Home, Values, Profiles) ->
    ok = albedo_credentials:write(filename:join(Home,<<"creds.json">>),#{<<"accounts">> => #{<<"zed">> => Values}}),
    ok = albedo_credentials:write(filename:join(Home,<<"config.json">>),#{<<"active">> => <<"one">>, <<"providers">> => Profiles}).

profile(Account) -> #{<<"extension">> => <<"zed">>, <<"accountId">> => Account, <<"baseUrl">> => <<"https://cloud.zed.dev">>}.

refresh_cases() ->
    Home = home(),
    try
        One = credential(<<"51">>,<<"one-account">>), Two = credential(<<"52">>,<<"two-account">>),
        Profiles = #{<<"one">> => profile(<<"one-account">>), <<"two">> => profile(<<"two-account">>)},
        configure(Home,[One,Two],Profiles),
        Parent = self(),
        [spawn_link(fun() -> Parent ! {refreshed,albedo_zed_auth:access(Home,<<"one">>)} end) || _ <- lists:seq(1,8)],
        Tokens = [receive {refreshed,{ok,T}} -> T after 5000 -> error(refresh_timeout) end || _ <- lists:seq(1,8)],
        [T1] = lists:usort(Tokens),
        [{_,1}] = ets:lookup(zed_login_fixture,{<<"/client/llm_tokens">>,<<"51 editor-test-secret">>}),
        {ok,T2} = albedo_zed_auth:access(Home,<<"two">>), true = T1 =/= T2,
        {some,<<"albedo:zed:profile:two">>} = albedo_zed_auth:catalog_endpoint(Home,<<"two">>,none),
        {ok,T2} = albedo_zed_auth:access_account(Home,<<"two-account">>),
        {ok,{<<"https://cloud.zed.dev">>,T2}} = albedo_zed:access(Home,<<"two">>),
        {ok,A} = albedo_credentials:accounts(albedo_credentials:creds_path(Home)),
        [First,Second] = albedo_credentials:values(A,<<"zed">>),
        Expired = First#{<<"jwt_expires">> => 0},
        ok = albedo_credentials:put_accounts(albedo_credentials:creds_path(Home),#{<<"zed">> => [Expired,Second]}),
        {ok,T3a} = albedo_zed_auth:access(Home,<<"one">>), true = T3a =/= T1,
        {ok, CacheA} = albedo_credentials:accounts(albedo_credentials:creds_path(Home)),
        [CachedOne,CachedTwo] = albedo_credentials:values(CacheA,<<"zed">>),
        lists:foreach(fun(Bad) ->
            ok = albedo_credentials:put_accounts(albedo_credentials:creds_path(Home),#{<<"zed">> => [Bad,CachedTwo]}),
            {ok,FreshValid} = albedo_zed_auth:access(Home,<<"one">>),
            {ok,_} = albedo_zed_auth:jwt_expiry(FreshValid)
        end,[CachedOne#{<<"jwt_expires">> => null}, CachedOne#{<<"jwt">> => null},
              CachedOne#{<<"jwt">> => <<"bad.jwt.value">>}, CachedOne#{<<"jwt_expires">> => <<"9000000000">>}]),
        {ok,T3} = albedo_zed_auth:access(Home,<<"one">>),
        put(attempts,0), put(events,[]),
        Run = fun(_,Token,Emit) ->
            put(attempts,get(attempts)+1),
            case Token =:= T3 of
                true -> continue = Emit({responded,401}), {error,{http_error,401,<<"expired">>}};
                false -> continue = Emit({text_delta,0,0,<<"only-once">>}), {ok,success}
            end
        end,
        OnEvent = fun(E) -> put(events,[E|get(events)]), continue end,
        {ok,success} = albedo_zed:exchange(Home,<<"one">>,Run,OnEvent),
        2 = get(attempts), [{text_delta,0,0,<<"only-once">>}] = get(events),
        {ok,Current} = albedo_zed_auth:access(Home,<<"one">>), put(attempts,0),
        Partial = fun(_,_,Emit) -> put(attempts,get(attempts)+1),Emit({arguments_delta,0,<<"tool">>,<<"{}">>}),{error,{http_error,401,<<>>}} end,
        {error,_} = albedo_zed:exchange(Home,<<"one">>,Partial,OnEvent), 1 = get(attempts),
        ChangedRun = fun(_,_,_) ->
            put(attempts,get(attempts)+1),
            ok = albedo_credentials:write(filename:join(Home,<<"config.json">>),
                #{<<"providers">> => Profiles#{<<"one">> := profile(<<"two-account">>)}}),
            {error,{http_error,401,<<>>}}
        end,
        put(attempts,0),
        {error,_} = albedo_zed:exchange(Home,<<"one">>,ChangedRun,OnEvent), 1 = get(attempts),
        ok = albedo_credentials:write(filename:join(Home,<<"config.json">>),#{<<"providers">> => Profiles}),
        mode(expired), albedo_zed_auth:reject(Home,<<"one">>,Current),
        {error,_} = albedo_zed_auth:access(Home,<<"one">>), mode(normal),
        configure(Home,[One,Two],#{<<"ambiguous">> => #{<<"extension">> => <<"zed">>}}),
        {error,_} = albedo_zed_auth:access(Home,<<"ambiguous">>),
        %% Browser sign-in is the only credential: a profile apiKey, a daemon
        %% ZED_TOKEN and a custom endpoint are each refused, never used.
        configure(Home,[One],#{<<"keyed">> => (profile(<<"one-account">>))#{<<"apiKey">> => <<"manual-jwt">>}}),
        {error, Keyed} = albedo_zed:access(Home,<<"keyed">>),
        true = binary:match(Keyed, <<"apiKey">>) =/= nomatch,
        true = binary:match(Keyed, <<"/login zed">>) =/= nomatch,
        nomatch = binary:match(Keyed, <<"manual-jwt">>),
        {error, KeyedCatalog} = albedo_zed:models(Home,<<"albedo:zed:profile:keyed">>),
        true = binary:match(KeyedCatalog, <<"apiKey">>) =/= nomatch,
        configure(Home,[One],#{<<"custom">> => (profile(<<"one-account">>))#{<<"baseUrl">> => <<"https://untrusted.invalid">>}}),
        {error, Custom} = albedo_zed:access(Home,<<"custom">>),
        true = binary:match(Custom, <<"https://cloud.zed.dev">>) =/= nomatch,
        configure(Home,[One],#{<<"zed">> => profile(<<"one-account">>)}),
        {ok,{<<"https://cloud.zed.dev">>,_}} = albedo_zed:access(Home,<<"zed">>),
        os:putenv("ZED_TOKEN", "environment-jwt"),
        {error, Env} = albedo_zed:access(Home,<<"zed">>),
        true = binary:match(Env, <<"ZED_TOKEN">>) =/= nomatch,
        true = binary:match(Env, <<"/login zed">>) =/= nomatch,
        nomatch = binary:match(Env, <<"environment-jwt">>),
        %% Two leftovers at once name the first refusal only: apiKey, then
        %% ZED_TOKEN, then the endpoint.
        Both = (profile(<<"one-account">>))#{<<"apiKey">> => <<"manual-jwt">>,
            <<"baseUrl">> => <<"https://untrusted.invalid">>},
        configure(Home,[One],#{<<"both">> => Both}),
        {error, KeyFirst} = albedo_zed:access(Home,<<"both">>),
        true = binary:match(KeyFirst, <<"apiKey">>) =/= nomatch,
        nomatch = binary:match(KeyFirst, <<"ZED_TOKEN">>),
        nomatch = binary:match(KeyFirst, <<"untrusted.invalid">>),
        configure(Home,[One],#{<<"both">> => (profile(<<"one-account">>))#{<<"baseUrl">> => <<"https://untrusted.invalid">>}}),
        {error, TokenFirst} = albedo_zed:access(Home,<<"both">>),
        true = binary:match(TokenFirst, <<"ZED_TOKEN">>) =/= nomatch,
        nomatch = binary:match(TokenFirst, <<"untrusted.invalid">>),
        true = os:unsetenv("ZED_TOKEN"),
        {ok,{<<"https://cloud.zed.dev">>,_}} = albedo_zed:access(Home,<<"zed">>),
        %% The catalog's model info names its limits, endpoint and source, and
        %% advertises no environment credential for Zed.
        {some, {model_info, <<"browser-fixture-model">>, <<"zed">>, {some, 10000}, none,
            none, [<<"text">>], {some, <<"https://cloud.zed.dev">>}, [],
            <<"Zed /models">>, [<<"high">>]}} =
            albedo_zed:lookup(Home, <<"https://cloud.zed.dev">>, <<"browser-fixture-model">>),
        %% A token the transport cannot send is not a credential.
        true = albedo_zed:usable(<<"inference-jwt">>),
        false = albedo_zed:usable(<<>>),
        false = albedo_zed:usable(<<"inference
jwt">>),
        false = albedo_zed:usable(<<"inference
jwt">>),
        false = albedo_zed:usable(not_a_binary)
    after os:unsetenv("ZED_TOKEN"), file:del_dir_r(Home) end.

transport_cases() ->
    Headers = [{<<"authorization">>,<<"42 editor-test-secret">>}],
    %% Each transport failure keeps its own diagnosis instead of collapsing
    %% into one generic transport error.
    mode(redirect),
    {error, Redirect} = albedo_zed_auth:request(<<"GET">>,<<"/client/users/me">>,Headers,<<>>),
    true = binary:match(Redirect, <<"redirects are refused">>) =/= nomatch,
    mode(oversized),
    {error, Oversized} = albedo_zed_auth:request(<<"GET">>,<<"/client/users/me">>,Headers,<<>>),
    true = binary:match(Oversized, <<"size or time budget">>) =/= nomatch,
    mode(malformed),
    {error, Malformed} = albedo_zed_auth:request(<<"GET">>,<<"/client/users/me">>,Headers,<<>>),
    true = binary:match(Malformed, <<"Invalid Zed account JSON">>) =/= nomatch,
    Home = home(),
    try
        C = (credential(<<"73">>,<<"redirect-account">>))#{
            <<"jwt">> => jwt(erlang:system_time(second)+3600,1,<<"73">>),
            <<"jwt_expires">> => erlang:system_time(second)+3600},
        configure(Home,[C],#{<<"redirect-profile">> => profile(<<"redirect-account">>)}),
        mode(redirect),
        {error,_} = albedo_zed:models(Home,<<"albedo:zed:account:redirect-account">>),
        [{last,{'GET',<<"/models">>,_,<<>>}}] = ets:lookup(zed_login_fixture,last)
    after file:del_dir_r(Home) end,
    Endpoint = <<"https://cloud.zed.dev">>,
    lists:foreach(fun(M) ->
        mode(M), 'suite_zed_login_test':header_case(Endpoint)
    end,[expired_header,outdated_header]),
    mode(normal).

inference_body() ->
    Native = [
        #{<<"type">> => <<"message_start">>, <<"message">> => #{
            <<"id">> => <<"browser-only">>,
            <<"usage">> => #{<<"input_tokens">> => 1, <<"output_tokens">> => 0}}},
        #{<<"type">> => <<"content_block_start">>, <<"index">> => 0,
            <<"content_block">> => #{<<"type">> => <<"text">>, <<"text">> => <<>>}},
        #{<<"type">> => <<"content_block_delta">>, <<"index">> => 0,
            <<"delta">> => #{<<"type">> => <<"text_delta">>, <<"text">> => <<"browser-only-reply">>}},
        #{<<"type">> => <<"content_block_stop">>, <<"index">> => 0},
        #{<<"type">> => <<"message_delta">>, <<"delta">> => #{<<"stop_reason">> => <<"end_turn">>},
            <<"usage">> => #{<<"output_tokens">> => 1}},
        #{<<"type">> => <<"message_stop">>}
    ],
    Events = [#{<<"event">> => E} || E <- Native] ++ [#{<<"status">> => <<"stream_ended">>}],
    lists:join(<<"\n">>,[json:encode(E) || E <- Events]).

clean_home_inference(Home, PublicId) ->
    %% This home began empty; the browser callback is the only credential source.
    ok = albedo_credentials:write(filename:join(Home,<<"config.json">>),
        #{<<"active">> => <<"browser">>, <<"providers">> => #{<<"browser">> => profile(PublicId)}}),
    {ok,[<<"browser-fixture-model">>,<<"thinking-off-fixture-model">>,<<"thinking-on-fixture-model">>]} =
        albedo_zed:models(Home,<<"albedo:zed:account:",PublicId/binary>>),
    put(browser_events,[]),
    OnEvent = fun(E) -> put(browser_events,[E|get(browser_events)]), continue end,
    Run = fun(Endpoint,Token,Emit) ->
        <<"https://cloud.zed.dev">> = Endpoint,
        'suite_zed_login_test':inference(Home,Endpoint,Token,Emit)
    end,
    {ok,_} = albedo_zed:exchange(Home,<<"browser">>,Run,OnEvent),
    [{inference_attempt,2}] = ets:lookup(zed_login_fixture,inference_attempt),
    [{text_delta,_,_,<<"browser-only-reply">>}] = [E || E = {text_delta,_,_,_} <- get(browser_events)],
    {ok, Accounts} = albedo_credentials:accounts(albedo_credentials:creds_path(Home)),
    [#{<<"access_token">> := <<"editor-test-secret">>, <<"jwt">> := _, <<"jwt_expires">> := _}] = albedo_credentials:values(Accounts,<<"zed">>).

%% Delay readiness before opening the account transport, not its scaled timeout.
delayed_identity_start() ->
    {ok,{Url,Instructions,Complete}} = albedo_zed_auth:start(),
    {ok,{Url,Instructions,fun(Progress) ->
        Complete(fun(Text) -> timer:sleep(150), Progress(Text) end)
    end}}.

unpolled_expiry_cases() ->
    OriginalScale = persistent_term:get({albedo_clock,scale},1),
    persistent_term:put({albedo_clock,scale},100),
    Home = home(), CompleteHome = home(), CancelHome = home(), CorruptHome = home(),
    Parent = self(),
    L = setelement(7,login(),{device,fun() ->
        Parent ! {native_expiry_actor,self()}, delayed_identity_start()
    end}),
    try
        Owner = whereis(albedo_oauth),
        erlang:trace_pattern({albedo_clock,send_after,3},true,[local]),
        erlang:trace(Owner,true,[call,{tracer,self()}]),
        {Id,Initial} = start(Home,L),
        Expiry = receive
            {trace,Owner,call,{albedo_clock,send_after,[300000,Owner,Message]}} -> Message
        after 1000 -> error(no_expiry_timer) end,
        erlang:trace(Owner,false,[call]),
        erlang:trace_pattern({albedo_clock,send_after,3},false,[local]),
        Pid = receive {native_expiry_actor,P} -> P after 1000 -> error(no_actor) end,
        Monitor = erlang:monitor(process,Pid),
        Port = callback(Initial,<<"81">>),
        #{<<"state">> := <<"confirming">>, <<"intent">> := Intent, <<"expires">> := Deadline} =
            await_stored_state(Home,Id,<<"confirming">>),
        no_accounts(Home),
        %% A stale deadline or home cannot target the active attempt.
        {expire_identified,Home,Id,Intent,Deadline,MonoDeadline} = Expiry,
        Owner ! {expire_identified,Home,Id,Intent,Deadline-1,MonoDeadline},
        Owner ! {expire_identified,CompleteHome,Id,Intent,Deadline,MonoDeadline},
        Owner ! Expiry,
        timer:sleep(20), true = is_process_alive(Pid),
        {DoneId,DoneInitial} = start(CompleteHome),
        callback(DoneInitial,<<"82">>),
        Confirm = await_state(CompleteHome,DoneId,<<"confirming">>),
        {ok,_} = albedo_oauth:input_identified(CompleteHome,DoneId,albedo_http_api:etag(Confirm),<<"confirm">>,[login()]),
        Done = await_state(CompleteHome,DoneId,<<"complete">>),
        {CancelId,_} = start(CancelHome),
        {ok, Cancelled} = albedo_oauth:cancel_identified(CancelHome,CancelId,[login()]),
        CorruptLogin = setelement(7,login(),{device,fun() ->
            Parent ! {corrupt_expiry_actor,self()}, delayed_identity_start()
        end}),
        {CorruptId,CorruptInitial} = start(CorruptHome,CorruptLogin),
        CorruptPid = receive {corrupt_expiry_actor,CP} -> CP after 1000 -> error(no_corrupt_actor) end,
        CorruptMonitor = erlang:monitor(process,CorruptPid),
        CorruptPort = callback(CorruptInitial,<<"83">>),
        #{<<"state">> := <<"confirming">>} = await_stored_state(CorruptHome,CorruptId,<<"confirming">>),
        ok = file:write_file(filename:join(CorruptHome,<<"oauth-logins.json">>),<<"corrupt-records">>),
        %% No GET/input/cancel touches the pending attempt until its actor dies.
        receive {'DOWN',Monitor,process,Pid,killed} -> ok after 5000 -> error(unpolled_expiry_did_not_kill_actor) end,
        receive {'DOWN',CorruptMonitor,process,CorruptPid,killed} -> ok after 5000 -> error(corrupt_storage_retained_actor) end,
        false = is_process_alive(CorruptPid), no_accounts(CorruptHome),
        {error,econnrefused} = gen_tcp:connect({127,0,0,1},CorruptPort,[binary,{active,false}],1000),
        false = is_process_alive(Pid),
        {error,econnrefused} = gen_tcp:connect({127,0,0,1},Port,[binary,{active,false}],1000),
        no_accounts(Home),
        Expired = get(Home,Id), <<"expired">> = state(Expired),
        {error,{409,_,_}} = albedo_oauth:input_identified(Home,Id,albedo_http_api:etag(Expired),<<"confirm">>,[L]),
        no_accounts(Home),
        %% Let the later attempts' original timers race their terminal records.
        timer:sleep(700),
        Done = get(CompleteHome,DoneId), Cancelled = get(CancelHome,CancelId),
        [#{<<"access_token">> := <<"editor-test-secret">>}] = begin
            {ok,A} = albedo_credentials:accounts(albedo_credentials:creds_path(CompleteHome)),
            albedo_credentials:values(A,<<"zed">>)
        end,
        no_accounts(CancelHome)
    after
        persistent_term:put({albedo_clock,scale},OriginalScale),
        file:del_dir_r(Home),file:del_dir_r(CompleteHome),file:del_dir_r(CancelHome),file:del_dir_r(CorruptHome)
    end.
