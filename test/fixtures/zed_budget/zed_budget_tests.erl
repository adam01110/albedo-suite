-module(zed_budget_tests).
-export([run/0]).

run() ->
    application:load({application, hackney, [{vsn, "fixture"}, {modules, [hackney]},
        {applications, [kernel, stdlib]}]}),
    check("valid, zero and over-limit USD budgets", fun budgets/0),
    check("missing values stay unknown", fun missing/0),
    check("malformed, negative, nonfinite and changed schemas", fun malformed/0),
    check("absent or invalid cookie never fetches or falls back to JWT", fun absent/0),
    check("fixed HTTPS origin, TLS, cookie-only credential and no redirects", fun isolation/0),
    check("expired, redirected and unavailable are sanitized", fun failures/0),
    check("bounded response and credential-isolated memory cache", fun cache/0),
    check("whole-call deadline cancels an incomplete body", fun deadline/0),
    check("source scope and unverified association exclude private metadata", fun labeling/0),
    io:format("9 Zed budget regression groups passed~n").

check(Name, Run) -> Run(), io:format("ok: ~s~n", [Name]).

fixture(Used, Limit) -> iolist_to_binary(json:encode(#{<<"current_usage">> =>
    #{<<"token_spend">> => #{<<"spend_in_cents">> => Used, <<"limit_in_cents">> => Limit}}})).

budgets() ->
    #{<<"status">> := <<"available">>, <<"spend">> := <<"USD 12.34">>,
      <<"limit">> := <<"USD 20.00">>, <<"remaining">> := <<"USD 7.66">>,
      <<"remaining_in_cents">> := 766} = albedo_zed_budget:decode(fixture(1234, 2000)),
    #{<<"status">> := <<"available">>, <<"remaining_in_cents">> := 0,
      <<"limit">> := <<"USD 0.00">>} = albedo_zed_budget:decode(fixture(0, 0)),
    #{<<"status">> := <<"over_limit">>, <<"remaining">> := <<"-USD 2.00">>,
      <<"remaining_in_cents">> := -200} = albedo_zed_budget:decode(fixture(2200, 2000)),
    #{<<"status">> := <<"over_limit">>, <<"remaining_in_cents">> := -100} =
        albedo_zed_budget:decode(fixture(100, 0)),
    #{<<"spend">> := <<"USD 1.25">>} = albedo_zed_budget:decode(fixture(125.0, 500)).

missing() ->
    lists:foreach(fun(Body) ->
        #{<<"status">> := <<"unknown">>, <<"remaining_in_cents">> := null,
          <<"remaining">> := <<"Unknown">>} = albedo_zed_budget:decode(Body)
    end, [fixture(null, 0), fixture(0, null),
        <<"{\"current_usage\":{\"token_spend\":{\"spend_in_cents\":100}}}">>,
        <<"{\"current_usage\":{\"token_spend\":{}}}">>]).

malformed() ->
    lists:foreach(fun(Body) ->
        #{<<"status">> := <<"schema_error">>} = albedo_zed_budget:decode(Body)
    end, [fixture(-1, 100), fixture(1, -100), fixture(<<"100">>, 200),
        fixture(1, false), fixture(#{}, 2), fixture([], 2),
        fixture(9007199254740992, 2),
        <<"{\"current_usage\":{\"token_spend\":{\"spend_in_cents\":1e999}}}">>,
        <<"{\"current_usage\":{\"token_spend\":{\"spend_in_cents\":NaN}}}">>,
        <<"{\"current_usage\":{\"edit_predictions\":{}}}">>,
        <<"{\"current_usage\":{\"token_spend\":[]}}">>, <<"{}">>, <<"sensitive malformed body">>]).

reset(Fixture) ->
    persistent_term:erase(albedo_zed_budget),
    persistent_term:put(budget_fixture, Fixture),
    persistent_term:put(budget_calls, 0),
    persistent_term:put(budget_body_reads, 0),
    persistent_term:put(budget_closed, false).

read() -> json:decode(albedo_zed_budget:read()).

absent() ->
    reset({200, [fixture(100, 200)]}),
    os:putenv("ZED_TOKEN", "fake-inference-token"),
    os:unsetenv("ZED_BILLING_SESSION"),
    #{<<"status">> := <<"unconfigured">>} = read(),
    os:putenv("ZED_BILLING_SESSION", ""),
    #{<<"status">> := <<"unconfigured">>} = read(),
    lists:foreach(fun(Cookie) ->
        os:putenv("ZED_BILLING_SESSION", Cookie),
        #{<<"status">> := <<"invalid_configuration">>} = read()
    end, ["bad;second=cookie", "bad\r\nheader:value", "Cookie: value", "zed.session=value", "bad cookie", lists:duplicate(8193, $x)]),
    0 = persistent_term:get(budget_calls).

isolation() ->
    reset({200, [fixture(1234, 2000)]}),
    os:putenv("ZED_BILLING_SESSION", "fake-browser-session"),
    os:putenv("ZED_TOKEN", "different-inference-token"),
    #{<<"status">> := <<"available">>} = read(),
    {<<"https://cloud.zed.dev/frontend/billing/usage">>, Options} = persistent_term:get(budget_connection),
    false = proplists:get_value(follow_redirect, Options),
    false = proplists:get_value(pool, Options),
    Ssl = proplists:get_value(ssl_options, Options),
    verify_peer = proplists:get_value(verify, Ssl),
    "cloud.zed.dev" = proplists:get_value(server_name_indication, Ssl),
    {get, <<"/frontend/billing/usage">>, Headers, <<>>} = persistent_term:get(budget_request),
    <<"zed.session=fake-browser-session">> = proplists:get_value(<<"cookie">>, Headers),
    undefined = proplists:get_value(<<"authorization">>, Headers),
    true = persistent_term:get(budget_closed).

failures() ->
    os:putenv("ZED_BILLING_SESSION", "fake-browser-session"),
    lists:foreach(fun({Code, Status}) ->
        reset({Code, [<<"private server body and cookie">>]}),
        #{<<"status">> := Status} = read(),
        0 = persistent_term:get(budget_body_reads),
        1 = persistent_term:get(budget_calls),
        true = persistent_term:get(budget_closed)
    end, [{401, <<"expired">>}, {403, <<"expired">>}, {302, <<"unavailable">>},
        {307, <<"unavailable">>}, {429, <<"unavailable">>}, {500, <<"unavailable">>}]),
    reset(network_error),
    #{<<"status">> := <<"unavailable">>} = read().

cache() ->
    reset({200, [fixture(100, 200)]}),
    os:putenv("ZED_BILLING_SESSION", "fake-browser-one"),
    One = read(), One = read(),
    1 = persistent_term:get(budget_calls),
    {Hash, _, _} = persistent_term:get(albedo_zed_budget),
    persistent_term:put(albedo_zed_budget, {Hash, erlang:monotonic_time(second) - 1, One}),
    Body = fixture(1000, 2000),
    <<A:10/binary, B/binary>> = Body,
    persistent_term:put(budget_fixture, {200, [A, B]}),
    #{<<"limit_in_cents">> := 2000} = read(),
    2 = persistent_term:get(budget_calls),
    os:putenv("ZED_BILLING_SESSION", "fake-browser-two"),
    #{<<"limit_in_cents">> := 2000} = read(),
    3 = persistent_term:get(budget_calls),
    os:unsetenv("ZED_BILLING_SESSION"),
    #{<<"status">> := <<"unconfigured">>} = read(),
    os:putenv("ZED_BILLING_SESSION", "fake-browser-two"),
    persistent_term:erase(albedo_zed_budget),
    persistent_term:put(budget_fixture, {200, [binary:copy(<<"x">>, 65537)]}),
    #{<<"status">> := <<"schema_error">>} = read(),
    true = persistent_term:get(budget_closed).

deadline() ->
    reset({200, [wait]}),
    os:putenv("ZED_BILLING_SESSION", "fake-browser-session"),
    Before = erlang:monotonic_time(millisecond),
    #{<<"status">> := <<"unavailable">>, <<"message">> := <<"Zed budget request timed out">>} = read(),
    Elapsed = erlang:monotonic_time(millisecond) - Before,
    true = Elapsed >= 10000 andalso Elapsed < 12000.

labeling() ->
    Value = albedo_zed_budget:decode(<<"{\"plan\":{\"subscription_period\":\"private-reset\"},\"email\":\"private-email\",\"current_usage\":{\"token_spend\":{\"spend_in_cents\":100,\"limit_in_cents\":200},\"edit_predictions\":{\"limit\":999}}}">>),
    #{<<"source">> := <<"Zed browser billing session (ZED_BILLING_SESSION)">>,
      <<"account_association">> := <<"Unverified:", _/binary>>,
      <<"scope">> := <<"Hosted model token spend only; edit predictions are separate">>,
      <<"reset">> := <<"Unknown; not reported by this integration">>} = Value,
    false = maps:is_key(<<"used_percent">>, Value),
    false = maps:is_key(<<"plan">>, Value),
    false = maps:is_key(<<"email">>, Value),
    Encoded = iolist_to_binary(json:encode(Value)),
    nomatch = binary:match(Encoded, [<<"private-reset">>, <<"private-email">>, <<"fake-browser">>]).
