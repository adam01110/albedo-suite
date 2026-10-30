-module(albedo_zed_auth).
-include_lib("public_key/include/public_key.hrl").
-export([catalog_endpoint/3, access_account/2, binding/2, start/0, account/1, access/2, reject/3, decrypt/3, identity/3,
         request/4, read_response/2, jwt_expiry/1]).

-define(ORIGIN, <<"https://cloud.zed.dev">>).
-define(LIMIT, 1048576).

start() ->
    try
        Private = public_key:generate_key({rsa, 2048, 65537}),
        Public = #'RSAPublicKey'{modulus = Private#'RSAPrivateKey'.modulus,
                                 publicExponent = Private#'RSAPrivateKey'.publicExponent},
        Encoded = base64:encode(public_key:der_encode('RSAPublicKey', Public), #{mode => urlsafe}),
        {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {ip, {127,0,0,1}},
                                        {packet, http_bin}, {packet_size, 8192}]),
        {ok, {_, Port}} = inet:sockname(Listen),
        Query = uri_string:compose_query([{<<"native_app_port">>, integer_to_binary(Port)},
                                         {<<"native_app_public_key">>, Encoded}]),
        Url = <<"https://zed.dev/native_app_signin?", Query/binary>>,
        Deadline = erlang:monotonic_time(millisecond) + 300000,
        Complete = fun(Progress) ->
            try
                case callback(Listen, Private, Port, Deadline) of
                    {ok, {Id, Token}} ->
                        Progress(<<"Validating Zed account identity">>),
                        case request(<<"GET">>, <<"/client/users/me">>, auth(Id, Token), <<>>) of
                            {ok, Response} ->
                                case identity(Id, Token, Response) of
                                    {ok, Credential} ->
                                        {account, _, Label, Detail, _} = account(Credential),
                                        case albedo_oauth:confirm(<<"Zed account: ", Label/binary, " (", Detail/binary, ")">>) of
                                            {ok, nil} -> {ok, Credential};
                                            Error -> Error
                                        end;
                                    Error -> Error
                                end;
                            Error -> Error
                        end;
                    Error -> Error
                end
            after gen_tcp:close(Listen) end
        end,
        {ok, {Url, <<"Sign in at zed.dev, then verify and confirm the account shown here. Do not share the sign-in URL.">>, Complete}}
    catch _:_ -> {error, <<"Could not start Zed browser sign-in">>} end.

callback(Listen, Private, Port, Deadline) ->
    Left = Deadline - erlang:monotonic_time(millisecond),
    case Left > 0 of
        false -> {error, <<"Zed browser sign-in expired">>};
        true -> case gen_tcp:accept(Listen, min(Left, 1000)) of
            {ok, Socket} ->
                Result = try serve(Socket, Private, Port) catch _:_ -> {error, invalid_callback} end,
                gen_tcp:close(Socket),
                case Result of {ok, _} -> Result; _ -> callback(Listen, Private, Port, Deadline) end;
            {error, timeout} -> callback(Listen, Private, Port, Deadline);
            _ -> {error, <<"Zed callback listener closed">>}
        end
    end.

serve(Socket, Private, Port) ->
    Result = case gen_tcp:recv(Socket, 0, 1000) of
        {ok, {http_request, 'GET', {abs_path, Target}, _}} ->
            Headers = headers(Socket, 32, #{}),
            Hosts = [<<"127.0.0.1:", (integer_to_binary(Port))/binary>>, <<"localhost:", (integer_to_binary(Port))/binary>>],
            true = lists:member(maps:get(<<"host">>, Headers, <<>>), Hosts),
            false = maps:is_key(<<"origin">>, Headers),
            #{path := <<"/">>, query := Query} = uri_string:parse(Target),
            Pairs = uri_string:dissect_query(Query),
            2 = length(Pairs),
            #{<<"user_id">> := Id, <<"access_token">> := Cipher} = maps:from_list(Pairs),
            decrypt(Private, Id, Cipher);
        _ -> {error, invalid_callback}
    end,
    Text = <<"Return to albedo to verify the account and confirm sign-in.">>,
    gen_tcp:send(Socket, [<<"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\nContent-Length: ">>,
                         integer_to_binary(byte_size(Text)), <<"\r\n\r\n">>, Text]),
    Result.

headers(_, 0, _) -> error(too_many_headers);
headers(Socket, Left, Acc) ->
    case gen_tcp:recv(Socket, 0, 1000) of
        {ok, http_eoh} -> Acc;
        {ok, {http_header, _, Name, _, Value}} ->
            Key = string:lowercase(case is_atom(Name) of true -> atom_to_binary(Name); false -> Name end),
            false = maps:is_key(Key, Acc),
            headers(Socket, Left - 1, Acc#{Key => Value});
        _ -> error(invalid_headers)
    end.

decrypt(Private, Id, Cipher) ->
    try
        true = is_binary(Id) andalso byte_size(Id) =< 12,
        N = binary_to_integer(Id), true = N > 0, Id = integer_to_binary(N),
        true = is_binary(Cipher) andalso byte_size(Cipher) =< 512,
        Bytes = base64:decode(Cipher, #{mode => urlsafe, padding => false}),
        256 = byte_size(Bytes),
        Token = public_key:decrypt_private(Bytes, Private,
            [{rsa_padding, rsa_pkcs1_oaep_padding}, {rsa_oaep_md, sha256}, {rsa_mgf1_md, sha256}]),
        true = safe(Token),
        {ok, {Id, Token}}
    catch _:_ -> {error, <<"Invalid Zed callback">>} end.

safe(B) when is_binary(B), byte_size(B) > 0, byte_size(B) =< 16384 ->
    re:run(B, <<"^[!-~]+$">>, [{capture, none}]) =:= match;
safe(_) -> false.

auth(Id, Token) -> [{<<"authorization">>, <<Id/binary, " ", Token/binary>>}].

identity(Id, Token, Response) ->
    try
        #{<<"user">> := #{<<"legacy_user_id">> := N, <<"github_login">> := Login,
                           <<"username">> := Username},
          <<"default_organization_id">> := Organization, <<"organizations">> := Organizations} = Response,
        Id = integer_to_binary(N), true = safe(Token),
        true = safe(Login), true = safe(Username), true = safe(Organization),
        true = lists:any(fun(O) -> maps:get(<<"id">>, O, null) =:= Organization end, Organizations),
        {ok, #{<<"type">> => <<"oauth">>, <<"user_id">> => Id, <<"access_token">> => Token,
               <<"github_login">> => Login, <<"username">> => Username,
               <<"organization_id">> => Organization}}
    catch _:_ -> {error, <<"Zed account identity or default organization could not be verified">>} end.

account(C) ->
    Id = maps:get(<<"user_id">>, C, <<>>),
    Login = maps:get(<<"github_login">>, C, <<"Zed">>),
    Org = maps:get(<<"organization_id">>, C, <<>>),
    {account, <<Id/binary, ":", Org/binary>>, maps:get(<<"label">>, C, Login),
     <<"user ", Id/binary, ", organization ", Org/binary>>, false}.

%% Native credentials are never sent to a profile-controlled endpoint.
request(Method, Path, Headers, Body) when Path =:= <<"/client/users/me">>; Path =:= <<"/client/llm_tokens">> ->
    Url = <<?ORIGIN/binary, Path/binary>>,
    case albedo_openai_transport:open_method(Method, Url,
            [{<<"content-type">>, <<"application/json">>} | Headers], Body, 15000) of
        {ok, Connection} ->
            albedo_openai_transport:with_connection_discard_errors(Connection, fun() ->
                read_response(Connection, erlang:monotonic_time(millisecond) + 15000)
            end);
        _ -> {error, <<"Could not reach Zed account service">>}
    end;
request(_, _, _, _) -> {error, <<"Untrusted Zed account endpoint">>}.

read_response(Connection, Deadline) ->
    case albedo_openai_transport:receive_until(Connection, Deadline) of
        {ok, {headers, 200, _, false}} -> body(Connection, Deadline, [], 0);
        {ok, {headers, Status, _, _}} ->
            {error, iolist_to_binary(io_lib:format("Zed account service returned HTTP ~B (redirects are refused)", [Status]))};
        _ -> {error, <<"Invalid Zed account response">>}
    end.

body(Connection, Deadline, Chunks, Size) ->
    case albedo_openai_transport:receive_until(Connection, Deadline) of
        {ok, {data, Bytes, Final}} when Size + byte_size(Bytes) =< ?LIMIT ->
            case Final of
                false -> body(Connection, Deadline, [Bytes | Chunks], Size + byte_size(Bytes));
                true -> try json:decode(iolist_to_binary(lists:reverse([Bytes | Chunks]))) of
                    Map when is_map(Map) -> {ok, Map};
                    _ -> {error, <<"Invalid Zed account JSON">>}
                catch _:_ -> {error, <<"Invalid Zed account JSON">>} end
            end;
        _ -> {error, <<"Zed account response exceeded its size or time budget">>}
    end.

access(Home, Profile) ->
    albedo_settings_lock:with_lock(Home, fun() -> access_locked(Home, Profile) end,
        fun() -> {error, <<"Zed credential store is busy">>} end).

access_locked(Home, Profile) ->
    Path = albedo_credentials:creds_path(Home),
    case albedo_credentials:accounts(Path) of
        {ok, Accounts} ->
            Values = albedo_credentials:values(Accounts, <<"zed">>),
            case selected(Home, Profile, Values) of
                {ok, [C]} -> token(Home, Accounts, C);
                {error, _} = Error -> Error;
                _ -> {error, <<"Select exactly one Zed account for this profile in /login">>}
            end;
        _ -> {error, <<"Sign in to Zed with /login">>}
    end.

selected(Home, Profile, Values) ->
    case albedo_credentials:config(Home) of
        {ok, #{<<"providers">> := Profiles}} ->
            P = maps:get(Profile, Profiles, #{}),
            case {maps:get(<<"accountId">>, P, null), maps:get(<<"accountIds">>, P, null)} of
                {null, null} -> case Values of [C] -> {ok, [C]}; _ -> {ok, []} end;
                _ -> albedo_credentials:bound_values(Home, Profile, Values)
            end;
        _ -> {error, <<"Zed profile is unavailable">>}
    end.

token(Home, Accounts, C) ->
    Now = erlang:system_time(second),
    case C of
        #{<<"jwt">> := Token, <<"jwt_expires">> := Exp} when is_integer(Exp), is_binary(Token), Exp > Now + 60 ->
            case jwt_expiry(Token) of
                {ok, Exp} -> {ok, Token};
                _ -> refresh_token(Home, Accounts, C, Now)
            end;
        _ -> refresh_token(Home, Accounts, C, Now)
    end.

refresh_token(Home, Accounts, C, Now) ->
    Id = maps:get(<<"user_id">>, C), Secret = maps:get(<<"access_token">>, C),
    Org = maps:get(<<"organization_id">>, C),
    Payload = iolist_to_binary(json:encode(#{<<"organization_id">> => Org})),
    case request(<<"POST">>, <<"/client/llm_tokens">>, auth(Id, Secret), Payload) of
        {ok, #{<<"token">> := Jwt}} ->
            case jwt_expiry(Jwt) of
                {ok, Expiry} when Expiry > Now + 60 ->
                    Updated = C#{<<"jwt">> => Jwt, <<"jwt_expires">> => Expiry},
                    Values = [case V =:= C of true -> Updated; false -> V end || V <- albedo_credentials:values(Accounts, <<"zed">>)],
                    case albedo_credentials:put_accounts(albedo_credentials:creds_path(Home),
                            albedo_credentials:put_values(Accounts, <<"zed">>, Values)) of
                        ok -> {ok, Jwt};
                        _ -> {error, <<"Could not save Zed token">>}
                    end;
                _ -> {error, <<"Zed returned an invalid or expired inference token">>}
            end;
        {ok, _} -> {error, <<"Zed returned no inference token">>};
        Error -> Error
    end.

jwt_expiry(Jwt) ->
    try
        true = safe(Jwt), [_, Payload, _] = binary:split(Jwt, <<".">>, [global]),
        #{<<"exp">> := Exp} = json:decode(base64:decode(Payload, #{mode => urlsafe, padding => false})),
        true = is_integer(Exp), {ok, Exp}
    catch _:_ -> {error, invalid_jwt} end.

reject(Home, Profile, Jwt) ->
    albedo_settings_lock:with_lock(Home, fun() ->
        Path = albedo_credentials:creds_path(Home),
        case albedo_credentials:accounts(Path) of
            {ok, Accounts} ->
                Values = albedo_credentials:values(Accounts, <<"zed">>),
                case selected(Home, Profile, Values) of
                    {ok, [#{<<"jwt">> := Jwt} = C]} ->
                        Updated = maps:without([<<"jwt">>, <<"jwt_expires">>], C),
                        albedo_credentials:put_accounts(Path, albedo_credentials:put_values(Accounts, <<"zed">>,
                            [case V =:= C of true -> Updated; false -> V end || V <- Values]));
                    _ -> ok
                end;
            _ -> ok
        end, nil
    end, fun() -> nil end).

catalog_endpoint(Home, Profile, Ordinary) ->
    case albedo_credentials:config(Home) of
        {ok, #{<<"providers">> := Ps}} ->
            case maps:get(Profile, Ps, #{}) of
                #{<<"extension">> := <<"zed">>} -> {some, <<"albedo:zed:profile:", Profile/binary>>};
                _ -> Ordinary
            end;
        _ -> Ordinary
    end.

access_account(Home, Id) ->
    albedo_settings_lock:with_lock(Home, fun() ->
        case albedo_credentials:accounts(albedo_credentials:creds_path(Home)) of
            {ok, Accounts} ->
                case [C || C <- albedo_credentials:values(Accounts, <<"zed">>), maps:get(<<"_albedo_account_id">>, C, null) =:= Id] of
                    [C] -> token(Home, Accounts, C);
                    _ -> {error, <<"Selected Zed account is unavailable">>}
                end;
            _ -> {error, <<"Sign in to Zed with /login">>}
        end
    end, fun() -> {error, <<"Zed credential store is busy">>} end).

binding(Home, Profile) ->
    case albedo_credentials:config(Home) of
        {ok, #{<<"providers">> := Ps}} ->
            P = maps:get(Profile, Ps, #{}),
            case maps:get(<<"apiKey">>, P, <<>>) =:= <<>> andalso string:trim(os:getenv("ZED_TOKEN", "")) =:= "" of
                true -> native_binding(Home, Profile);
                false -> none
            end;
        _ -> none
    end.

native_binding(Home, Profile) ->
    case albedo_credentials:accounts(albedo_credentials:creds_path(Home)) of
        {ok, Accounts} ->
            case selected(Home, Profile, albedo_credentials:values(Accounts, <<"zed">>)) of
                {ok, [C]} -> {ok, crypto:hash(sha256, term_to_binary(maps:with(
                    [<<"_albedo_account_id">>, <<"user_id">>, <<"organization_id">>, <<"access_token">>], C)))};
                _ -> none
            end;
        _ -> none
    end.
