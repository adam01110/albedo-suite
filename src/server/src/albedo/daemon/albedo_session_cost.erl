-module(albedo_session_cost).
-export([estimate/2, estimate_rows/2]).

estimate(Catalog, Rows) ->
    try estimate_rows(albedo_models:prices(Catalog), Rows)
    catch _:_ -> none end.

estimate_rows(Prices, Rows) ->
    try {some, lists:foldl(fun(Row, Total) -> Total + row(Prices, Row) end,
                          0.0, Rows)}
    catch throw:unknown -> none end.

row(Prices, Tuple) when is_tuple(Tuple) -> row(Prices, tuple_to_list(Tuple));
row(Prices, [Provider, Model, Input, Cached0, Created0, W50, W10, Output, Count])
  when is_integer(Input), Input >= 0, is_integer(Output), Output >= 0 ->
    Cached = tokens(Cached0), Created = tokens(Created0),
    W5 = tokens(W50), W1 = tokens(W10),
    Cost = tier(price(Prices, Provider, Model), Input),
    Fresh = max(0, Input - Cached - Created),
    %% An hour write costs 2x input; the catalog's write rate is the 5m rate.
    Write = case W5 + W1 of
        0 -> charge(Cost, <<"cache_write">>, Created);
        Created -> charge(Cost, <<"cache_write">>, W5) +
                   charge(Cost, <<"input">>, W1) * 2;
        _ -> throw(unknown)
    end,
    Count * (charge(Cost, <<"input">>, Fresh) +
             charge(Cost, <<"cache_read">>, Cached) + Write +
             charge(Cost, <<"output">>, Output)) / 1000000;
row(_, _) -> throw(unknown).

tokens(undefined) -> 0;
tokens(N) when is_integer(N), N >= 0 -> N;
tokens(_) -> throw(unknown).

charge(_, _, 0) -> 0.0;
charge(Cost, Key, Tokens) ->
    case maps:get(Key, Cost, unknown) of
        Rate when is_number(Rate), Rate >= 0 -> Tokens * Rate;
        _ -> throw(unknown)
    end.

price(Prices, Provider, Model) ->
    case maps:find({Provider, Model}, Prices) of
        {ok, Cost} -> Cost;
        error ->
            %% Subscription and proxy transports use the model's public API rate.
            Canonical = case Model of
                <<"claude-", _/binary>> -> <<"anthropic">>;
                <<"gpt-", _/binary>> -> <<"openai">>;
                <<"o1", _/binary>> -> <<"openai">>;
                <<"o3", _/binary>> -> <<"openai">>;
                <<"o4", _/binary>> -> <<"openai">>;
                <<"gemini-", _/binary>> -> <<"google">>;
                _ -> Provider
            end,
            case maps:find({Canonical, Model}, Prices) of
                {ok, Cost} -> Cost;
                error ->
                    case lists:usort([C || {{_, M}, C} <- maps:to_list(Prices), M =:= Model]) of
                        [Cost] -> Cost;
                        _ -> throw(unknown)
                    end
            end
    end.

tier(Cost, Input) ->
    Tiers = maps:get(<<"tiers">>, Cost, []),
    Context = lists:sort([{Size, T} ||
        #{<<"tier">> := #{<<"type">> := <<"context">>, <<"size">> := Size}} = T <- Tiers,
        is_number(Size), Input > Size]),
    case Context of
        [] when Input > 200000 -> maps:merge(Cost, maps:get(<<"context_over_200k">>, Cost, #{}));
        [] -> Cost;
        _ -> maps:merge(Cost, element(2, lists:last(Context)))
    end.
