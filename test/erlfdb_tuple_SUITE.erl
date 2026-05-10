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

-module(erlfdb_tuple_SUITE).

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
    pack_empty/1,
    pack_binary/1,
    pack_integer/1,
    pack_utf8/1,
    pack_null/1,
    pack_bool/1,
    pack_float/1,
    pack_nested/1,
    pack_with_prefix/1,
    pack_roundtrip/1,
    pack_vs/1,
    pack_vs_missing/1,
    unpack_with_prefix/1,
    range_basic/1,
    range_with_prefix/1,
    compare_equal/1,
    compare_less/1,
    compare_greater/1
]).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        pack_empty,
        pack_binary,
        pack_integer,
        pack_utf8,
        pack_null,
        pack_bool,
        pack_float,
        pack_nested,
        pack_with_prefix,
        pack_roundtrip,
        pack_vs,
        pack_vs_missing,
        unpack_with_prefix,
        range_basic,
        range_with_prefix,
        compare_equal,
        compare_less,
        compare_greater
    ].

groups() -> [].

init_per_suite(Config) -> Config.
end_per_suite(_Config) -> ok.
init_per_group(_Group, Config) -> Config.
end_per_group(_Group, _Config) -> ok.
init_per_testcase(_TestCase, Config) -> Config.
end_per_testcase(_TestCase, _Config) -> ok.

%%--------------------------------------------------------------------
%% Test cases
%%--------------------------------------------------------------------

pack_empty(_Config) ->
    Packed = erlfdb_tuple:pack({}),
    ?assertEqual({}, erlfdb_tuple:unpack(Packed)).

pack_binary(_Config) ->
    Packed = erlfdb_tuple:pack({<<"hello">>}),
    ?assertEqual({<<"hello">>}, erlfdb_tuple:unpack(Packed)).

pack_integer(_Config) ->
    lists:foreach(
        fun(N) ->
            Packed = erlfdb_tuple:pack({N}),
            ?assertEqual({N}, erlfdb_tuple:unpack(Packed))
        end,
        [0, 1, -1, 255, 256, -256, 16#7FFFFFFFFFFFFFFF, -16#7FFFFFFFFFFFFFFF]
    ).

pack_utf8(_Config) ->
    Packed = erlfdb_tuple:pack({{utf8, <<"hello"/utf8>>}}),
    {Got} = erlfdb_tuple:unpack(Packed),
    ?assertEqual({utf8, <<"hello">>}, Got).

pack_null(_Config) ->
    Packed = erlfdb_tuple:pack({null}),
    ?assertEqual({null}, erlfdb_tuple:unpack(Packed)).

pack_bool(_Config) ->
    ?assertEqual({true}, erlfdb_tuple:unpack(erlfdb_tuple:pack({true}))),
    ?assertEqual({false}, erlfdb_tuple:unpack(erlfdb_tuple:pack({false}))).

pack_float(_Config) ->
    Packed = erlfdb_tuple:pack({{float, 3.14}}),
    {{float, Got}} = erlfdb_tuple:unpack(Packed),
    ?assert(abs(Got - 3.14) < 1.0e-5).

pack_nested(_Config) ->
    Tuple = {<<"outer">>, {<<"inner">>, 42}},
    Packed = erlfdb_tuple:pack(Tuple),
    ?assertEqual(Tuple, erlfdb_tuple:unpack(Packed)).

pack_with_prefix(_Config) ->
    Prefix = <<"pfx">>,
    Packed = erlfdb_tuple:pack({<<"v">>}, Prefix),
    ?assert(binary:match(Packed, Prefix) =/= nomatch),
    ?assertEqual({<<"v">>}, erlfdb_tuple:unpack(Packed, Prefix)).

pack_roundtrip(_Config) ->
    Tuples = [
        {},
        {null},
        {true, false},
        {1, 2, 3},
        {<<"bin">>, {utf8, <<"utf">>}},
        {<<"a">>, 42, null, true}
    ],
    lists:foreach(
        fun(T) ->
            ?assertEqual(T, erlfdb_tuple:unpack(erlfdb_tuple:pack(T)))
        end,
        Tuples
    ).

pack_vs(_Config) ->
    %% An incomplete versionstamp uses all-0xFF sentinel values.
    VS = {versionstamp, 16#ffffffffffffffff, 16#ffff, 16#ffff},
    Packed = erlfdb_tuple:pack_vs({VS}),
    ?assert(is_binary(Packed)),
    %% pack_vs appends a 4-byte little-endian offset at the end.
    ?assert(byte_size(Packed) > 0).

pack_vs_missing(_Config) ->
    %% pack_vs without a versionstamp element must raise an error.
    ?assertError(
        {erlfdb_tuple_error, missing_incomplete_versionstamp},
        erlfdb_tuple:pack_vs({<<"no_vs">>})
    ).

unpack_with_prefix(_Config) ->
    Prefix = <<"pre">>,
    Packed = erlfdb_tuple:pack({1, 2}, Prefix),
    ?assertEqual({1, 2}, erlfdb_tuple:unpack(Packed, Prefix)).

range_basic(_Config) ->
    {Start, End} = erlfdb_tuple:range({<<"foo">>}),
    ?assert(is_binary(Start)),
    ?assert(is_binary(End)),
    ?assert(Start < End),
    %% Any key packed for a child tuple must fall within the range.
    Child = erlfdb_tuple:pack({<<"foo">>, 1}),
    ?assert(Child >= Start andalso Child < End).

range_with_prefix(_Config) ->
    Prefix = <<"p">>,
    {Start, End} = erlfdb_tuple:range({<<"x">>}, Prefix),
    Child = erlfdb_tuple:pack({<<"x">>, 1}, Prefix),
    ?assert(Child >= Start andalso Child < End).

compare_equal(_Config) ->
    ?assertEqual(0, erlfdb_tuple:compare({1, <<"a">>}, {1, <<"a">>})).

compare_less(_Config) ->
    ?assertEqual(-1, erlfdb_tuple:compare({1}, {2})).

compare_greater(_Config) ->
    ?assertEqual(1, erlfdb_tuple:compare({<<"b">>}, {<<"a">>})).
