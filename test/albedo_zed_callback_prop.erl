%% Property cases for the Zed browser sign-in callback. A listener answers a
%% callback only when its own key turns the encrypted user_id/access_token pair
%% into a token; `albedo_zed_auth:decrypt/3` is that gate, so these cases drive
%% it with blocks built from the PKCS#1 v1.5 type 2 layout and from OAEP-SHA256
%% and judge the answer against those formats, not against the module.
-module(albedo_zed_callback_prop).
-include_lib("public_key/include/public_key.hrl").
-export([run/0]).

-define(BLOCK, 256).
-define(RANDOM_SAMPLES, 2000).
-define(BLOCK_SAMPLES, 64).
-define(OAEP_SAMPLES, 50).
-define(ID_SAMPLES, 40).

run() ->
    {ok, _} = application:ensure_all_started(crypto),
    K = public_key:generate_key({rsa, 2048, 65537}),
    P = public(K),
    Groups = [
        {undecryptable, fun() -> undecryptable(K) end},
        {type2, fun() -> type2(K, P) end},
        {oaep, fun() -> oaep(K, P) end},
        {identifiers, fun() -> identifiers(K, P) end}
    ],
    Counts = lists:map(fun({Name, Group}) ->
        try Group() of Count -> {Name, Count}
        catch Class:Reason -> {Name, {Class, Reason}} end
    end, Groups),
    Failures = [F || {_, V} = F <- Counts, not is_integer(V)],
    Failures =:= [] orelse error({zed_callback_properties, Failures}),
    io:format("Zed callback properties passed: ~p~n", [Counts]),
    nil.

public(K) ->
    #'RSAPublicKey'{modulus = K#'RSAPrivateKey'.modulus, publicExponent = 65537}.

%% A full block encrypted without padding is exactly what the listener
%% decrypts, so building the block here keeps the oracle separate from the code
%% under test.
raw(P, Block) when byte_size(Block) =:= ?BLOCK ->
    base64:encode(public_key:encrypt_public(Block, P, [{rsa_padding, rsa_no_padding}]),
                  #{mode => urlsafe, padding => false}).

oaep_cipher(P, Message) ->
    base64:encode(public_key:encrypt_public(Message, P,
        [{rsa_padding, rsa_pkcs1_oaep_padding}, {rsa_oaep_md, sha256}, {rsa_mgf1_md, sha256}]),
        #{mode => urlsafe, padding => false}).

%% A ciphertext nobody holds a token for must be refused, whatever it decrypts
%% to: only a type 2 block is a token, and a random block carries that layout
%% about once in 65536 turns, so a run of them accepts none.
undecryptable(K) ->
    seed(1),
    Accepted = lists:foldl(fun(_, Count) ->
        Cipher = base64:encode(crypto:strong_rand_bytes(?BLOCK), #{mode => urlsafe, padding => false}),
        case albedo_zed_auth:decrypt(K, <<"7">>, Cipher) of
            {error, _} -> Count;
            {ok, _} -> Count + 1
        end
    end, 0, lists:seq(1, ?RANDOM_SAMPLES)),
    Accepted =:= 0 orelse error({accepted_random_ciphertexts, Accepted}),
    ?RANDOM_SAMPLES.

%% Valid type 2 blocks decrypt to their message; every block that breaks the
%% layout is refused, including one whose padding is too short to be legal even
%% though its separator is there.
type2(K, P) ->
    seed(2),
    Valid = [begin
        Length = rand:uniform(100),
        Message = printable(Length),
        Padding = ?BLOCK - 3 - Length,
        Block = <<0, 2, (nonzero(Padding))/binary, 0, Message/binary>>,
        case albedo_zed_auth:decrypt(K, <<"7">>, raw(P, Block)) of
            {ok, {<<"7">>, Message}} -> ok;
            Other -> error({type2_rejected, Length, Padding, Other})
        end
    end || _ <- lists:seq(1, ?BLOCK_SAMPLES)],
    Invalid = [begin
        Block = invalid_block(rand:uniform(5)),
        case albedo_zed_auth:decrypt(K, <<"7">>, raw(P, Block)) of
            {error, _} -> ok;
            Other -> error({accepted_invalid_block, Block, Other})
        end
    end || _ <- lists:seq(1, ?BLOCK_SAMPLES)],
    length(Valid) + length(Invalid).

invalid_block(1) -> <<0, 3, (nonzero(?BLOCK - 4))/binary, 0, "a">>;
invalid_block(2) -> <<1, 2, (nonzero(?BLOCK - 4))/binary, 0, "a">>;
invalid_block(3) ->
    %% Short padding and a printable message, so only the padding rule can
    %% refuse the block.
    Short = rand:uniform(7),
    <<0, 2, (nonzero(Short))/binary, 0, (printable(?BLOCK - 3 - Short))/binary>>;
invalid_block(4) -> <<0, 2, (nonzero(?BLOCK - 3))/binary, 0>>;
invalid_block(5) -> <<0, 2, (nonzero(?BLOCK - 2))/binary>>.

nonzero(Length) ->
    list_to_binary([rand:uniform(255) || _ <- lists:seq(1, Length)]).

printable(Length) ->
    list_to_binary([rand:uniform(94) + 32 || _ <- lists:seq(1, Length)]).

%% OAEP-SHA256 ciphertexts of printable tokens reach the flow as those tokens.
oaep(K, P) ->
    seed(3),
    [case albedo_zed_auth:decrypt(K, <<"7">>, oaep_cipher(P, printable(rand:uniform(64)))) of
        {ok, {<<"7">>, _}} -> ok;
        Other -> error({oaep_rejected, Other})
    end || _ <- lists:seq(1, ?OAEP_SAMPLES)],
    ?OAEP_SAMPLES.

%% The user id in a callback names the credential, so only its canonical
%% decimal form is taken: a padded or non-numeric id would store a credential
%% under a name the callback did not carry.
identifiers(K, P) ->
    seed(4),
    Cipher = raw(P, <<0, 2, (nonzero(?BLOCK - 8))/binary, 0, "token">>),
    Ids = identifier_samples(?ID_SAMPLES),
    lists:foreach(fun(Id) ->
        case {canonical(Id), albedo_zed_auth:decrypt(K, Id, Cipher)} of
            {Id, {ok, {Id, <<"token">>}}} -> ok;
            {invalid, {error, _}} -> ok;
            {Expected, Other} -> error({identifier, Id, Expected, Other})
        end
    end, Ids),
    length(Ids).

%% The id as the listener must report it back, or `invalid` when the callback
%% did not carry a positive number.
canonical(Id) ->
    try binary_to_integer(Id) of
        N when is_integer(N), N > 0 ->
            case integer_to_binary(N) of
                Id -> Id;
                _ -> invalid
            end;
        _ -> invalid
    catch _:_ -> invalid end.

identifier_samples(Count) ->
    [case rand:uniform(5) of
        1 -> integer_to_binary(rand:uniform(999999));
        2 -> <<"0", (integer_to_binary(rand:uniform(999)))/binary>>;
        3 -> list_to_binary([rand:uniform(10) - 1 + $0 || _ <- lists:seq(1, 12)]);
        4 -> integer_to_binary(rand:uniform(99));
        5 -> <<"12a">>
    end || _ <- lists:seq(1, Count)].

seed(N) ->
    rand:seed(exsss, {N * 7 + 1, N * 13 + 3, N * 29 + 5}).
