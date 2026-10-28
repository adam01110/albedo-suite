-module(albedo_opencode_go).
%% OpenCode Go provider: OpenCode Console RFC 8628 device OAuth, live /models
%% discovery with disk cache, non-chat entitlement filtering, and key/account
%% pool resolution.

-include_lib("kernel/include/file.hrl").
-export([models/2, cached_models/1, cached_models/2, reload/1, fetch_models/2,
         device_start/0, device_start/1, account/1, accounts/1, expire/2,
         access/3, limited/4, metadata_route/2, owns_endpoint/2]).

-define(DEFAULT_BASE_URL, <<"https://opencode.ai/inference/go/v1">>).
-define(DEFAULT_CONSOLE_URL, <<"https://opencode.ai/console">>).
-define(CLIENT_ID, <<"opencode-cli">>).
-define(STORE, <<"opencode-go">>).
-define(CACHE_MAX_AGE_MS, 3600000). %% 1 hour
-define(FETCH_TIMEOUT_MS, 10000).
-define(REFRESH_SKEW_MS, 60000).
-define(EXPIRY_MARGIN_MS, 60000).
-define(SCOPE, <<"opencode-go">>).
%% Used when a spent quota names no reset time.
-define(DEFAULT_LIMIT_MS, 900000).
%% Tokens- and requests-per-minute limits clear within a minute.
-define(RATE_LIMIT_MS, 30000).

%% ---- OAuth device authorization (RFC 8628) ------------------------------

device_start() ->
    device_start(console_server()).

device_start(Server0) ->
    Server = string:trim(binary(Server0), trailing, "/"),
    Body = json:encode(#{<<"client_id">> => ?CLIENT_ID, <<"supports_org_scope">> => true}),
    case post_json(<<Server/binary, "/auth/device/code">>, Body) of
        {ok, 200, Response} ->
            try json:decode(Response) of
                #{<<"device_code">> := <<_, _/binary>> = DeviceCode,
                  <<"user_code">> := <<_, _/binary>> = UserCode,
                  <<"verification_uri_complete">> := <<_, _/binary>> = Verification} = Data ->
                    ExpiresIn = positive_int(maps:get(<<"expires_in">>, Data, 600), 600),
                    Interval = positive_int(maps:get(<<"interval">>, Data, 5), 5),
                    case verification_url(Server, Verification) of
                        {ok, Url} ->
                            Deadline = erlang:system_time(millisecond) + ExpiresIn * 1000,
                            Instructions = <<"Confirm code ", UserCode/binary,
                                             " in your browser and select Authorize.">>,
                            Complete = fun(Progress) ->
                                poll_device(Server, DeviceCode, Interval * 1000, Deadline, Progress)
                            end,
                            {ok, {Url, Instructions, Complete}};
                        Error -> Error
                    end;
                _ -> {error, <<"OpenCode Console returned an incomplete device-code response.">>}
            catch _:_ -> {error, <<"OpenCode Console returned an invalid device-code response.">>}
            end;
        {ok, Status, Response} ->
            {error, albedo_http:failure(<<"OpenCode Console device authorization">>, Status, Response)};
        {error, Reason} ->
            {error, Reason}
    end.

console_server() ->
    case os:getenv("OPENCODE_CONSOLE_SERVER") of
        Url when is_list(Url), Url =/= "" ->
            unicode:characters_to_binary(string:trim(Url, trailing, "/"));
        _ -> ?DEFAULT_CONSOLE_URL
    end.

verification_url(Server, Verification) ->
    case uri_string:parse(Verification) of
        #{scheme := Scheme, host := Host} when (Scheme =:= <<"http">> orelse Scheme =:= <<"https">>),
                                               Host =/= <<>> ->
            {ok, Verification};
        #{path := Path} = Rel when is_binary(Path), byte_size(Path) > 0 ->
            case uri_string:parse(Server) of
                #{scheme := Scheme, host := Host} = Base
                  when (Scheme =:= <<"http">> orelse Scheme =:= <<"https">>), Host =/= <<>> ->
                    PortPart = case maps:find(port, Base) of
                        {ok, Port} when is_integer(Port) -> [":", integer_to_binary(Port)];
                        _ -> []
                    end,
                    QueryPart = case maps:find(query, Rel) of
                        {ok, Q} when is_binary(Q), Q =/= <<>> -> ["?", Q];
                        _ -> []
                    end,
                    JoinedPath = case binary:at(Path, 0) of
                        $/ -> Path;
                        _ -> <<(maps:get(path, Base, <<>>))/binary, "/", Path/binary>>
                    end,
                    {ok, iolist_to_binary([Scheme, "://", Host, PortPart, JoinedPath, QueryPart])};
                _ -> {error, <<"Invalid OpenCode Console server URL.">>}
            end;
        _ -> {error, <<"Invalid OpenCode Console verification URL.">>}
    end.

poll_device(Server, DeviceCode, IntervalMs, Deadline, Progress) ->
    case erlang:system_time(millisecond) >= Deadline of
        true -> {error, <<"OpenCode Console device code expired.">>};
        false ->
            Progress(<<"Waiting for authorization in your browser…"/utf8>>),
            receive
                {input, _} -> ok
            after IntervalMs -> ok
            end,
            Body = json:encode(#{
                <<"grant_type">> => <<"urn:ietf:params:oauth:grant-type:device_code">>,
                <<"device_code">> => DeviceCode,
                <<"client_id">> => ?CLIENT_ID
            }),
            case post_json(<<Server/binary, "/auth/device/token">>, Body) of
                {ok, 200, Response} ->
                    try json:decode(Response) of
                        #{<<"access_token">> := <<_, _/binary>> = Access,
                          <<"refresh_token">> := <<_, _/binary>> = Refresh} = Token ->
                            ExpiresIn = positive_int(maps:get(<<"expires_in">>, Token, 3600), 3600),
                            GrantedOrg = optional_binary(maps:get(<<"org_id">>, Token, undefined)),
                            build_credential(Server, Access, Refresh, ExpiresIn, GrantedOrg);
                        #{<<"error">> := Error} ->
                            handle_poll_error(Server, DeviceCode, IntervalMs, Deadline, Progress, Error);
                        _ -> {error, <<"OpenCode Console token response is incomplete.">>}
                    catch _:_ -> {error, <<"OpenCode Console token response is invalid.">>}
                    end;
                {ok, Status, Response} when Status =:= 400; Status =:= 428 ->
                    case decode_error(Response) of
                        {ok, Error} ->
                            handle_poll_error(Server, DeviceCode, IntervalMs, Deadline, Progress, Error);
                        error ->
                            {error, albedo_http:failure(<<"OpenCode Console token exchange">>, Status, Response)}
                    end;
                {ok, Status, Response} ->
                    {error, albedo_http:failure(<<"OpenCode Console token exchange">>, Status, Response)};
                {error, Reason} ->
                    {error, Reason}
            end
    end.

handle_poll_error(Server, DeviceCode, IntervalMs, Deadline, Progress, <<"authorization_pending">>) ->
    poll_device(Server, DeviceCode, IntervalMs, Deadline, Progress);
handle_poll_error(Server, DeviceCode, IntervalMs, Deadline, Progress, <<"slow_down">>) ->
    poll_device(Server, DeviceCode, IntervalMs + 5000, Deadline, Progress);
handle_poll_error(_, _, _, _, _, <<"expired_token">>) ->
    {error, <<"OpenCode Console device code expired.">>};
handle_poll_error(_, _, _, _, _, <<"access_denied">>) ->
    {error, <<"OpenCode Console authorization was denied.">>};
handle_poll_error(_, _, _, _, _, Error) when is_binary(Error) ->
    {error, <<"OpenCode Console authorization failed: ", Error/binary>>}.

decode_error(Response) ->
    try json:decode(Response) of
        #{<<"error">> := Error} when is_binary(Error) -> {ok, Error};
        _ -> error
    catch _:_ -> error
    end.

build_credential(Server, Access, Refresh, ExpiresIn, GrantedOrg) ->
    User = fetch_user(Server, Access),
    Orgs = fetch_orgs(Server, Access),
    {OrgId, OrgName} = select_org(GrantedOrg, Orgs),
    Email = maps:get(<<"email">>, User, <<>>),
    AccountId = case maps:get(<<"id">>, User, <<>>) of
        <<>> -> case OrgId of <<>> -> token_id(Refresh); _ -> OrgId end;
        Uid -> Uid
    end,
    Base = #{
        <<"type">> => <<"oauth">>,
        <<"access">> => Access,
        <<"refresh">> => Refresh,
        <<"expires">> => erlang:system_time(millisecond) + ExpiresIn * 1000 - ?EXPIRY_MARGIN_MS,
        <<"accountId">> => AccountId,
        <<"server">> => Server
    },
    WithEmail = case Email of <<>> -> Base; _ -> Base#{<<"email">> => Email} end,
    WithOrg = case OrgId of <<>> -> WithEmail; _ -> WithEmail#{<<"orgId">> => OrgId} end,
    WithOrgName = case OrgName of <<>> -> WithOrg; _ -> WithOrg#{<<"orgName">> => OrgName} end,
    {ok, WithOrgName}.

fetch_user(Server, Access) ->
    case get_json(<<Server/binary, "/api/user">>, Access) of
        {ok, Map} when is_map(Map) ->
            maps:filter(fun(_, V) -> is_binary(V) andalso V =/= <<>> end,
                        maps:with([<<"id">>, <<"email">>], Map));
        _ -> #{}
    end.

fetch_orgs(Server, Access) ->
    case get_json(<<Server/binary, "/api/orgs">>, Access) of
        {ok, List} when is_list(List) ->
            Orgs = [{Id, Name} || #{<<"id">> := Id, <<"name">> := Name} <- List,
                                  is_binary(Id), Id =/= <<>>, is_binary(Name), Name =/= <<>>],
            lists:sort(fun({IdA, NameA}, {IdB, NameB}) ->
                {string:lowercase(NameA), IdA} =< {string:lowercase(NameB), IdB}
            end, Orgs);
        _ -> []
    end.

select_org(GrantedOrg, Orgs) when is_binary(GrantedOrg), GrantedOrg =/= <<>> ->
    case lists:keyfind(GrantedOrg, 1, Orgs) of
        {Id, Name} -> {Id, Name};
        false -> {GrantedOrg, <<>>}
    end;
select_org(_, [{Id, Name} | _]) ->
    {Id, Name};
select_org(_, []) ->
    {<<>>, <<>>}.

post_json(Url, Body) ->
    Headers = [{"accept", "application/json"}, {"user-agent", "albedo/1.0"}],
    albedo_http:fetch(post, Url, Headers, {"application/json", Body}).

get_json(Url, Access) ->
    Headers = [{"authorization", "Bearer " ++ text(Access)},
               {"accept", "application/json"},
               {"user-agent", "albedo/1.0"}],
    case albedo_http:fetch(get, Url, Headers, none) of
        {ok, 200, Body} ->
            try {ok, json:decode(Body)} catch _:_ -> error end;
        _ -> error
    end.

positive_int(Value, _) when is_integer(Value), Value > 0 -> Value;
positive_int(Value, _) when is_float(Value), Value > 0 -> round(Value);
positive_int(_, Default) -> Default.

optional_binary(Value) when is_binary(Value), Value =/= <<>> -> Value;
optional_binary(_) -> <<>>.

%% ---- /login & quota account representation ------------------------------

account(Credential) when is_map(Credential) ->
    Selected = maps:get(<<"selected">>, Credential, false) =:= true,
    Email = optional_binary(maps:get(<<"email">>, Credential, <<>>)),
    OrgName = optional_binary(maps:get(<<"orgName">>, Credential, <<>>)),
    AccountId = optional_binary(maps:get(<<"accountId">>, Credential, <<>>)),
    BaseLabel = first_nonempty([Email, OrgName, AccountId, <<"OpenCode Go">>]),
    Label = case Email =/= <<>> andalso OrgName =/= <<>> of
        true -> <<Email/binary, " · "/utf8, OrgName/binary>>;
        false -> BaseLabel
    end,
    Now = erlang:system_time(millisecond),
    Detail = iolist_to_binary([
        <<"opencode go account">>,
        case Selected of true -> <<" · selected"/utf8>>; false -> <<>> end,
        case albedo_accounts:limited(Credential, Now) of
            true -> [<<" · limited until "/utf8>>, albedo_accounts:local_time(maps:get(<<"limitedUntil">>, Credential))];
            false -> <<>>
        end
    ]),
    {account, credential_identity(Credential), Label, Detail, Selected};
account(_) ->
    {account, <<>>, <<"invalid OpenCode Go account">>, <<>>, false}.

credential_identity(Credential) when is_map(Credential) ->
    AccountId = optional_binary(maps:get(<<"accountId">>, Credential, <<>>)),
    OrgId = optional_binary(maps:get(<<"orgId">>, Credential, <<>>)),
    Email = optional_binary(maps:get(<<"email">>, Credential, <<>>)),
    case AccountId =/= <<>> andalso OrgId =/= <<>> andalso AccountId =/= OrgId of
        true -> <<AccountId/binary, ":", OrgId/binary>>;
        false ->
            first_nonempty([
                AccountId,
                OrgId,
                Email,
                token_id(optional_binary(maps:get(<<"refresh">>, Credential,
                    maps:get(<<"access">>, Credential,
                        maps:get(<<"apiKey">>, Credential,
                            maps:get(<<"key">>, Credential, <<>>))))))
            ])
    end.

first_nonempty([]) -> <<>>;
first_nonempty([<<_, _/binary>> = V | _]) -> V;
first_nonempty([_ | Rest]) -> first_nonempty(Rest).

token_id(<<>>) -> <<>>;
token_id(Token) ->
    binary:encode_hex(binary:part(crypto:hash(sha256, Token), 0, 8), lowercase).

%% Every OpenCode Go OAuth account for the quota poller, refreshed the way
%% requests refresh it.
accounts(Home0) ->
    Path = albedo_credentials:creds_path(text(Home0)),
    case albedo_credentials:accounts(Path) of
        {ok, Data} ->
            [quota_entry(refreshed_oauth(Path, V))
             || V <- albedo_credentials:oauth(Data, ?STORE),
                credential_identity(V) =/= <<>>];
        _ -> []
    end.

quota_entry(Value) ->
    {account, Id, Label, _, _} = account(Value),
    #{
        <<"label">> => first_nonempty([Label, Id]),
        <<"access">> => optional_binary(maps:get(<<"access">>, Value, <<>>)),
        <<"accountId">> => Id,
        <<"email">> => optional_binary(maps:get(<<"email">>, Value, <<>>))
    }.

expire(Home0, Access0) ->
    albedo_credentials:expire_access(albedo_credentials:creds_path(text(Home0)), ?STORE, binary(Access0)).

%% Per-model SDK metadata takes precedence over the provider's default SDK.
metadata_route(Home, Model) ->
    Path = filename:join(unicode:characters_to_list(Home), "models.json"),
    Npm = try
        {ok, Body} = file:read_file(Path),
        Catalog = json:decode(Body),
        Provider = maps:get(<<"opencode-go">>, Catalog),
        Entry = maps:get(Model, maps:get(<<"models">>, Provider, #{}), #{}),
        maps:get(<<"npm">>, maps:get(<<"provider">>, Entry, #{}),
                 maps:get(<<"npm">>, Provider, <<>>))
    catch _:_ -> <<>> end,
    case Npm of
        <<"@ai-sdk/anthropic">> -> <<"messages">>;
        <<"@ai-sdk/openai">> -> <<"responses">>;
        <<"@ai-sdk/openai-compatible">> -> <<"chat_completions">>;
        <<"@ai-sdk/google">> -> <<"gemini">>;
        _ -> <<>>
    end.

%% ---- models catalog -----------------------------------------------------

%% Only the selected endpoint's cache participates in discovery or lookup.
cached_models(Home0) ->
    Home = text(Home0),
    cached_models(Home, <<>>).

cached_models(Home0, Endpoint0) ->
    Home = text(Home0),
    read_cache(cache_path(Home, catalog_endpoint(Home, binary(Endpoint0)))).

models(Home0, Endpoint0) ->
    Home = text(Home0),
    Endpoint = catalog_endpoint(Home, binary(Endpoint0)),
    CachePath = cache_path(Home, Endpoint),
    case is_cache_fresh(CachePath) andalso read_cache(CachePath) of
        {ok, Ids} when Ids =/= [] -> {ok, Ids};
        _ -> refresh_or_default(Home, Endpoint, CachePath)
    end.

reload(Home0) ->
    Home = text(Home0),
    Keys = catalog_keys(Home),
    Endpoints = lists:usort([catalog_endpoint(Home, <<>>) |
        [resolve_base_url(Url) || #{<<"baseUrl">> := Url} <- Keys]]),
    reload_endpoints(Home, Endpoints).

reload_endpoints(_, []) -> {ok, nil};
reload_endpoints(Home, [Endpoint | Rest]) ->
    case fetch_live(Home, Endpoint, cache_path(Home, Endpoint)) of
        {ok, _} -> reload_endpoints(Home, Rest);
        Error -> Error
    end.

%% Resolve each profile before the rotation pool's key-only deduplication.
catalog_keys(Home) ->
    discovery_keys(Home) ++ pool(Home, <<>>).

catalog_profiles(Home) ->
    case albedo_credentials:config(Home) of
        {ok, #{<<"providers">> := Providers}} when is_map(Providers) ->
            [{Name, P} || {Name, #{<<"extension">> := <<"opencode-go">>} = P}
                <- lists:sort(maps:to_list(Providers))];
        _ -> []
    end.

owns_endpoint(Home0, Endpoint0) ->
    Endpoint = resolve_base_url(binary(Endpoint0)),
    Endpoint =:= ?DEFAULT_BASE_URL orelse
    Endpoint =:= <<"https://opencode.ai/zen/go/v1">> orelse
    lists:any(fun({_, P}) ->
        resolve_base_url(maps:get(<<"baseUrl">>, P, <<>>)) =:= Endpoint
    end, catalog_profiles(text(Home0))).

catalog_endpoint(Home, <<>>) ->
    case pool(Home, <<>>) of
        [#{<<"baseUrl">> := Url} | _] -> resolve_base_url(Url);
        [] -> ?DEFAULT_BASE_URL
    end;
catalog_endpoint(_, Endpoint) -> resolve_base_url(Endpoint).

cache_path(Home, Endpoint) ->
    Hash = binary:encode_hex(crypto:hash(sha256, Endpoint)),
    filename:join(Home, "opencode-go-models-" ++ binary_to_list(Hash) ++ ".json").

refresh_or_default(Home, Endpoint, CachePath) ->
    case fetch_live(Home, Endpoint, CachePath) of
        {ok, Ids} -> {ok, Ids};
        {error, _} -> fallback_cache_or_default(CachePath)
    end.

%% Never send a credential from another endpoint to an explicitly requested URL.
fetch_live(Home, Endpoint, CachePath) ->
    Keys = [Key || #{<<"baseUrl">> := Url} = Key <- catalog_keys(Home),
                   resolve_base_url(Url) =:= Endpoint],
    ApiKey = case Keys of
        [#{<<"apiKey">> := Key} | _] -> Key;
        [] -> <<>>
    end,
    case fetch_models(Endpoint, ApiKey) of
        {ok, Ids} ->
            _ = write_cache(CachePath, Ids),
            {ok, Ids};
        Error -> Error
    end.

fallback_cache_or_default(CachePath) ->
    case read_cache(CachePath) of
        {ok, Ids} when Ids =/= [] -> {ok, Ids};
        _ -> {ok, []}
    end.

%% Live GET to ${BaseUrl}/models with optional Bearer auth.
fetch_models(BaseUrl0, ApiKey0) ->
    BaseUrl = text(BaseUrl0),
    ApiKey = text(ApiKey0),
    Url = string:trim(BaseUrl, trailing, "/") ++ "/models",
    Auth = case ApiKey of
        "" -> [];
        _ -> [{"authorization", "Bearer " ++ ApiKey}]
    end,
    Headers = Auth ++ [
        {"accept", "application/json"},
        {"user-agent", "albedo/1.0"}
    ],
    case albedo_http:get(Url, Headers, ?FETCH_TIMEOUT_MS, 5000) of
        {ok, {200, _, Body}} ->
            try json:decode(Body) of
                #{<<"data">> := List} when is_list(List) ->
                    Ids = [Id || #{<<"id">> := Id} <- List, is_binary(Id), is_chat_model(Id)],
                    {ok, lists:usort(Ids)};
                _ -> {error, <<"unexpected /models response shape">>}
            catch _:_ -> {error, <<"invalid JSON from /models">>}
            end;
        {ok, {Status, _, _}} ->
            {error, iolist_to_binary(io_lib:format("endpoint returned HTTP ~B", [Status]))};
        {error, Reason} ->
            {error, iolist_to_binary(io_lib:format("could not reach endpoint: ~p", [Reason]))}
    end.

%% Non-chat entitlement filter: skips image generation, TTS, audio, and realtime routes.
is_chat_model(<<"auto">>) -> false;
is_chat_model(Id) when is_binary(Id) ->
    case binary:match(Id, [
        <<"audio">>,
        <<"tts">>,
        <<"realtime">>,
        <<"image">>,
        <<"asr">>
    ]) of
        nomatch -> true;
        _ -> false
    end;
is_chat_model(_) -> false.

is_cache_fresh(Path) ->
    case albedo_credentials:read_json(Path) of
        {ok, #{<<"time">> := Time}} when is_integer(Time) ->
            Age = erlang:system_time(millisecond) - Time,
            Age >= 0 andalso Age < ?CACHE_MAX_AGE_MS;
        _ -> false
    end.

read_cache(Path) ->
    case albedo_credentials:read_json(Path) of
        {ok, #{<<"ids">> := List}} when is_list(List) ->
            {ok, [Id || Id <- List, is_binary(Id)]};
        {ok, _} -> {error, invalid};
        Error -> Error
    end.

write_cache(Path, Ids) ->
    albedo_credentials:write(Path, json:encode(#{
        <<"time">> => erlang:system_time(millisecond), <<"ids">> => Ids})).

%% ---- key & OAuth account pool -------------------------------------------

%% The session's credential as {BaseUrl, ApiKey, OrgId}. Only an explicit
%% accountIds list can hand a request to another account.
access(Home0, Profile0, Session0) ->
    Home = text(Home0),
    Profile = binary(Profile0),
    Session = binary(Session0),
    case pool_for_profile(Home, Profile) of
        {error, Reason} -> {error, Reason};
        {ok, []} ->
            {error, <<"OpenCode Go is not authenticated; add an account or key in /login">>};
        {ok, Keys} ->
            [First | _] = albedo_accounts:order(?SCOPE, Keys, Session, fun id/1),
            albedo_accounts:remember(?SCOPE, Session, id(First)),
            {ok, {maps:get(<<"baseUrl">>, First),
                  maps:get(<<"apiKey">>, First),
                  maps:get(<<"orgId">>, First, <<>>)}}
    end.

%% Every OpenCode Go 429 is a limit. Spent subscription quotas last longer
%% than per-minute request limits.
limited(Home0, Profile0, Key0, Body0) ->
    Home = text(Home0),
    Profile = binary(Profile0),
    Key = binary(Key0),
    Body = binary(Body0),
    Lasting = 'albedo@harness@rotation':key_lasting(Body) orelse
        lists:any(fun(Mark) -> binary:match(Body, Mark) =/= nomatch end,
                  [<<"usage_limit">>, <<"UsageLimit">>, <<"RateLimit">>,
                   <<"monthly">>, <<"weekly">>, <<"rolling">>]),
    Until = erlang:system_time(millisecond) + case Lasting of
        true -> ?DEFAULT_LIMIT_MS;
        false -> ?RATE_LIMIT_MS
    end,
    Path = albedo_credentials:creds_path(Home),
    Entries = pool(Home, Profile),
    Hit = [E || E <- Entries, maps:get(<<"apiKey">>, E) =:= Key],
    SavedIds = [Id || #{<<"_albedo_account_id">> := Id, <<"source">> := <<"saved">>} <- Hit],
    Marked = case SavedIds of
        [] ->
            Ids = case Hit of [] -> [token_id(Key)]; _ -> [id(E) || E <- Hit] end,
            lists:foreach(fun(Id) -> albedo_accounts:note(?SCOPE, Id, Until) end, Ids);
        _ -> albedo_accounts:mark(Path, ?STORE,
            fun(V) -> lists:member(maps:get(<<"_albedo_account_id">>, V, null), SavedIds) end, Until)
    end,
    case Marked of
        {error, _} = Error -> Error;
        _ ->
            Now = erlang:system_time(millisecond),
            Next = [K || K <- pool(Home, Profile), maps:get(<<"apiKey">>, K) =/= Key,
                         not albedo_accounts:limited(K, Now)],
            NextName = case Next of [#{<<"name">> := Name} | _] -> Name; [] -> <<>> end,
            {ok, {limited, <<>>, albedo_accounts:local_time(Until), NextName, Lasting}}
    end.

pool(Home, Profile) ->
    case pool_for_profile(Home, Profile) of
        {ok, Keys} -> Keys;
        {error, _} -> []
    end.

pool_for_profile(Home, Profile) ->
    Settings = profile_settings(Home, Profile),
    BaseUrl = resolve_base_url(maps:get(<<"baseUrl">>, Settings, <<>>)),
    Path = albedo_credentials:creds_path(Home),
    Stored = case albedo_credentials:accounts(Path) of
        {ok, Data} -> albedo_credentials:values(Data, ?STORE);
        _ -> []
    end,
    Env = albedo_key_accounts:env(Home, ?STORE, BaseUrl),
    Bound = case {maps:get(<<"apiKey">>, Settings, <<>>),
                  maps:get(<<"accountId">>, Settings, null),
                  maps:get(<<"accountIds">>, Settings, null)} of
        {<<_, _/binary>> = Key, _, _} ->
            {ok, [#{<<"apiKey">> => Key, <<"label">> => Profile}]};
        {_, null, null} ->
            OAuth = [V || #{<<"type">> := <<"oauth">>} = V <- Stored],
            case selected_account(OAuth) of
                [] -> {ok, lists:sublist(Env, 1)};
                One -> {ok, One}
            end;
        _ -> albedo_credentials:bound_values(Home, Profile, Stored ++ Env)
    end,
    case Bound of
        {ok, Values} ->
            Entries = lists:filtermap(fun(V) -> resolve_account_entry(Path, BaseUrl, V) end, Values),
            case length(Entries) =:= length(Values) of
                true -> {ok, Entries};
                false -> {error, <<"Profile's selected OpenCode Go account could not be refreshed; run /login">>}
            end;
        Error -> Error
    end.

selected_account(Values) ->
    case [V || V <- Values, maps:get(<<"selected">>, V, false) =:= true] of
        [Chosen | _] -> [Chosen];
        [] -> lists:sublist(Values, 1)
    end.

%% Catalog discovery can inspect credentials from every configured profile;
%% request selection above never adds those profiles to a rotation.
discovery_keys(Home) ->
    Profiles = case albedo_credentials:config(Home) of
        {ok, #{<<"providers">> := Providers}} ->
            [Name || {Name, #{<<"extension">> := ?STORE}} <- lists:sort(maps:to_list(Providers))];
        _ -> []
    end,
    case Profiles of
        [] -> pool(Home, <<>>);
        _ -> lists:flatmap(fun(Profile) -> pool(Home, Profile) end, Profiles)
    end.

%% Stable account ids survive OAuth token refreshes; legacy keys use a hash.
id(#{<<"_albedo_account_id">> := Id}) -> Id;
id(#{<<"apiKey">> := Key}) -> token_id(Key).

resolve_account_entry(Path, BaseUrl, #{<<"type">> := <<"oauth">>} = Value) ->
    Current = refreshed_oauth(Path, Value),
    {account, _, Label, _, _} = account(Current),
    account_entry(Current, BaseUrl, optional_binary(maps:get(<<"access">>, Current, <<>>)), Label);
resolve_account_entry(_, BaseUrl, #{<<"apiKey">> := Key} = Value) ->
    account_entry(Value, BaseUrl, Key, <<"OpenCode Go key">>);
resolve_account_entry(_, _, _) -> false.

account_entry(_, _, <<>>, _) -> false;
account_entry(Value, BaseUrl, Key, DefaultLabel) ->
    Endpoint = first_nonempty([maps:get(<<"endpoint">>, Value, <<>>), BaseUrl]),
    Source = maps:get(<<"source">>, Value, <<"saved">>),
    Until = max(albedo_accounts:until_of(Value, undefined),
                albedo_accounts:noted(?SCOPE, id(Value#{<<"apiKey">> => Key}))),
    Entry = Value#{<<"name">> => first_nonempty([maps:get(<<"label">>, Value, <<>>), DefaultLabel]),
                   <<"baseUrl">> => Endpoint, <<"apiKey">> => Key, <<"source">> => Source,
                   <<"orgId">> => maps:get(<<"orgId">>, Value, <<>>), <<"limitedUntil">> => Until},
    {true, Entry}.

refreshed_oauth(Path, Value) ->
    Expires = maps:get(<<"expires">>, Value, 0),
    Refresh = optional_binary(maps:get(<<"refresh">>, Value, <<>>)),
    case is_integer(Expires) andalso Expires > erlang:system_time(millisecond) + ?REFRESH_SKEW_MS of
        true -> Value;
        false when Refresh =:= <<>> -> Value;
        false ->
            Id = credential_identity(Value),
            case albedo_settings_lock:with_lock(filename:dirname(Path),
                    fun() -> refresh_locked(Path, Id) end,
                    fun() -> {error, busy} end) of
                {ok, Updated} -> Updated;
                _ -> Value
            end
    end.

refresh_locked(Path, Id) ->
    case albedo_credentials:accounts(Path) of
        {ok, Data} ->
            Values = albedo_credentials:values(Data, ?STORE),
            case [V || V <- Values, is_map(V), credential_identity(V) =:= Id] of
                [Current | _] ->
                    case maps:get(<<"expires">>, Current, 0) > erlang:system_time(millisecond) + ?REFRESH_SKEW_MS of
                        true -> {ok, Current};
                        false -> refresh_current(Path, Data, Values, Current, Id)
                    end;
                [] -> {error, not_found}
            end;
        Error -> Error
    end.

refresh_current(Path, Data, Values, Current, Id) ->
    Server = case optional_binary(maps:get(<<"server">>, Current, <<>>)) of
        <<>> -> console_server();
        S -> string:trim(S, trailing, "/")
    end,
    Refresh = optional_binary(maps:get(<<"refresh">>, Current, <<>>)),
    Body = json:encode(#{
        <<"grant_type">> => <<"refresh_token">>,
        <<"refresh_token">> => Refresh,
        <<"client_id">> => ?CLIENT_ID
    }),
    case post_json(<<Server/binary, "/auth/device/token">>, Body) of
        {ok, 200, Response} ->
            try json:decode(Response) of
                #{<<"access_token">> := <<_, _/binary>> = Access,
                  <<"refresh_token">> := <<_, _/binary>> = NewRefresh} = Token ->
                    ExpiresIn = positive_int(maps:get(<<"expires_in">>, Token, 3600), 3600),
                    Updated0 = Current#{
                        <<"type">> => <<"oauth">>,
                        <<"access">> => Access,
                        <<"refresh">> => NewRefresh,
                        <<"expires">> => erlang:system_time(millisecond) + ExpiresIn * 1000 - ?EXPIRY_MARGIN_MS
                    },
                    Updated = case optional_binary(maps:get(<<"org_id">>, Token, undefined)) of
                        <<>> -> Updated0;
                        OrgId -> Updated0#{<<"orgId">> => OrgId}
                    end,
                    Replaced = [case is_map(V) andalso credential_identity(V) =:= Id of
                        true -> Updated;
                        false -> V
                    end || V <- Values],
                    case albedo_credentials:put_accounts(Path, albedo_credentials:put_values(Data, ?STORE, Replaced)) of
                        ok -> {ok, Updated};
                        Error -> Error
                    end;
                _ -> {error, invalid_refresh_response}
            catch _:_ -> {error, invalid_refresh_response}
            end;
        _ -> {error, refresh_failed}
    end.

resolve_base_url(<<>>) ->
    case os:getenv("OPENCODE_GO_BASE_URL") of
        Url when is_list(Url), Url =/= "" -> unicode:characters_to_binary(string:trim(Url, trailing, "/"));
        _ -> ?DEFAULT_BASE_URL
    end;
resolve_base_url(Url) when is_binary(Url) ->
    string:trim(Url, trailing, "/").

profile_settings(Home, Profile) ->
    case albedo_credentials:config(Home) of
        {ok, #{<<"providers">> := #{Profile := P}}} when is_map(P) -> P;
        _ -> #{}
    end.

text(Val) when is_binary(Val) -> unicode:characters_to_list(Val);
text(Val) when is_list(Val) -> Val.

binary(Val) when is_list(Val) -> unicode:characters_to_binary(Val);
binary(Val) when is_binary(Val) -> Val.
