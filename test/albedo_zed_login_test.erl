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
        identity_cases(),
        confirmation_cases(),
        unpolled_expiry_cases(),
        refresh_cases(),
        transport_cases(),
        io:format("Zed login: crypto, identity, confirmation, persistence/logout, expiry, refresh isolation/concurrency, retry and bounded redirect refusal passed~n")
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
    Special = "open_method(M, <<\"https://cloud.zed.dev\", Path/binary>>, H, B, T) -> P = persistent_term:get(zed_login_fixture_port), U = iolist_to_binary([\"http://127.0.0.1:\", integer_to_binary(P), Path]), albedo_zed_fixture_transport:open_method(M,U,H,B,T); open_method(_,_,_,_,_) -> error(untrusted_origin).\n",
    Open = "open(U,H,B,T) -> open_method(<<\"POST\">>,U,H,B,T).\n",
    Rest = [begin
        Vars = lists:join(",", ["A" ++ integer_to_list(I) || I <- lists:seq(1, A)]),
        io_lib:format("~p(~s) -> albedo_zed_fixture_transport:~p(~s).~n", [N,Vars,N,Vars])
    end || {N,A} <- Exports, N =/= open_method, N =/= open],
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
        _ ->
            [Id | _] = binary:split(Auth, <<" ">>),
            case Path of
                <<"/client/users/me">> ->
                    N = case Mode of wrong_identity -> 999; _ -> binary_to_integer(Id) end,
                    {200, <<>>, json:encode(identity_response(N))};
                <<"/models">> ->
                    true = binary:match(Auth, <<"Bearer ">>) =:= {0,7},
                    {200, <<>>, json:encode(#{<<"models">> => [#{<<"id">> => <<"browser-fixture-model">>,
                        <<"provider">> => <<"anthropic">>, <<"max_token_count">> => 10000}]})};
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
    {error, _} = albedo_zed_auth:decrypt(K, <<"42">>, Legacy).

encrypt(Public, Token) -> base64:encode(public_key:encrypt_public(Token, Public,
    [{rsa_padding,rsa_pkcs1_oaep_padding},{rsa_oaep_md,sha256},{rsa_mgf1_md,sha256}]), #{mode=>urlsafe}).

identity_cases() ->
    R = identity_response(42),
    {ok, _} = albedo_zed_auth:identity(<<"42">>, <<"secret">>, R),
    {error, _} = albedo_zed_auth:identity(<<"43">>, <<"secret">>, R),
    {error, _} = albedo_zed_auth:identity(<<"42">>, <<"secret">>, R#{<<"default_organization_id">> => <<"foreign-org">>}),
    {error, _} = albedo_zed_auth:request(<<"GET">>, <<"https://untrusted.invalid">>, [], <<>>).

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
    {ok, Socket} = gen_tcp:connect({127,0,0,1},Port,[binary,{active,false}],1000),
    gen_tcp:send(Socket,["GET /?",Query," HTTP/1.1\r\nHost: ",Host,":",integer_to_binary(Port),"\r\n\r\n"]),
    {ok, _} = gen_tcp:recv(Socket,0,2000), gen_tcp:close(Socket), Port.

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
        <<"expired">> = state(get(Home,Expired)), no_accounts(Home),
        mode(wrong_identity), {Wrong, WrongInitial} = start(Home), callback(WrongInitial,<<"42">>),
        _ = await_state(Home,Wrong,<<"failed">>), no_accounts(Home), mode(normal)
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
        configure(Home,[One],#{<<"custom">> => (profile(<<"one-account">>))#{<<"baseUrl">> => <<"https://untrusted.invalid">>}}),
        {error,_} = albedo_zed:access(Home,<<"custom">>),
        Manual = (profile(<<"one-account">>))#{<<"baseUrl">> => <<"https://custom.invalid">>, <<"apiKey">> => <<"manual-jwt">>},
        configure(Home,[One],#{<<"custom">> => Manual}),
        {ok,{<<"https://custom.invalid">>,<<"manual-jwt">>}} = albedo_zed:access(Home,<<"custom">>)
    after file:del_dir_r(Home) end.

transport_cases() ->
    Headers = [{<<"authorization">>,<<"42 editor-test-secret">>}],
    lists:foreach(fun(M) ->
        mode(M), {error,_} = albedo_zed_auth:request(<<"GET">>,<<"/client/users/me">>,Headers,<<>>)
    end,[redirect,oversized,malformed]),
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
    {ok,[<<"browser-fixture-model">>]} = albedo_zed:models(Home,<<"albedo:zed:account:",PublicId/binary>>),
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
