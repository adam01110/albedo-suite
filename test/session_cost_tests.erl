-module(session_cost_tests).
-export([run/0]).

run() ->
    P = #{{<<"openai">>, <<"gpt-test">>} => #{<<"input">> => 2, <<"output">> => 10, <<"cache_read">> => 0.2, <<"cache_write">> => 2.5}},
    Row = [<<"codex">>, <<"gpt-test">>, 1000000, 500000, 100000, 100000, 0, 100000, 2],
    {some, V} = albedo_session_cost:estimate_rows(P, [list_to_tuple(Row)]),
    true = abs(V - 4.3) < 0.00001,
    {some, 0.00022} = albedo_session_cost:estimate_rows(P, [{<<"openai">>, <<"gpt-test">>, 10, undefined, undefined, undefined, undefined, 20, 1}]),
    {some, +0.0} = albedo_session_cost:estimate_rows(#{}, []),
    none = albedo_session_cost:estimate_rows(#{}, [Row]),
    none = albedo_session_cost:estimate_rows(P, [[<<"codex">>, <<"gpt-test">>, null, null, null, null, null, null, 1]]),
    %% Model/provider changes accumulate instead of repricing the whole session.
    P2 = P#{{<<"custom">>, <<"local">>} => #{<<"input">> => 0, <<"output">> => 0}},
    {some, V} = albedo_session_cost:estimate_rows(P2, [Row, [<<"custom">>, <<"local">>, 20, 0, 0, 0, 0, 10, 1]]),
    Tiered = #{{<<"openai">>, <<"gpt-test">>} => #{<<"input">> => 1, <<"output">> => 2,
        <<"tiers">> => [#{<<"tier">> => #{<<"type">> => <<"context">>, <<"size">> => 200000}, <<"input">> => 2, <<"output">> => 4}]}},
    {some, 0.6} = albedo_session_cost:estimate_rows(Tiered, [[<<"openai">>, <<"gpt-test">>, 300000, 0, 0, 0, 0, 0, 1]]),
    {some, 0.2} = albedo_session_cost:estimate_rows(Tiered, [[<<"openai">>, <<"gpt-test">>, 200000, 0, 0, 0, 0, 0, 1]]),
    {some, Hour} = albedo_session_cost:estimate_rows(P, [[<<"openai">>, <<"gpt-test">>, 100000, 0, 100000, 0, 100000, 0, 1]]),
    true = abs(Hour - 0.4) < 0.00001,
    subscription_prices(),
    catalog_prices(),
    io:format("session cost pricing tests passed~n"), ok.

subscription_prices() ->
    Api = #{<<"input">> => 2, <<"output">> => 10, <<"cache_read">> => 0.2},
    Prices = #{{<<"openai">>, <<"gpt-5.4">>} => Api,
               {<<"zai">>, <<"glm-5">>} => Api,
               {<<"moonshotai">>, <<"kimi-k2.5">>} => Api,
               {<<"minimax">>, <<"MiniMax-M2.7">>} => Api,
               {<<"opencode-go">>, <<"glm-5">>} => #{<<"input">> => 0, <<"output">> => 0},
               {<<"proxy">>, <<"glm-5">>} => #{<<"input">> => 99, <<"output">> => 99}},
    lists:foreach(fun({Provider, Model}) ->
        {some, 2.2} = albedo_session_cost:estimate_rows(Prices,
            [[Provider, Model, 1000000, 0, 0, 0, 0, 0, 1],
             [Provider, Model, 1000000, 1000000, 0, 0, 0, 0, 1]])
    end, [{<<"codex">>, <<"gpt-5.4">>}, {<<"opencode-go">>, <<"glm-5">>},
          {<<"opencode-go">>, <<"kimi-k2.5">>}, {<<"opencode-go">>, <<"minimax-m2.7">>}]),
    {some, 99.0} = albedo_session_cost:estimate_rows(Prices,
        [[<<"proxy">>, <<"glm-5">>, 1000000, 0, 0, 0, 0, 0, 1]]).

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
