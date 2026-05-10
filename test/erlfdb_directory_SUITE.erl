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

-module(erlfdb_directory_SUITE).

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
    create_or_open_idempotent/1,
    create/1,
    create_duplicate/1,
    open/1,
    open_missing/1,
    list/1,
    list_empty/1,
    exists/1,
    exists_missing/1,
    move/1,
    move_to/1,
    remove/1,
    remove_if_exists/1,
    remove_if_exists_missing/1,
    pack_unpack/1,
    range/1
]).

suite() ->
    [{timetrap, {seconds, 60}}].

all() ->
    [
        create_or_open,
        create_or_open_idempotent,
        create,
        create_duplicate,
        open,
        open_missing,
        list,
        list_empty,
        exists,
        exists_missing,
        move,
        move_to,
        remove,
        remove_if_exists,
        remove_if_exists_missing,
        pack_unpack,
        range
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

db(Config) -> erlfdb_test_util:get_db(Config).
root() -> erlfdb_directory:root().

%% Directory path elements are {utf8, Binary} — wrap bare names accordingly.
child_path(Config, Name) ->
    Node = erlfdb_test_util:get_dir(Config),
    Path = erlfdb_directory:get_path(Node),
    Path ++ [{utf8, Name}].

%%--------------------------------------------------------------------
%% Test cases
%%--------------------------------------------------------------------

create_or_open(Config) ->
    Db = db(Config),
    Path = child_path(Config, <<"subdir">>),
    Node = erlfdb_directory:create_or_open(Db, root(), Path),
    ?assert(is_map(Node)),
    ?assert(erlfdb_directory:exists(Db, root(), Path)).

create_or_open_idempotent(Config) ->
    Db = db(Config),
    Path = child_path(Config, <<"idem">>),
    Node1 = erlfdb_directory:create_or_open(Db, root(), Path),
    Node2 = erlfdb_directory:create_or_open(Db, root(), Path),
    ?assertEqual(erlfdb_directory:get_id(Node1), erlfdb_directory:get_id(Node2)).

create(Config) ->
    Db = db(Config),
    Path = child_path(Config, <<"newdir">>),
    Node = erlfdb_directory:create(Db, root(), Path),
    ?assert(is_map(Node)),
    ?assert(erlfdb_directory:exists(Db, root(), Path)).

create_duplicate(Config) ->
    Db = db(Config),
    Path = child_path(Config, <<"dup">>),
    erlfdb_directory:create(Db, root(), Path),
    ?assertError(_, erlfdb_directory:create(Db, root(), Path)).

open(Config) ->
    Db = db(Config),
    Path = child_path(Config, <<"existing">>),
    Created = erlfdb_directory:create(Db, root(), Path),
    Opened = erlfdb_directory:open(Db, root(), Path),
    ?assertEqual(erlfdb_directory:get_id(Created), erlfdb_directory:get_id(Opened)).

open_missing(Config) ->
    Db = db(Config),
    Path = child_path(Config, <<"nosuchdir">>),
    ?assertError(_, erlfdb_directory:open(Db, root(), Path)).

list(Config) ->
    Db = db(Config),
    Node = erlfdb_test_util:get_dir(Config),
    Names = [<<"alpha">>, <<"beta">>, <<"gamma">>],
    [erlfdb_directory:create(Db, Node, [N]) || N <- Names],
    Listed = erlfdb_directory:list(Db, Node),
    %% list/2 returns [{PathElement, Node}]; path elements are {utf8, Binary}.
    ListedNames = [N || {{utf8, N}, _} <- Listed],
    lists:foreach(
        fun(Name) ->
            ?assert(lists:member(Name, ListedNames))
        end,
        Names
    ).

list_empty(Config) ->
    Db = db(Config),
    Node = erlfdb_test_util:get_dir(Config),
    ?assertEqual([], erlfdb_directory:list(Db, Node)).

exists(Config) ->
    Db = db(Config),
    Path = child_path(Config, <<"yes">>),
    erlfdb_directory:create(Db, root(), Path),
    ?assert(erlfdb_directory:exists(Db, root(), Path)).

exists_missing(Config) ->
    Db = db(Config),
    Path = child_path(Config, <<"nope">>),
    ?assertNot(erlfdb_directory:exists(Db, root(), Path)).

move(Config) ->
    Db = db(Config),
    Node = erlfdb_test_util:get_dir(Config),
    OldPath = [{utf8, <<"old">>}],
    NewPath = [{utf8, <<"new">>}],
    erlfdb_directory:create(Db, Node, OldPath),
    _Moved = erlfdb_directory:move(Db, Node, OldPath, NewPath),
    ?assertNot(erlfdb_directory:exists(Db, Node, OldPath)),
    ?assert(erlfdb_directory:exists(Db, Node, NewPath)).

move_to(Config) ->
    Db = db(Config),
    Node = erlfdb_test_util:get_dir(Config),
    Src = erlfdb_directory:create(Db, Node, [{utf8, <<"src">>}]),
    %% move_to relocates Src to a new absolute path that must not already exist.
    NodePath = erlfdb_directory:get_path(Node),
    NewAbsPath = NodePath ++ [{utf8, <<"relocated">>}],
    Moved = erlfdb_directory:move_to(Db, Src, NewAbsPath),
    ?assertEqual(NewAbsPath, erlfdb_directory:get_path(Moved)).

remove(Config) ->
    Db = db(Config),
    Path = child_path(Config, <<"todelete">>),
    erlfdb_directory:create(Db, root(), Path),
    ?assert(erlfdb_directory:exists(Db, root(), Path)),
    erlfdb_directory:remove(Db, root(), Path),
    ?assertNot(erlfdb_directory:exists(Db, root(), Path)).

remove_if_exists(Config) ->
    Db = db(Config),
    Path = child_path(Config, <<"maybe">>),
    erlfdb_directory:create(Db, root(), Path),
    ok = erlfdb_directory:remove_if_exists(Db, root(), Path),
    ?assertNot(erlfdb_directory:exists(Db, root(), Path)).

remove_if_exists_missing(Config) ->
    Db = db(Config),
    Path = child_path(Config, <<"gone">>),
    ok = erlfdb_directory:remove_if_exists(Db, root(), Path).

pack_unpack(Config) ->
    Node = erlfdb_test_util:get_dir(Config),
    Tuple = {<<"hello">>, 42},
    Packed = erlfdb_directory:pack(Node, Tuple),
    ?assert(is_binary(Packed)),
    Unpacked = erlfdb_directory:unpack(Node, Packed),
    ?assertEqual(Tuple, Unpacked).

range(Config) ->
    Node = erlfdb_test_util:get_dir(Config),
    {Start, End} = erlfdb_directory:range(Node),
    ?assert(is_binary(Start)),
    ?assert(is_binary(End)),
    ?assert(Start < End),
    %% Subrange on a prefix.
    {S2, E2} = erlfdb_directory:range(Node, {<<"prefix">>}),
    ?assert(S2 >= Start),
    ?assert(E2 =< End).
