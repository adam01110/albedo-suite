-module(albedo_zed_login_test).
-include_lib("public_key/include/public_key.hrl").
-export([run/0]).

run() ->
    application:ensure_all_started(crypto),
    application:ensure_all_started(public_key),
    install_transport(),
    {ok, OAuth} = 'albedo_sdk@oauth_flows':start(),
    persistent_term:put(zed_login_oauth, OAuth),
    Table = ets:new(zed_login_fixture, [named_table, public, set]),
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {ip, {127,0,0,1}}, {packet, http_bin}]),
    {ok, {_, Port}} = inet:sockname(Listen),
    persistent_term:put(zed_login_fixture_port, Port),
    Server = spawn_link(fun() -> fixture(Listen) end),
    try
        crypto_cases(),
        credential_cases(),
        forgery_cases(),
        callback_cases(),
        listener_property_cases(),
        rejected_callback_cases(),
        identity_cases(),
        status_cases(),
        quota_cases(),
        catalog_cases(),
        catalog_provider_less_cases(),
        catalog_effort_level_cases(),
        catalog_account_retry_cases(),
        confirmation_cases(),
        refresh_cases(),
        transport_cases(),
        home_cases(),
        io:format("Zed login: crypto, credential validation, callback contract, identity, status envelopes, catalog token refresh, malformed catalog entries, confirmation, persistence/logout, refresh isolation/concurrency, retry and bounded redirect refusal passed~n")
    after unlink(Server), exit(Server, kill), gen_tcp:close(Listen), ets:delete(Table) end,
    nil.

%% Gleam-built modules ship no Erlang source, so the transport is copied from
%% its abstract code: the copy keeps the real client, and a wrapper with the
%% same exports sends cloud.zed.dev to the local fixture and refuses others.
install_transport() ->
    {ok, {albedo_http, [{abstract_code, {raw_abstract_v1, Forms}}]}} =
        beam_lib:chunks(code:which(albedo_http), [abstract_code]),
    Renamed = [case F of
        {attribute, A, module, albedo_http} -> {attribute, A, module, albedo_zed_fixture_transport};
        _ -> F
    end || F <- Forms],
    {ok, albedo_zed_fixture_transport, Binary} = compile:forms(Renamed, [binary, report_errors]),
    {module, _} = code:load_binary(albedo_zed_fixture_transport, "albedo_zed_fixture_transport.erl", Binary),
    Exports = [E || E = {Name, _} <- albedo_http:module_info(exports), Name =/= module_info],
    Temp = transport_temp(),
    Head = ["-module(albedo_http).\n-export([", lists:join(",", [io_lib:format("~p/~B", [N,A]) || {N,A} <- Exports]), "]).\n"],
    Special = "open_method(O, M, <<\"https://cloud.zed.dev\", Path/binary>>, H, B, T) -> P = persistent_term:get(zed_login_fixture_port), U = iolist_to_binary([\"http://127.0.0.1:\", integer_to_binary(P), Path]), albedo_zed_fixture_transport:open_method(O,M,U,H,B,T); open_method(_,_,_,_,_,_) -> error(untrusted_origin).\n",
    Open = "open(O,U,H,B,T) -> open_method(O,<<\"POST\">>,U,H,B,T).\n",
    Rest = [begin
        Vars = lists:join(",", ["A" ++ integer_to_list(I) || I <- lists:seq(1, A)]),
        io_lib:format("~p(~s) -> albedo_zed_fixture_transport:~p(~s).~n", [N,Vars,N,Vars])
    end || {N,A} <- Exports, N =/= open, N =/= open_method],
    ok = file:write_file(Temp, [Head, Special, Open, Rest]),
    {ok, albedo_http, Wrapper} = compile:file(Temp, [binary, report_errors]),
    code:purge(albedo_http),
    {module, _} = code:load_binary(albedo_http, Temp, Wrapper),
    file:delete(Temp).

%% The SDK modules the moved Erlang APIs became.
-define(CREDS, 'albedo_sdk@credential_store').

oauth_service() -> persistent_term:get(zed_login_oauth).
start_identified(Home, Id, Provider, Login, Intent) ->
    'albedo_sdk@oauth_flows':start_identified(oauth_service(), Home, Id, Provider, Login, none, Intent, fun() -> none end).
get_identified(Home, Id, Logins) ->
    'albedo_sdk@oauth_flows':get_identified(oauth_service(), Home, Id, Logins).
input_identified(Home, Id, Match, Text, Logins) ->
    'albedo_sdk@oauth_flows':input_identified(oauth_service(), Home, Id, Match, Text, Logins).
cancel_identified(Home, Id, Logins) ->
    'albedo_sdk@oauth_flows':cancel_identified(oauth_service(), Home, Id, Logins).
etag(Flow) -> 'albedo_web@etag':strong(Flow).
read_json(Path) -> 'albedo_sdk@settings_store':read_object(Path).
write_json(Path, Value) -> {ok, nil} = ?CREDS:write(Path, Value), ok.
put_accounts(Path, Accounts) -> {ok, nil} = ?CREDS:put_accounts(Path, Accounts), ok.

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
        models_levels_not_a_list when Path =:= <<"/models">> ->
            {200, <<>>, json:encode(#{<<"models">> => [
                #{<<"id">> => <<"levels-not-a-list">>, <<"provider">> => <<"anthropic">>,
                  <<"supported_effort_levels">> => <<"low">>},
                #{<<"id">> => <<"levels-fixture-model">>, <<"provider">> => <<"anthropic">>,
                  <<"supports_thinking">> => true,
                  <<"supported_effort_levels">> => [#{<<"value">> => <<"low">>}]}]})};
        models_entry_without_provider when Path =:= <<"/models">> ->
            {200, <<>>, json:encode(#{<<"models">> => [
                #{<<"id">> => <<"provider-less-model">>, <<"max_token_count">> => 1000},
                #{<<"id">> => <<"provider-fixture-model">>, <<"provider">> => <<"anthropic">>}]})};
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

%% A credential the transport cannot send is not a credential, as
%% albedo_zed:usable/1 states for the inference token. A `$`-anchored printable
%% run also matches before a final newline, so every validator must still refuse
%% one: the decrypted callback token, the account the poller lists, and the
%% reading that puts the stored token in a header.
credential_cases() ->
    K = public_key:generate_key({rsa,2048,65537}),
    P = #'RSAPublicKey'{modulus=K#'RSAPrivateKey'.modulus, publicExponent=65537},
    {ok, {<<"42">>, <<"editor-test-secret">>}} =
        albedo_zed_auth:decrypt(K, <<"42">>, encrypt(P, <<"editor-test-secret">>)),
    {error, _} = albedo_zed_auth:decrypt(K, <<"42">>, encrypt(P, <<"editor-test-secret\n">>)),
    {error, <<"Zed account credential is unusable">>} =
        albedo_zed_quota:read(<<"42">>, <<"quota-fixture-secret\n">>),
    {error, <<"Zed account credential is unusable">>} =
        albedo_zed_quota:read(<<"42\n">>, <<"quota-fixture-secret">>),
    Home = home(),
    try
        Good = credential(<<"61">>, <<"good-account">>),
        Bad = (credential(<<"62">>, <<"newline-account">>))#{<<"access_token">> => <<"editor-test-secret\n">>},
        configure(Home, [Good, Bad], #{<<"one">> => profile(<<"good-account">>)}),
        [#{<<"accountId">> := <<"61">>}] = albedo_zed_auth:accounts(Home)
    after file:del_dir_r(Home) end.

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
        true = binary:match(Reply, <<"Location: https://zed.dev/native_app_signin_succeeded\r\n">>) =/= nomatch,
        _ = await_state(Home, Id, <<"confirming">>),
        {ok, _} = cancel_identified(Home, Id, [L]),
        %% A callback that cannot be decrypted is answered 404 and the attempt stays waiting.
        {Rejected, RejectedInitial} = start(Home),
        {WrongId, WrongInitial} = start(Home),
        {_, NotFound} = callback(RejectedInitial, <<"62">>, WrongInitial, <<"127.0.0.1">>, {127,0,0,1}, <<"/">>, <<>>),
        <<"HTTP/1.1 404", _/binary>> = NotFound,
        <<"waiting">> = state(get(Home, Rejected)), no_accounts(Home),
        {ok, _} = cancel_identified(Home, Rejected, [L]),
        {ok, _} = cancel_identified(Home, WrongId, [L]),
        %% localhost can resolve to ::1, so both loopback addresses reach the attempt.
        {V6, V6Initial} = start(Home),
        case gen_tcp:connect({0,0,0,0,0,0,0,1}, port_of(V6Initial), [binary, {active, false}, inet6], 1000) of
            {ok, Probe} ->
                gen_tcp:close(Probe),
                {_, V6Reply} = callback(V6Initial, <<"63">>, V6Initial, <<"[::1]">>, {0,0,0,0,0,0,0,1}, <<"/">>, <<>>),
                <<"HTTP/1.1 302", _/binary>> = V6Reply,
                _ = await_state(Home, V6, <<"confirming">>),
                {ok, _} = cancel_identified(Home, V6, [L]);
            {error, _} -> ok
        end
    after file:del_dir_r(Home) end.

port_of(Flow) ->
    #{<<"url">> := Url} = json:decode(Flow),
    #{query := Query} = uri_string:parse(Url),
    binary_to_integer(maps:get(<<"native_app_port">>, maps:from_list(uri_string:dissect_query(Query)))).

% A callback token must be impossible to forge without the listener's key.
% OpenSSL answers a block whose PKCS#1 v1.5 padding does not check out with an
% implicit rejection message instead of an error, so the legacy path accepted a
% random ciphertext as a token whenever the rejection happened to be short and
% printable. The key and ciphertext below are one such pair, kept as fixtures
% because the rejection is deterministic for them.
forgery_cases() ->
    Key = binary_to_term(base64:decode(forgery_fixture(forgery_key))),
    {error, _} = albedo_zed_auth:decrypt(Key, <<"7">>, list_to_binary(forgery_fixture(forgery_cipher))),
    % The same hole over fresh ciphertexts, so a fix cannot special-case one.
    Accepted = lists:foldl(fun(_, Count) ->
        Cipher = base64:encode(crypto:strong_rand_bytes(256), #{mode => urlsafe, padding => false}),
        case albedo_zed_auth:decrypt(Key, <<"7">>, Cipher) of
            {error, _} -> Count;
            {ok, _} -> Count + 1
        end
    end, 0, lists:seq(1, 500)),
    0 = Accepted.

forgery_fixture(forgery_key) ->
            "g2gLdw1SU0FQcml2YXRlS2V5dwl0d28tcHJpbWVvAAABAAB9hGO+JCutrgYqHiWGEceyOMXXy/CY"
            "ijd5qmCkFi7ddiF3PjhPCspJECBGxIgd447b5rGNWyrW3hTL6GRPBVMXmDnm4wPxfC5R9SjW7Sm6"
            "2yUtXWzxWlSM1EqB7LBh8UImbKyudGrRp5Zq++fdEWJJMPS0FJssWGwLNRyCXnnrkFarh1J55alo"
            "qJG+/v3/Cd7PxxEqfAqLQqQQcIqVFnA7cia+FYaaZpWsgaLQL5SaBgDdDtAvnykUBp4PNYk4vSuo"
            "fxkXnS+AZUZu8vIvNCde1g+Lr4w24o3mtRqyVQiHFmyrEsWzTfxMMeiSvf9VSdzltoCKYmQhTdSM"
            "J6c3/JWfYgABAAFvAAABAACRcm5+fXS/uEPRtoYH+TnuT+U47ckW2T+AomY1igM2s4HmV3GslGBL"
            "eK1PLIEvZFaoTkiEph8p9jz9SKwHa2u3wWvqsS1YKurdf2A43OQ7ANDRN6ZXwnwR9MdaX8wD4JPu"
            "na9Wy2PutOJmrBs7p0pdpBK8EilARmgSheQJp552ZXzPmBFeK2Dny8yfmzxgaIM5fXtc2cgxl+nD"
            "cIhHF5+dNMHZIfbfW45uJg4RqNt2xhZ4mI6ck1AMPK+BW8DbYnBLmtiV9bUs1SfTVDqoAkddxtTP"
            "kaAL4d2WqI2HXC1oVDyQzsjRoAzOuosNUmm4/IyMCC3mQdctZBvYCr3Zc0kBboAAdSzVsWhKK8ve"
            "5yCPqdMiUVhlgktdWxLp4rWBeYbgvj2fvZZUFum+6Z5aWRX38Fu2OhNW63i7M9h7iVsK6jNeAsOO"
            "2GUBVf0qfDssqUmA57QrgjRo8hEsNAD3MVKrQq3TD6Ia8FGjvjTznZ1dH8eBhRzF0T3EIG58FYZY"
            "9TqIB9JugADpFtxJh1QqEkFGt+ZSVrxvUqKxnnDF4Q3upXXNL+l7SS98sQtLqrvnz02KMXUqBUXo"
            "gkeQr5lSZCrjxjmLZme3/ADS2Du7bqRMOFaLhW2ahL848NwhCCsFqVNSnwKlAm5+2ZUE7JNyVvd6"
            "MIC5+cIz6IIojvj6cDKyS+/6BfqDwm6AAAUDXyVWJsprSXsdcFnloBkChSlADd7JD4nf98VbeK3i"
            "vi2EkrI1LcM2fGrLje9D+2POCpNSWbt5ZTk1//UNJRX8rWF4cC3wZva36oNDzFkqo6ESLOYiEBcj"
            "V8jcgxRdDG9jPQTTkRIfz1daf2mvynWqMqs2Loogxq4UUmXbahYtboAAcbFiSZ1c6teEOQeJ3cNf"
            "BHT9tC1ZfJD/PAQYpO56URaPZX1NJLWHx3RXP/huy3ymAp6hN5eA9RMaCfErk4dFVAYrDowSbYIp"
            "n25qpAdQIYeYeR8tDnBBk4h0y3bI0rQt4Cp48MtTlAwQcsRSHD10M0cOo8P07OJZXvZcPveSKx9u"
            "gABrjUbnGhuwDAXs/2CeLHRlLW+4Y43ejPkMToP1Cvce3+t2E5PdCm3qared9MVJfmmDSP1Oxe8k"
            "sl4Zxl89H+RJUtUxErUST/I6LvAbCYA+kWlbw5q/B6IEA5d/Y0RL8GwTUdtdklMcOhTnkFA7erMJ"
            "PlP7flEP0ScphwuCX4WVMHcMYXNuMV9OT1ZBTFVF";
forgery_fixture(forgery_cipher) ->
            "TGnU9sOrqouCML1tnQO13jF2Hv2MEyiWH-EOwChvR8Vp5IaQobSDT5hnhF6Fz3RE9vhNK4Z7kpUl"
            "pEqeQ3t1upBXqUBB6_BYPIoHgCYwcF4vM1p1pYoAxEc78DulpHGsy7wS_Im9ZFLm9BsdFdwBlWG9"
            "MzmTfbt77n6lRlzxxNW0XWIl8Qp8VLaMYkedebZ2qaXdHAxPf4X4AqriE7AaUcpPm2ECJKl-7TsJ"
            "-Bzpd--wKBQQGKDg7D5d1_pLiFBvrK6FqJTWcr2rAGOcyGzh9NByPWWplZDo31FFXnOFo2dbYvPG"
            "871YQy0cFayR7bWrdkqvMXqUc6KQ6vZbDf9wQw".

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
    %% `organizations` is `#[serde(default)]`: an omitted list cannot contradict
    %% the account's own default, so the default stands.
    {ok, #{<<"organization_id">> := <<"org-42">>}} =
        albedo_zed_auth:identity(<<"42">>, <<"secret">>, Documented#{<<"organizations">> => []}),
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
    {error, <<"Zed account identity could not be verified">>} = albedo_zed_auth:identity(<<"42">>, <<"secret">>, #{}),
    {error, _} = albedo_zed_auth:request(<<"GET">>, <<"https://untrusted.invalid">>, [], <<>>).

%% The editor drops a status it does not recognise and keeps reading; a failed
%% status still fails the turn.
status_cases() ->
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
        [low, high] = element(11, On),
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

%% The catalog is remote data. An entry that states its effort levels as
%% anything but a list offers none of them, the way an entry with no levels at
%% all does; it does not take the model lookup down with it.
catalog_effort_level_cases() ->
    Home = home(),
    try
        Exp = erlang:system_time(second) + 3600,
        C = (credential(<<"77">>, <<"catalog-levels">>))#{<<"jwt">> => jwt(Exp, 1, <<"77">>), <<"jwt_expires">> => Exp},
        configure(Home, [C], #{<<"levels">> => profile(<<"catalog-levels">>)}),
        mode(models_levels_not_a_list),
        {ok, {_, Token}} = albedo_zed:access(Home, <<"levels">>),
        %% The same catalog, reachable three ways: no crash, no efforts.
        {some, Info} = albedo_zed:lookup(Home, <<"https://cloud.zed.dev">>, <<"levels-not-a-list">>),
        [] = element(11, Info),
        {some, Listed} = albedo_zed:lookup(Home, <<"https://cloud.zed.dev">>, <<"levels-fixture-model">>),
        [low] = element(11, Listed),
        {ok, <<"anthropic">>} = albedo_zed:route(Home, <<"https://cloud.zed.dev">>, Token, <<"levels-not-a-list">>),
        {ok, Models} = albedo_zed:models(Home, <<"https://cloud.zed.dev">>),
        true = lists:member(<<"levels-not-a-list">>, Models)
    after mode(normal), file:del_dir_r(Home) end.

%% The catalog is remote data. An entry that names no provider names no wire
%% protocol, so routing refuses it with the answer it gives a provider it
%% cannot send, instead of ending in a case clause.
catalog_provider_less_cases() ->
    Home = home(),
    try
        Exp = erlang:system_time(second) + 3600,
        C = (credential(<<"78">>, <<"catalog-provider">>))#{<<"jwt">> => jwt(Exp, 1, <<"78">>), <<"jwt_expires">> => Exp},
        configure(Home, [C], #{<<"provider">> => profile(<<"catalog-provider">>)}),
        mode(models_entry_without_provider),
        {ok, {_, Token}} = albedo_zed:access(Home, <<"provider">>),
        {ok, Models} = albedo_zed:models(Home, <<"https://cloud.zed.dev">>),
        true = lists:member(<<"provider-less-model">>, Models),
        {error, Message} = albedo_zed:route(Home, <<"https://cloud.zed.dev">>, Token, <<"provider-less-model">>),
        <<"model uses a provider this integration does not send">> = Message,
        %% A routable entry beside it still routes.
        {ok, <<"anthropic">>} = albedo_zed:route(Home, <<"https://cloud.zed.dev">>, Token, <<"provider-fixture-model">>)
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

%% zed.dev sends the browser back to the literal loopback authority it was
%% given: http://127.0.0.1:<native_app_port>/?user_id=..&access_token=.., which
%% is why Zed's own client binds 127.0.0.1:0 and nothing else
%% (crates/client/src/client.rs, authenticate_with_browser). The cases below pin
%% what follows from that: what an attempt advertises, that its IPv4 authority
%% completes whatever the IPv6 loopback does, that the Host header must name this
%% attempt's loopback authority, that a rejected callback never ends an attempt,
%% and that two live attempts never accept each other's callbacks.
listener_property_cases() ->
    rand:seed(exsss, {20261121, 51723, 9}),
    advertised_url_cases(8),
    ipv4_authority_cases(6),
    host_header_cases(48),
    malformed_callback_cases(),
    attempt_isolation_cases(6),
    io:format("Zed sign-in listener: advertised URL, IPv4 authority, Host/port "
              "validation, undecryptable callbacks and attempt isolation passed~n").

with_attempt(Run) ->
    Home = home(), L = login(),
    {Id, Flow} = start(Home),
    try Run(Home, Id, Flow)
    after listener_cancel(Home, Id, L), file:del_dir_r(Home) end.

%% The advertised URL names zed.dev's sign-in page, this attempt's port and a
%% fresh RSA-2048 public key, and carries no other parameter.
advertised_url_cases(N) ->
    Moduli = [with_attempt(fun(_, _, Flow) -> advertised_url(Flow) end) || _ <- lists:seq(1, N)],
    N = length(lists:usort(Moduli)),
    ok.

advertised_url(Flow) ->
    #{<<"url">> := Url} = json:decode(Flow),
    #{scheme := <<"https">>, host := <<"zed.dev">>, path := <<"/native_app_signin">>,
      query := Query} = uri_string:parse(Url),
    Params = uri_string:dissect_query(Query),
    2 = length(Params),
    #{<<"native_app_port">> := PortBinary, <<"native_app_public_key">> := Key} = maps:from_list(Params),
    Port = binary_to_integer(PortBinary),
    PortBinary = integer_to_binary(Port),
    true = Port >= 1024 andalso Port =< 65535,
    #'RSAPublicKey'{modulus = Modulus} =
        public_key:der_decode('RSAPublicKey', base64:decode(Key, #{mode => urlsafe})),
    2048 = bit_size(binary:encode_unsigned(Modulus)),
    Modulus.

%% Whoever owns ::1:Port, whether this attempt, another process, or a kernel
%% without IPv6, zed.dev's redirect to 127.0.0.1:Port must still complete.
ipv4_authority_cases(N) ->
    Verdicts = [with_attempt(fun(Home, Id, Flow) ->
        Port = port_of(Flow),
        Verdict = case gen_tcp:listen(Port, [inet6, {ip, {0,0,0,0,0,0,0,1}}, {ipv6_v6only, true},
                                             binary, {active, false}]) of
            {ok, Probe} -> gen_tcp:close(Probe), free;
            {error, eaddrinuse} -> taken;
            {error, Reason} -> {unavailable, Reason}
        end,
        <<"waiting">> = state(get(Home, Id)),
        <<"HTTP/1.1 302", _/binary>> =
            listener_request(Port, listener_host(<<"127.0.0.1">>, Port), <<"/">>, listener_query(Flow), <<>>),
        _ = await_state(Home, Id, <<"confirming">>),
        Verdict
    end) || _ <- lists:seq(1, N)],
    io:format("  ::1:~p free=~B taken=~B other=~p~n",
        [port, length([V || V <- Verdicts, V =:= free]),
         length([V || V <- Verdicts, V =:= taken]), [V || V <- Verdicts, not is_atom(V)]]).

%% A callback is accepted exactly when its Host names this attempt's loopback
%% authority, and a refused one leaves the attempt waiting and completable.
host_header_cases(N) ->
    lists:foreach(fun(_) ->
        {Name, PortKind, Expected} = listener_host_variant(),
        Target = element(rand:uniform(3), {<<"/">>, <<"/native_app_signin">>, <<"/callback/deep">>}),
        Headers = element(rand:uniform(3), {<<>>, <<"Origin: https://cloud.zed.dev\r\n">>,
                                            <<"Sec-Fetch-Site: cross-site\r\n">>}),
        ExtraQuery = case rand:uniform(2) of 1 -> []; 2 -> [{<<"country_code">>, <<"NL">>}] end,
        with_attempt(fun(Home, Id, Flow) ->
            Port = port_of(Flow),
            Header = case {Name, PortKind} of
                {none, _} -> none;
                {_, bare} -> Name;
                {_, attempt} -> listener_host(Name, Port);
                {_, other} -> listener_host(Name, listener_other_port(Port))
            end,
            Query = listener_query(Flow, ExtraQuery),
            case Expected of
                accept ->
                    <<"HTTP/1.1 302", _/binary>> = listener_request(Port, Header, Target, Query, Headers),
                    _ = await_state(Home, Id, <<"confirming">>);
                reject ->
                    listener_404(listener_request(Port, Header, Target, Query, Headers), {Name, PortKind, Port}),
                    <<"waiting">> = state(get(Home, Id)),
                    <<"HTTP/1.1 302", _/binary>> =
                        listener_request(Port, listener_host(<<"127.0.0.1">>, Port), Target, Query, Headers),
                    _ = await_state(Home, Id, <<"confirming">>)
            end
        end)
    end, lists:seq(1, N)).

%% Only a Host naming one of the three loopback spellings of this attempt's port
%% is accepted; every other authority, and a missing one, is refused.
listener_host_variant() ->
    Accepted = {<<"127.0.0.1">>, <<"localhost">>, <<"[::1]">>},
    Foreign = {<<"LOCALHOST">>, <<"localhost.">>, <<"127.0.0.2">>, <<"0.0.0.0">>,
               <<"[::2]">>, <<"::1">>, <<"evil.invalid">>, <<"127.0.0.1:0">>},
    case rand:uniform(5) of
        1 -> {listener_pick(Accepted), attempt, accept};
        2 -> {listener_pick(Foreign), attempt, reject};
        3 -> {listener_pick(Accepted), other, reject};
        4 -> {listener_pick(Accepted), bare, reject};
        5 -> case rand:uniform(2) of
                 1 -> {none, none, reject};
                 2 -> {listener_pick(Foreign), other, reject}
             end
    end.

listener_pick(Values) -> element(rand:uniform(tuple_size(Values)), Values).

listener_other_port(Port) ->
    Candidate = case rand:uniform(4) of
        1 -> Port + 1;
        2 -> Port - 1;
        3 -> 80;
        4 -> 1024 + rand:uniform(64000)
    end,
    case Candidate =:= Port orelse Candidate < 1 orelse Candidate > 65535 of
        true -> listener_other_port(Port);
        false -> Candidate
    end.

%% Every rejected callback is answered 404, never ends the attempt, and leaves
%% it able to complete with a valid callback afterwards.
malformed_callback_cases() ->
    Ids = {<<"0">>, <<>>, <<"007">>, <<"12a">>, <<"1234567890123">>, <<"-3">>, <<"42">>},
    Tokens = {empty, junk, foreign_key, random_256, control_bytes},
    lists:foreach(fun(Id) ->
        lists:foreach(fun(Token) -> malformed_callback(Id, Token) end, tuple_to_list(Tokens))
    end, tuple_to_list(Ids)).

malformed_callback(Id, Token) ->
    with_attempt(fun(Home, Attempt, Flow) ->
        Port = port_of(Flow),
        Public = listener_key(Flow),
        Cipher = case Token of
            empty -> <<>>;
            junk -> <<"not-base64-at-all">>;
            foreign_key -> listener_cipher(listener_foreign_public(), <<"editor-test-secret">>);
            random_256 -> base64:encode(crypto:strong_rand_bytes(256));
            control_bytes -> listener_cipher(Public, <<"editor-test", 10, "secret">>)
        end,
        Query = uri_string:compose_query([{<<"user_id">>, Id}, {<<"access_token">>, Cipher}]),
        listener_404(listener_request(Port, listener_host(<<"127.0.0.1">>, Port), <<"/">>, Query, <<>>),
                     {Id, Token}),
        <<"waiting">> = state(get(Home, Attempt)),
        <<"HTTP/1.1 302", _/binary>> =
            listener_request(Port, listener_host(<<"localhost">>, Port), <<"/">>, listener_query(Flow), <<>>),
        _ = await_state(Home, Attempt, <<"confirming">>)
    end).

%% Two live attempts advertise distinct ports and refuse each other's callback.
attempt_isolation_cases(N) ->
    lists:foreach(fun(_) ->
        Home = home(), L = login(),
        {A, AFlow} = start(Home), {B, BFlow} = start(Home),
        try
            PortA = port_of(AFlow), PortB = port_of(BFlow),
            true = PortA =/= PortB,
            Cross = uri_string:compose_query([{<<"user_id">>, <<"42">>},
                {<<"access_token">>, listener_cipher(listener_key(AFlow), <<"editor-test-secret">>)}]),
            listener_404(listener_request(PortB, listener_host(<<"127.0.0.1">>, PortB), <<"/">>, Cross, <<>>),
                         cross_attempt),
            <<"waiting">> = state(get(Home, A)),
            <<"waiting">> = state(get(Home, B)),
            <<"HTTP/1.1 302", _/binary>> =
                listener_request(PortB, listener_host(<<"127.0.0.1">>, PortB), <<"/">>, listener_query(BFlow), <<>>),
            _ = await_state(Home, B, <<"confirming">>),
            <<"waiting">> = state(get(Home, A)),
            <<"HTTP/1.1 302", _/binary>> =
                listener_request(PortA, listener_host(<<"127.0.0.1">>, PortA), <<"/">>, listener_query(AFlow), <<>>),
            _ = await_state(Home, A, <<"confirming">>)
        after listener_cancel(Home, A, L), listener_cancel(Home, B, L), file:del_dir_r(Home) end
    end, lists:seq(1, N)).

listener_request(Port, HostHeader, Target, Query, Extra) ->
    Request = ["GET ", Target, "?", Query, " HTTP/1.1\r\n",
               case HostHeader of none -> []; Header -> ["Host: ", Header, "\r\n"] end, Extra, "\r\n"],
    {ok, Socket} = gen_tcp:connect({127,0,0,1}, Port, [binary, {active, false}], 1000),
    ok = gen_tcp:send(Socket, Request),
    Reply = response(Socket, <<>>),
    gen_tcp:close(Socket),
    Reply.

%% docs/zed.md: a malformed callback is answered 404 and never ends the attempt.
listener_404(<<"HTTP/1.1 404", _/binary>>, _) -> ok;
listener_404(Reply, Case) -> error({callback_not_answered_404, Case, Reply}).

listener_cancel(Home, Id, L) ->
    try cancel_identified(Home, Id, [L]) catch _:_ -> ok end.

listener_host(Name, Port) -> <<Name/binary, ":", (integer_to_binary(Port))/binary>>.

listener_key(Flow) ->
    #{<<"url">> := Url} = json:decode(Flow),
    #{query := Query} = uri_string:parse(Url),
    Key = maps:get(<<"native_app_public_key">>, maps:from_list(uri_string:dissect_query(Query))),
    public_key:der_decode('RSAPublicKey', base64:decode(Key, #{mode => urlsafe})).

listener_cipher(Public, Token) -> encrypt(Public, Token).

listener_query(Flow) -> listener_query(Flow, []).

listener_query(Flow, Extra) ->
    uri_string:compose_query([{<<"user_id">>, <<"42">>},
        {<<"access_token">>, listener_cipher(listener_key(Flow), <<"editor-test-secret">>)} | Extra]).

listener_foreign_public() ->
    case persistent_term:get(zed_listener_foreign_key, undefined) of
        undefined ->
            Key = public_key:generate_key({rsa, 2048, 65537}),
            Public = #'RSAPublicKey'{modulus = Key#'RSAPrivateKey'.modulus,
                                     publicExponent = Key#'RSAPrivateKey'.publicExponent},
            persistent_term:put(zed_listener_foreign_key, Public),
            Public;
        Public -> Public
    end.

%% Every refusal is answered, as docs/zed.md promises: a Host that is not this
%% attempt's loopback authority and a callback without the encrypted pair are
%% rejected with 404 instead of a silently closed connection, and the attempt
%% keeps waiting for the real callback.
rejected_callback_cases() ->
    Home = home(), L = login(),
    {Id, Flow} = start(Home),
    try
        Port = port_of(Flow), P = integer_to_binary(Port),
        Query = callback_query(Flow, <<"42">>),
        lists:foreach(fun(Host) ->
            <<"HTTP/1.1 404", _/binary>> = raw_callback(Port, Host, <<"/">>, Query)
        end, [<<"evil.invalid:", P/binary>>, none, <<"127.0.0.1">>,
              <<"127.0.0.1:", (integer_to_binary(Port + 1))/binary>>]),
        <<"HTTP/1.1 404", _/binary>> = raw_callback(Port, <<"127.0.0.1:", P/binary>>, <<"/">>, <<"user_id=42">>),
        <<"waiting">> = state(get(Home, Id)),
        callback(Flow, <<"42">>),
        _ = await_state(Home, Id, <<"confirming">>)
    after cancel_identified(Home, Id, [L]), file:del_dir_r(Home) end.

callback_query(KeyFlow, User) ->
    #{<<"url">> := KeyUrl} = json:decode(KeyFlow),
    #{query := KeyQuery} = uri_string:parse(KeyUrl),
    KeyParams = maps:from_list(uri_string:dissect_query(KeyQuery)),
    Public = public_key:der_decode('RSAPublicKey', base64:decode(maps:get(<<"native_app_public_key">>, KeyParams), #{mode=>urlsafe})),
    Cipher = encrypt(Public, <<"editor-test-secret">>),
    uri_string:compose_query([{<<"user_id">>,User},{<<"access_token">>,Cipher}]).

%% A callback request whose Host header is written verbatim, or left out.
raw_callback(Port, none, Target, Query) ->
    raw_request(Port, ["GET ", Target, "?", Query, " HTTP/1.1\r\n\r\n"]);
raw_callback(Port, Host, Target, Query) ->
    raw_request(Port, ["GET ", Target, "?", Query, " HTTP/1.1\r\nHost: ", Host, "\r\n\r\n"]).

raw_request(Port, Request) ->
    {ok, Socket} = gen_tcp:connect({127,0,0,1}, Port, [binary, {active, false}], 1000),
    ok = gen_tcp:send(Socket, Request),
    Reply = response(Socket, <<>>),
    gen_tcp:close(Socket),
    Reply.

home() ->
    prepare_home(list_to_binary(filename:join("/tmp", "zed-login-home-" ++ os:getpid() ++ "-" ++ integer_to_list(erlang:unique_integer([positive]))))).

%% A run that died leaves its home behind at the name a later run reuses.
prepare_home(Home) ->
    _ = file:del_dir_r(Home),
    ok = filelib:ensure_dir(filename:join(Home, <<"dummy">>)),
    Home.

%% Compiling the wrapper needs a scratch file of its own: two runs writing the
%% same path would delete each other's source mid-compile.
transport_temp() ->
    filename:join("/tmp", "zed-login-transport-" ++ os:getpid() ++ "-" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".erl").

%% Two runs of this fixture never share a home or a scratch file: erlang's
%% counter is only unique inside one runtime, so a neighbouring VM picks the
%% same name.
home_cases() ->
    Home = home(),
    true = string:find(binary_to_list(Home), os:getpid()) =/= nomatch,
    Temp = transport_temp(),
    true = string:find(Temp, os:getpid()) =/= nomatch,
    Stale = filename:join(Home, <<"sessions.json">>),
    ok = file:write_file(Stale, <<"{}">>),
    Home = prepare_home(Home),
    false = filelib:is_file(Stale),
    _ = file:del_dir_r(Home),
    nil.

login() -> {login, <<"zed">>, <<"Zed">>, <<"browser">>, model, <<"zed">>, {device, fun albedo_zed_auth:start/0},
            fun(_) -> <<>> end, fun(_,_,_) -> {error,unused} end, fun albedo_zed_auth:account/1, none}.

start(Home) -> start(Home, login()).

start(Home, L) ->
    Id = albedo_oauth_test_support:identity(),
    {ok, {true, Flow}} = start_identified(Home, Id, <<"zed">>, {some,L}, <<"zed">>),
    {Id, Flow}.

get(Home, Id) -> {ok, F} = get_identified(Home,Id,[login()]), F.

state(Flow) -> maps:get(<<"state">>, json:decode(Flow)).

await_state(Home, Id, State) -> await_state(Home, Id, State, 200).
await_state(Home, Id, Expected, N) when N > 0 ->
    F = get(Home, Id),
    case state(F) of Expected -> F; _ -> timer:sleep(10), await_state(Home,Id,Expected,N-1) end;
await_state(Home, Id, Expected, _) -> error({state_timeout, Expected, json:decode(get(Home, Id))}).

callback(Flow, User) -> callback(Flow, User, Flow, <<"127.0.0.1">>).

callback(Flow, User, KeyFlow, Host) ->
    {Port, _} = callback(Flow, User, KeyFlow, Host, {127,0,0,1}, <<"/">>, <<>>),
    Port.

callback(Flow, User, KeyFlow, Host, Address, Target, Extra) ->
    Port = port_of(Flow),
    Query = callback_query(KeyFlow, User),
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
    case ?CREDS:accounts(?CREDS:path(Home)) of
        {ok,A} -> [] = ?CREDS:values(A,<<"zed">>);
        {error,enoent} -> ok
    end.

confirmation_cases() ->
    Home = home(),
    try
        L = login(),
        {ok, Snapshot} = 'albedo_sdk@auth_accounts':auth_snapshot(Home,[L],'albedo_sdk@key_environment':empty()),
        #{<<"providers">> := [#{<<"id">> := <<"zed">>, <<"flows">> := [<<"browser">>]}]} = json:decode(Snapshot),
        {Id, Initial} = start(Home),
        %% Input while waiting only wakes a device flow; it never confirms.
        {ok, _} = input_identified(Home,Id,etag(Initial),<<"confirm">>,[L]),
        {WrongAttempt, WrongKey} = start(Home),
        callback(Initial, <<"42">>, WrongKey, <<"127.0.0.1">>),
        <<"waiting">> = state(get(Home, Id)), no_accounts(Home),
        {ok,_} = cancel_identified(Home,WrongAttempt,[L]),
        callback(Initial, <<"42">>),
        Confirm = await_state(Home,Id,<<"confirming">>), no_accounts(Home),
        {ok, Records} = file:read_file(filename:join(Home,<<"oauth-logins.json">>)),
        nomatch = binary:match(Records,<<"editor-test-secret">>),
        true = binary:match(Confirm,<<"github-42">>) =/= nomatch,
        {error, {412,_,_}} = input_identified(Home,Id,etag(Initial),<<"confirm">>,[L]),
        {error, {400,_,_}} = input_identified(Home,Id,etag(Confirm),<<"yes">>,[L]),
        {Other, OtherInitial} = start(Home),
        {error, {412,_,_}} = input_identified(Home,Id,etag(OtherInitial),<<"confirm">>,[L]),
        {ok,_} = cancel_identified(Home,Other,[L]),
        {ok,_} = input_identified(Home,Id,etag(Confirm),<<"confirm">>,[L]),
        _ = await_state(Home,Id,<<"complete">>),
        {ok,A} = ?CREDS:accounts(?CREDS:path(Home)),
        [#{<<"access_token">> := <<"editor-test-secret">>, <<"_albedo_account_id">> := PublicId}] = ?CREDS:values(A,<<"zed">>),
        clean_home_inference(Home, PublicId),
        ok = write_json(filename:join(Home,<<"config.json">>),#{<<"providers">> => #{}}),
        {ok,nil} = 'albedo_sdk@auth_accounts':remove_account(Home,[L],PublicId,'albedo_sdk@key_environment':empty()), no_accounts(Home),
        {Cancelled, CancelInitial} = start(Home),
        callback(CancelInitial, <<"43">>, CancelInitial, <<"localhost">>),
        _ = await_state(Home,Cancelled,<<"confirming">>),
        {ok,_} = cancel_identified(Home,Cancelled,[L]), no_accounts(Home),
        {error,{409,_,_}} = input_identified(Home,Cancelled,etag(get(Home,Cancelled)),<<"confirm">>,[L]),
        {Expired, ExpInitial} = start(Home), callback(ExpInitial,<<"44">>),
        _ = await_state(Home,Expired,<<"confirming">>),
        RecordsPath = filename:join(Home,<<"oauth-logins.json">>),
        {ok, R0} = read_json(RecordsPath),
        ok = write_json(RecordsPath,R0#{Expired := (maps:get(Expired,R0))#{<<"expires">> := 0}}),
        <<"expired">> = state(get(Home,Expired)), no_accounts(Home)
        %% A differing legacy_user_id is no longer refused: the credential keeps
        %% the callback's user id, as the editor's does (identity_cases).

    after file:del_dir_r(Home) end.

credential(Id, Public) ->
    {ok,C} = albedo_zed_auth:identity(Id,<<"editor-test-secret">>,identity_response(binary_to_integer(Id))),
    C#{<<"_albedo_account_id">> => Public}.

configure(Home, Values, Profiles) ->
    ok = write_json(filename:join(Home,<<"creds.json">>),#{<<"accounts">> => #{<<"zed">> => Values}}),
    ok = write_json(filename:join(Home,<<"config.json">>),#{<<"active">> => <<"one">>, <<"providers">> => Profiles}).

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
        {ok,A} = ?CREDS:accounts(?CREDS:path(Home)),
        [First,Second] = ?CREDS:values(A,<<"zed">>),
        Expired = First#{<<"jwt_expires">> => 0},
        ok = put_accounts(?CREDS:path(Home),#{<<"zed">> => [Expired,Second]}),
        {ok,T3a} = albedo_zed_auth:access(Home,<<"one">>), true = T3a =/= T1,
        {ok, CacheA} = ?CREDS:accounts(?CREDS:path(Home)),
        [CachedOne,CachedTwo] = ?CREDS:values(CacheA,<<"zed">>),
        lists:foreach(fun(Bad) ->
            ok = put_accounts(?CREDS:path(Home),#{<<"zed">> => [Bad,CachedTwo]}),
            {ok,FreshValid} = albedo_zed_auth:access(Home,<<"one">>),
            {ok,_} = albedo_zed_auth:jwt_expiry(FreshValid)
        end,[CachedOne#{<<"jwt_expires">> => null},
              CachedOne#{<<"jwt">> => <<"bad.jwt.value">>}]),
        {ok,T3} = albedo_zed_auth:access(Home,<<"one">>),
        put(attempts,0), put(events,[]),
        Run = fun(_,Token,Emit) ->
            put(attempts,get(attempts)+1),
            case Token =:= T3 of
                true -> continue = Emit({responded,401}), {error,{refused,credential_rejected,{some,401},<<"expired">>}};
                false -> continue = Emit({text_delta,0,0,<<"only-once">>}), {ok,success}
            end
        end,
        OnEvent = fun(E) -> put(events,[E|get(events)]), continue end,
        {ok,success} = albedo_zed:exchange(Home,<<"one">>,Run,OnEvent),
        2 = get(attempts), [{text_delta,0,0,<<"only-once">>}] = get(events),
        {ok,Current} = albedo_zed_auth:access(Home,<<"one">>), put(attempts,0),
        Partial = fun(_,_,Emit) -> put(attempts,get(attempts)+1),Emit({arguments_delta,0,<<"tool">>,<<"{}">>}),{error,{refused,credential_rejected,{some,401},<<>>}} end,
        {error,_} = albedo_zed:exchange(Home,<<"one">>,Partial,OnEvent), 1 = get(attempts),
        ChangedRun = fun(_,_,_) ->
            put(attempts,get(attempts)+1),
            ok = write_json(filename:join(Home,<<"config.json">>),
                #{<<"providers">> => Profiles#{<<"one">> := profile(<<"two-account">>)}}),
            {error,{refused,credential_rejected,{some,401},<<>>}}
        end,
        put(attempts,0),
        {error,_} = albedo_zed:exchange(Home,<<"one">>,ChangedRun,OnEvent), 1 = get(attempts),
        ok = write_json(filename:join(Home,<<"config.json">>),#{<<"providers">> => Profiles}),
        mode(expired), albedo_zed_auth:reject(Home,<<"one">>,Current),
        {error,_} = albedo_zed_auth:access(Home,<<"one">>), mode(normal),
        configure(Home,[One,Two],#{<<"ambiguous">> => #{<<"extension">> => <<"zed">>}}),
        {error,_} = albedo_zed_auth:access(Home,<<"ambiguous">>),
        %% Browser sign-in is the only credential: a profile apiKey still
        %% refuses the profile's catalogue, and two leftovers name the first.
        configure(Home,[One],#{<<"keyed">> => (profile(<<"one-account">>))#{<<"apiKey">> => <<"manual-jwt">>}}),
        {error, KeyedCatalog} = albedo_zed:models(Home,<<"albedo:zed:profile:keyed">>),
        true = binary:match(KeyedCatalog, <<"apiKey">>) =/= nomatch,
        configure(Home,[One],#{<<"zed">> => profile(<<"one-account">>)}),
        {ok,{<<"https://cloud.zed.dev">>,_}} = albedo_zed:access(Home,<<"zed">>),
        os:putenv("ZED_TOKEN", "environment-jwt"),
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
            <<"Zed /models">>, [high], none, <<"provider">>, none}} =
            albedo_zed:lookup(Home, <<"https://cloud.zed.dev">>, <<"browser-fixture-model">>),
        %% A token the transport cannot send is not a credential.
        true = albedo_zed:usable(<<"inference-jwt">>),
        false = albedo_zed:usable(<<>>),
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
    ok = write_json(filename:join(Home,<<"config.json">>),
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
    {ok, Accounts} = ?CREDS:accounts(?CREDS:path(Home)),
    [#{<<"access_token">> := <<"editor-test-secret">>, <<"jwt">> := _, <<"jwt_expires">> := _}] = ?CREDS:values(Accounts,<<"zed">>).
