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

-module(erlfdb_tx_SUITE).

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
    get_approximate_size/1,
    size_limit/1,
    size_limit_on_db/1,
    disallow_writes/1,
    allow_writes_toggle/1,
    disallow_after_write/1,
    watch_requires_writes_allowed/1,
    get_next_tx_id/1,
    get_next_tx_id_overflow/1,
    get_read_version/1,
    set_read_version/1,
    get_committed_version/1,
    is_read_only/1,
    has_watches/1,
    get_writes_allowed/1,
    add_read_conflict_key/1,
    add_write_conflict_key/1,
    add_conflict_range/1,
    get_conflicting_keys/1,
    get_estimated_range_size/1,
    get_addresses_for_key/1,
    on_error/1,
    retry_loop/1
]).

suite() ->
    [{timetrap, {seconds, 60}}].

all() ->
    [
        get_approximate_size,
        size_limit,
        size_limit_on_db,
        disallow_writes,
        allow_writes_toggle,
        disallow_after_write,
        watch_requires_writes_allowed,
        get_next_tx_id,
        get_next_tx_id_overflow,
        get_read_version,
        set_read_version,
        get_committed_version,
        is_read_only,
        has_watches,
        get_writes_allowed,
        add_read_conflict_key,
        add_write_conflict_key,
        add_conflict_range,
        get_conflicting_keys,
        get_estimated_range_size,
        get_addresses_for_key,
        on_error,
        retry_loop
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

get_approximate_size(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Key = erlfdb_test_util:dir_key(Config, {<<"sz">>}),
    erlfdb:transactional(Db, fun(Tx) ->
        ok = erlfdb:set(Tx, Key, crypto:strong_rand_bytes(5000)),
        Size1 = erlfdb:wait(erlfdb:get_approximate_size(Tx)),
        ?assert(Size1 > 5000 andalso Size1 < 6000),
        ok = erlfdb:set(Tx, Key, crypto:strong_rand_bytes(5000)),
        Size2 = erlfdb:wait(erlfdb:get_approximate_size(Tx)),
        ?assert(Size2 > 10000)
    end).

size_limit(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Key = erlfdb_test_util:dir_key(Config, {<<"sizelimit">>}),
    ?assertError(
        {erlfdb_error, 2101},
        erlfdb:transactional(Db, fun(Tx) ->
            erlfdb:set_option(Tx, size_limit, 10000),
            erlfdb:set(Tx, Key, crypto:strong_rand_bytes(11000))
        end)
    ).

size_limit_on_db(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Key = erlfdb_test_util:dir_key(Config, {<<"sizelimit_db">>}),
    erlfdb:set_option(Db, size_limit, 10000),
    ?assertError(
        {erlfdb_error, 2101},
        erlfdb:transactional(Db, fun(Tx) ->
            erlfdb:set(Tx, Key, crypto:strong_rand_bytes(11000))
        end)
    ).

disallow_writes(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Key = erlfdb_test_util:dir_key(Config, {<<"dis">>}),
    ?assertError(
        writes_not_allowed,
        erlfdb:transactional(Db, fun(Tx) ->
            erlfdb:set_option(Tx, disallow_writes),
            erlfdb:set(Tx, Key, <<"v">>)
        end)
    ).

allow_writes_toggle(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Key = erlfdb_test_util:dir_key(Config, {<<"toggle">>}),
    erlfdb:transactional(Db, fun(Tx) ->
        ?assert(erlfdb:get_writes_allowed(Tx)),
        erlfdb:set_option(Tx, disallow_writes),
        ?assertNot(erlfdb:get_writes_allowed(Tx)),
        erlfdb:set_option(Tx, allow_writes),
        ?assert(erlfdb:get_writes_allowed(Tx)),
        erlfdb:set(Tx, Key, <<"ok">>)
    end).

disallow_after_write(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Key = erlfdb_test_util:dir_key(Config, {<<"dis_after">>}),
    ?assertError(
        badarg,
        erlfdb:transactional(Db, fun(Tx) ->
            erlfdb:set(Tx, Key, <<"v">>),
            erlfdb:set_option(Tx, disallow_writes)
        end)
    ).

watch_requires_writes_allowed(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Key = erlfdb_test_util:dir_key(Config, {<<"wrwa">>}),
    ?assertError(
        writes_not_allowed,
        erlfdb:transactional(Db, fun(Tx) ->
            erlfdb:set_option(Tx, disallow_writes),
            erlfdb:watch(Tx, Key)
        end)
    ).

get_next_tx_id(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    erlfdb:transactional(Db, fun(Tx) ->
        lists:foreach(
            fun(I) -> ?assertEqual(I, erlfdb:get_next_tx_id(Tx)) end,
            lists:seq(0, 10)
        )
    end).

get_next_tx_id_overflow(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    erlfdb:transactional(Db, fun(Tx) ->
        %% get_next_tx_id uses a uint16 counter; it wraps to badarg at 65536.
        lists:foreach(
            fun(I) -> ?assertEqual(I, erlfdb:get_next_tx_id(Tx)) end,
            lists:seq(0, 65535)
        ),
        ?assertError(badarg, erlfdb:get_next_tx_id(Tx))
    end).

get_read_version(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Version = erlfdb:transactional(Db, fun(Tx) ->
        erlfdb:wait(erlfdb:get_read_version(Tx))
    end),
    ?assert(is_integer(Version)),
    ?assert(Version > 0).

set_read_version(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    %% Obtain a valid version first to avoid "past_version" errors.
    BaseVersion = erlfdb:transactional(Db, fun(Tx) ->
        erlfdb:wait(erlfdb:get_read_version(Tx))
    end),
    Got = erlfdb:transactional(Db, fun(Tx) ->
        erlfdb:set_read_version(Tx, BaseVersion),
        erlfdb:wait(erlfdb:get_read_version(Tx))
    end),
    ?assertEqual(BaseVersion, Got).

get_committed_version(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Key = erlfdb_test_util:dir_key(Config, {<<"cv">>}),
    Tx = erlfdb:create_transaction(Db),
    erlfdb:set(Tx, Key, <<"v">>),
    erlfdb:wait(erlfdb:commit(Tx)),
    Version = erlfdb:get_committed_version(Tx),
    ?assert(is_integer(Version)),
    ?assert(Version > 0).

is_read_only(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Key = erlfdb_test_util:dir_key(Config, {<<"ro">>}),
    erlfdb:transactional(Db, fun(Tx) ->
        ?assert(erlfdb:is_read_only(Tx)),
        %% A read does not make it non-read-only.
        _ = erlfdb:get(Tx, Key),
        ?assert(erlfdb:is_read_only(Tx)),
        erlfdb:set(Tx, Key, <<"v">>),
        ?assertNot(erlfdb:is_read_only(Tx))
    end).

has_watches(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Key = erlfdb_test_util:dir_key(Config, {<<"hw">>}),
    erlfdb:transactional(Db, fun(Tx) ->
        erlfdb:set(Tx, Key, <<"v">>)
    end),
    erlfdb:transactional(Db, fun(Tx) ->
        ?assertNot(erlfdb:has_watches(Tx)),
        _Watch = erlfdb:watch(Tx, Key),
        ?assert(erlfdb:has_watches(Tx))
    end).

get_writes_allowed(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    erlfdb:transactional(Db, fun(Tx) ->
        ?assert(erlfdb:get_writes_allowed(Tx)),
        erlfdb:set_option(Tx, disallow_writes),
        ?assertNot(erlfdb:get_writes_allowed(Tx))
    end).

add_read_conflict_key(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Key = erlfdb_test_util:dir_key(Config, {<<"rck">>}),
    WriteKey = erlfdb_test_util:dir_key(Config, {<<"rck_w">>}),
    erlfdb:transactional(Db, fun(Tx) -> erlfdb:set(Tx, Key, <<"init">>) end),

    %% Pin a read version for Tx1 before the concurrent write, then register
    %% Key as a read-conflict key.  Tx1 must also write something — FDB only
    %% checks conflict sets on read-write transactions.
    Tx1 = erlfdb:create_transaction(Db),
    erlfdb:wait(erlfdb:get_read_version(Tx1)),
    erlfdb:add_read_conflict_key(Tx1, Key),
    erlfdb:set(Tx1, WriteKey, <<"v">>),

    %% Concurrent writer commits after Tx1's read version.
    erlfdb:transactional(Db, fun(Tx2) -> erlfdb:set(Tx2, Key, <<"new">>) end),

    ?assertError(
        {erlfdb_error, _},
        erlfdb:wait(erlfdb:commit(Tx1))
    ).

add_write_conflict_key(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Key = erlfdb_test_util:dir_key(Config, {<<"wck">>}),
    WriteKey = erlfdb_test_util:dir_key(Config, {<<"wck_w">>}),

    %% Tx1 reads Key (establishes read-conflict on Key) and also writes
    %% something so FDB performs conflict checking.
    Tx1 = erlfdb:create_transaction(Db),
    erlfdb:wait(erlfdb:get(Tx1, Key)),
    erlfdb:set(Tx1, WriteKey, <<"v">>),

    %% Tx2 marks Key as a write-conflict key and commits after Tx1's read
    %% version.
    Tx2 = erlfdb:create_transaction(Db),
    erlfdb:add_write_conflict_key(Tx2, Key),
    erlfdb:wait(erlfdb:commit(Tx2)),

    ?assertError(
        {erlfdb_error, _},
        erlfdb:wait(erlfdb:commit(Tx1))
    ).

add_conflict_range(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    {Start, End} = erlfdb_test_util:dir_range(Config),
    WriteKey = erlfdb_test_util:dir_key(Config, {<<"cr_w">>}),

    Tx1 = erlfdb:create_transaction(Db),
    erlfdb:wait(erlfdb:get_read_version(Tx1)),
    erlfdb:add_conflict_range(Tx1, Start, End, read),
    erlfdb:set(Tx1, WriteKey, <<"v">>),

    %% Concurrent write inside the read-conflict range.
    erlfdb:transactional(Db, fun(Tx2) ->
        erlfdb:set(Tx2, erlfdb_test_util:dir_key(Config, {1}), <<"v">>)
    end),

    ?assertError(
        {erlfdb_error, _},
        erlfdb:wait(erlfdb:commit(Tx1))
    ).

get_conflicting_keys(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Key = erlfdb_test_util:dir_key(Config, {<<"ck">>}),
    WriteKey = erlfdb_test_util:dir_key(Config, {<<"ck_w">>}),
    erlfdb:transactional(Db, fun(Tx) -> erlfdb:set(Tx, Key, <<"init">>) end),

    %% Tx1 reads Key (read-conflict) and writes something (so FDB checks
    %% conflicts on commit).  report_conflicting_keys must be set before commit
    %% for get_conflicting_keys to return results.
    Tx1 = erlfdb:create_transaction(Db),
    erlfdb:set_option(Tx1, report_conflicting_keys),
    erlfdb:wait(erlfdb:get(Tx1, Key)),
    erlfdb:set(Tx1, WriteKey, <<"v">>),

    %% Concurrent write to Key after Tx1's read version.
    erlfdb:transactional(Db, fun(Tx2) -> erlfdb:set(Tx2, Key, <<"new">>) end),

    ?assertError({erlfdb_error, _}, erlfdb:wait(erlfdb:commit(Tx1))),

    %% After the failed commit, get_conflicting_keys should list Key.
    Conflicts = erlfdb:get_conflicting_keys(Tx1),
    ?assert(length(Conflicts) > 0).

get_estimated_range_size(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    [
        erlfdb:transactional(Db, fun(Tx) ->
            erlfdb:set(Tx, erlfdb_test_util:dir_key(Config, {I}), crypto:strong_rand_bytes(100))
        end)
     || I <- lists:seq(1, 5)
    ],
    {Start, End} = erlfdb_test_util:dir_range(Config),
    Size = erlfdb:transactional(Db, fun(Tx) ->
        erlfdb:wait(erlfdb:get_estimated_range_size(Tx, Start, End))
    end),
    ?assert(is_integer(Size)).

get_addresses_for_key(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Key = erlfdb_test_util:dir_key(Config, {<<"addr">>}),
    Addrs = erlfdb:get_addresses_for_key(Db, Key),
    ?assertMatch([X | _] when is_binary(X), Addrs).

on_error(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    %% 1007 = transaction_too_old — retryable
    Tx = erlfdb:create_transaction(Db),
    F = erlfdb:on_error(Tx, {erlfdb_error, 1007}),
    ?assertMatch({erlfdb_future, _, _}, F),
    erlfdb:wait(F).

retry_loop(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Key = erlfdb_test_util:dir_key(Config, {<<"retry">>}),
    Counter = counters:new(1, []),
    erlfdb:transactional(Db, fun(Tx) ->
        counters:add(Counter, 1, 1),
        Count = counters:get(Counter, 1),
        case Count of
            1 ->
                %% First attempt: read a key to set the read version, then
                %% force not_committed so the retry loop kicks in.
                erlfdb:wait(erlfdb:get(Tx, Key)),
                erlang:error({erlfdb_error, 1020});
            _ ->
                erlfdb:set(Tx, Key, <<"ok">>)
        end
    end),
    Got = erlfdb:transactional(Db, fun(Tx) ->
        erlfdb:wait(erlfdb:get(Tx, Key))
    end),
    ?assertEqual(<<"ok">>, Got),
    ?assert(counters:get(Counter, 1) >= 2).
