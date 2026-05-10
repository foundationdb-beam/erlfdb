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

-module(erlfdb_subspace_SUITE).

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
    create_basic/1,
    create_with_prefix/1,
    create_from_subspace/1,
    key/1,
    pack_empty/1,
    pack_tuple/1,
    pack_with_prefix_subspace/1,
    pack_vs/1,
    unpack/1,
    unpack_wrong_subspace/1,
    range_basic/1,
    range_tuple/1,
    contains_yes/1,
    contains_no/1,
    add/1,
    subspace/1
]).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        create_basic,
        create_with_prefix,
        create_from_subspace,
        key,
        pack_empty,
        pack_tuple,
        pack_with_prefix_subspace,
        pack_vs,
        unpack,
        unpack_wrong_subspace,
        range_basic,
        range_tuple,
        contains_yes,
        contains_no,
        add,
        subspace
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

create_basic(_Config) ->
    SS = erlfdb_subspace:create({<<"ns">>}),
    Key = erlfdb_subspace:key(SS),
    ?assert(is_binary(Key)).

create_with_prefix(_Config) ->
    Prefix = <<"raw">>,
    SS = erlfdb_subspace:create({<<"x">>}, Prefix),
    Key = erlfdb_subspace:key(SS),
    ?assert(binary:match(Key, Prefix) =/= nomatch).

create_from_subspace(_Config) ->
    Parent = erlfdb_subspace:create({<<"parent">>}),
    Child = erlfdb_subspace:create(Parent, {<<"child">>}),
    ChildKey = erlfdb_subspace:key(Child),
    ParentKey = erlfdb_subspace:key(Parent),
    %% Child key must start with parent key.
    ParentLen = byte_size(ParentKey),
    ?assertEqual(ParentKey, binary:part(ChildKey, 0, ParentLen)).

key(_Config) ->
    SS = erlfdb_subspace:create({1, 2}),
    K1 = erlfdb_subspace:key(SS),
    K2 = erlfdb_subspace:pack(SS),
    ?assertEqual(K1, K2).

pack_empty(_Config) ->
    SS = erlfdb_subspace:create({<<"ns">>}),
    Packed = erlfdb_subspace:pack(SS),
    ?assertEqual(erlfdb_subspace:key(SS), Packed).

pack_tuple(_Config) ->
    SS = erlfdb_subspace:create({<<"ns">>}),
    Packed = erlfdb_subspace:pack(SS, {42}),
    Prefix = erlfdb_subspace:key(SS),
    ?assert(byte_size(Packed) > byte_size(Prefix)).

pack_with_prefix_subspace(_Config) ->
    Outer = erlfdb_subspace:create({<<"outer">>}),
    Inner = erlfdb_subspace:create(Outer, {<<"inner">>}),
    OuterPacked = erlfdb_subspace:pack(Outer, {1}),
    InnerPacked = erlfdb_subspace:pack(Inner, {1}),
    ?assertNotEqual(OuterPacked, InnerPacked),
    OuterPrefix = erlfdb_subspace:key(Outer),
    OuterLen = byte_size(OuterPrefix),
    ?assertEqual(OuterPrefix, binary:part(InnerPacked, 0, OuterLen)).

pack_vs(_Config) ->
    SS = erlfdb_subspace:create({<<"vs">>}),
    VS = {versionstamp, 16#ffffffffffffffff, 16#ffff, 16#ffff},
    Packed = erlfdb_subspace:pack_vs(SS, {VS}),
    ?assert(is_binary(Packed)).

unpack(_Config) ->
    SS = erlfdb_subspace:create({<<"ns">>}),
    Original = {<<"hello">>, 99},
    Packed = erlfdb_subspace:pack(SS, Original),
    ?assertEqual(Original, erlfdb_subspace:unpack(SS, Packed)).

unpack_wrong_subspace(_Config) ->
    SS1 = erlfdb_subspace:create({<<"ns1">>}),
    SS2 = erlfdb_subspace:create({<<"ns2">>}),
    Key = erlfdb_subspace:pack(SS1, {1}),
    ?assertError(_, erlfdb_subspace:unpack(SS2, Key)).

range_basic(_Config) ->
    SS = erlfdb_subspace:create({<<"r">>}),
    {Start, End} = erlfdb_subspace:range(SS),
    ?assert(is_binary(Start)),
    ?assert(is_binary(End)),
    ?assert(Start < End).

range_tuple(_Config) ->
    SS = erlfdb_subspace:create({<<"r">>}),
    {Start, End} = erlfdb_subspace:range(SS, {<<"prefix">>}),
    Child = erlfdb_subspace:pack(SS, {<<"prefix">>, 1}),
    ?assert(Child >= Start andalso Child < End).

contains_yes(_Config) ->
    SS = erlfdb_subspace:create({<<"ns">>}),
    Key = erlfdb_subspace:pack(SS, {1}),
    ?assert(erlfdb_subspace:contains(SS, Key)).

contains_no(_Config) ->
    SS1 = erlfdb_subspace:create({<<"ns1">>}),
    SS2 = erlfdb_subspace:create({<<"ns2">>}),
    Key = erlfdb_subspace:pack(SS1, {1}),
    ?assertNot(erlfdb_subspace:contains(SS2, Key)).

add(_Config) ->
    SS = erlfdb_subspace:create({<<"ns">>}),
    Extended = erlfdb_subspace:add(SS, <<"extra">>),
    SSKey = erlfdb_subspace:key(SS),
    ExtKey = erlfdb_subspace:key(Extended),
    SSLen = byte_size(SSKey),
    ?assertEqual(SSKey, binary:part(ExtKey, 0, SSLen)).

subspace(_Config) ->
    SS = erlfdb_subspace:create({<<"ns">>}),
    Sub = erlfdb_subspace:subspace(SS, {<<"child">>}),
    SubKey = erlfdb_subspace:key(Sub),
    SSKey = erlfdb_subspace:key(SS),
    SSLen = byte_size(SSKey),
    ?assertEqual(SSKey, binary:part(SubKey, 0, SSLen)).
