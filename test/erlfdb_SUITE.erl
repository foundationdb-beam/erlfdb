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

-module(erlfdb_SUITE).

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

%% Test cases
-export([
    nif_loads/1,
    get_error_string/1,
    sandbox_open/1,
    open_with_cluster_file/1,
    open_all/1,
    transactional_db/1,
    main_thread_busyness/1,
    client_status/1
]).

suite() ->
    [{timetrap, {seconds, 60}}].

all() ->
    [
        nif_loads,
        get_error_string,
        sandbox_open,
        open_with_cluster_file,
        open_all,
        transactional_db,
        main_thread_busyness,
        {group, vsn_730}
    ].

groups() ->
    [{vsn_730, [], [client_status]}].

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

%% No per-testcase directory needed: none of these tests write persistent data.
init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

%%--------------------------------------------------------------------
%% Test cases
%%--------------------------------------------------------------------

nif_loads(_Config) ->
    %% ohai/0 is a trivial NIF that returns the atom `foo`.
    %% If the NIF failed to load it would raise undef or badarg.
    foo = erlfdb_nif:ohai().

get_error_string(_Config) ->
    ?assertEqual(<<"Success">>, erlfdb_nif:get_error(0)),
    ?assertEqual(
        <<"Transaction exceeds byte limit">>,
        erlfdb_nif:get_error(2101)
    ),
    ?assertEqual(<<"UNKNOWN_ERROR">>, erlfdb_nif:get_error(9999)).

sandbox_open(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    %% A transactional call that does no I/O should succeed immediately,
    %% confirming the sandbox is reachable.
    Result = erlfdb:transactional(Db, fun(_Tx) -> ping end),
    ?assertEqual(ping, Result).

open_with_cluster_file(_Config) ->
    {ok, ClusterFile} = erlfdb_util:init_test_cluster(erlfdb_sandbox:default_options()),
    ?assert(is_binary(ClusterFile)),
    Db = erlfdb:open(ClusterFile),
    Result = erlfdb:transactional(Db, fun(_Tx) -> pong end),
    ?assertEqual(pong, Result).

open_all(_Config) ->
    {ok, ClusterFile} = erlfdb_util:init_test_cluster(erlfdb_sandbox:default_options()),
    Dbs = erlfdb:open_all(ClusterFile),
    ?assert(is_list(Dbs)),
    ?assert(length(Dbs) > 0),
    lists:foreach(
        fun(DbI) ->
            ?assertMatch({erlfdb_database, _}, DbI)
        end,
        Dbs
    ).

transactional_db(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Key = erlfdb_test_util:gen_key(8),
    Val = crypto:strong_rand_bytes(8),
    erlfdb:transactional(Db, fun(Tx) ->
        ok = erlfdb:set(Tx, Key, Val)
    end),
    Got = erlfdb:transactional(Db, fun(Tx) ->
        erlfdb:wait(erlfdb:get(Tx, Key))
    end),
    ?assertEqual(Val, Got),
    %% Clean up
    erlfdb:transactional(Db, fun(Tx) -> erlfdb:clear(Tx, Key) end).

main_thread_busyness(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Busyness = erlfdb:get_main_thread_busyness(Db),
    ?assert(is_float(Busyness)).

client_status(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Status = erlfdb:wait(erlfdb:get_client_status(Db)),
    ?assert(is_binary(Status)).
