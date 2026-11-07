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
    io:format("session cost pricing tests passed~n"), ok.
