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

-module(erlfdb_range_SUITE).

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
    get_range_basic/1,
    get_range_limit/1,
    get_range_reverse/1,
    get_range_startswith/1,
    get_range_target_bytes/1,
    get_range_streaming_modes/1,
    get_range_wait_interleaving/1,
    fold_range/1,
    fold_range_future/1,
    get_range_split_points/1,
    get_mapped_range_minimal/1,
    get_mapped_range_continuation/1,
    fold_mapped_range_future/1
]).

suite() ->
    [{timetrap, {seconds, 60}}].

all() ->
    [
        get_range_basic,
        get_range_limit,
        get_range_reverse,
        get_range_startswith,
        get_range_target_bytes,
        get_range_streaming_modes,
        get_range_wait_interleaving,
        fold_range,
        fold_range_future,
        get_range_split_points,
        {group, vsn_730}
    ].

groups() ->
    [
        {vsn_730, [], [
            get_mapped_range_minimal, get_mapped_range_continuation, fold_mapped_range_future
        ]}
    ].

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

%% Insert N key-value pairs packed under the test directory.
%% Keys: {1} .. {N}, Values: <<"val_1">> .. <<"val_N">>
insert_range(Db, Config, N) ->
    KVs = [
        {erlfdb_test_util:dir_key(Config, {I}), iolist_to_binary(["val_", integer_to_list(I)])}
     || I <- lists:seq(1, N)
    ],
    erlfdb:transactional(Db, fun(Tx) ->
        [erlfdb:set(Tx, K, V) || {K, V} <- KVs]
    end),
    KVs.

dir_start_end(Config) ->
    erlfdb_test_util:dir_range(Config).

%%--------------------------------------------------------------------
%% Test cases
%%--------------------------------------------------------------------

get_range_basic(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    KVs = insert_range(Db, Config, 5),
    {Start, End} = dir_start_end(Config),
    Got = erlfdb:transactional(Db, fun(Tx) ->
        erlfdb:get_range(Tx, Start, End)
    end),
    ?assertEqual(KVs, Got).

get_range_limit(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    KVs = insert_range(Db, Config, 5),
    {Start, End} = dir_start_end(Config),
    Got = erlfdb:transactional(Db, fun(Tx) ->
        erlfdb:get_range(Tx, Start, End, [{limit, 3}])
    end),
    ?assertEqual(lists:sublist(KVs, 3), Got).

get_range_reverse(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    KVs = insert_range(Db, Config, 5),
    {Start, End} = dir_start_end(Config),
    Got = erlfdb:transactional(Db, fun(Tx) ->
        erlfdb:get_range(Tx, Start, End, [{reverse, true}])
    end),
    ?assertEqual(lists:reverse(KVs), Got).

get_range_startswith(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    %% Use a sub-prefix so we can verify only matching keys come back.
    Prefix = erlfdb_test_util:dir_key(Config, {<<"pfx">>}),
    KeyA = <<Prefix/binary, 1>>,
    KeyB = <<Prefix/binary, 2>>,
    Outside = erlfdb_test_util:dir_key(Config, {<<"other">>}),
    erlfdb:transactional(Db, fun(Tx) ->
        erlfdb:set(Tx, KeyA, <<"a">>),
        erlfdb:set(Tx, KeyB, <<"b">>),
        erlfdb:set(Tx, Outside, <<"x">>)
    end),
    Got = erlfdb:transactional(Db, fun(Tx) ->
        erlfdb:get_range_startswith(Tx, Prefix)
    end),
    ?assertEqual([{KeyA, <<"a">>}, {KeyB, <<"b">>}], Got).

get_range_target_bytes(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    KVs = insert_range(Db, Config, 5),
    {Start, End} = dir_start_end(Config),
    %% target_bytes=1 forces multiple chunks; the result must still be complete.
    Got = erlfdb:transactional(Db, fun(Tx) ->
        erlfdb:get_range(Tx, Start, End, [{target_bytes, 1}])
    end),
    ?assertEqual(KVs, Got).

get_range_streaming_modes(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    KVs = insert_range(Db, Config, 5),
    {Start, End} = dir_start_end(Config),
    Modes = [small, medium, large, serial],
    lists:foreach(
        fun(Mode) ->
            Got = erlfdb:transactional(Db, fun(Tx) ->
                erlfdb:get_range(Tx, Start, End, [{mode, Mode}])
            end),
            ?assertEqual(KVs, Got, {mode, Mode})
        end,
        Modes
    ).

get_range_wait_interleaving(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    KVs = insert_range(Db, Config, 10),
    {Start, End} = dir_start_end(Config),
    Got = erlfdb:transactional(Db, fun(Tx) ->
        erlfdb:get_range(Tx, Start, End, [{wait, interleaving}, {chunk_size, 1}, {target_bytes, 1}])
    end),
    ?assertEqual(KVs, Got).

fold_range(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    KVs = insert_range(Db, Config, 5),
    {Start, End} = dir_start_end(Config),
    %% fold_range calls Fun(KV, Acc) once per row (individual {K,V} tuples).
    Got = erlfdb:transactional(Db, fun(Tx) ->
        erlfdb:fold_range(Tx, Start, End, fun(KV, Acc) -> [KV | Acc] end, [])
    end),
    ?assertEqual(KVs, lists:reverse(Got)).

fold_range_future(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    KVs = insert_range(Db, Config, 5),
    {Start, End} = dir_start_end(Config),
    %% fold_range_wait also calls Fun(Chunk, Acc).
    Got = erlfdb:transactional(Db, fun(Tx) ->
        FF = erlfdb:fold_range_future(Tx, Start, End, []),
        erlfdb:fold_range_wait(Tx, FF, fun(Chunk, Acc) -> Acc ++ Chunk end, [])
    end),
    ?assertEqual(KVs, Got).

get_range_split_points(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    insert_range(Db, Config, 20),
    {Start, End} = dir_start_end(Config),
    SplitPoints = erlfdb:transactional(Db, fun(Tx) ->
        erlfdb:wait(erlfdb:get_range_split_points(Tx, Start, End, [{chunk_size, 5}]))
    end),
    ?assert(is_list(SplitPoints)),
    ?assert(length(SplitPoints) >= 2).

%%--------------------------------------------------------------------
%% v730 group
%%--------------------------------------------------------------------

get_mapped_range_minimal(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Prefix = erlfdb_test_util:subspace_prefix(Config),
    PK = erlfdb_test_util:dir_key(Config, {<<"a">>}),
    %% SK = erlfdb_tuple:pack({Prefix}) is the start of the prefix-tuple
    %% secondary keyspace for this test.  The mapper's {V[0]} extracts Prefix
    %% and {…} scopes the secondary scan to [SK, strinc(SK)), which contains
    %% only SK because no {Prefix, …} extension keys are written here.
    SK = erlfdb_tuple:pack({Prefix, <<"b">>}),
    erlfdb:transactional(Db, fun(Tx) ->
        erlfdb:set(Tx, PK, SK),
        erlfdb:set(Tx, SK, <<"c">>)
    end),
    Result = erlfdb:transactional(Db, fun(Tx) ->
        erlfdb:get_mapped_range(Tx, PK, erlfdb_key:strinc(PK), {<<"{V[0]}">>, <<"{...}">>})
    end),
    ?assertMatch([{{PK, _}, {_, _}, [{SK, <<"c">>}]}], Result).

get_mapped_range_continuation(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    N = 20,
    Node = erlfdb_test_util:get_dir(Config),
    Prefix = erlfdb_test_util:subspace_prefix(Config),
    erlfdb:transactional(Db, fun(Tx) ->
        [
            begin
                AK = erlfdb_test_util:dir_key(Config, {<<"a">>, X}),
                BK = erlfdb_tuple:pack({Prefix, X}),
                erlfdb:set(Tx, AK, erlfdb_tuple:pack({X})),
                erlfdb:set(Tx, BK, <<"v">>)
            end
         || X <- lists:seq(1, N)
        ]
    end),
    {Start, End} = erlfdb_directory:range(Node, {<<"a">>}),
    Result = erlfdb:transactional(Db, fun(Tx) ->
        erlfdb:get_mapped_range(Tx, Start, End, {Prefix, <<"{V[0]}">>, <<"{...}">>})
    end),
    ?assertEqual(N, length(Result)).

fold_mapped_range_future(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    N = 5,
    Node = erlfdb_test_util:get_dir(Config),
    Prefix = erlfdb_test_util:subspace_prefix(Config),
    erlfdb:transactional(Db, fun(Tx) ->
        [
            begin
                AK = erlfdb_test_util:dir_key(Config, {<<"a">>, X}),
                BK = erlfdb_tuple:pack({Prefix, X}),
                erlfdb:set(Tx, AK, erlfdb_tuple:pack({X})),
                erlfdb:set(Tx, BK, <<"v">>)
            end
         || X <- lists:seq(1, N)
        ]
    end),
    {Start, End} = erlfdb_directory:range(Node, {<<"a">>}),
    %% fold_range_wait calls Fun(Chunk, Acc) where Chunk is a list of mapped rows.
    Got = erlfdb:transactional(Db, fun(Tx) ->
        FF = erlfdb:fold_mapped_range_future(Tx, Start, End, {Prefix, <<"{V[0]}">>, <<"{...}">>}),
        erlfdb:fold_range_wait(Tx, FF, fun(Chunk, Acc) -> Acc ++ Chunk end, [])
    end),
    ?assertEqual(N, length(Got)).
