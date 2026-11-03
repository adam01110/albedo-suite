-module(albedo_zed_auth).
-include_lib("public_key/include/public_key.hrl").
-export([catalog_endpoint/3, access_account/2, accounts/1, binding/2, start/0, account/1, access/2, reject/3, refresh_rejected_token/2, decrypt/3,
         identity/3, request/4, read_response/2, read_body/2, jwt_expiry/1]).

-define(ORIGIN, <<"https://cloud.zed.dev">>).
-define(SIGN_IN, <<"https://zed.dev/native_app_signin">>).
-define(SUCCEEDED, <<"https://zed.dev/native_app_signin_succeeded">>).
-define(ATTEMPT_MS, 300000).
-define(LIMIT, 1048576).

start() ->
    try
        Private = public_key:generate_key({rsa, 2048, 65537}),
        Public = #'RSAPublicKey'{modulus = Private#'RSAPrivateKey'.modulus,
                                 publicExponent = Private#'RSAPrivateKey'.publicExponent},
        Encoded = base64:encode(public_key:der_encode('RSAPublicKey', Public), #{mode => urlsafe}),
        {V4, V6, Port} = listen(),
        Query = uri_string:compose_query([{<<"native_app_port">>, integer_to_binary(Port)},
                                         {<<"native_app_public_key">>, Encoded}]),
        Url = <<?SIGN_IN/binary, "?", Query/binary>>,
        Deadline = erlang:monotonic_time(millisecond) + ?ATTEMPT_MS,
        Listeners = [L || L <- [V4, V6], is_port(L)],
        Complete = fun(Progress) ->
            try
                case callback(Listeners, Private, Port, Deadline) of
                    {ok, {Id, Token}} -> verify(Id, Token, Progress);
                    Error -> Error
                end
            after close(Listeners) end
        end,
        {ok, {Url, <<"Sign in at zed.dev with your Zed account, then confirm the account shown here. No Zed editor is needed. Do not share the sign-in URL.">>, Complete}}
    catch _:_ -> {error, <<"Could not start Zed browser sign-in">>} end.

%% Both loopback addresses share one port, so a browser resolving localhost to
%% ::1 reaches the same attempt. The IPv6 socket is optional.
listen() ->
    Options = [binary, {active, false}, {packet, http_bin}, {packet_size, 8192}, {reuseaddr, true}],
    {ok, V4} = gen_tcp:listen(0, [{ip, {127,0,0,1}} | Options]),
    {ok, {_, Port}} = inet:sockname(V4),
    V6 = case gen_tcp:listen(Port, [inet6, {ip, {0,0,0,0,0,0,0,1}}, {ipv6_v6only, true} | Options]) of
        {ok, Listen} -> Listen;
        _ -> undefined
    end,
    {V4, V6, Port}.

close(Listen) ->
    [gen_tcp:close(L) || L <- Listen, is_port(L)],
    ok.

verify(Id, Token, Progress) ->
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
    end.

callback(Listen, Private, Port, Deadline) ->
    Left = Deadline - erlang:monotonic_time(millisecond),
    case Left > 0 of
        false -> {error, <<"Zed browser sign-in expired">>};
        true -> case accept(Listen, min(Left, 250)) of
            {ok, Socket} ->
                Result = try serve(Socket, Private, Port) catch _:_ -> {error, invalid_callback} end,
                gen_tcp:close(Socket),
                case Result of {ok, _} -> Result; _ -> callback(Listen, Private, Port, Deadline) end;
            {error, timeout} -> callback(Listen, Private, Port, Deadline);
            _ -> {error, <<"Zed callback listener closed">>}
        end
    end.

accept([Listen], Wait) -> gen_tcp:accept(Listen, max(Wait, 0));
accept([Listen | Rest], Wait) ->
    case gen_tcp:accept(Listen, max(Wait, 0)) of
        {ok, Socket} -> {ok, Socket};
        {error, timeout} -> accept(Rest, 0);
        Error -> Error
    end.

%% The callback path and its extra query parameters are not part of the
%% contract; only the encrypted user_id/access_token pair is.
serve(Socket, Private, Port) ->
    Result = case gen_tcp:recv(Socket, 0, 1000) of
        {ok, {http_request, 'GET', {abs_path, Target}, _}} ->
            Headers = headers(Socket, 32, #{}),
            true = loopback(maps:get(<<"host">>, Headers, <<>>), Port),
            Query = maps:get(query, uri_string:parse(Target), <<>>),
            Params = maps:from_list(uri_string:dissect_query(Query)),
            #{<<"user_id">> := Id, <<"access_token">> := Cipher} = Params,
            decrypt(Private, Id, Cipher);
        _ -> {error, invalid_callback}
    end,
    respond(Socket, Result),
    Result.

loopback(Host, Port) ->
    P = integer_to_binary(Port),
    lists:member(Host, [<<"127.0.0.1:", P/binary>>, <<"localhost:", P/binary>>, <<"[::1]:", P/binary>>]).

%% A rejected callback answers 404 and the attempt keeps waiting; a decrypted
%% one sends the browser to zed.dev's success page, as the editor does.
respond(Socket, {ok, _}) ->
    gen_tcp:send(Socket, [<<"HTTP/1.1 302 Found\r\nLocation: ">>, ?SUCCEEDED,
                          <<"\r\nContent-Length: 0\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n">>]);
respond(Socket, _) ->
    gen_tcp:send(Socket, <<"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n">>).

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
        Token = token(Bytes, Private),
        true = safe(Token),
        {ok, {Id, Token}}
    catch _:_ -> {error, <<"Invalid Zed callback">>} end.

%% Current servers encrypt with OAEP-SHA256; the editor still accepts the older
%% PKCS#1 v1.5 format, so both decrypt.
token(Bytes, Private) ->
    try
        public_key:decrypt_private(Bytes, Private,
            [{rsa_padding, rsa_pkcs1_oaep_padding}, {rsa_oaep_md, sha256}, {rsa_mgf1_md, sha256}])
    catch _:_ ->
        public_key:decrypt_private(Bytes, Private, [{rsa_padding, rsa_pkcs1_padding}])
    end.

safe(B) when is_binary(B), byte_size(B) > 0, byte_size(B) =< 16384 ->
    re:run(B, <<"^[!-~]+$">>, [{capture, none}]) =:= match;
safe(_) -> false.

auth(Id, Token) -> [{<<"authorization">>, <<Id/binary, " ", Token/binary>>}].

%% GetAuthenticatedUserResponse: user.legacy_user_id identifies the account the
%% callback named, and default_organization_id is optional.
identity(Id, Token, Response) ->
    try
        %% `organizations` is `#[serde(default)]` in the account schema, so an
        %% account may omit it, and the editor takes the callback's user id as
        %% the credential identity instead of comparing account documents.
        #{<<"user">> := User} = Response,
        Organizations = maps:get(<<"organizations">>, Response, []),
        #{<<"github_login">> := Login} = User,
        Username = maps:get(<<"username">>, User, Login),
        true = is_list(Organizations),
        true = safe(Token) andalso safe(Login) andalso safe(Username),
        Organization = organization(maps:get(<<"default_organization_id">>, Response, null), Organizations),
        true = safe(Organization),
        {ok, #{<<"type">> => <<"oauth">>, <<"user_id">> => Id, <<"access_token">> => Token,
               <<"github_login">> => Login, <<"username">> => Username,
               <<"organization_id">> => Organization}}
    catch _:_ -> {error, <<"Zed account identity could not be verified">>} end.

%% The account's default organization when it names one of its organizations,
%% otherwise its only personal one, so an account without a default still signs in.
organization(Default, Organizations) when is_list(Organizations) ->
    Ids = [Id || #{<<"id">> := Id} <- Organizations, is_binary(Id)],
    case Default of
        Id when is_binary(Id), Id =/= <<>> ->
            %% With no organization list to contradict it, the account's own
            %% default stands; otherwise it must be one of the account's.
            true = Ids =:= [] orelse lists:member(Id, Ids),
            Id;
        _ ->
            case [Id || #{<<"id">> := Id, <<"is_personal">> := true} <- Organizations, is_binary(Id)] of
                [Id] -> Id;
                [] -> case Ids of [Id] -> Id; _ -> error(no_default_organization) end
            end
    end.

account(C) ->
    Id = maps:get(<<"user_id">>, C, <<>>),
    Login = maps:get(<<"github_login">>, C, <<"Zed">>),
    Org = maps:get(<<"organization_id">>, C, <<>>),
    {account, <<Id/binary, ":", Org/binary>>, maps:get(<<"label">>, C, Login),
     <<"user ", Id/binary, ", organization ", Org/binary>>, false}.

%% Native credentials are never sent to a profile-controlled endpoint.
request(Method, Path, Headers, Body) when Path =:= <<"/client/users/me">>; Path =:= <<"/client/llm_tokens">> ->
    Url = <<?ORIGIN/binary, Path/binary>>,
    case albedo_openai_transport:open(Method, Url,
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

%% The body of a 200 answer, for callers that read the status themselves.
read_body(Connection, Deadline) -> body(Connection, Deadline, [], 0).

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

%% Refresh the account that owned the rejected JWT, never a profile selected
%% later by endpoint. An ambiguous or superseded credential fails closed.
refresh_rejected_token(Home, Token) ->
    albedo_settings_lock:with_lock(Home, fun() ->
        Path = albedo_credentials:creds_path(Home),
        case albedo_credentials:accounts(Path) of
            {ok, Accounts} ->
                Values = albedo_credentials:values(Accounts, <<"zed">>),
                case [C || #{<<"jwt">> := Jwt} = C <- Values, Jwt =:= Token] of
                    [C] -> refresh_token(Home, Accounts, C, erlang:system_time(second));
                    _ -> {error, <<"Zed account changed during model discovery">>}
                end;
            _ -> {error, <<"Zed credential store is unavailable">>}
        end
    end, fun() -> {error, <<"Zed credential store is busy">>} end).

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

%% Every stored Zed account as the quota poller needs it: the label /login
%% shows, the legacy user id, and the access token the account endpoint
%% authenticates with. That endpoint takes the stored token, not the inference
%% JWT, so polling renews nothing: it must not spend a token exchange on an
%% account nobody is inferring with.
accounts(Home) ->
    albedo_settings_lock:with_lock(Home, fun() ->
        case albedo_credentials:accounts(albedo_credentials:creds_path(Home)) of
            {ok, Accounts} ->
                lists:filtermap(fun entry/1, albedo_credentials:values(Accounts, <<"zed">>));
            _ -> []
        end
    end, fun() -> [] end).

entry(C) ->
    Id = maps:get(<<"user_id">>, C, <<>>),
    Access = maps:get(<<"access_token">>, C, <<>>),
    Label = label(C),
    case Label =/= <<>> andalso safe(Id) andalso safe(Access) of
        true -> {true, #{<<"label">> => Label, <<"accountId">> => Id, <<"access">> => Access}};
        false -> false
    end.

%% A renamed account keeps that name, as it does everywhere else it is shown.
label(C) ->
    case [L || K <- [<<"label">>, <<"github_login">>, <<"username">>],
               L <- [maps:get(K, C, <<>>)], is_binary(L), L =/= <<>>] of
        [L | _] -> L;
        [] -> <<>>
    end.

%% Browser sign-in is the only credential, so every Zed profile refreshes the
%% same way; a profile without one has nothing to refresh.
binding(Home, Profile) ->
    case albedo_credentials:accounts(albedo_credentials:creds_path(Home)) of
        {ok, Accounts} ->
            case selected(Home, Profile, albedo_credentials:values(Accounts, <<"zed">>)) of
                {ok, [C]} -> {ok, crypto:hash(sha256, term_to_binary(maps:with(
                    [<<"_albedo_account_id">>, <<"user_id">>, <<"organization_id">>, <<"access_token">>], C)))};
                _ -> none
            end;
        _ -> none
    end.
