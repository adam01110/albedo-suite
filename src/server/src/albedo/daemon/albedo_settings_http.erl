-module(albedo_settings_http).
-export([observe/3, patch/9]).
-import(albedo_settings_store, [object/2, check/1, commit_group/2]).

%% These are HTTP boundary projections. Persisted names remain owned by the
%% harness, including callers from trusted model tools.
observe(Home, Group, Declared) -> locked(Home, fun() -> guarded(fun() ->
    Groups = case Group of
        <<"ui">> -> #{<<"ui">> => projection('albedo@harness@settings@projection':ui_group(albedo_settings_store:read(Home, <<"picker.json">>)))};
        _ -> projection('albedo@harness@settings@projection':groups(documents(Home), Declared))
    end,
    Revisions = albedo_settings_store:read(Home, <<"settings-revisions.json">>),
    Value = case Group of
        <<>> -> Groups#{<<"group_resources">> => maps:map(fun(Name, V) -> validator(Name, V, Revisions) end, Groups)};
        _ -> group(Group, Groups)
    end,
    Tag = case Group of <<>> -> none; _ -> {some, group_etag(Group, Value, Revisions)} end,
    {ok, {group_snapshot, encode(Value), Tag}}
end) end).

patch(Home, Group, Match, PatchJSON, Providers, Logins, Resolve, Defaults, Declared) ->
    Captured = locked(Home, fun() -> guarded(fun() ->
        Docs = documents(Home), Groups = projection('albedo@harness@settings@projection':groups(Docs, Declared)), Prior = group(Group, Groups),
        Revisions = albedo_settings_store:read(Home, <<"settings-revisions.json">>),
        match_group(Group, Match, Prior, Revisions),
        {ok, Patch} = albedo_http_api:parse(PatchJSON),
        {Next, Validation} = candidate(Home, Group, Patch, Docs, Resolve, Defaults, Declared),
        case Group of <<"providers">> -> validate_provider_accounts(Home, Next, Providers, Logins); _ -> ok end,
        case Group =:= <<"mcp">> andalso maps:get(<<"validate_connection">>, Patch, true) of
            true -> {ok, {probe, Patch, checked_candidates(Patch, Next)}};
            false -> {ok, {complete, publish(Home, Group, Docs, Next, Validation, Revisions, Declared)}}
        end
    end) end),
    case Captured of
        {error, _} = Error -> Error;
        {ok, {complete, Result}} -> {ok, Result};
        {ok, {probe, Patch, Checked}} -> guarded(fun() ->
            %% Candidate clients are closed by check_candidate before publication.
            %% Initialization must not hold the mutex used by unrelated readers.
            lists:foreach(fun({Name, Definition, Secret}) ->
                check(albedo_mcp:check_candidate(Name, Definition, Secret))
            end, Checked),
            locked(Home, fun() -> guarded(fun() ->
                Docs = documents(Home), Prior = group(Group, projection('albedo@harness@settings@projection':groups(Docs, Declared))),
                Revisions = albedo_settings_store:read(Home, <<"settings-revisions.json">>),
                match_group(Group, Match, Prior, Revisions),
                {Next, Validation} = candidate(Home, Group, Patch, Docs, Resolve, Defaults, Declared),
                %% Redacted validators alone cannot detect direct secret changes.
                ensure(checked_candidates(Patch, Next) =:= Checked, 412,
                    <<"precondition_failed">>, <<"MCP candidate inputs changed during validation">>),
                {ok, publish(Home, Group, Docs, Next, Validation, Revisions, Declared)}
            end) end)
        end)
    end.

match_group(Group, Match, Prior, Revisions) ->
    case Match of
        <<>> -> refusal(428, <<"precondition_required">>, <<"If-Match is required">>);
        _ -> ensure(Match =:= group_etag(Group, Prior, Revisions), 412,
            <<"precondition_failed">>, <<"settings changed">>)
    end.

checked_candidates(Patch, Docs) ->
    Definitions = object(<<"servers">>, object(<<"mcp">>, maps:get(<<"extensions.json">>, Docs))),
    Secrets = object(<<"mcp">>, maps:get(<<"creds.json">>, Docs)),
    %% A probe may record that a server asks for a sign-in; that is not a change.
    [{Name, maps:get(Name, Definitions), maps:remove(<<"oauth">>, maps:get(Name, Secrets, #{}))}
        || {Name, Change} <- lists:sort(maps:to_list(object(<<"definitions">>, Patch))), Change =/= null].

publish(Home, Group, Docs, Next, Validation, Revisions, Declared) ->
    Value = group(Group, projection('albedo@harness@settings@projection':groups(Next, Declared))),
    Changed = maps:filter(fun(File, V) -> V =/= maps:get(File, Docs) end, Next),
    NextRevisions = case map_size(Changed) of
        0 -> Revisions;
        _ ->
            Updated = Revisions#{Group => maps:get(Group, Revisions, 0) + 1},
            commit_group(Home, Changed#{<<"settings-revisions.json">> => Updated}),
            Updated
    end,
    Resource = (validator(Group, Value, NextRevisions))#{<<"value">> => Value},
    encode(#{<<"group">> => Group, <<"resource">> => Resource, <<"validation">> => Validation}).

documents(Home) -> maps:from_list([{File, albedo_settings_store:read(Home, File)} || File <-
    [<<"config.json">>, <<"creds.json">>, <<"extensions.json">>, <<"capabilities.json">>, <<"picker.json">>]]).

group(Name, Groups) -> case maps:find(Name, Groups) of {ok, Value} -> Value; error -> refusal(400, <<"invalid_request">>, <<"unknown settings group">>) end.
validator(Name, Value, Revisions) -> #{<<"url">> => <<"/settings?group=", Name/binary>>, <<"etag">> => group_etag(Name, Value, Revisions)}.
group_etag(Name, Value, Revisions) ->
    Counter = maps:get(Name, Revisions, 0), true = is_integer(Counter) andalso Counter >= 0,
    albedo_http_api:etag(encode(#{<<"value">> => observed(Name, Value), <<"revision">> => Counter})).

%% The cache priors list every profile's model, so a model switch would stale
%% a cap edit made against the models group it did not touch.
observed(<<"models">>, Value) -> maps:remove(<<"cache_ttl_priors">>, Value);
observed(_, Value) -> Value.
encode(Value) -> iolist_to_binary(json:encode(Value)).
nonempty(<<>>) -> null; nonempty(Value) -> Value.

candidate(Home, <<"providers">>, Patch, Docs, _, _, _) ->
    fields(Patch, [<<"profiles">>, <<"default_profile">>, <<"renames">>]),
    Config = saved_config(maps:get(<<"config.json">>, Docs)), Creds = maps:get(<<"creds.json">>, Docs),
    Changes = object(<<"profiles">>, Patch),
    {SavedProfiles, SavedKeys} = maps:fold(fun(Name, Profile, {Profiles0, Keys0}) ->
        Keys = case maps:find(<<"apiKey">>, Profile) of
            {ok, <<_, _/binary>> = Key} -> Keys0#{Name => #{<<"apiKey">> => Key}};
            _ -> Keys0
        end,
        {Profiles0#{Name => maps:remove(<<"apiKey">>, Profile)}, Keys}
    end, {#{}, object(<<"providers">>, Creds)}, object(<<"providers">>, Config)),
    {RenamedProfiles, RenamedKeys, Active} = rename_profiles(object(<<"renames">>, Patch),
        SavedProfiles, SavedKeys, nonempty(maps:get(<<"active">>, Config, null))),
    {Profiles, Keys, Accounts} = maps:fold(fun(Name, Change, {Profiles0, Keys0, Accounts0}) ->
        text(Name, 1, 64),
        case Change of
            null -> {maps:remove(Name, Profiles0), maps:remove(Name, Keys0), Accounts0};
            _ ->
                fields(Change, [<<"enabled">>, <<"extension">>, <<"api">>, <<"endpoint">>, <<"protocol">>, <<"model">>, <<"effort">>, <<"image_edge">>, <<"account_id">>, <<"account_ids">>, <<"project">>, <<"location">>, <<"api_key">>]),
                case maps:find(<<"enabled">>, Change) of
                    {ok, Enabled} -> true = is_boolean(Enabled);
                    error -> ok
                end,
                ensure(maps:is_key(Name, Profiles0) orelse not maps:is_key(<<"enabled">>, Change) orelse maps:is_key(<<"model">>, Change),
                    400, <<"invalid_request">>, <<"cannot toggle an unknown provider profile">>),
                Old = maps:get(Name, Profiles0, #{}),
                Public = translate(maps:remove(<<"api_key">>, Change), provider_fields()),
                Complete = maps:merge(Old, Public),
                Standard = Complete#{<<"baseUrl">> => case maps:get(<<"baseUrl">>, Complete, <<>>) of null -> <<>>; Endpoint -> Endpoint end, <<"protocol">> => maps:get(<<"protocol">>, Complete, <<"responses">>)},
                {ok, Validated} = 'albedo@daemon@configuration':normalize_profile(Name, Standard),
                Valid = maps:merge(maps:remove(<<"apiKey">>, Standard), maps:remove(<<"apiKey">>, Validated)),
                {Bound, NewKeys, NewAccounts} = profile_key(Home, Change, Name, Valid, Keys0, Accounts0),
                nullable_text(maps:get(<<"effort">>, Bound, null), 100), nullable_text(maps:get(<<"accountId">>, Bound, null), 512),
                AccountIds = maps:get(<<"accountIds">>, Bound, null),
                case AccountIds of null -> ok; Ids -> strings(Ids, 50, 512), ensure(Ids =/= [], 400, <<"invalid_request">>, <<"account_ids must not be empty">>) end,
                ensure(not (maps:get(<<"accountId">>, Bound, null) =/= null andalso AccountIds =/= null), 400,
                    <<"credential_conflict">>, <<"Clear account_id before selecting a rotation">>),
                nullable_text(maps:get(<<"project">>, Bound, null), 256), nullable_text(maps:get(<<"location">>, Bound, null), 256),
                case maps:get(<<"imageEdge">>, Bound, null) of null -> ok; Edge -> counter(Edge, 1, 65536) end,
                {Profiles0#{Name => Bound}, NewKeys, NewAccounts}
        end
    end, {RenamedProfiles, RenamedKeys, object(<<"accounts">>, Creds)}, Changes),
    Default = maps:get(<<"default_profile">>, Patch, Active),
    ensure(Default =:= null orelse maps:is_key(Default, Profiles), 409, <<"invalid_default_profile">>, <<"replace or clear the selected profile">>),
    {Docs#{<<"config.json">> => Config#{<<"accountsVersion">> => 2, <<"providers">> => Profiles, <<"active">> => case Default of null -> <<>>; _ -> Default end},
           <<"creds.json">> => Creds#{<<"providers">> => Keys, <<"accounts">> => Accounts}}, <<"not_applicable">>};
candidate(_, <<"extensions">>, Patch, Docs, _, Defaults, _) ->
    fields(Patch, [<<"defaults">>]), Ext = maps:get(<<"extensions.json">>, Docs),
    Current = object(<<"enabled">>, Ext), Changes = object(<<"defaults">>, Patch),
    _ = boolean_choices(Current, Changes),
    NativeChanges = [{Name, case Value of null -> none; _ -> {some, Value} end}
        || {Name, Value} <- lists:sort(maps:to_list(Changes))],
    Next = case Defaults(lists:sort(maps:to_list(Current)), NativeChanges) of
        {ok, Choices} -> maps:from_list(Choices);
        {error, {Status, Code, Detail}} -> refusal(Status, Code, Detail)
    end,
    {Docs#{<<"extensions.json">> => Ext#{<<"enabled">> => Next}}, <<"not_applicable">>};
candidate(_, <<"extension_settings">>, Patch, Docs, _, _, Declared) ->
    fields(Patch, [<<"values">>]),
    ensure(maps:is_key(<<"values">>, Patch), 400, <<"invalid_request">>, <<"values is required">>),
    Ext = maps:get(<<"extensions.json">>, Docs),
    Next = case 'albedo@harness@settings@declared':patch(Declared, Ext, maps:get(<<"values">>, Patch)) of
        {ok, Value} -> Value;
        {error, {Status, Code, Detail}} -> refusal(Status, Code, Detail)
    end,
    {Docs#{<<"extensions.json">> => Next}, <<"not_applicable">>};
candidate(_, <<"models">>, Patch, Docs, _, _, _) ->
    fields(Patch, [<<"raised_caps">>, <<"compact_at">>]), Ext = maps:get(<<"extensions.json">>, Docs),
    Raised = boolean_choices(object(<<"raisedCaps">>, Ext), object(<<"raised_caps">>, Patch)),
    Next = case maps:is_key(<<"compact_at">>, Patch) of
        true -> Ext#{<<"compactAt">> => window_choices(object(<<"compactAt">>, Ext), object(<<"compact_at">>, Patch))};
        false -> Ext
    end,
    {Docs#{<<"extensions.json">> => Next#{<<"raisedCaps">> => Raised}}, <<"not_applicable">>};
candidate(_, <<"ui">>, Patch, Docs, _, _, _) ->
    fields(Patch, [<<"thinking">>, <<"tools">>, <<"dismissed_notices">>, <<"web_allow">>, <<"proxy_allow">>]),
    maps:foreach(
        fun
            (<<"dismissed_notices">>, Value) -> strings(Value, 1000, 512);
            (<<"web_allow">>, Value) -> strings(Value, 64, 64);
            (<<"proxy_allow">>, Value) -> strings(Value, 64, 64);
            (_, Value) -> true = is_boolean(Value)
        end,
        Patch
    ),
    Picker = maps:get(<<"picker.json">>, Docs),
    {Docs#{<<"picker.json">> => maps:merge(Picker, Patch)}, <<"not_applicable">>};
candidate(_, <<"capabilities">>, Patch, Docs, Resolve, _, _) ->
    fields(Patch, [<<"catalog_session_id">>, <<"catalog_revision">>, <<"choices">>]),
    Resolved = case Resolve(Patch) of
        {ok, Value} -> Value;
        {error, Detail} -> refusal(409, <<"catalog_changed">>, Detail)
    end,
    Caps = maps:get(<<"capabilities.json">>, Docs), Global = object(<<"global">>, Caps),
    Next = maps:fold(fun(Kind, Changes, Acc) ->
        NativeChanges = maps:map(fun(_, {some, Bool}) -> Bool; (_, none) -> null end, Changes),
        case map_size(NativeChanges) of
            0 -> Acc;
            _ -> Acc#{Kind => boolean_choices(object(Kind, Acc), NativeChanges)}
        end
    end, Global, Resolved),
    Updated = Caps#{<<"global">> => Next}, albedo_settings_store:validate_caps(Updated),
    ensure(byte_size(encode(Updated)) =< albedo_capabilities:max_bytes(), 409,
        <<"settings_capacity">>, <<"capability preferences exceed their saved byte limit">>),
    {Docs#{<<"capabilities.json">> => Updated}, <<"not_applicable">>};
candidate(_, <<"mcp">>, Patch, Docs, _, _, _) ->
    fields(Patch, [<<"definitions">>, <<"validate_connection">>]),
    Probe = maps:get(<<"validate_connection">>, Patch, true), true = is_boolean(Probe),
    Ext = maps:get(<<"extensions.json">>, Docs), MCP = object(<<"mcp">>, Ext), Creds = maps:get(<<"creds.json">>, Docs),
    {Definitions, Secrets} = maps:fold(fun(Name, Change, {Definitions0, Secrets0}) ->
        case Change of
            null -> {maps:remove(Name, Definitions0), maps:remove(Name, Secrets0)};
            _ ->
                {Definition, Secret} = mcp_candidate(Change, maps:get(Name, Definitions0, #{}), maps:get(Name, Secrets0, #{})),
                {ok, nil} = albedo_mcp:validate_settings(Name, {some, Definition}, Secret),
                {Definitions0#{Name => Definition}, Secrets0#{Name => Secret}}
        end
    end, {object(<<"servers">>, MCP), object(<<"mcp">>, Creds)}, object(<<"definitions">>, Patch)),
    {Docs#{<<"extensions.json">> => Ext#{<<"mcp">> => MCP#{<<"servers">> => Definitions}}, <<"creds.json">> => Creds#{<<"mcp">> => Secrets}},
     case Probe of true -> <<"passed">>; false -> <<"skipped">> end}.

%% A rename moves the profile, its key and the default to the new name. The
%% sessions on it are the daemon's to move once this is published.
rename_profiles(Renames, Profiles0, Keys0, Default0) ->
    Targets = maps:values(Renames),
    ensure(length(lists:usort(Targets)) =:= length(Targets), 400, <<"invalid_request">>, <<"two profiles cannot take one name">>),
    lists:foldl(fun({From, To}, {Profiles, Keys, Default}) ->
        ensure(maps:is_key(From, Profiles), 409, <<"unknown_profile">>, <<"no profile is named ", From/binary>>),
        text(To, 1, 64),
        ensure(not maps:is_key(To, Profiles0), 409, <<"profile_exists">>, <<"a profile is already named ", To/binary>>),
        {Profile, Rest} = maps:take(From, Profiles),
        {ok, _} = 'albedo@daemon@configuration':normalize_profile(To, Profile),
        {Rest#{To => Profile},
         case maps:take(From, Keys) of {Key, Others} -> Others#{To => Key}; error -> Keys end,
         case Default of From -> To; _ -> Default end}
    end, {Profiles0, Keys0, Default0}, lists:sort(maps:to_list(Renames))).

provider_fields() -> [{<<"enabled">>, <<"enabled">>}, {<<"extension">>, <<"extension">>}, {<<"api">>, <<"api">>}, {<<"endpoint">>, <<"baseUrl">>}, {<<"protocol">>, <<"protocol">>},
    {<<"model">>, <<"model">>}, {<<"effort">>, <<"effort">>}, {<<"image_edge">>, <<"imageEdge">>}, {<<"account_id">>, <<"accountId">>}, {<<"account_ids">>, <<"accountIds">>},
    {<<"project">>, <<"project">>}, {<<"location">>, <<"location">>}].
translate(Map, Names) -> maps:from_list([{Stored, maps:get(Wire, Map)} || {Wire, Stored} <- Names, maps:is_key(Wire, Map)]).

mcp_candidate(Patch, Prior, Secrets0) ->
    fields(Patch, [Wire || {Wire, _} <- 'albedo@harness@settings@projection':mcp_fields()] ++ [<<"environment">>, <<"headers">>, <<"secrets">>]),
    Public0 = maps:merge(Prior, translate(Patch, 'albedo@harness@settings@projection':mcp_fields())),
    SecretPatch = object(<<"secrets">>, Patch), fields(SecretPatch, [<<"bearer_token">>, <<"environment">>, <<"headers">>, <<"oauth">>, <<"oauth_client">>]),
    {Public1, Secrets1} = lists:foldl(fun({Wire, Stored}, {Public, Secrets}) ->
        PublicChanges = maps:get(Wire, Patch, #{}), SecretChanges = maps:get(Wire, SecretPatch, #{}),
        Sources = source_choices(object(Stored, Public), PublicChanges),
        Saved = secret_choices(object(Stored, Secrets), SecretChanges),
        PNames = case PublicChanges of null -> []; _ -> [K || {K,V} <- maps:to_list(PublicChanges), V =/= null] end,
        SNames = case SecretChanges of null -> []; _ -> [K || {K,V} <- maps:to_list(SecretChanges), V =/= null] end,
        true = lists:all(fun(K) -> not lists:member(K, SNames) end, PNames),
        {Public#{Stored => maps:without(SNames, Sources)}, Secrets#{Stored => maps:without(PNames, Saved)}}
    end, {Public0, Secrets0}, [{<<"environment">>, <<"env">>}, {<<"headers">>, <<"headers">>}]),
    {Public, Secrets} = case maps:find(<<"bearer_token">>, SecretPatch) of
        error -> {Public1, Secrets1};
        {ok, null} -> {Public1, maps:remove(<<"bearerToken">>, Secrets1)};
        {ok, Token} -> text(Token, 1, 16384), {maps:remove(<<"bearerTokenEnvVar">>, Public1), Secrets1#{<<"bearerToken">> => Token}}
    end,
    Secrets3 = case maps:find(<<"bearer_token_env_var">>, Patch) of
        {ok, Name} when is_binary(Name) -> true = not maps:is_key(<<"bearer_token">>, SecretPatch) orelse maps:get(<<"bearer_token">>, SecretPatch) =:= null, maps:remove(<<"bearerToken">>, Secrets);
        _ -> Secrets
    end,
    Secrets2 = oauth_choices(Secrets3, SecretPatch),
    Type = maps:get(<<"type">>, Public),
    case Type of
        <<"http">> -> true = maps:get(<<"command">>, Public, null) =:= null, true = maps:get(<<"cwd">>, Public, null) =:= null, true = maps:get(<<"args">>, Public, []) =:= [], true = map_size(object(<<"env">>, Public)) =:= 0;
        <<"stdio">> -> true = maps:get(<<"url">>, Public, null) =:= null, true = maps:get(<<"bearerTokenEnvVar">>, Public, null) =:= null, true = map_size(object(<<"headers">>, Public)) =:= 0, true = map_size(object(<<"headers">>, Secrets2)) =:= 0, true = maps:get(<<"bearerToken">>, Secrets2, null) =:= null
    end,
    case maps:find(<<"startupTimeoutMs">>, Public) of {ok, Millis} -> counter(Millis, 1, 300000); error -> ok end,
    {Public, Secrets2}.

%% `oauth: null` signs the server out, keeping what it asked for; a sign-in
%% itself only ever comes from the daemon's sign-in flow. `oauth_client` is a
%% client id (and secret) the user registered with the server's
%% authorization server, or null to forget it.
oauth_choices(Secrets, SecretPatch) ->
    Signed = case maps:find(<<"oauth">>, SecretPatch) of
        error -> Secrets;
        {ok, null} ->
            case maps:find(<<"oauth">>, Secrets) of
                {ok, Record} -> Secrets#{<<"oauth">> => albedo_mcp_oauth:signed_out(Record)};
                error -> Secrets
            end
    end,
    case maps:find(<<"oauth_client">>, SecretPatch) of
        error -> Signed;
        {ok, null} -> maps:remove(<<"oauthClient">>, Signed);
        {ok, Client} ->
            fields(Client, [<<"client_id">>, <<"client_secret">>]),
            Id = maps:get(<<"client_id">>, Client), text(Id, 1, 1024),
            Secret = maps:get(<<"client_secret">>, Client, null), nullable_text(Secret, 4096),
            Signed#{<<"oauthClient">> => #{<<"clientId">> => Id, <<"clientSecret">> => Secret}}
    end.

source_choices(_, null) -> #{};
source_choices(Prior, Changes) -> maps:fold(fun
    (K, null, Acc) -> maps:remove(K, Acc);
    (K, Value, Acc) -> fields(Value, [<<"source">>, <<"value">>]), Text = maps:get(<<"value">>, Value), text(Text, 0, 16384),
        Source = case maps:get(<<"source">>, Value) of <<"literal">> -> Text; <<"env">> -> #{<<"env">> => Text} end,
        Acc#{K => Source}
end, Prior, Changes).
secret_choices(_, null) -> #{};
secret_choices(Prior, Changes) -> maps:fold(fun(K, null, Acc) -> maps:remove(K, Acc); (K, V, Acc) -> text(V, 0, 16384), Acc#{K => V} end, Prior, Changes).
window_choices(Prior, Changes) -> maps:fold(fun(K, null, Acc) -> maps:remove(K, Acc); (K, V, Acc) -> text(K, 1, 512), counter(V, 1, 100000000), Acc#{K => V} end, Prior, Changes).
boolean_choices(Prior, Changes) -> maps:fold(fun(K, null, Acc) -> maps:remove(K, Acc); (K, V, Acc) when is_boolean(V) -> text(K, 1, 512), Acc#{K => V} end, Prior, Changes).

fields(Map, Allowed) when is_map(Map) -> true = lists:all(fun(K) -> lists:member(K, Allowed) end, maps:keys(Map));
fields(_, _) -> erlang:error(invalid_object).
text(Value, Min, Max) -> true = is_binary(Value) andalso byte_size(Value) >= Min andalso byte_size(Value) =< Max.
nullable_text(null, _) -> ok; nullable_text(Text, Max) -> text(Text, 1, Max).
counter(Value, Min, Max) -> true = is_integer(Value) andalso Value >= Min andalso Value =< Max.
strings(Values, Max, Width) -> true = is_list(Values) andalso length(Values) =< Max, lists:foreach(fun(V) -> text(V, 1, Width) end, Values).
%% The store lock reports a busy store or an incomplete recovery as a bare
%% reason; this boundary answers every failure as {Status, Code, Detail}.
locked(Home, Run) ->
    case albedo_settings_store:with_lock(Home, Run) of
        {error, Reason} when is_binary(Reason) -> {error, {503, <<"settings_unavailable">>, Reason}};
        Result -> Result
    end.

ensure(true, _, _, _) -> ok; ensure(false, Status, Code, Detail) -> refusal(Status, Code, Detail).
refusal(Status, Code, Detail) -> throw({http_settings, {Status, Code, Detail}}).
guarded(Run) -> try Run() catch
    throw:{http_settings, Failure} -> {error, Failure};
    throw:{settings, _} -> {error, {503, <<"settings_unavailable">>, <<"settings could not be published">>}};
    _:_ -> {error, {400, <<"invalid_request">>, <<"invalid settings candidate">>}}
end.

profile_key(Home, Change, Name, Profile, Keys, Accounts) ->
    Extension = maps:get(<<"extension">>, Profile, <<"openai">>),
    case {lists:member(Extension, albedo_key_accounts:providers()), maps:find(<<"api_key">>, Change)} of
        {_, error} -> {Profile, Keys, Accounts};
        {true, {ok, null}} ->
            Id = maps:get(<<"accountId">>, Profile, null),
            Values = albedo_credentials:values(Accounts, Extension) ++
                albedo_key_accounts:env(Home, Extension, maps:get(<<"baseUrl">>, Profile, <<>>)),
            IsKey = lists:any(fun(V) -> maps:get(<<"_albedo_account_id">>, V, null) =:= Id andalso
                maps:get(<<"type">>, V, null) =:= <<"key">> end, Values),
            Bound = case IsKey of true -> maps:remove(<<"accountId">>, Profile); false -> Profile end,
            {Bound, maps:remove(Name, Keys), Accounts};
        {true, {ok, Key}} ->
            text(Key, 1, 16384),
            {ok, _} = 'albedo@daemon@configuration':normalize_profile(Name, Profile#{<<"apiKey">> => Key}),
            Endpoint = maps:get(<<"baseUrl">>, Profile, <<>>),
            Values = albedo_credentials:values(Accounts, Extension),
            Existing = [V || V <- Values, maps:get(<<"type">>, V, null) =:= <<"key">>,
                maps:get(<<"apiKey">>, V, null) =:= Key, maps:get(<<"endpoint">>, V, null) =:= Endpoint],
            {Id, Updated} = case Existing of
                [V | _] -> {maps:get(<<"_albedo_account_id">>, V), Accounts};
                [] ->
                    NewId = binary:encode_hex(crypto:strong_rand_bytes(16), lowercase),
                    Credential = #{<<"type">> => <<"key">>, <<"apiKey">> => Key, <<"endpoint">> => Endpoint,
                        <<"label">> => albedo_key_accounts:label(Key), <<"_albedo_account_id">> => NewId},
                    {NewId, albedo_credentials:put_values(Accounts, Extension, Values ++ [Credential])}
            end,
            {maps:remove(<<"accountIds">>, Profile#{<<"accountId">> => Id}), maps:remove(Name, Keys), Updated};
        {false, {ok, null}} -> {Profile, maps:remove(Name, Keys), Accounts};
        {false, {ok, Key}} ->
            text(Key, 1, 16384),
            {ok, _} = 'albedo@daemon@configuration':normalize_profile(Name, Profile#{<<"apiKey">> => Key}),
            {Profile, Keys#{Name => #{<<"apiKey">> => Key}}, Accounts}
    end.

validate_provider_accounts(Home, Docs, Providers, Logins) ->
    Config = saved_config(maps:get(<<"config.json">>, Docs)), Creds = maps:get(<<"creds.json">>, Docs),
    Accounts = object(<<"accounts">>, Creds), Keys = object(<<"providers">>, Creds),
    maps:foreach(fun(Name, Profile) ->
        {ok, Normalized} = 'albedo@daemon@configuration':normalize_profile(Name, Profile),
        Extension = maps:get(<<"extension">>, Normalized),
        ensure(lists:member(Extension, Providers), 400, <<"provider_unknown">>, <<"Provider extension is not installed">>),
        KeyProvider = lists:member(Extension, albedo_key_accounts:providers()),
        Stores = lists:usort([element(6, Login) || Login <- Logins, element(2, Login) =:= Extension] ++
            case KeyProvider of true -> [Extension]; false -> [] end),
        Env = case KeyProvider of
            true -> albedo_key_accounts:env(Home, Extension, maps:get(<<"baseUrl">>, Normalized));
            false -> []
        end,
        Values = lists:flatmap(fun(Store) -> albedo_credentials:values(Accounts, Store) end, Stores) ++ Env,
        Known = fun(Id) -> lists:any(fun(Credential) -> maps:get(<<"_albedo_account_id">>, Credential, null) =:= Id end, Values) end,
        Pin = maps:get(<<"accountId">>, Profile, null),
        Rotation = maps:get(<<"accountIds">>, Profile, null),
        ensure(not (Pin =/= null andalso Rotation =/= null), 400,
            <<"credential_conflict">>, <<"Choose either account_id or account_ids">>),
        case Pin of null -> ok; Id -> ensure(Known(Id), 400, <<"account_unknown">>, <<"Account does not belong to this provider">>) end,
        case Rotation of
            null -> ok;
            Ids when is_list(Ids), Ids =/= [] ->
                strings(Ids, 50, 512),
                lists:foreach(fun(Id) -> ensure(Known(Id), 400, <<"account_unknown">>, <<"Account does not belong to this provider">>) end, Ids);
            _ -> refusal(400, <<"invalid_request">>, <<"account_ids must be a nonempty list">>)
        end,
        ensure((Pin =:= null andalso Rotation =:= null) orelse not maps:is_key(Name, Keys),
            400, <<"credential_conflict">>, <<"Clear the API key before selecting accounts">>)
    end, object(<<"providers">>, Config)).

%% Gleam returns native JSON maps so validators retain the existing encoding.

projection({ok, Value}) -> Value;
projection({error, invalid_section}) -> throw({settings, <<"invalid settings section">>});
projection({error, invalid_value}) -> erlang:error(invalid_settings_value).

saved_config(Document) ->
    case 'albedo@daemon@configuration':named_config(Document) of
        {ok, Value} -> Value;
        {error, Reason} -> throw({settings, Reason})
    end.
