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

-module(erlfdb_directory_cache_SUITE).

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
    create_or_open/1,
    open_returns_cached_node/1,
    open_missing/1,
    invalidate/1,
    store/1,
    remove/1,
    remove_missing/1,
    remove_if_exists/1,
    remove_if_exists_missing/1,
    purge_all/1,
    purge_ttl/1,
    purge_keeps_fresh/1
]).

suite() ->
    [{timetrap, {seconds, 60}}].

all() ->
    [
        create_or_open,
        open_returns_cached_node,
        open_missing,
        invalidate,
        store,
        remove,
        remove_missing,
        remove_if_exists,
        remove_if_exists_missing,
        purge_all,
        purge_ttl,
        purge_keeps_fresh
    ].

groups() -> [].

init_per_suite(Config) ->
    erlfdb_test_util:open_sandbox(Config).

end_per_suite(_Config) ->
    ok.

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

%% Create a per-testcase ETS table and return {Table, Root, Db}.
setup(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Root = erlfdb_test_util:get_dir(Config),
    TC = proplists:get_value(tc_name, Config, unnamed),
    TableName = list_to_atom("erlfdb_dc_" ++ atom_to_list(TC)),
    Table = erlfdb_directory_cache:new(TableName),
    {Table, Root, Db}.

%%--------------------------------------------------------------------
%% Test cases
%%--------------------------------------------------------------------

create_or_open(Config) ->
    {Table, Root, Db} = setup(Config),
    Path = [{utf8, <<"mydir">>}],
    Node = erlfdb_directory_cache:create_or_open(Table, Db, Root, Path),
    ?assert(is_map(Node)),
    ?assertEqual(1, ets:info(Table, size)).

open_returns_cached_node(Config) ->
    {Table, Root, Db} = setup(Config),
    Path = [{utf8, <<"cached">>}],
    erlfdb_directory:create_or_open(Db, Root, Path),
    Node1 = erlfdb_directory_cache:open(Table, Db, Root, Path),
    Node2 = erlfdb_directory_cache:open(Table, Db, Root, Path),
    %% Second call must be a cache hit — identical term, same ETS entry.
    ?assertEqual(Node1, Node2),
    ?assertEqual(1, ets:info(Table, size)).

open_missing(Config) ->
    {Table, Root, Db} = setup(Config),
    Path = [{utf8, <<"nosuchdir">>}],
    ?assertError(
        {erlfdb_directory, {open_error, path_missing, _}},
        erlfdb_directory_cache:open(Table, Db, Root, Path)
    ).

invalidate(Config) ->
    {Table, Root, Db} = setup(Config),
    Path = [{utf8, <<"invalidated">>}],
    Node1 = erlfdb_directory_cache:create_or_open(Table, Db, Root, Path),
    erlfdb_directory_cache:invalidate(Table, Root, Path),
    ?assertEqual(0, ets:info(Table, size)),
    Node2 = erlfdb_directory_cache:create_or_open(Table, Db, Root, Path),
    %% After invalidation, re-resolve gives a node with the same id.
    ?assertEqual(erlfdb_directory:get_id(Node1), erlfdb_directory:get_id(Node2)).

store(Config) ->
    {Table, Root, Db} = setup(Config),
    Path = [{utf8, <<"stored">>}],
    Node = erlfdb_directory:create_or_open(Db, Root, Path),
    erlfdb_directory_cache:store(Table, Root, Node),
    ?assertEqual(1, ets:info(Table, size)),
    FromCache = erlfdb_directory_cache:open(Table, Db, Root, Path),
    ?assertEqual(Node, FromCache).

remove(Config) ->
    {Table, Root, Db} = setup(Config),
    Path = [{utf8, <<"removed">>}],
    erlfdb_directory_cache:create_or_open(Table, Db, Root, Path),
    ?assertEqual(1, ets:info(Table, size)),
    erlfdb_directory_cache:remove(Table, Db, Root, Path),
    ?assertEqual(0, ets:info(Table, size)),
    %% Directory is gone in FDB; opening it must raise path_missing.
    ?assertError(
        {erlfdb_directory, {open_error, path_missing, _}},
        erlfdb_directory_cache:open(Table, Db, Root, Path)
    ).

remove_missing(Config) ->
    {Table, Root, Db} = setup(Config),
    Path = [{utf8, <<"never_existed">>}],
    ?assertError(
        {erlfdb_directory, {remove_error, path_missing, _}},
        erlfdb_directory_cache:remove(Table, Db, Root, Path)
    ).

remove_if_exists(Config) ->
    {Table, Root, Db} = setup(Config),
    Path = [{utf8, <<"removed_if_exists">>}],
    erlfdb_directory_cache:create_or_open(Table, Db, Root, Path),
    ?assertEqual(1, ets:info(Table, size)),
    erlfdb_directory_cache:remove_if_exists(Table, Db, Root, Path),
    ?assertEqual(0, ets:info(Table, size)),
    ?assertError(
        {erlfdb_directory, {open_error, path_missing, _}},
        erlfdb_directory_cache:open(Table, Db, Root, Path)
    ).

remove_if_exists_missing(Config) ->
    {Table, Root, Db} = setup(Config),
    Path = [{utf8, <<"never_existed">>}],
    %% Must succeed without error when directory is absent.
    ok = erlfdb_directory_cache:remove_if_exists(Table, Db, Root, Path).

purge_all(Config) ->
    {Table, Root, Db} = setup(Config),
    erlfdb_directory_cache:create_or_open(Table, Db, Root, [{utf8, <<"a">>}]),
    erlfdb_directory_cache:create_or_open(Table, Db, Root, [{utf8, <<"b">>}]),
    ?assertEqual(2, ets:info(Table, size)),
    erlfdb_directory_cache:purge(Table),
    ?assertEqual(0, ets:info(Table, size)).

purge_ttl(Config) ->
    {Table, Root, Db} = setup(Config),
    erlfdb_directory_cache:create_or_open(Table, Db, Root, [{utf8, <<"old">>}]),
    timer:sleep(50),
    erlfdb_directory_cache:create_or_open(Table, Db, Root, [{utf8, <<"new">>}]),
    ?assertEqual(2, ets:info(Table, size)),
    %% Purge entries older than 25 ms — the first (age ~50ms) is evicted.
    erlfdb_directory_cache:purge(Table, 25),
    ?assertEqual(1, ets:info(Table, size)),
    %% The surviving entry is the recently cached one.
    Surviving = erlfdb_directory_cache:open(Table, Db, Root, [{utf8, <<"new">>}]),
    ?assert(is_map(Surviving)).

purge_keeps_fresh(Config) ->
    {Table, Root, Db} = setup(Config),
    erlfdb_directory_cache:create_or_open(Table, Db, Root, [{utf8, <<"fresh">>}]),
    erlfdb_directory_cache:purge(Table, 60000),
    ?assertEqual(1, ets:info(Table, size)).
