-module(albedo_zed).
-export([exchange/4, access/2, models/2, lookup/3, route/4, reload/1, wrap/4, unwrap/1, usable/1]).

-define(ENDPOINT, <<"https://cloud.zed.dev">>).

%% Browser sign-in in the native credential store is the only Zed credential:
%% a profile apiKey, a daemon ZED_TOKEN, or a profile-controlled endpoint is
%% refused rather than used or sent elsewhere.
access(Home, Profile) ->
    P = maps:get(Profile, profiles(Home), #{}),
    Endpoint = endpoint(maps:get(<<"baseUrl">>, P, ?ENDPOINT)),
    case refusal(P, Endpoint) of
        ok -> case albedo_zed_auth:access(Home, Profile) of
            {ok, Token} -> credential(Endpoint, Token);
            Error -> Error
        end;
        Error -> Error
    end.

%% A token the transport cannot send is not a credential.
credential(Endpoint, Token) ->
    case usable(Token) of
        true -> {ok, {Endpoint, Token}};
        false -> {error, <<"Zed returned an unusable inference token; sign in again with /login zed">>}
    end.

usable(Token) when is_binary(Token), Token =/= <<>> ->
    binary:match(Token, [<<"\r">>, <<"\n">>]) =:= nomatch;
usable(_) -> false.

refusal(P, Endpoint) ->
    case {maps:get(<<"apiKey">>, P, <<>>), env("ZED_TOKEN"), native_endpoint(Endpoint)} of
        {Key, _, _} when is_binary(Key), Key =/= <<>> ->
            {error, <<"Zed has no apiKey credential; remove apiKey from this profile and sign in with /login zed">>};
        {_, Token, _} when Token =/= <<>> ->
            {error, <<"Zed no longer reads ZED_TOKEN; unset it in the daemon environment and sign in with /login zed">>};
        {_, _, false} ->
            {error, <<"Zed sends native credentials only to https://cloud.zed.dev; custom Zed base URLs are unsupported">>};
        _ -> ok
    end.

profiles(Home) ->
    case albedo_credentials:config(Home) of
        {ok, #{<<"providers">> := Ps}} when is_map(Ps) -> Ps;
        _ -> #{}
    end.

env(Name) ->
    case os:getenv(Name) of false -> <<>>; S -> unicode:characters_to_binary(string:trim(S)) end.

endpoint(<<>>) -> ?ENDPOINT;
endpoint(B) when is_binary(B) -> string:trim(B, trailing, "/");
endpoint(_) -> <<>>.

%% The fixed origin, plus the loopback HTTP fixtures offline tests serve; a
%% native credential never reaches another origin.
native_endpoint(?ENDPOINT) -> true;
native_endpoint(B) ->
    try uri_string:parse(B) of
        #{scheme := <<"http">>, host := Host} = Uri ->
            lists:member(Host, [<<"127.0.0.1">>, <<"localhost">>, <<"::1">>])
            andalso not lists:any(fun(K) -> maps:is_key(K, Uri) end, [userinfo, query, fragment]);
        _ -> false
    catch _:_ -> false end.

%% Only the selected endpoint's profile can supply its credential.
catalog_access(Home, <<"albedo:zed:profile:", Profile/binary>>) -> access(Home, Profile);
catalog_access(Home, <<"albedo:zed:account:", Id/binary>>) ->
    case albedo_zed_auth:access_account(Home, Id) of
        {ok, Token} -> {ok, {?ENDPOINT, Token}};
        Error -> Error
    end;
catalog_access(Home, Endpoint) ->
    Matches = [Name || {Name, #{<<"extension">> := <<"zed">>} = P} <- lists:sort(maps:to_list(profiles(Home))),
        endpoint(maps:get(<<"baseUrl">>, P, ?ENDPOINT)) =:= Endpoint],
    Active = case albedo_credentials:config(Home) of
        {ok, Config} -> maps:get(<<"active">>, Config, <<>>);
        _ -> <<>>
    end,
    case lists:member(Active, Matches) of
        true -> access(Home, Active);
        false -> case Matches of
            [Name] -> access(Home, Name);
            [] when Endpoint =:= ?ENDPOINT -> access(Home, <<>>);
            [] -> {error, <<"no Zed profile for this endpoint">>};
            _ -> {error, <<"multiple Zed profiles for this endpoint; select an active profile for discovery">>}
        end
    end.

models(Home, Endpoint) ->
    case catalog(Home, Endpoint, false) of
        {ok, Models} -> {ok, [Id || #{<<"id">> := Id} = M <- Models, enabled(M)]};
        Error -> Error
    end.

lookup(Home, Endpoint, Id) ->
    case catalog(Home, Endpoint, false) of
        {ok, Models} ->
            case [M || #{<<"id">> := I} = M <- Models, I =:= Id, enabled(M)] of
                [M | _] ->
                    Modalities = case maps:get(<<"supports_images">>, M, false) of true -> [<<"text">>, <<"image">>]; _ -> [<<"text">>] end,
                    %% The catalog, not a fixed list, decides which efforts the
                    %% model offers; a model without thinking offers none, so no
                    %% encoder can request reasoning the model does not support.
                    Efforts = case maps:get(<<"supports_thinking">>, M, true) of
                        false -> [];
                        _ -> [V || #{<<"value">> := V} <- maps:get(<<"supported_effort_levels">>, M, []), is_binary(V)]
                    end,
                    {some, {model_info, Id, <<"zed">>, positive(maps:get(<<"max_token_count">>, M, 0)),
                        positive(maps:get(<<"max_token_count_in_max_mode">>, M, 0)),
                        positive(maps:get(<<"max_output_tokens">>, M, 0)), Modalities,
                        {some, Endpoint}, [], <<"Zed /models">>, Efforts}};
                _ -> none
            end;
        _ -> none
    end.

positive(N) when is_integer(N), N > 0 -> {some, N};
positive(_) -> none.

reload(Home) ->
    Targets = [Name || {Name, #{<<"extension">> := <<"zed">>}} <- maps:to_list(profiles(Home))],
    lists:foldl(fun(Name, Acc) ->
        Result = case access(Home, Name) of
            {ok, {E, Token}} -> catalog_token(Home, E, Token, true);
            Error -> Error
        end,
        case Result of {ok, _} -> Acc; ErrorResult -> ErrorResult end
    end, {ok, nil}, Targets).

%% A model the account cannot select stays in the cache with the reason the
%% catalog gives, so lookup and routing can tell it apart from a misspelt id.
enabled(M) -> maps:get(<<"is_disabled">>, M, false) =/= true.

catalog(Home, Endpoint, Force) ->
    case catalog_access(Home, Endpoint) of
        {ok, {Actual, Token}} -> catalog_token(Home, Actual, Token, Force);
        Error -> Error
    end.

catalog_token(Home, Endpoint, Token, Force) ->
    Path = catalog_path(Home, Endpoint, Token),
    Cached = case file:read_file(Path) of
        {ok, B} -> try json:decode(B) catch _:_ -> #{} end;
        _ -> #{}
    end,
    Now = erlang:system_time(second),
    case Cached of
        #{<<"at">> := At, <<"models">> := Ms} when not Force, is_integer(At), At + 3600 > Now, is_list(Ms) -> {ok, Ms};
        _ -> fetch_models(Home, Endpoint, Token, Now)
    end.

catalog_path(Home, Endpoint, Token) ->
    Hash = binary:encode_hex(crypto:hash(sha256, <<Endpoint/binary, 0, Token/binary>>), lowercase),
    filename:join(Home, <<"zed-models-", Hash/binary, ".json">>).

%% The editor sends /models through the same authenticated path as inference
%% and retries once with a refreshed token when the server rejects the cached
%% one; a second rejection is a credential problem, not a transport failure.
fetch_models(Home, Endpoint, Token, Now) ->
    case models_request(Endpoint, Token) of
        {ok, Models} -> store_models(Home, Endpoint, Token, Now, Models);
        {error, unauthorized} -> refresh_models(Home, Endpoint, Token, Now);
        Error -> catalog_error(Error)
    end.

refresh_models(Home, Endpoint, Token, Now) ->
    case albedo_zed_auth:refresh_rejected_token(Home, Token) of
        {ok, Fresh} -> case models_request(Endpoint, Fresh) of
            {ok, Models} -> store_models(Home, Endpoint, Fresh, Now, Models);
            {error, unauthorized} -> {error, <<"Zed rejected the inference token for /models; sign in again with /login zed">>};
            Error -> catalog_error(Error)
        end;
        {error, Reason} -> {error, Reason}
    end.

store_models(Home, Endpoint, Token, Now, Models) ->
    try Models of
        #{<<"models">> := Ms} when is_list(Ms) ->
            Valid = [M || #{<<"id">> := Id} = M <- Ms, is_binary(Id)],
            Path = catalog_path(Home, Endpoint, Token),
            _ = filelib:ensure_dir(Path),
            _ = file:write_file(Path, json:encode(#{<<"at">> => Now, <<"models">> => Valid})),
            {ok, Valid};
        _ -> {error, <<"unexpected Zed /models response">>}
    catch _:_ -> {error, <<"invalid Zed /models JSON">>} end.

catalog_error({error, {http, Status}}) ->
    {error, iolist_to_binary(io_lib:format("Zed /models returned HTTP ~B", [Status]))};
catalog_error(_) ->
    {error, <<"could not reach Zed /models">>}.

models_request(Endpoint, Token) ->
    Headers = [{"authorization", binary_to_list(<<"Bearer ", Token/binary>>)},
               {"x-zed-client-supports-x-ai", "true"}],
    model_response(Endpoint, Headers).

wrap(Body, Session, Provider, Model) ->
    try
        Decoded = json:decode(Body),
        Request = case Provider of
            <<"google">> -> Decoded#{<<"model">> => <<"models/", Model/binary>>};
            _ -> Decoded
        end,
        Prompt = binary:encode_hex(crypto:strong_rand_bytes(16), lowercase),
        Payload = #{<<"provider">> => Provider, <<"model">> => Model,
            <<"thread_id">> => Session, <<"prompt_id">> => Prompt,
            <<"provider_request">> => Request},
        {ok, iolist_to_binary(json:encode(Payload))}
    catch _:_ -> {error, <<"invalid Zed provider request">>} end.

unwrap(Line) ->
    try json:decode(Line) of
        #{<<"event">> := Event} when is_map(Event) -> {ok, iolist_to_binary(json:encode(Event))};
        #{<<"status">> := <<"stream_ended">>} -> {ok, <<"stream_ended">>};
        #{<<"status">> := <<"started">>} -> {ok, <<>>};
        #{<<"status">> := #{<<"queued">> := _}} -> {ok, <<>>};
        #{<<"status">> := #{<<"failed">> := Failure}} ->
            {error, maps:get(<<"message">>, Failure, <<"Zed stream failed">>)};
        %% The status enum has a catch-all, and the editor maps an unrecognised
        %% status to no event: a new status name is not a failed turn.
        #{<<"status">> := _} ->
            {ok, <<>>};
        _ -> {error, <<"unrecognized Zed stream envelope">>}
    catch _:_ -> {error, <<"invalid Zed stream JSON">>} end.

route(Home, Endpoint, Token, Id) ->
    case catalog_token(Home, Endpoint, Token, false) of
        {ok, Models} ->
            case [M || #{<<"id">> := I} = M <- Models, I =:= Id] of
                [#{<<"is_disabled">> := true, <<"disabled_reason">> := Reason} | _] when is_binary(Reason), Reason =/= <<>> ->
                    {error, <<"model is disabled for this Zed account: ", Reason/binary>>};
                [#{<<"is_disabled">> := true} | _] ->
                    {error, <<"model is disabled for this Zed account">>};
                [#{<<"provider">> := P} | _] ->
                    case lists:member(P, [<<"anthropic">>, <<"open_ai">>, <<"google">>, <<"x_ai">>]) of
                        true -> {ok, P};
                        false -> {error, <<"model uses a provider this integration does not send">>}
                    end;
                [] -> {error, <<"model is not in the Zed catalog for this account">>}
            end;
        Error -> Error
    end.

%% A 401 before model output is safe to retry once; never replay a partial turn.
exchange(Home, Profile, Run, OnEvent) ->
    case snapshot(Home, Profile) of
        {ok, {Endpoint, Token, Binding}} ->
            retry(Home, Profile, Endpoint, Token, Binding, Run, OnEvent);
        {error, Reason} -> {error, {invalid_request, Reason}}
    end.

snapshot(Home, Profile) ->
    albedo_settings_lock:with_lock(Home, fun() ->
        case access(Home, Profile) of
            {ok, {Endpoint, Token}} -> {ok, {Endpoint, Token, albedo_zed_auth:binding(Home, Profile)}};
            Error -> Error
        end
    end, fun() -> {error, <<"Zed credential store is busy">>} end).

retry(Home, Profile, Endpoint, Token, Binding, Run, OnEvent) ->
    Ref = make_ref(), put(Ref, false),
    Forward = fun(Event) ->
        case Event of
            {responded, 401} -> continue;
            {responded, _} -> OnEvent(Event);
            _ -> put(Ref, true), OnEvent(Event)
        end
    end,
    try Run(Endpoint, Token, Forward) of
        {error, {http_error, 401, _}} = Error ->
            case get(Ref) of
                false when Binding =/= none ->
                    Refreshed = albedo_settings_lock:with_lock(Home, fun() ->
                        case albedo_zed_auth:binding(Home, Profile) =:= Binding of
                            true -> albedo_zed_auth:reject(Home, Profile, Token), snapshot(Home, Profile);
                            false -> {error, <<"Zed account changed during the request">>}
                        end
                    end, fun() -> {error, <<"Zed credential store is busy">>} end),
                    case Refreshed of
                        {ok, {Endpoint, Fresh, Binding}} -> Run(Endpoint, Fresh, OnEvent);
                        _ -> Error
                    end;
                _ -> Error
            end;
        Result -> Result
    after erase(Ref) end.

%% A rejected token is reported as such, so discovery can refresh it instead of
%% presenting an authentication failure as an unreachable service.
model_response(Endpoint, Headers) ->
    case albedo_openai_transport:open(<<"GET">>, <<Endpoint/binary, "/models">>,
            [{list_to_binary(K), list_to_binary(V)} || {K, V} <- Headers], <<>>, 10000) of
        {ok, Connection} ->
            Deadline = erlang:monotonic_time(millisecond) + 10000,
            albedo_openai_transport:with_connection_discard_errors(Connection, fun() ->
                case albedo_openai_transport:receive_until(Connection, Deadline) of
                    {ok, {headers, 200, _, false}} -> albedo_zed_auth:read_body(Connection, Deadline);
                    {ok, {headers, 401, _, _}} -> {error, unauthorized};
                    {ok, {headers, Status, _, _}} -> {error, {http, Status}};
                    _ -> {error, transport}
                end
            end);
        _ -> {error, transport}
    end.
