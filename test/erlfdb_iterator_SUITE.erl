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

-module(erlfdb_iterator_SUITE).

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
    single_page/1,
    multi_page/1,
    reverse/1,
    run/1,
    pipeline/1,
    early_cancel/1,
    mapped_single_page/1,
    mapped_multi_page/1
]).

suite() ->
    [{timetrap, {seconds, 60}}].

all() ->
    [
        single_page,
        multi_page,
        reverse,
        run,
        pipeline,
        early_cancel,
        {group, vsn_730}
    ].

groups() ->
    [{vsn_730, [], [mapped_single_page, mapped_multi_page]}].

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

insert_range(Db, Config, N) ->
    KVs = [
        {erlfdb_test_util:dir_key(Config, {I}), iolist_to_binary(["v", integer_to_list(I)])}
     || I <- lists:seq(1, N)
    ],
    erlfdb:transactional(Db, fun(Tx) ->
        [erlfdb:set(Tx, K, V) || {K, V} <- KVs]
    end),
    KVs.

unpack_rows(Rows) ->
    Rows.

%%--------------------------------------------------------------------
%% Test cases
%%--------------------------------------------------------------------

single_page(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    KVs = insert_range(Db, Config, 3),
    {Start, End} = erlfdb_test_util:dir_range(Config),
    Got = erlfdb:transactional(Db, fun(Tx) ->
        Iterator = erlfdb_range_iterator:start(Tx, Start, End, []),
        {halt, [Rows], Iterator1} = erlfdb_iterator:next(Iterator),
        ok = erlfdb_iterator:stop(Iterator1),
        unpack_rows(Rows)
    end),
    ?assertEqual(KVs, Got).

multi_page(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    KVs = insert_range(Db, Config, 3),
    {Start, End} = erlfdb_test_util:dir_range(Config),
    Got = erlfdb:transactional(Db, fun(Tx) ->
        %% target_bytes=1 forces one row per page.
        Iterator = erlfdb_range_iterator:start(Tx, Start, End, [{target_bytes, 1}]),
        {cont, [[Row1]], It1} = erlfdb_iterator:next(Iterator),
        {cont, [[Row2]], It2} = erlfdb_iterator:next(It1),
        {cont, [[Row3]], It3} = erlfdb_iterator:next(It2),
        {halt, It4} = erlfdb_iterator:next(It3),
        ok = erlfdb_iterator:stop(It4),
        [Row1, Row2, Row3]
    end),
    ?assertEqual(KVs, Got).

reverse(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    KVs = insert_range(Db, Config, 3),
    {Start, End} = erlfdb_test_util:dir_range(Config),
    Got = erlfdb:transactional(Db, fun(Tx) ->
        Iterator = erlfdb_range_iterator:start(Tx, Start, End, [
            {limit, 2}, {reverse, true}
        ]),
        {halt, [Rows], Iterator1} = erlfdb_iterator:next(Iterator),
        ok = erlfdb_iterator:stop(Iterator1),
        Rows
    end),
    ?assertEqual(lists:reverse(lists:sublist(KVs, 2, 2)), Got).

run(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    KVs = insert_range(Db, Config, 3),
    {Start, End} = erlfdb_test_util:dir_range(Config),
    Got = erlfdb:transactional(Db, fun(Tx) ->
        Iterator = erlfdb_range_iterator:start(Tx, Start, End),
        {[Rows], Iterator1} = erlfdb_iterator:run(Iterator),
        ok = erlfdb_iterator:stop(Iterator1),
        unpack_rows(Rows)
    end),
    ?assertEqual(KVs, Got).

pipeline(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    KVs = insert_range(Db, Config, 3),
    {Start, End} = erlfdb_test_util:dir_range(Config),
    Got = erlfdb:transactional(Db, fun(Tx) ->
        IterA = erlfdb_range_iterator:start(Tx, Start, End, [{target_bytes, 1}]),
        IterB = erlfdb_range_iterator:start(Tx, Start, End),
        [
            {[[RowA1], [RowA2], [RowA3]], ItA1},
            {[RowsB], ItB1}
        ] = erlfdb_iterator:pipeline([IterA, IterB]),
        ok = erlfdb_iterator:stop(ItA1),
        ok = erlfdb_iterator:stop(ItB1),
        RowsA = [RowA1, RowA2, RowA3],
        ?assertEqual(RowsA, RowsB),
        unpack_rows(RowsA)
    end),
    ?assertEqual(KVs, Got).

early_cancel(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    insert_range(Db, Config, 3),
    {Start, End} = erlfdb_test_util:dir_range(Config),
    erlfdb:transactional(Db, fun(Tx) ->
        Iterator = erlfdb_range_iterator:start(Tx, Start, End, [{target_bytes, 1}]),
        {cont, [[_Row1]], Iterator1} = erlfdb_iterator:next(Iterator),
        %% The iterator has an in-flight future; stop must cancel it cleanly.
        {_, State} = erlfdb_iterator:module_state(Iterator1),
        Future = erlfdb_range_iterator:get_future(State),
        ?assert(is_tuple(Future)),
        ok = erlfdb_iterator:stop(Iterator1)
    end).

%%--------------------------------------------------------------------
%% v730 group
%%--------------------------------------------------------------------

mapped_single_page(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    N = 3,
    Node = erlfdb_test_util:get_dir(Config),
    Prefix = erlfdb_test_util:subspace_prefix(Config),
    Mapper = erlfdb_tuple:pack({Prefix, <<"{V[0]}">>, <<"{...}">>}),
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
    Got = erlfdb:transactional(Db, fun(Tx) ->
        Iterator = erlfdb_range_iterator:start(Tx, Start, End, [{mapper, Mapper}]),
        {halt, [Rows], It1} = erlfdb_iterator:next(Iterator),
        ok = erlfdb_iterator:stop(It1),
        Rows
    end),
    ?assertEqual(N, length(Got)).

mapped_multi_page(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    N = 5,
    Node = erlfdb_test_util:get_dir(Config),
    Prefix = erlfdb_test_util:subspace_prefix(Config),
    Mapper = erlfdb_tuple:pack({Prefix, <<"{V[0]}">>, <<"{...}">>}),
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
    AllRows = erlfdb:transactional(Db, fun(Tx) ->
        Iterator = erlfdb_range_iterator:start(Tx, Start, End, [
            {mapper, Mapper}, {target_bytes, 10}
        ]),
        collect_all(Iterator, [])
    end),
    ?assertEqual(N, length(AllRows)).

collect_all(Iterator, Acc) ->
    case erlfdb_iterator:next(Iterator) of
        {halt, It1} ->
            erlfdb_iterator:stop(It1),
            lists:flatten(lists:reverse(Acc));
        {halt, [Rows], It1} ->
            erlfdb_iterator:stop(It1),
            lists:flatten(lists:reverse([Rows | Acc]));
        {cont, [Rows], It1} ->
            collect_all(It1, [Rows | Acc])
    end.
