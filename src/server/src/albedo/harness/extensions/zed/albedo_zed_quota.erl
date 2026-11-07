-module(albedo_zed_quota).
%% The one account reading a Zed inference credential can fetch about itself:
%% account-level edit-prediction usage from the identity endpoint the request
%% path already validates against. Hosted-model spend is not available through
%% the inference account credential.
-export([read/2]).

-define(URL, <<"https://cloud.zed.dev/client/users/me">>).
-define(CAP, 65536).
-define(TIMEOUT, 15000).

%% The status is data, not a driver failure: a rejected credential must become
%% the reading's own error, never a crash that hides which account failed.
read(Id, Access)
        when is_binary(Id), is_binary(Access) ->
    case safe(Id) andalso safe(Access) of
        true -> fetch(Id, Access);
        false -> {error, <<"Zed account credential is unusable">>}
    end;
read(_, _) ->
    {error, <<"Zed account credential is unavailable">>}.

fetch(Id, Access) ->
    Headers = [{<<"authorization">>, <<Id/binary, " ", Access/binary>>},
        {<<"accept">>, <<"application/json">>}, {<<"accept-encoding">>, <<"identity">>}],
    case albedo_openai_transport:open(<<"GET">>, ?URL, Headers, <<>>, ?TIMEOUT) of
        {ok, Connection} ->
            albedo_openai_transport:with_connection_discard_errors(Connection, fun() ->
                status(Connection, erlang:monotonic_time(millisecond) + ?TIMEOUT)
            end);
        _ -> {error, <<"Could not reach the Zed account service">>}
    end.

%% Any status is answered as itself; only a 200 has a body worth reading.
status(Connection, Deadline) ->
    case albedo_openai_transport:receive_until(Connection, Deadline) of
        {ok, {headers, 200, _, _}} -> body(Connection, Deadline, [], 0);
        {ok, {headers, Status, _, _}} -> {ok, {Status, <<>>}};
        _ -> {error, <<"Invalid Zed account response">>}
    end.

body(Connection, Deadline, Acc, Size) ->
    case albedo_openai_transport:receive_until(Connection, Deadline) of
        {ok, {data, Bytes, Final}} when Size + byte_size(Bytes) =< ?CAP ->
            case Final of
                false -> body(Connection, Deadline, [Bytes | Acc], Size + byte_size(Bytes));
                true -> {ok, {200, iolist_to_binary(lists:reverse([Bytes | Acc]))}}
            end;
        _ -> {error, <<"Zed account response exceeded its size or time budget">>}
    end.

%% The credential rides in a header, so each part is one printable run of its
%% own: no space, no control byte, no separator.
safe(B) when is_binary(B), byte_size(B) > 0, byte_size(B) =< 16384 ->
    re:run(B, <<"^[!-~]+$">>, [{capture, none}]) =:= match;
safe(_) -> false.
