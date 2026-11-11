-module(session_cost_tests).
-export([run/0]).

%% Ledger rows: profile, provider, model, input, cached, created, 5m, 1h,
%% output, outcome, count.
row(Profile, Endpoint, Model, Tokens, Outcome, Count) ->
    [Profile, Endpoint, Model | Tokens] ++ [Outcome, Count].

run() ->
    P = #{{<<"openai">>, <<"gpt-test">>} => #{<<"input">> => 2, <<"output">> => 10, <<"cache_read">> => 0.2, <<"cache_write">> => 2.5}},
    Codex = <<"responses:https://chatgpt.com/backend-api">>,
    Row = row(<<"codex">>, Codex, <<"gpt-test">>, [1000000, 500000, 100000, 100000, 0, 100000], <<"ok">>, 2),
    {some, V} = albedo_session_cost:estimate_rows(P, [list_to_tuple(Row)]),
    true = abs(V - 4.3) < 0.00001,
    {some, 0.00022} = albedo_session_cost:estimate_rows(P, [list_to_tuple(row(<<"openai">>, undefined, <<"gpt-test">>, [10, undefined, undefined, undefined, undefined, 20], <<"ok">>, 1))]),
    {some, +0.0} = albedo_session_cost:estimate_rows(#{}, []),
    none = albedo_session_cost:estimate_rows(#{}, [Row]),
    %% A successful request without usage is unknown, not free.
    Unmetered = [undefined, undefined, undefined, undefined, undefined, undefined],
    none = albedo_session_cost:estimate_rows(P, [row(<<"codex">>, Codex, <<"gpt-test">>, Unmetered, <<"ok">>, 1)]),
    %% Rejected attempts (429, 5xx) report no usage and add nothing.
    {some, V} = albedo_session_cost:estimate_rows(P, [Row,
        row(<<"codex">>, Codex, <<"gpt-test">>, Unmetered, <<"error">>, 3),
        row(<<"codex">>, Codex, <<"gpt-test">>, [null, null, null, null, null, null], <<"error">>, 1)]),
    %% Model/provider changes accumulate instead of repricing the whole session.
    P2 = P#{{<<"custom">>, <<"local">>} => #{<<"input">> => 0, <<"output">> => 0}},
    {some, V} = albedo_session_cost:estimate_rows(P2, [Row, row(<<"custom">>, undefined, <<"local">>, [20, 0, 0, 0, 0, 10], <<"ok">>, 1)]),
    Tiered = #{{<<"openai">>, <<"gpt-test">>} => #{<<"input">> => 1, <<"output">> => 2,
        <<"tiers">> => [#{<<"tier">> => #{<<"type">> => <<"context">>, <<"size">> => 200000}, <<"input">> => 2, <<"output">> => 4}]}},
    {some, 0.6} = albedo_session_cost:estimate_rows(Tiered, [row(<<"openai">>, undefined, <<"gpt-test">>, [300000, 0, 0, 0, 0, 0], <<"ok">>, 1)]),
    {some, 0.2} = albedo_session_cost:estimate_rows(Tiered, [row(<<"openai">>, undefined, <<"gpt-test">>, [200000, 0, 0, 0, 0, 0], <<"ok">>, 1)]),
    {some, Hour} = albedo_session_cost:estimate_rows(P, [row(<<"openai">>, undefined, <<"gpt-test">>, [100000, 0, 100000, 0, 100000, 0], <<"ok">>, 1)]),
    true = abs(Hour - 0.4) < 0.00001,
    %% A page prices each session from its own rows; one unknown stays local.
    Grouped = maps:from_list(albedo_session_cost:estimate_grouped(P,
        [list_to_tuple([<<"a">> | row(<<"openai">>, undefined, <<"gpt-test">>, [10, undefined, undefined, undefined, undefined, 20], <<"ok">>, 1)]),
         list_to_tuple([<<"a">> | row(<<"openai">>, undefined, <<"gpt-test">>, [10, undefined, undefined, undefined, undefined, 20], <<"ok">>, 1)]),
         list_to_tuple([<<"b">> | row(<<"unknown">>, undefined, <<"model">>, [10, 0, 0, 0, 0, 20], <<"ok">>, 1)])])),
    {some, A} = maps:get(<<"a">>, Grouped),
    true = abs(A - 0.00044) < 0.0000001,
    none = maps:get(<<"b">>, Grouped),
    [] = albedo_session_cost:estimate_grouped(P, []),
    subscription_prices(),
    endpoint_prices(),
    catalog_prices(),
    io:format("session cost pricing tests passed~n"), ok.

subscription_prices() ->
    Api = #{<<"input">> => 2, <<"output">> => 10, <<"cache_read">> => 0.2},
    Go = <<"chat_completions:https://opencode.ai/inference/go/v1">>,
    Prices = #{{<<"openai">>, <<"gpt-5.4">>} => Api,
               {<<"zai">>, <<"glm-5">>} => Api,
               {<<"moonshotai">>, <<"kimi-k2.5">>} => Api,
               {<<"minimax">>, <<"MiniMax-M2.7">>} => Api,
               {<<"anthropic">>, <<"claude-sonnet-5-5">>} => Api,
               {<<"opencode-go">>, <<"glm-5">>} => #{<<"input">> => 0, <<"output">> => 0},
               {<<"proxy">>, <<"glm-5">>} => #{<<"input">> => 99, <<"output">> => 99}},
    lists:foreach(fun({Profile, Endpoint, Model}) ->
        {some, 2.2} = albedo_session_cost:estimate_rows(Prices,
            [row(Profile, Endpoint, Model, [1000000, 0, 0, 0, 0, 0], <<"ok">>, 1),
             row(Profile, Endpoint, Model, [1000000, 1000000, 0, 0, 0, 0], <<"ok">>, 1)])
    end, [{<<"codex">>, <<"responses:https://chatgpt.com/backend-api">>, <<"gpt-5.4">>},
          {<<"opencode-go">>, Go, <<"glm-5">>},
          {<<"opencode-go">>, Go, <<"kimi-k2.5">>},
          {<<"opencode-go">>, Go, <<"minimax-m2.7">>},
          %% Renamed profiles still resolve from their endpoint.
          {<<"work">>, Go, <<"glm-5">>},
          {<<"zed">>, <<"chat_completions:https://cloud.zed.dev">>, <<"gpt-5.4">>},
          {<<"my-zed">>, <<"chat_completions:https://cloud.zed.dev">>, <<"claude-sonnet-5-5">>},
          {<<"claude">>, <<"chat_completions:https://api.anthropic.com">>, <<"claude-sonnet-5-5">>}]),
    {some, 99.0} = albedo_session_cost:estimate_rows(Prices,
        [row(<<"proxy">>, <<"chat_completions:https://proxy.example/v1">>, <<"glm-5">>, [1000000, 0, 0, 0, 0, 0], <<"ok">>, 1)]).

%% Models many catalog providers resell resolve through the serving provider.
endpoint_prices() ->
    Prices = #{{<<"opencode-go">>, <<"deepseek-v4.1-flash">>} => #{<<"input">> => 1, <<"output">> => 2},
               {<<"opencode">>, <<"deepseek-v4.1-flash">>} => #{<<"input">> => 5, <<"output">> => 5},
               {<<"vultr">>, <<"deepseek-v4.1-flash">>} => #{<<"input">> => 7, <<"output">> => 7},
               {<<"openrouter">>, <<"anthropic/claude-sonnet-5.5">>} => #{<<"input">> => 3, <<"output">> => 15},
               {<<"vercel">>, <<"anthropic/claude-sonnet-5.5">>} => #{<<"input">> => 4, <<"output">> => 15}},
    Tokens = [1000000, 0, 0, 0, 0, 0],
    {some, 1.0} = albedo_session_cost:estimate_rows(Prices,
        [row(<<"opencode-go">>, <<"chat_completions:https://opencode.ai/inference/go/v1">>, <<"deepseek-v4.1-flash">>, Tokens, <<"ok">>, 1)]),
    {some, 1.0} = albedo_session_cost:estimate_rows(Prices,
        [row(undefined, <<"chat_completions:https://opencode.ai/zen/go/v1">>, <<"deepseek-v4.1-flash">>, Tokens, <<"ok">>, 1)]),
    {some, 3.0} = albedo_session_cost:estimate_rows(Prices,
        [row(<<"openrouter">>, <<"responses:https://openrouter.ai/api/v1">>, <<"anthropic/claude-sonnet-5.5">>, Tokens, <<"ok">>, 1)]),
    {some, 3.0} = albedo_session_cost:estimate_rows(Prices,
        [row(<<"router">>, <<"responses:https://openrouter.ai/api/v1">>, <<"anthropic/claude-sonnet-5.5">>, Tokens, <<"ok">>, 1)]),
    none = albedo_session_cost:estimate_rows(Prices,
        [row(<<"other">>, <<"responses:https://other.example/v1">>, <<"deepseek-v4.1-flash">>, Tokens, <<"ok">>, 1)]).

catalog_prices() ->
    Catalog = "session-cost-models.json",
    Cost = #{<<"input">> => 2, <<"output">> => 10},
    Data = #{<<"openai">> => #{<<"name">> => <<"OpenAI">>, <<"models">> =>
        #{<<"gpt-test">> => #{<<"id">> => <<"gpt-test">>, <<"cost">> => Cost}}}},
    try
        ok = file:write_file(Catalog, json:encode(Data)),
        {ok, Info} = file:read_file_info(Catalog, [{time, posix}]),
        Revision = {element(2, Info), element(6, Info)},
        %% Version 3 predates the price index and must be rebuilt from JSON.
        ok = file:write_file(Catalog ++ ".index", term_to_binary(
            {3, Revision, #{index => #{}, providers => #{}}})),
        Expected = #{{<<"openai">>, <<"gpt-test">>} => Cost},
        Expected = albedo_models:prices(Catalog),
        %% Trimming and loading the persisted index both retain prices.
        persistent_term:erase({albedo_models, Catalog}),
        Expected = albedo_models:prices(Catalog),
        {ok, Trimmed} = file:read_file(Catalog),
        #{<<"openai">> := #{<<"models">> := #{<<"gpt-test">> := #{<<"cost">> := Cost}}}} = json:decode(Trimmed)
    after
        persistent_term:erase({albedo_models, Catalog}),
        file:delete(Catalog), file:delete(Catalog ++ ".index")
    end.
