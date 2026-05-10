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

-module(erlfdb_tenant_SUITE).

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
    create_and_get_tenant/1,
    create_duplicate/1,
    delete_tenant/1,
    list_tenants/1,
    open_tenant/1,
    tenant_crud/1,
    tenant_isolation/1
]).

suite() ->
    [{timetrap, {seconds, 60}}].

all() ->
    [
        create_and_get_tenant,
        create_duplicate,
        delete_tenant,
        list_tenants,
        open_tenant,
        tenant_crud,
        tenant_isolation
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

%% Directory isolation for key namespace; tenants themselves are the thing
%% under test and are created/destroyed within each case.
init_per_testcase(TestCase, Config) ->
    erlfdb_test_util:make_dir(?MODULE, TestCase, Config).

end_per_testcase(_TestCase, Config) ->
    erlfdb_test_util:remove_dir(Config).

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

make_tenant(Db, Name) ->
    erlfdb_tenant_management:create_tenant(Db, Name).

%% Clears all tenant data before deleting — required because FDB rejects
%% deletion of a non-empty tenant (error 2133).
drop_tenant(Db, Name) ->
    erlfdb_util:clear_and_delete_tenant(Db, Name).

%%--------------------------------------------------------------------
%% Test cases
%%--------------------------------------------------------------------

create_and_get_tenant(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Name = <<"ct_tenant_create_get">>,
    make_tenant(Db, Name),
    try
        Result = erlfdb_tenant_management:get_tenant(Db, Name),
        %% get_tenant returns either the binary metadata or not_found.
        ?assertNotEqual(not_found, Result)
    after
        drop_tenant(Db, Name)
    end.

create_duplicate(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Name = <<"ct_tenant_dup">>,
    make_tenant(Db, Name),
    try
        %% Creating the same tenant again should raise tenant_already_exists (2132).
        ?assertError(
            {erlfdb_error, 2132},
            erlfdb_tenant_management:create_tenant(Db, Name)
        )
    after
        drop_tenant(Db, Name)
    end.

delete_tenant(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Name = <<"ct_tenant_delete">>,
    make_tenant(Db, Name),
    drop_tenant(Db, Name),
    Result = erlfdb_tenant_management:get_tenant(Db, Name),
    ?assertEqual(not_found, Result).

list_tenants(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Names = [<<"ct_list_a">>, <<"ct_list_b">>, <<"ct_list_c">>],
    [make_tenant(Db, N) || N <- Names],
    try
        Listed = erlfdb_tenant_management:list_tenants(Db),
        ListedNames = [N || {N, _V} <- Listed],
        lists:foreach(
            fun(Name) ->
                ?assert(lists:member(Name, ListedNames), {missing, Name})
            end,
            Names
        )
    after
        [drop_tenant(Db, N) || N <- Names]
    end.

open_tenant(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Name = <<"ct_tenant_open">>,
    make_tenant(Db, Name),
    try
        Tenant = erlfdb:open_tenant(Db, Name),
        ?assertMatch({erlfdb_tenant, _}, Tenant)
    after
        drop_tenant(Db, Name)
    end.

tenant_crud(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Name = <<"ct_tenant_crud">>,
    make_tenant(Db, Name),
    try
        Tenant = erlfdb:open_tenant(Db, Name),
        Key = erlfdb_test_util:dir_key(Config, {<<"k">>}),
        Val = <<"hello">>,
        erlfdb:transactional(Tenant, fun(Tx) -> erlfdb:set(Tx, Key, Val) end),
        Got = erlfdb:transactional(Tenant, fun(Tx) ->
            erlfdb:wait(erlfdb:get(Tx, Key))
        end),
        ?assertEqual(Val, Got),
        erlfdb:transactional(Tenant, fun(Tx) -> erlfdb:clear(Tx, Key) end),
        Gone = erlfdb:transactional(Tenant, fun(Tx) ->
            erlfdb:wait(erlfdb:get(Tx, Key))
        end),
        ?assertEqual(not_found, Gone)
    after
        drop_tenant(Db, Name)
    end.

tenant_isolation(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    NameA = <<"ct_tenant_iso_a">>,
    NameB = <<"ct_tenant_iso_b">>,
    make_tenant(Db, NameA),
    make_tenant(Db, NameB),
    try
        TenantA = erlfdb:open_tenant(Db, NameA),
        TenantB = erlfdb:open_tenant(Db, NameB),
        Key = <<"shared_key">>,
        erlfdb:transactional(TenantA, fun(Tx) -> erlfdb:set(Tx, Key, <<"in_A">>) end),
        %% Key must not be visible in tenant B.
        GotB = erlfdb:transactional(TenantB, fun(Tx) ->
            erlfdb:wait(erlfdb:get(Tx, Key))
        end),
        ?assertEqual(not_found, GotB)
    after
        drop_tenant(Db, NameA),
        drop_tenant(Db, NameB)
    end.
