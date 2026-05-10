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

-module(erlfdb_test_util).

-export([
    open_sandbox/1,
    make_dir/3,
    remove_dir/1,
    get_db/1,
    get_dir/1,
    subspace_prefix/1,
    dir_key/2,
    dir_range/1,
    gen_key/1,
    api_version/0,
    vsn_at_least/1
]).

%% Open the sandbox database and store the handle under the key `db` in Config.
%% Call from init_per_suite/1.
open_sandbox(Config) ->
    Db = erlfdb_sandbox:open(),
    [{db, Db} | Config].

%% Create an isolated directory node for a single test case and prepend
%% `dir_node` and `dir_path` to Config.  Any leftover data from a previous
%% crashed run is removed first.  Call from init_per_testcase/2, passing
%% ?MODULE as Suite.
make_dir(Suite, TestCase, Config) ->
    Db = proplists:get_value(db, Config),
    Root = erlfdb_directory:root(),
    SuiteBin = atom_to_binary(Suite, utf8),
    TestBin = atom_to_binary(TestCase, utf8),
    Path = [<<"ct">>, SuiteBin, TestBin],
    erlfdb_directory:remove_if_exists(Db, Root, Path),
    Node = erlfdb_directory:create_or_open(Db, Root, Path),
    [{dir_node, Node}, {dir_path, Path} | Config].

%% Remove the per-testcase directory and all data under it.  Also clears the
%% prefix-tuple secondary keyspace used by getMappedRange tests (keys of the
%% form erlfdb_tuple:pack({Prefix, …}) that fall outside the directory range
%% and are not removed by erlfdb_directory:remove_if_exists).
%% Call from end_per_testcase/2.
remove_dir(Config) ->
    Db = proplists:get_value(db, Config),
    Node = proplists:get_value(dir_node, Config),
    Root = erlfdb_directory:root(),
    Path = proplists:get_value(dir_path, Config),
    Prefix = erlfdb_directory:key(Node),
    SecBegin = erlfdb_tuple:pack({Prefix}),
    SecEnd = erlfdb_key:strinc(SecBegin),
    erlfdb:transactional(Db, fun(Tx) -> erlfdb:clear_range(Tx, SecBegin, SecEnd) end),
    erlfdb_directory:remove_if_exists(Db, Root, Path).

get_db(Config) ->
    proplists:get_value(db, Config).

get_dir(Config) ->
    proplists:get_value(dir_node, Config).

%% Return the raw subspace prefix bytes for the test-case directory node.
%% Use as the first element in erlfdb_tuple:pack({Prefix, …}) secondary keys
%% for getMappedRange tests so secondary keys are scoped to this test and
%% cleaned up by remove_dir/1.
subspace_prefix(Config) ->
    erlfdb_directory:key(proplists:get_value(dir_node, Config)).

%% Pack a tuple into a key within the test-case directory.
dir_key(Config, Tuple) ->
    Node = proplists:get_value(dir_node, Config),
    erlfdb_directory:pack(Node, Tuple).

%% Return the {StartKey, EndKey} range covering the whole test-case directory.
dir_range(Config) ->
    Node = proplists:get_value(dir_node, Config),
    erlfdb_directory:range(Node).

%% Generate a random key that sorts before normal user keys (0x00 prefix).
gen_key(N) when is_integer(N), N > 1 ->
    <<0, (crypto:strong_rand_bytes(N - 1))/binary>>.

api_version() ->
    erlfdb_nif:get_default_api_version().

vsn_at_least(V) ->
    api_version() >= V.
