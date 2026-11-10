-module(albedo_session_cost).
-export([estimate/2, estimate_rows/2]).

estimate(Catalog, Rows) ->
    try estimate_rows(albedo_models:prices(Catalog), Rows)
    catch _:_ -> none end.

estimate_rows(Prices, Rows) ->
    try {some, lists:foldl(fun(Row, Total) -> Total + row(Prices, Row) end,
                          0.0, Rows)}
    catch throw:unknown -> none end.

%% Rows: profile, ledger provider ("protocol:base-url"), model, token counts,
%% outcome and the number of identical requests.
row(Prices, Tuple) when is_tuple(Tuple) -> row(Prices, tuple_to_list(Tuple));
%% A failed attempt without reported usage was rejected before metering.
row(_, [_, _, _, Input, _, _, _, _, Output, <<"error">>, _])
  when not is_integer(Input), not is_integer(Output) -> 0.0;
row(Prices, [Profile, Endpoint, Model, Input, Cached0, Created0, W50, W10, Output, _, Count])
  when is_integer(Input), Input >= 0, is_integer(Output), Output >= 0 ->
    Cached = tokens(Cached0), Created = tokens(Created0),
    W5 = tokens(W50), W1 = tokens(W10),
    Cost = tier(price(Prices, Profile, Endpoint, Model), Input),
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

tokens(N) when is_integer(N), N >= 0 -> N;
tokens(N) when N =:= undefined; N =:= null -> 0;
tokens(_) -> throw(unknown).

charge(_, _, 0) -> 0.0;
charge(Cost, Key, Tokens) ->
    case maps:get(Key, Cost, unknown) of
        Rate when is_number(Rate), Rate >= 0 -> Tokens * Rate;
        _ -> throw(unknown)
    end.

%% Candidate catalog providers in order: the profile name, the provider serving
%% the request endpoint, then the model vendor's public API. Subscription
%% transports put the public API first because their catalog rates may be zero.
price(Prices, Profile, Endpoint, Model) ->
    Normalized = string:lowercase(Model),
    Canonical = vendor(Normalized),
    {Host, Path} = endpoint(Endpoint),
    Served = served(Host, Path),
    Own = [P || P <- [Profile, Served], is_binary(P)],
    Candidates = case subscription(Profile, Host, Path) of
        true -> [Canonical | Own];
        false -> Own ++ [Canonical]
    end,
    first_price(Prices, [C || C <- Candidates, is_binary(C)], Normalized).

first_price(Prices, [Provider | Rest], Model) ->
    case find_price(Prices, Provider, Model) of
        {ok, Cost} -> Cost;
        error -> first_price(Prices, Rest, Model)
    end;
first_price(Prices, [], Model) ->
    unique_price([C || {{_, M}, C} <- maps:to_list(Prices), string:lowercase(M) =:= Model]).

vendor(<<"claude-", _/binary>>) -> <<"anthropic">>;
vendor(<<"gpt-", _/binary>>) -> <<"openai">>;
vendor(<<"o1", _/binary>>) -> <<"openai">>;
vendor(<<"o3", _/binary>>) -> <<"openai">>;
vendor(<<"o4", _/binary>>) -> <<"openai">>;
vendor(<<"gemini-", _/binary>>) -> <<"google">>;
vendor(<<"deepseek-", _/binary>>) -> <<"deepseek">>;
vendor(<<"glm-", _/binary>>) -> <<"zai">>;
vendor(<<"kimi-", _/binary>>) -> <<"moonshotai">>;
vendor(<<"minimax-", _/binary>>) -> <<"minimax">>;
vendor(_) -> undefined.

endpoint(Endpoint) when is_binary(Endpoint) ->
    Url = case binary:split(Endpoint, <<":">>) of
        [Protocol, Rest] when Protocol =/= <<"http">>, Protocol =/= <<"https">> -> Rest;
        _ -> Endpoint
    end,
    case uri_string:parse(Url) of
        #{host := Host} = Parsed when is_binary(Host) ->
            {string:lowercase(Host), maps:get(path, Parsed, <<>>)};
        _ -> {<<>>, <<>>}
    end;
endpoint(_) -> {<<>>, <<>>}.

served(<<"api.anthropic.com">>, _) -> <<"anthropic">>;
served(<<"api.openai.com">>, _) -> <<"openai">>;
served(<<"openrouter.ai">>, _) -> <<"openrouter">>;
served(<<"opencode.ai">>, Path) ->
    case binary:match(Path, <<"/go/">>) of
        nomatch -> <<"opencode">>;
        _ -> <<"opencode-go">>
    end;
served(_, _) -> undefined.

subscription(Profile, Host, Path) ->
    lists:member(Profile, [<<"claude">>, <<"codex">>, <<"zed">>, <<"opencode-go">>])
        orelse lists:member(Host, [<<"chatgpt.com">>, <<"cloud.zed.dev">>])
        orelse served(Host, Path) =:= <<"opencode-go">>.

find_price(Prices, Provider, Model) ->
    case maps:find({Provider, Model}, Prices) of
        {ok, _} = Found -> Found;
        error ->
            case lists:usort([C || {{P, M}, C} <- maps:to_list(Prices),
                                  P =:= Provider, string:lowercase(M) =:= Model]) of
                [Cost] -> {ok, Cost};
                _ -> error
            end
    end.

unique_price(Costs) ->
    case lists:usort(Costs) of
        [Cost] -> Cost;
        _ -> throw(unknown)
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
