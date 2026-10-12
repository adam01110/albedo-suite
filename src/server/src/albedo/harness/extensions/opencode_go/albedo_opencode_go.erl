-module(albedo_opencode_go).
-export([access/2, route/2, models/2, reload/1, compatible_body/1, owns_endpoint/2]).

-define(BASE, <<"https://opencode.ai/zen/go/v1">>).
-define(TTL, 3600000).

access(Home, Profile) ->
    case albedo_credentials:config(unicode:characters_to_list(Home)) of
        {ok, #{<<"providers">> := Providers}} ->
            config(maps:get(Profile, Providers, #{}));
        _ -> config(#{})
    end.

config(Profile) when is_map(Profile) ->
    Base0 = maps:get(<<"baseUrl">>, Profile, ?BASE),
    Base = case is_binary(Base0) of
        true -> string:trim(Base0, trailing, "/");
        false -> <<>>
    end,
    Key = case maps:get(<<"apiKey">>, Profile, <<>>) of
        <<>> -> case os:getenv("OPENCODE_API_KEY") of
            false -> <<>>;
            Value -> unicode:characters_to_binary(Value)
        end;
        Value -> Value
    end,
    case valid_url(Base) andalso valid_key(Key) of
        true -> {ok, {Base, Key}};
        false -> {error, <<"OpenCode Go needs a valid baseUrl and API key; run /login or set OPENCODE_API_KEY">>}
    end;
config(_) -> {error, <<"invalid OpenCode Go profile">>}.

valid_key(Key) when is_binary(Key) ->
    string:trim(Key) =/= <<>> andalso binary:match(Key, [<<"\r">>, <<"\n">>]) =:= nomatch;
valid_key(_) -> false.

valid_url(Base) when is_binary(Base) ->
    try uri_string:parse(Base) of
        #{scheme := Scheme, host := Host} = Url ->
            (Scheme =:= <<"https">> orelse Scheme =:= <<"http">>) andalso Host =/= <<>>
            andalso not maps:is_key(query, Url) andalso not maps:is_key(fragment, Url)
            andalso binary:match(Base, [<<"\r">>, <<"\n">>]) =:= nomatch;
        _ -> false
    catch _:_ -> false end;
valid_url(_) -> false.

%% Per-model SDK metadata takes precedence over the provider's default SDK.
route(Home, Model) ->
    Path = filename:join(unicode:characters_to_list(Home), "models.json"),
    Npm = try
        {ok, Body} = file:read_file(Path),
        Catalog = json:decode(Body),
        Provider = maps:get(<<"opencode-go">>, Catalog),
        Entry = maps:get(Model, maps:get(<<"models">>, Provider)),
        maps:get(<<"npm">>, maps:get(<<"provider">>, Entry, #{}),
                 maps:get(<<"npm">>, Provider, <<>>))
    catch _:_ -> <<>> end,
    case Npm of
        <<"@ai-sdk/anthropic">> -> <<"messages">>;
        <<"@ai-sdk/openai">> -> <<"responses">>;
        <<"@ai-sdk/openai-compatible">> -> <<"chat_completions">>;
        _ -> documented_route(Model)
    end.

documented_route(<<"minimax-", _/binary>>) -> <<"messages">>;
documented_route(<<"claude-", _/binary>>) -> <<"messages">>;
documented_route(<<"qwen3.7-", _/binary>>) -> <<"messages">>;
documented_route(<<"qwen3.8-", _/binary>>) -> <<"messages">>;
documented_route(<<"gpt-", _/binary>>) -> <<"responses">>;
documented_route(<<"grok-", _/binary>>) -> <<"responses">>;
documented_route(<<"muse-spark-", _/binary>>) -> <<"responses">>;
documented_route(_) -> <<"chat_completions">>.

models(Home, Endpoint0) ->
    Endpoint = endpoint(Endpoint0),
    Path = cache_path(Home, Endpoint),
    case read_cache(Path) of
        {ok, Time, Ids} ->
            case erlang:system_time(millisecond) - Time < ?TTL of
                true -> {ok, Ids};
                false -> case fetch(Home, Endpoint, Path) of
                    {ok, _} = Result -> Result;
                    _ -> {ok, Ids}
                end
            end;
        _ -> fetch(Home, Endpoint, Path)
    end.

reload(Home) ->
    Configured = [endpoint(maps:get(<<"baseUrl">>, P, ?BASE)) || P <- profiles(Home)],
    Endpoints = lists:usort(case Configured of [] -> [?BASE]; _ -> Configured end),
    reload_endpoints(Home, Endpoints).

reload_endpoints(_, []) -> {ok, nil};
reload_endpoints(Home, [Endpoint | Rest]) ->
    case fetch(Home, Endpoint, cache_path(Home, Endpoint)) of
        {ok, _} -> reload_endpoints(Home, Rest);
        Error -> Error
    end.

endpoint(<<>>) -> ?BASE;
endpoint(Value) when is_binary(Value) -> string:trim(Value, trailing, "/");
endpoint(_) -> <<>>.

profiles(Home) ->
    case albedo_credentials:config(unicode:characters_to_list(Home)) of
        {ok, #{<<"providers">> := Ps}} ->
            [P || {_, P} <- lists:sort(maps:to_list(Ps)),
                  maps:get(<<"extension">>, P, <<>>) =:= <<"opencode-go">>];
        _ -> []
    end.

owns_endpoint(Home, Endpoint0) ->
    Endpoint = endpoint(Endpoint0),
    Endpoint0 =/= <<>> andalso (Endpoint =:= ?BASE orelse lists:any(fun(P) ->
        endpoint(maps:get(<<"baseUrl">>, P, ?BASE)) =:= Endpoint
    end, profiles(Home))).

fetch(Home, Endpoint, Path) ->
    Profiles = [P || P <- profiles(Home),
                    endpoint(maps:get(<<"baseUrl">>, P, ?BASE)) =:= Endpoint],
    Keys = [Key || P <- Profiles,
                   {ok, {_, Key}} <- [config(P#{<<"baseUrl">> => Endpoint})]],
    Auth = case Keys of
        [Key | _] -> [{"authorization", "Bearer " ++ binary_to_list(Key)}];
        [] -> case config(#{<<"baseUrl">> => Endpoint}) of
            {ok, {_, Key}} -> [{"authorization", "Bearer " ++ binary_to_list(Key)}];
            _ -> []
        end
    end,
    case valid_url(Endpoint) of
        false -> {error, <<"invalid OpenCode Go endpoint">>};
        true -> case albedo_http:get(<<Endpoint/binary, "/models">>,
                    Auth ++ [{"accept", "application/json"}], 5000, 2000) of
            {ok, {200, _, Body}} ->
                try
                    #{<<"data">> := Entries} = json:decode(iolist_to_binary(Body)),
                    true = is_list(Entries),
                    Ids = lists:usort([Id || #{<<"id">> := Id} <- Entries,
                                            is_binary(Id), Id =/= <<>>]),
                    Cache = #{<<"time">> => erlang:system_time(millisecond), <<"ids">> => Ids},
                    _ = write_cache(Path, json:encode(Cache)),
                    {ok, Ids}
                catch _:_ -> {error, <<"invalid OpenCode Go /models response">>} end;
            {ok, {Status, _, _}} -> {error, iolist_to_binary(io_lib:format("OpenCode Go /models HTTP ~B", [Status]))};
            {error, _} -> {error, <<"could not reach OpenCode Go /models">>}
        end
    end.

cache_path(Home, Endpoint) ->
    Hash = binary:encode_hex(crypto:hash(sha256, Endpoint)),
    filename:join(unicode:characters_to_list(Home), "opencode-go-models-" ++ binary_to_list(Hash) ++ ".json").

write_cache(Path, Body) ->
    Temp = Path ++ "." ++ integer_to_list(erlang:unique_integer([positive])) ++ ".tmp",
    case file:write_file(Temp, Body) of
        ok ->
            Result = file:rename(Temp, Path),
            _ = file:delete(Temp),
            Result;
        Error -> Error
    end.

read_cache(Path) ->
    try
        {ok, Body} = file:read_file(Path),
        #{<<"time">> := Time, <<"ids">> := Ids} = json:decode(Body),
        true = is_integer(Time) andalso is_list(Ids),
        true = lists:all(fun is_binary/1, Ids),
        {ok, Time, Ids}
    catch _:_ -> {error, invalid_cache} end.

%% Keep portable Messages fields, not Claude-only context editing or effort.
compatible_body(Body) ->
    Fields = json:decode(Body),
    Drop = case maps:get(<<"model">>, Fields, <<>>) of
        <<"claude-", _/binary>> -> [<<"context_management">>];
        _ -> [<<"context_management">>, <<"thinking">>, <<"output_config">>]
    end,
    Portable = maps:without(Drop, Fields),
    Cached = maps:map(fun
        (Field, Value) when Field =:= <<"system">>; Field =:= <<"tools">>; Field =:= <<"messages">> -> portable_cache(Value);
        (_, Value) -> Value
    end, Portable),
    unicode:characters_to_binary(json:encode(Cached)).

%% Go's compatible routes do not need Anthropic's extended-cache beta.
portable_cache(Value) when is_map(Value) ->
    maps:map(fun
        (<<"cache_control">>, Cache) when is_map(Cache) -> maps:remove(<<"ttl">>, Cache);
        (<<"content">>, Blocks) when is_list(Blocks) -> portable_cache(Blocks);
        (_, Child) -> Child
    end, Value);
portable_cache(Value) when is_list(Value) -> [portable_cache(Child) || Child <- Value];
portable_cache(Value) -> Value.
