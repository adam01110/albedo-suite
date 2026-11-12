-module(albedo_opencode_go).
%% OpenCode Go provider: OpenCode Console RFC 8628 device OAuth, live /models
%% discovery, non-chat entitlement filtering, and key/account
%% pool resolution.

-include_lib("kernel/include/file.hrl").
-export([
    device_start/0,
    credential_identity/1,
    account_label/1,
    metadata_route/2,
    owns_endpoint/2
]).

-define(DEFAULT_BASE_URL, <<"https://opencode.ai/inference/go/v1">>).
-define(DEFAULT_CONSOLE_URL, <<"https://opencode.ai/console">>).
-define(CLIENT_ID, <<"opencode-cli">>).
-define(STORE, <<"opencode-go">>).
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
    albedo_device_flow:start(#{
        server => console_server(),
        code_path => <<"/auth/device/code">>,
        token_path => <<"/auth/device/token">>,
        encoding => json,
        code_form => [{<<"client_id">>, ?CLIENT_ID}, {<<"supports_org_scope">>, true}],
        token_form => [
            {<<"client_id">>, ?CLIENT_ID},
            {<<"grant_type">>, <<"urn:ietf:params:oauth:grant-type:device_code">>}
        ],
        headers => [{"accept", "application/json"}, {"user-agent", "albedo/1.0"}],
        progress => <<"Waiting for authorization in your browser\xe2\x80\xa6">>,
        instructions => fun(Code, _Url) ->
            <<"Confirm code ", Code/binary, " in your browser and select Authorize.">>
        end,
        credential => fun(Token) -> build_credential(console_server(), Token) end
    }).

console_server() ->
    case os:getenv("OPENCODE_CONSOLE_SERVER") of
        Url when is_list(Url), Url =/= "" ->
            unicode:characters_to_binary(string:trim(Url, trailing, "/"));
        _ ->
            ?DEFAULT_CONSOLE_URL
    end.

build_credential(
    Server,
    #{
        <<"access_token">> := Access,
        <<"refresh_token">> := <<_, _/binary>> = Refresh
    } = Token
) ->
    ExpiresIn = positive_int(maps:get(<<"expires_in">>, Token, 3600), 3600),
    GrantedOrg = optional_binary(maps:get(<<"org_id">>, Token, undefined)),
    User = fetch_user(Server, Access),
    Orgs = fetch_orgs(Server, Access),
    {OrgId, OrgName} = select_org(GrantedOrg, Orgs),
    Email = maps:get(<<"email">>, User, <<>>),
    AccountId =
        case maps:get(<<"id">>, User, <<>>) of
            <<>> ->
                case OrgId of
                    <<>> -> token_id(Refresh);
                    _ -> OrgId
                end;
            Uid ->
                Uid
        end,
    Base = #{
        <<"type">> => <<"oauth">>,
        <<"access">> => Access,
        <<"refresh">> => Refresh,
        <<"expires">> => erlang:system_time(millisecond) + ExpiresIn * 1000 - ?EXPIRY_MARGIN_MS,
        <<"accountId">> => AccountId,
        <<"server">> => Server
    },
    WithEmail =
        case Email of
            <<>> -> Base;
            _ -> Base#{<<"email">> => Email}
        end,
    WithOrg =
        case OrgId of
            <<>> -> WithEmail;
            _ -> WithEmail#{<<"orgId">> => OrgId}
        end,
    WithOrgName =
        case OrgName of
            <<>> -> WithOrg;
            _ -> WithOrg#{<<"orgName">> => OrgName}
        end,
    {ok, WithOrgName};
build_credential(_Server, _Incomplete) ->
    {error, <<"OpenCode Console token response is incomplete.">>}.

fetch_user(Server, Access) ->
    case get_json(<<Server/binary, "/api/user">>, Access) of
        {ok, Map} when is_map(Map) ->
            maps:filter(
                fun(_, V) -> is_binary(V) andalso V =/= <<>> end,
                maps:with([<<"id">>, <<"email">>], Map)
            );
        _ ->
            #{}
    end.

fetch_orgs(Server, Access) ->
    case get_json(<<Server/binary, "/api/orgs">>, Access) of
        {ok, List} when is_list(List) ->
            Orgs = [
                {Id, Name}
             || #{<<"id">> := Id, <<"name">> := Name} <- List,
                is_binary(Id),
                Id =/= <<>>,
                is_binary(Name),
                Name =/= <<>>
            ],
            lists:sort(
                fun({IdA, NameA}, {IdB, NameB}) ->
                    {string:lowercase(NameA), IdA} =< {string:lowercase(NameB), IdB}
                end,
                Orgs
            );
        _ ->
            []
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

get_json(Url, Access) ->
    Headers = [
        {"authorization", "Bearer " ++ text(Access)},
        {"accept", "application/json"},
        {"user-agent", "albedo/1.0"}
    ],
    case albedo_http:fetch(get, Url, Headers, none) of
        {ok, 200, Body} ->
            try
                {ok, json:decode(Body)}
            catch
                _:_ -> error
            end;
        _ ->
            error
    end.

positive_int(Value, _) when is_integer(Value), Value > 0 -> Value;
positive_int(Value, _) when is_float(Value), Value > 0 -> round(Value);
positive_int(_, Default) -> Default.

optional_binary(Value) when is_binary(Value), Value =/= <<>> -> Value;
optional_binary(_) -> <<>>.

%% ---- /login & quota account representation ------------------------------

%% How /login, quota and credential resolution name an account.
account_label(Credential) ->
    Email = optional_binary(maps:get(<<"email">>, Credential, <<>>)),
    OrgName = optional_binary(maps:get(<<"orgName">>, Credential, <<>>)),
    AccountId = optional_binary(maps:get(<<"accountId">>, Credential, <<>>)),
    case Email =/= <<>> andalso OrgName =/= <<>> of
        true -> <<Email/binary, " · "/utf8, OrgName/binary>>;
        false -> first_nonempty([Email, OrgName, AccountId, <<"OpenCode Go">>])
    end.

credential_identity(Credential) when is_map(Credential) ->
    AccountId = optional_binary(maps:get(<<"accountId">>, Credential, <<>>)),
    OrgId = optional_binary(maps:get(<<"orgId">>, Credential, <<>>)),
    Email = optional_binary(maps:get(<<"email">>, Credential, <<>>)),
    case AccountId =/= <<>> andalso OrgId =/= <<>> andalso AccountId =/= OrgId of
        true ->
            <<AccountId/binary, ":", OrgId/binary>>;
        false ->
            first_nonempty([
                AccountId,
                OrgId,
                Email,
                token_id(
                    optional_binary(
                        maps:get(
                            <<"refresh">>,
                            Credential,
                            maps:get(
                                <<"access">>,
                                Credential,
                                maps:get(
                                    <<"apiKey">>,
                                    Credential,
                                    maps:get(<<"key">>, Credential, <<>>)
                                )
                            )
                        )
                    )
                )
            ])
    end.

first_nonempty([]) -> <<>>;
first_nonempty([<<_, _/binary>> = V | _]) -> V;
first_nonempty([_ | Rest]) -> first_nonempty(Rest).

token_id(<<>>) -> <<>>;
token_id(Token) -> 'albedo@harness@credentials':fingerprint(Token).

text(Val) when is_binary(Val) -> unicode:characters_to_list(Val);
text(Val) when is_list(Val) -> Val.

%% ---- suite routing -------------------------------------------------------

%% Per-model SDK metadata takes precedence over the provider's default SDK.
%% Only a catalog entry for `Model` itself may inherit that default: an absent
%% entry keeps the documented family routing instead of a provider-wide SDK.
metadata_route(Home, Model) ->
    Path = filename:join(unicode:characters_to_list(Home), "models.json"),
    Npm =
        try
            {ok, Body} = file:read_file(Path),
            Catalog = json:decode(Body),
            Provider = maps:get(<<"opencode-go">>, Catalog),
            case maps:find(Model, maps:get(<<"models">>, Provider, #{})) of
                {ok, Entry} ->
                    maps:get(
                        <<"npm">>,
                        maps:get(<<"provider">>, Entry, #{}),
                        maps:get(<<"npm">>, Provider, <<>>)
                    );
                error ->
                    <<>>
            end
        catch
            _:_ -> <<>>
        end,
    case Npm of
        <<"@ai-sdk/anthropic">> -> <<"messages">>;
        <<"@ai-sdk/openai">> -> <<"responses">>;
        <<"@ai-sdk/openai-compatible">> -> <<"chat_completions">>;
        <<"@ai-sdk/google">> -> <<"gemini">>;
        _ -> <<>>
    end.

%% The documented OpenCode Go endpoints, or one an opencode-go profile names.
owns_endpoint(Home, Endpoint0) ->
    Endpoint = resolve_base_url(Endpoint0),
    Endpoint =:= ?DEFAULT_BASE_URL orelse
        Endpoint =:= <<"https://opencode.ai/zen/go/v1">> orelse
        lists:any(
            fun({_, P}) ->
                resolve_base_url(maps:get(<<"baseUrl">>, P, <<>>)) =:= Endpoint
            end,
            catalog_profiles(text(Home))
        ).

catalog_profiles(Home) ->
    case albedo_credentials:config(Home) of
        {ok, #{<<"providers">> := Providers}} when is_map(Providers) ->
            [
                {Name, P}
             || {Name, #{<<"extension">> := ?STORE} = P} <-
                    lists:sort(maps:to_list(Providers))
            ];
        _ ->
            []
    end.

resolve_base_url(<<>>) ->
    case os:getenv("OPENCODE_GO_BASE_URL") of
        Url when is_list(Url), Url =/= "" ->
            unicode:characters_to_binary(string:trim(Url, trailing, "/"));
        _ ->
            ?DEFAULT_BASE_URL
    end;
resolve_base_url(Url) when is_binary(Url) ->
    string:trim(Url, trailing, "/");
resolve_base_url(Url) when is_list(Url) ->
    resolve_base_url(unicode:characters_to_binary(Url)).
