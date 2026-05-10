% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(erlfdb_future_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
    all/0,
    suite/0,
    groups/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_group/2,
    end_per_group/2,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    wait/1,
    wait_with_timeout/1,
    wait_for_any/1,
    wait_for_any_watch/1,
    wait_for_all/1,
    wait_for_all_interleaving/1,
    wait_for_all_interleaving_mapped/1,
    cancel_future/1,
    cancel_future_flush/1,
    foregone_future_flush/1,
    get_last_error/1,
    is_ready/1
]).

suite() ->
    [{timetrap, {seconds, 60}}].

all() ->
    [
        wait,
        wait_with_timeout,
        wait_for_any,
        wait_for_any_watch,
        wait_for_all,
        wait_for_all_interleaving,
        cancel_future,
        cancel_future_flush,
        foregone_future_flush,
        get_last_error,
        is_ready,
        {group, vsn_730}
    ].

groups() ->
    [{vsn_730, [], [wait_for_all_interleaving_mapped]}].

init_per_suite(Config) ->
    erlfdb_test_util:open_sandbox(Config).

end_per_suite(_Config) ->
    ok.

init_per_group(vsn_730, Config) ->
    case erlfdb_test_util:vsn_at_least(730) of
        true -> Config;
        false -> {skip, "requires FDB API version >= 730"}
    end;
init_per_group(_Group, Config) ->
    Config.

end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(TestCase, Config) ->
    erlfdb_test_util:make_dir(?MODULE, TestCase, Config).

end_per_testcase(_TestCase, Config) ->
    erlfdb_test_util:remove_dir(Config).

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

insert_kv(Db, Config, I, V) ->
    Key = erlfdb_test_util:dir_key(Config, {I}),
    erlfdb:transactional(Db, fun(Tx) -> erlfdb:set(Tx, Key, V) end),
    Key.

%%--------------------------------------------------------------------
%% Test cases
%%--------------------------------------------------------------------

wait(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Key = erlfdb_test_util:dir_key(Config, {<<"wt">>}),
    erlfdb:transactional(Db, fun(Tx) -> erlfdb:set(Tx, Key, <<"hello">>) end),
    Val = erlfdb:transactional(Db, fun(Tx) ->
        erlfdb:wait(erlfdb:get(Tx, Key))
    end),
    ?assertEqual(<<"hello">>, Val).

wait_with_timeout(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Key = erlfdb_test_util:dir_key(Config, {<<"wtt">>}),
    erlfdb:transactional(Db, fun(Tx) -> erlfdb:set(Tx, Key, <<"v">>) end),
    %% A generous timeout should resolve fine.
    Val = erlfdb:transactional(Db, fun(Tx) ->
        erlfdb:wait(erlfdb:get(Tx, Key), [{timeout, 5000}])
    end),
    ?assertEqual(<<"v">>, Val).

wait_for_any(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Keys = [insert_kv(Db, Config, I, <<"v">>) || I <- lists:seq(1, 3)],
    %% wait_for_any returns the winning future (not the value); use erlfdb:get/1
    %% to extract the result.  Using a raw transaction avoids the transactional
    %% retry wrapper interfering with message delivery.
    Tx = erlfdb:create_transaction(Db),
    Futures = [erlfdb:get(Tx, K) || K <- Keys],
    Winner = erlfdb:wait_for_any(Futures),
    Val = erlfdb:get(Winner),
    ?assertEqual(<<"v">>, Val).

wait_for_any_watch(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Key = erlfdb_test_util:dir_key(Config, {<<"wfa_watch">>}),
    erlfdb:transactional(Db, fun(Tx) -> erlfdb:set(Tx, Key, <<"v1">>) end),
    %% Watch futures have a plain-reference MsgRef, unlike the {{TxRef, Ref}, ready}
    %% shape of transaction futures. Confirm wait_for_any handles both.
    WatchFuture = erlfdb:transactional(Db, fun(Tx) -> erlfdb:watch(Tx, Key) end),
    %% Trigger the watch by committing a write in a separate transaction.
    erlfdb:transactional(Db, fun(Tx) -> erlfdb:set(Tx, Key, <<"v2">>) end),
    Winner = erlfdb:wait_for_any([WatchFuture]),
    ?assertEqual(WatchFuture, Winner).

wait_for_all(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    KVs = [
        {insert_kv(Db, Config, I, integer_to_binary(I)), integer_to_binary(I)}
     || I <- lists:seq(1, 5)
    ],
    Got = erlfdb:transactional(Db, fun(Tx) ->
        Futures = [erlfdb:get(Tx, K) || {K, _} <- KVs],
        erlfdb:wait_for_all(Futures)
    end),
    Expected = [V || {_, V} <- KVs],
    ?assertEqual(Expected, Got).

wait_for_all_interleaving(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    N = 50,
    KVs = [
        {erlfdb_test_util:dir_key(Config, {I}), iolist_to_binary(["v_", integer_to_list(I)])}
     || I <- lists:seq(1, N)
    ],
    erlfdb:transactional(Db, fun(Tx) ->
        [erlfdb:set(Tx, K, V) || {K, V} <- KVs]
    end),
    {Start, End} = erlfdb_test_util:dir_range(Config),
    [R1, R2, foobar] = erlfdb:transactional(Db, fun(Tx) ->
        F1 = erlfdb:fold_range_future(Tx, Start, End, [{target_bytes, 1}]),
        F2 = erlfdb:get(Tx, erlfdb_test_util:dir_key(Config, {1})),
        erlfdb:wait_for_all_interleaving(Tx, [F1, F2, foobar])
    end),
    ?assertEqual(KVs, R1),
    ?assertEqual(<<"v_1">>, R2).

wait_for_all_interleaving_mapped(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    N = 10,
    Node = erlfdb_test_util:get_dir(Config),
    Prefix = erlfdb_test_util:subspace_prefix(Config),
    erlfdb:transactional(Db, fun(Tx) ->
        [
            begin
                AK = erlfdb_directory:pack(Node, {<<"a">>, X}),
                BK = erlfdb_tuple:pack({Prefix, X}),
                erlfdb:set(Tx, AK, erlfdb_tuple:pack({X})),
                erlfdb:set(Tx, BK, <<"msg">>)
            end
         || X <- lists:seq(1, N)
        ]
    end),
    {Start, End} = erlfdb_directory:range(Node, {<<"a">>}),
    Mapper = {Prefix, <<"{V[0]}">>, <<"{...}">>},
    [MappedRows] = erlfdb:transactional(Db, fun(Tx) ->
        FF = erlfdb:fold_mapped_range_future(Tx, Start, End, Mapper),
        erlfdb:wait_for_all_interleaving(Tx, [FF])
    end),
    ?assertEqual(N, length(MappedRows)).

cancel_future(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Key = erlfdb_test_util:dir_key(Config, {<<"cf">>}),
    erlfdb:transactional(Db, fun(Tx) -> erlfdb:set(Tx, Key, <<"v">>) end),
    erlfdb:transactional(Db, fun(Tx) ->
        Future = {erlfdb_future, MsgRef, _} = erlfdb:get(Tx, Key),
        ok = erlfdb:cancel(Future),
        receive
            {MsgRef, ready} -> error(unexpected_future_ready)
        after 200 -> ok
        end
    end).

cancel_future_flush(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Key = erlfdb_test_util:dir_key(Config, {<<"cff">>}),
    erlfdb:transactional(Db, fun(Tx) -> erlfdb:set(Tx, Key, <<"v">>) end),
    {erlfdb_future, MsgRef, _FRef} = erlfdb:transactional(Db, fun(Tx) ->
        F = erlfdb:get(Tx, Key),
        %% Let it resolve so the message is in the mailbox, then cancel+flush.
        erlfdb:block_until_ready(F),
        ok = erlfdb:cancel(F, [{flush, true}]),
        F
    end),
    receive
        {MsgRef, ready} -> error(message_not_flushed)
    after 200 -> ok
    end.

foregone_future_flush(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Key = erlfdb_test_util:dir_key(Config, {<<"fff">>}),
    erlfdb:transactional(Db, fun(Tx) -> erlfdb:set(Tx, Key, <<"v">>) end),
    %% Abandon a future without waiting, simulating a retry scenario.
    erlfdb:transactional(Db, fun(Tx) ->
        case erlfdb:get_last_error() of
            undefined ->
                _ = erlfdb:get(Tx, Key),
                timer:sleep(10),
                erlang:error({erlfdb_error, 1020});
            _ ->
                erlfdb:wait(erlfdb:get(Tx, Key))
        end
    end),
    %% After the retry loop the mailbox must be clean.
    Leaks = receive_ready_messages(),
    ?assertEqual([], Leaks).

get_last_error(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Key = erlfdb_test_util:dir_key(Config, {<<"gle">>}),
    %% transactional clears the error at entry; after a clean tx it is undefined.
    erlfdb:transactional(Db, fun(_Tx) -> ok end),
    ?assertEqual(undefined, erlfdb:get_last_error()),
    %% Simulate a retryable error; on retry get_last_error returns the code.
    erlfdb:transactional(Db, fun(Tx) ->
        case erlfdb:get_last_error() of
            undefined ->
                _ = erlfdb:get(Tx, Key),
                erlang:error({erlfdb_error, 1020});
            LastErr ->
                %% get_last_error returns the raw integer error code,
                %% not an {erlfdb_error, Code} tuple.
                ?assert(is_integer(LastErr)),
                erlfdb:set(Tx, Key, <<"ok">>)
        end
    end).

is_ready(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Key = erlfdb_test_util:dir_key(Config, {<<"ir">>}),
    erlfdb:transactional(Db, fun(Tx) -> erlfdb:set(Tx, Key, <<"v">>) end),
    erlfdb:transactional(Db, fun(Tx) ->
        F = erlfdb:get(Tx, Key),
        %% is_ready may be true or false before blocking; after blocking it must be true.
        erlfdb:block_until_ready(F),
        ?assert(erlfdb:is_ready(F))
    end).

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

receive_ready_messages() ->
    receive
        {_, ready} = Msg -> [Msg | receive_ready_messages()]
    after 0 -> []
    end.
