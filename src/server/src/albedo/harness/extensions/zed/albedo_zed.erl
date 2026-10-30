-module(albedo_zed).
-export([access/2, models/2, lookup/3, route/4, reload/1, wrap/4, unwrap/1]).

-define(ENDPOINT, <<"https://cloud.zed.dev">>).

access(Home, Profile) ->
    Profiles = profiles(Home),
    P = maps:get(Profile, Profiles, #{}),
    Endpoint = endpoint(maps:get(<<"baseUrl">>, P, ?ENDPOINT)),
    Key = maps:get(<<"apiKey">>, P, <<>>),
    Token = case Key of <<>> -> env("ZED_TOKEN"); _ -> Key end,
    case valid_endpoint(Endpoint) andalso is_binary(Token) andalso
         Token =/= <<>> andalso binary:match(Token, [<<"\r">>, <<"\n">>]) =:= nomatch of
        true -> {ok, {Endpoint, Token}};
        false -> {error, <<"Zed requires a valid HTTPS base URL and a JWT in apiKey or ZED_TOKEN (HTTP is allowed only on loopback)">>}
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

valid_endpoint(B) ->
    try uri_string:parse(B) of
        #{scheme := Scheme, host := Host} = Uri ->
            (Scheme =:= <<"https">> orelse
             (Scheme =:= <<"http">> andalso lists:member(Host, [<<"127.0.0.1">>, <<"localhost">>, <<"::1">>])))
            andalso not lists:any(fun(K) -> maps:is_key(K, Uri) end, [userinfo, query, fragment]);
        _ -> false
    catch _:_ -> false end.

%% Only the selected endpoint's profile can supply its credential.
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
        {ok, Models} -> {ok, [Id || #{<<"id">> := Id} <- Models]};
        Error -> Error
    end.

lookup(Home, Endpoint, Id) ->
    case catalog(Home, Endpoint, false) of
        {ok, Models} ->
            case [M || #{<<"id">> := I} = M <- Models, I =:= Id] of
                [M | _] ->
                    Modalities = case maps:get(<<"supports_images">>, M, false) of true -> [<<"text">>, <<"image">>]; _ -> [<<"text">>] end,
                    Efforts = [V || #{<<"value">> := V} <- maps:get(<<"supported_effort_levels">>, M, []), is_binary(V)],
                    {some, {model_info, Id, <<"zed">>, positive(maps:get(<<"max_token_count">>, M, 0)),
                        positive(maps:get(<<"max_token_count_in_max_mode">>, M, 0)),
                        positive(maps:get(<<"max_output_tokens">>, M, 0)), Modalities,
                        {some, Endpoint}, [<<"ZED_TOKEN">>], <<"Zed /models">>, Efforts}};
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

catalog(Home, Endpoint, Force) ->
    case catalog_access(Home, Endpoint) of
        {ok, {_, Token}} -> catalog_token(Home, Endpoint, Token, Force);
        Error -> Error
    end.

catalog_token(Home, Endpoint, Token, Force) ->
            Hash = binary:encode_hex(crypto:hash(sha256, <<Endpoint/binary, 0, Token/binary>>), lowercase),
            Path = filename:join(Home, <<"zed-models-", Hash/binary, ".json">>),
            Cached = case file:read_file(Path) of
                {ok, B} -> try json:decode(B) catch _:_ -> #{} end;
                _ -> #{}
            end,
            Now = erlang:system_time(second),
            case Cached of
                #{<<"at">> := At, <<"models">> := Ms} when not Force, is_integer(At), At + 3600 > Now, is_list(Ms) -> {ok, Ms};
                _ -> fetch_models(Endpoint, Token, Path, Now)
            end.

fetch_models(Endpoint, Token, Path, Now) ->
    Headers = [{"authorization", binary_to_list(<<"Bearer ", Token/binary>>)},
               {"x-zed-client-supports-x-ai", "true"}],
    case albedo_http:get(binary_to_list(<<Endpoint/binary, "/models">>), Headers, 10000, 5000) of
        {ok, {200, _, Body}} ->
            try json:decode(Body) of
                #{<<"models">> := Ms} when is_list(Ms) ->
                    Valid = [M || #{<<"id">> := Id} = M <- Ms, is_binary(Id), maps:get(<<"is_disabled">>, M, false) =/= true],
                    _ = filelib:ensure_dir(Path),
                    _ = file:write_file(Path, json:encode(#{<<"at">> => Now, <<"models">> => Valid})),
                    {ok, Valid};
                _ -> {error, <<"unexpected Zed /models response">>}
            catch _:_ -> {error, <<"invalid Zed /models JSON">>} end;
        {ok, {Status, _, _}} -> {error, iolist_to_binary(io_lib:format("Zed /models returned HTTP ~B", [Status]))};
        {error, _} -> {error, <<"could not reach Zed /models">>}
    end.

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
        _ -> {error, <<"unrecognized Zed stream envelope">>}
    catch _:_ -> {error, <<"invalid Zed stream JSON">>} end.

route(Home, Endpoint, Token, Id) ->
    case catalog_token(Home, Endpoint, Token, false) of
        {ok, Models} ->
            case [P || #{<<"id">> := I, <<"provider">> := P} <- Models, I =:= Id,
                lists:member(P, [<<"anthropic">>, <<"open_ai">>, <<"google">>, <<"x_ai">>])] of
                [P | _] -> {ok, P};
                _ -> {error, <<"model is not available in the Zed catalog or uses an unsupported provider">>}
            end;
        Error -> Error
    end.
