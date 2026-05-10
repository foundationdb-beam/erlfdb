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

-module(erlfdb_atomic_SUITE).

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
    add/1,
    bit_and/1,
    bit_or/1,
    bit_xor/1,
    min/1,
    max/1,
    byte_min/1,
    byte_max/1,
    set_versionstamped_key/1,
    set_versionstamped_value/1,
    get_versionstamp/1
]).

suite() ->
    [{timetrap, {seconds, 60}}].

all() ->
    [
        add,
        bit_and,
        bit_or,
        bit_xor,
        min,
        max,
        byte_min,
        byte_max,
        set_versionstamped_key,
        set_versionstamped_value,
        get_versionstamp
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

%% FDB atomic ops operate on little-endian integers.
encode_le64(N) ->
    <<N:64/little-unsigned>>.

decode_le64(Bin) ->
    <<N:64/little-unsigned>> = Bin,
    N.

get_val(Db, Key) ->
    erlfdb:transactional(Db, fun(Tx) ->
        erlfdb:wait(erlfdb:get(Tx, Key))
    end).

%%--------------------------------------------------------------------
%% Test cases
%%--------------------------------------------------------------------

add(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Key = erlfdb_test_util:dir_key(Config, {<<"add">>}),
    %% Seed with 10.
    erlfdb:transactional(Db, fun(Tx) -> erlfdb:set(Tx, Key, encode_le64(10)) end),
    erlfdb:transactional(Db, fun(Tx) -> erlfdb:add(Tx, Key, encode_le64(5)) end),
    ?assertEqual(15, decode_le64(get_val(Db, Key))).

bit_and(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Key = erlfdb_test_util:dir_key(Config, {<<"bit_and">>}),
    erlfdb:transactional(Db, fun(Tx) -> erlfdb:set(Tx, Key, encode_le64(2#1111)) end),
    erlfdb:transactional(Db, fun(Tx) -> erlfdb:bit_and(Tx, Key, encode_le64(2#1010)) end),
    ?assertEqual(2#1010, decode_le64(get_val(Db, Key))).

bit_or(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Key = erlfdb_test_util:dir_key(Config, {<<"bit_or">>}),
    erlfdb:transactional(Db, fun(Tx) -> erlfdb:set(Tx, Key, encode_le64(2#0101)) end),
    erlfdb:transactional(Db, fun(Tx) -> erlfdb:bit_or(Tx, Key, encode_le64(2#1010)) end),
    ?assertEqual(2#1111, decode_le64(get_val(Db, Key))).

bit_xor(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Key = erlfdb_test_util:dir_key(Config, {<<"bit_xor">>}),
    erlfdb:transactional(Db, fun(Tx) -> erlfdb:set(Tx, Key, encode_le64(2#1100)) end),
    erlfdb:transactional(Db, fun(Tx) -> erlfdb:bit_xor(Tx, Key, encode_le64(2#1010)) end),
    ?assertEqual(2#0110, decode_le64(get_val(Db, Key))).

min(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Key = erlfdb_test_util:dir_key(Config, {<<"min">>}),
    erlfdb:transactional(Db, fun(Tx) -> erlfdb:set(Tx, Key, encode_le64(10)) end),
    %% param < stored: value is replaced.
    erlfdb:transactional(Db, fun(Tx) -> erlfdb:min(Tx, Key, encode_le64(3)) end),
    ?assertEqual(3, decode_le64(get_val(Db, Key))),
    %% param > stored: value unchanged.
    erlfdb:transactional(Db, fun(Tx) -> erlfdb:min(Tx, Key, encode_le64(99)) end),
    ?assertEqual(3, decode_le64(get_val(Db, Key))).

max(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Key = erlfdb_test_util:dir_key(Config, {<<"max">>}),
    erlfdb:transactional(Db, fun(Tx) -> erlfdb:set(Tx, Key, encode_le64(10)) end),
    %% param > stored: value is replaced.
    erlfdb:transactional(Db, fun(Tx) -> erlfdb:max(Tx, Key, encode_le64(20)) end),
    ?assertEqual(20, decode_le64(get_val(Db, Key))),
    %% param < stored: value unchanged.
    erlfdb:transactional(Db, fun(Tx) -> erlfdb:max(Tx, Key, encode_le64(5)) end),
    ?assertEqual(20, decode_le64(get_val(Db, Key))).

byte_min(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Key = erlfdb_test_util:dir_key(Config, {<<"byte_min">>}),
    erlfdb:transactional(Db, fun(Tx) -> erlfdb:set(Tx, Key, <<"bbb">>) end),
    erlfdb:transactional(Db, fun(Tx) -> erlfdb:byte_min(Tx, Key, <<"aaa">>) end),
    ?assertEqual(<<"aaa">>, get_val(Db, Key)),
    erlfdb:transactional(Db, fun(Tx) -> erlfdb:byte_min(Tx, Key, <<"zzz">>) end),
    ?assertEqual(<<"aaa">>, get_val(Db, Key)).

byte_max(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Key = erlfdb_test_util:dir_key(Config, {<<"byte_max">>}),
    erlfdb:transactional(Db, fun(Tx) -> erlfdb:set(Tx, Key, <<"bbb">>) end),
    erlfdb:transactional(Db, fun(Tx) -> erlfdb:byte_max(Tx, Key, <<"zzz">>) end),
    ?assertEqual(<<"zzz">>, get_val(Db, Key)),
    erlfdb:transactional(Db, fun(Tx) -> erlfdb:byte_max(Tx, Key, <<"aaa">>) end),
    ?assertEqual(<<"zzz">>, get_val(Db, Key)).

set_versionstamped_key(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Node = erlfdb_test_util:get_dir(Config),
    %% pack_vs encodes the incomplete versionstamp and appends the 4-byte
    %% offset trailer required by fdb_transaction_atomic_op.
    VsKey = erlfdb_directory:pack_vs(
        Node,
        {<<"vs_key">>, {versionstamp, 16#ffffffffffffffff, 16#ffff, 16#ffff}}
    ),
    erlfdb:transactional(Db, fun(Tx) ->
        erlfdb:set_versionstamped_key(Tx, VsKey, <<"payload">>)
    end),
    %% After commit a key with the real versionstamp must exist in the range.
    {Start, End} = erlfdb_directory:range(Node, {<<"vs_key">>}),
    Results = erlfdb:transactional(Db, fun(Tx) ->
        erlfdb:get_range(Tx, Start, End)
    end),
    ?assertMatch([{_, <<"payload">>}], Results).

set_versionstamped_value(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Key = erlfdb_test_util:dir_key(Config, {<<"vs_val">>}),
    ValTemplate = erlfdb_tuple:pack_vs(
        {{versionstamp, 16#ffffffffffffffff, 16#ffff, 16#ffff}}
    ),
    erlfdb:transactional(Db, fun(Tx) ->
        erlfdb:set_versionstamped_value(Tx, Key, ValTemplate)
    end),
    Got = get_val(Db, Key),
    %% The value should be a non-empty binary that differs from the template.
    ?assert(is_binary(Got)),
    ?assert(byte_size(Got) > 0),
    ?assertNotEqual(ValTemplate, Got).

get_versionstamp(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Key = erlfdb_test_util:dir_key(Config, {<<"vs_future">>}),
    VsFuture = erlfdb:transactional(Db, fun(Tx) ->
        erlfdb:set(Tx, Key, <<"val">>),
        erlfdb:get_versionstamp(Tx)
    end),
    Vs = erlfdb:wait(VsFuture, [{timeout, 5000}]),
    ?assert(is_binary(Vs)),
    ?assertEqual(10, byte_size(Vs)).
