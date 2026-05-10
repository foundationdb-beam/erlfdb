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

-module(erlfdb_crud_SUITE).

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
    get_missing/1,
    set_and_get/1,
    set_on_db/1,
    clear/1,
    clear_range/1,
    clear_range_startswith/1,
    get_key_first_greater_than/1,
    get_key_first_greater_or_equal/1,
    get_key_last_less_than/1,
    get_key_last_less_or_equal/1,
    snapshot_read/1,
    snapshot_of_snapshot/1
]).

suite() ->
    [{timetrap, {seconds, 60}}].

all() ->
    [
        get_missing,
        set_and_get,
        set_on_db,
        clear,
        clear_range,
        clear_range_startswith,
        get_key_first_greater_than,
        get_key_first_greater_or_equal,
        get_key_last_less_than,
        get_key_last_less_or_equal,
        snapshot_read,
        snapshot_of_snapshot
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
%% Test cases
%%--------------------------------------------------------------------

get_missing(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Key = erlfdb_test_util:dir_key(Config, {<<"get_missing">>}),
    Result = erlfdb:transactional(Db, fun(Tx) ->
        erlfdb:wait(erlfdb:get(Tx, Key))
    end),
    ?assertEqual(not_found, Result).

set_and_get(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Key = erlfdb_test_util:dir_key(Config, {<<"key">>}),
    Val = crypto:strong_rand_bytes(16),
    erlfdb:transactional(Db, fun(Tx) ->
        ?assertEqual(not_found, erlfdb:wait(erlfdb:get(Tx, Key))),
        ok = erlfdb:set(Tx, Key, Val)
    end),
    Got = erlfdb:transactional(Db, fun(Tx) ->
        erlfdb:wait(erlfdb:get(Tx, Key))
    end),
    ?assertEqual(Val, Got).

set_on_db(Config) ->
    %% erlfdb:set/3 on a Db handle wraps in an implicit transaction.
    Db = erlfdb_test_util:get_db(Config),
    Key = erlfdb_test_util:dir_key(Config, {<<"db_key">>}),
    Val = crypto:strong_rand_bytes(8),
    ok = erlfdb:set(Db, Key, Val),
    Got = erlfdb:transactional(Db, fun(Tx) ->
        erlfdb:wait(erlfdb:get(Tx, Key))
    end),
    ?assertEqual(Val, Got).

clear(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Key = erlfdb_test_util:dir_key(Config, {<<"clr">>}),
    Val = crypto:strong_rand_bytes(8),
    erlfdb:transactional(Db, fun(Tx) -> erlfdb:set(Tx, Key, Val) end),
    erlfdb:transactional(Db, fun(Tx) -> erlfdb:clear(Tx, Key) end),
    Got = erlfdb:transactional(Db, fun(Tx) ->
        erlfdb:wait(erlfdb:get(Tx, Key))
    end),
    ?assertEqual(not_found, Got).

clear_range(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Keys = [erlfdb_test_util:dir_key(Config, {N}) || N <- lists:seq(1, 5)],
    erlfdb:transactional(Db, fun(Tx) ->
        [erlfdb:set(Tx, K, <<"v">>) || K <- Keys]
    end),
    %% Clear keys 2, 3, 4 (exclusive end on key 5)
    StartKey = erlfdb_test_util:dir_key(Config, {2}),
    EndKey = erlfdb_test_util:dir_key(Config, {5}),
    erlfdb:transactional(Db, fun(Tx) ->
        erlfdb:clear_range(Tx, StartKey, EndKey)
    end),
    %% Key 1 and 5 survive; 2-4 are gone.
    [K1, K2, K3, K4, K5] = Keys,
    erlfdb:transactional(Db, fun(Tx) ->
        ?assertEqual(<<"v">>, erlfdb:wait(erlfdb:get(Tx, K1))),
        ?assertEqual(not_found, erlfdb:wait(erlfdb:get(Tx, K2))),
        ?assertEqual(not_found, erlfdb:wait(erlfdb:get(Tx, K3))),
        ?assertEqual(not_found, erlfdb:wait(erlfdb:get(Tx, K4))),
        ?assertEqual(<<"v">>, erlfdb:wait(erlfdb:get(Tx, K5)))
    end).

clear_range_startswith(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    %% Pack with a shared prefix, plus one key outside.
    Prefix = erlfdb_test_util:dir_key(Config, {<<"pfx">>}),
    KeyA = <<Prefix/binary, "a">>,
    KeyB = <<Prefix/binary, "b">>,
    Outside = erlfdb_test_util:dir_key(Config, {<<"other">>}),
    erlfdb:transactional(Db, fun(Tx) ->
        erlfdb:set(Tx, KeyA, <<"1">>),
        erlfdb:set(Tx, KeyB, <<"2">>),
        erlfdb:set(Tx, Outside, <<"3">>)
    end),
    erlfdb:transactional(Db, fun(Tx) ->
        erlfdb:clear_range_startswith(Tx, Prefix)
    end),
    erlfdb:transactional(Db, fun(Tx) ->
        ?assertEqual(not_found, erlfdb:wait(erlfdb:get(Tx, KeyA))),
        ?assertEqual(not_found, erlfdb:wait(erlfdb:get(Tx, KeyB))),
        ?assertEqual(<<"3">>, erlfdb:wait(erlfdb:get(Tx, Outside)))
    end).

get_key_first_greater_than(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    K1 = erlfdb_test_util:dir_key(Config, {1}),
    K2 = erlfdb_test_util:dir_key(Config, {2}),
    erlfdb:transactional(Db, fun(Tx) ->
        erlfdb:set(Tx, K1, <<"a">>),
        erlfdb:set(Tx, K2, <<"b">>)
    end),
    Sel = erlfdb_key:first_greater_than(K1),
    Got = erlfdb:transactional(Db, fun(Tx) ->
        erlfdb:wait(erlfdb:get_key(Tx, Sel))
    end),
    ?assertEqual(K2, Got).

get_key_first_greater_or_equal(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    K1 = erlfdb_test_util:dir_key(Config, {1}),
    erlfdb:transactional(Db, fun(Tx) -> erlfdb:set(Tx, K1, <<"v">>) end),
    Sel = erlfdb_key:first_greater_or_equal(K1),
    Got = erlfdb:transactional(Db, fun(Tx) ->
        erlfdb:wait(erlfdb:get_key(Tx, Sel))
    end),
    ?assertEqual(K1, Got).

get_key_last_less_than(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    K1 = erlfdb_test_util:dir_key(Config, {1}),
    K2 = erlfdb_test_util:dir_key(Config, {2}),
    erlfdb:transactional(Db, fun(Tx) ->
        erlfdb:set(Tx, K1, <<"a">>),
        erlfdb:set(Tx, K2, <<"b">>)
    end),
    Sel = erlfdb_key:last_less_than(K2),
    Got = erlfdb:transactional(Db, fun(Tx) ->
        erlfdb:wait(erlfdb:get_key(Tx, Sel))
    end),
    ?assertEqual(K1, Got).

get_key_last_less_or_equal(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    K1 = erlfdb_test_util:dir_key(Config, {1}),
    K2 = erlfdb_test_util:dir_key(Config, {2}),
    erlfdb:transactional(Db, fun(Tx) ->
        erlfdb:set(Tx, K1, <<"a">>),
        erlfdb:set(Tx, K2, <<"b">>)
    end),
    Sel = erlfdb_key:last_less_or_equal(K2),
    Got = erlfdb:transactional(Db, fun(Tx) ->
        erlfdb:wait(erlfdb:get_key(Tx, Sel))
    end),
    ?assertEqual(K2, Got).

snapshot_read(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Key = erlfdb_test_util:dir_key(Config, {<<"snap">>}),
    Val = crypto:strong_rand_bytes(8),
    erlfdb:transactional(Db, fun(Tx) -> erlfdb:set(Tx, Key, Val) end),
    erlfdb:transactional(Db, fun(Tx) ->
        %% get_ss reads via snapshot read.
        ?assertEqual(Val, erlfdb:wait(erlfdb:get_ss(Tx, Key))),
        %% snapshot/1 returns a snapshot handle; reads from it are also snapshot reads.
        Ss = erlfdb:snapshot(Tx),
        ?assertEqual(Val, erlfdb:wait(erlfdb:get(Ss, Key)))
    end).

snapshot_of_snapshot(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Key = erlfdb_test_util:dir_key(Config, {<<"snap2">>}),
    Val = crypto:strong_rand_bytes(8),
    erlfdb:transactional(Db, fun(Tx) -> erlfdb:set(Tx, Key, Val) end),
    erlfdb:transactional(Db, fun(Tx) ->
        Ss = erlfdb:snapshot(Tx),
        %% snapshot/1 on a snapshot must return the same snapshot object.
        ?assertEqual(Ss, erlfdb:snapshot(Ss)),
        ?assertEqual(Val, erlfdb:wait(erlfdb:get(Ss, Key)))
    end).
