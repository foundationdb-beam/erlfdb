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

-module(erlfdb_02_anon_fdbserver_test).

-include_lib("eunit/include/eunit.hrl").

basic_init_test() ->
    {ok, ClusterFile} = erlfdb_util:init_test_cluster(erlfdb_sandbox:default_options()),
    ?assert(is_binary(ClusterFile)).

basic_open_test() ->
    {ok, ClusterFile} = erlfdb_util:init_test_cluster(erlfdb_sandbox:default_options()),
    Db = erlfdb:open(ClusterFile),
    erlfdb:transactional(Db, fun(_Tx) ->
        ?assert(true)
    end).

get_db_test() ->
    Db = erlfdb_sandbox:open(),
    erlfdb:transactional(Db, fun(_Tx) ->
        ?assert(true)
    end).

db_client_info_test() ->
    Db = erlfdb_sandbox:open(),
    Busyness = erlfdb:get_main_thread_busyness(Db),
    ?assert(is_float(Busyness)),
    Vsn = erlfdb_nif:get_default_api_version(),
    if
        Vsn >= 730 ->
            Status = erlfdb:wait(erlfdb:get_client_status(Db)),
            ?assert(is_binary(Status));
        true ->
            ok
    end.

get_set_get_test() ->
    Db = erlfdb_sandbox:open(),
    get_set_get(Db).

get_empty_test() ->
    Db = erlfdb_sandbox:open(),
    Tenant1 = erlfdb_util:create_and_open_test_tenant(Db, [empty]),
    Key = gen_key(8),
    Val = crypto:strong_rand_bytes(8),
    erlfdb:transactional(Tenant1, fun(Tx) ->
        ok = erlfdb:set(Tx, Key, Val)
    end),
    erlfdb:transactional(Tenant1, fun(Tx) ->
        ?assertEqual(Val, erlfdb:wait(erlfdb:get(Tx, Key)))
    end),

    % Check we can get an empty db
    Tenant2 = erlfdb_util:create_and_open_test_tenant(Db, [empty]),
    erlfdb:transactional(Tenant2, fun(Tx) ->
        ?assertEqual(not_found, erlfdb:wait(erlfdb:get(Tx, Key)))
    end),

    % And check state that the old db handle is
    % the same
    erlfdb:transactional(Tenant1, fun(Tx) ->
        ?assertEqual(not_found, erlfdb:wait(erlfdb:get(Tx, Key)))
    end).

get_set_get_tenant_test() ->
    Db = erlfdb_sandbox:open(),
    Tenant = erlfdb_util:create_and_open_test_tenant(Db, [empty]),
    get_set_get(Tenant),
    erlfdb_util:clear_and_delete_test_tenant(Db).

get_range_test() ->
    Db = erlfdb_sandbox:open(),
    Tenant = erlfdb_util:create_and_open_test_tenant(Db, [empty]),

    KVs = create_range(Tenant, <<"get_range_test">>, 3),

    {StartKey, EndKey} = erlfdb_tuple:range({<<"get_range_test">>}),
    GetRangeResult = erlfdb:transactional(Tenant, fun(Tx) ->
        PackedKVs = erlfdb:wait(erlfdb:get_range(Tx, StartKey, EndKey)),
        [{erlfdb_tuple:unpack(K), erlfdb_tuple:unpack(V)} || {K, V} <- PackedKVs]
    end),

    ?assertEqual(KVs, GetRangeResult),

    Vsn = erlfdb_nif:get_default_api_version(),

    if
        Vsn >= 730 ->
            Mapper = create_mapping_on_range(Tenant, <<"get_range_test">>, 1, <<"hello world">>),

            Result = erlfdb:transactional(Tenant, fun(Tx) ->
                MStartKey = erlfdb_tuple:pack({<<"get_range_test">>, 1}),
                MEndKey = erlfdb_key:strinc(MStartKey),

                [{{_PKey, _PValue}, {_SKeyBegin, _SKeyEnd}, [{_Key, Message}]}] = erlfdb:wait(
                    erlfdb:get_mapped_range(Tx, MStartKey, MEndKey, Mapper)
                ),
                Message
            end),

            ?assertEqual(<<"hello world">>, Result);
        true ->
            ok
    end.

interleaving_test() ->
    Db = erlfdb_sandbox:open(),
    Tenant = erlfdb_util:create_and_open_test_tenant(Db, [empty]),

    % Needs to be pretty large so that split points is non-trivial
    N = 5000,

    KVs = create_range(Tenant, <<"interleaving_test">>, N),
    Mapper = create_mapping_on_range(Tenant, <<"interleaving_test">>, N, <<"hello world">>),

    Vsn = erlfdb_nif:get_default_api_version(),

    [R1, R2, R3, foobar, R4] = erlfdb:transactional(Tenant, fun(Tx) ->
        % F1 is a future doing a small get_range
        F1 = erlfdb:fold_range_future(
            Tx,
            erlfdb_tuple:pack({<<"interleaving_test">>, 1}),
            erlfdb_tuple:pack({<<"interleaving_test">>, 2}),
            [{target_bytes, 1}]
        ),

        % F2 is a future with a simple get
        F2 = erlfdb:get(Tx, erlfdb_tuple:pack({<<"interleaving_test">>, 2})),

        % F3 is a future with a larger get_range
        F3 = erlfdb:fold_range_future(
            Tx,
            erlfdb_tuple:pack({<<"interleaving_test">>, 2}),
            erlfdb_tuple:pack({<<"interleaving_test">>, N + 1}),
            [{target_bytes, 1}]
        ),

        % foobar is simulating some data that was already resolved, but found
        % its way into a wait call
        Futures =
            if
                Vsn >= 730 ->
                    % F4 is a get_range with a mapper
                    F4 = erlfdb:fold_mapped_range_future(
                        Tx,
                        erlfdb_tuple:pack({<<"interleaving_test">>, 1}),
                        erlfdb_tuple:pack({<<"interleaving_test">>, N + 1}),
                        Mapper
                    ),
                    [F1, F2, F3, foobar, F4];
                true ->
                    [F1, F2, F3, foobar, vsn]
            end,

        % wait_for_all_interleaving will wait on the first round o futures and then process to
        % issue the necessary gets to the db in stages, interleaved with each other to help reduce
        % waiting on the network.
        erlfdb:wait_for_all_interleaving(Tx, Futures)
    end),

    ?assertEqual(KVs, [{erlfdb_tuple:unpack(K), erlfdb_tuple:unpack(V)} || {K, V} <- R1 ++ R3]),
    ?assertEqual({<<"interleaving_test">>, <<"B">>}, erlfdb_tuple:unpack(R2)),

    if
        Vsn >= 730 ->
            ExpectMessages = lists:duplicate(N, <<"hello world">>),
            ActualMessages = [
                Message
             || {{_PKey, _PValue}, {_SKeyBegin, _SKeyEnd}, [{_Key, Message}]} <- R4
            ],
            ?assertEqual(ExpectMessages, ActualMessages);
        true ->
            ok
    end,

    % Using range split points, issue a set of get_range operations with interleaving
    % waits (pipelined).
    SplitResult = erlfdb:transactional(Tenant, fun(Tx) ->
        erlfdb:get_range(
            Tx,
            erlfdb_tuple:pack({<<"interleaving_test">>, 1}),
            erlfdb_tuple:pack({<<"interleaving_test">>, N + 1}),
            [{wait, interleaving}, {chunk_size, 1}, {target_bytes, 1}]
        )
    end),

    SplitResult2 = [
        {erlfdb_tuple:unpack(K), erlfdb_tuple:unpack(V)}
     || {K, V} <- SplitResult
    ],

    ?assertEqual(KVs, SplitResult2).

create_range(Tenant, Label, N) ->
    KVs = [
        {{Label, X}, {Label, <<($A + X - 1)>>}}
     || X <- lists:seq(1, N)
    ],

    erlfdb:transactional(Tenant, fun(Tx) ->
        [erlfdb:set(Tx, erlfdb_tuple:pack(K), erlfdb_tuple:pack(V)) || {K, V} <- KVs]
    end),

    KVs.

create_mapping_on_range(Tenant, Label, N, Message) ->
    erlfdb:transactional(Tenant, fun(Tx) ->
        [
            erlfdb:set(Tx, erlfdb_tuple:pack({Label, <<($A + X - 1)>>, <<"msg">>}), Message)
         || X <- lists:seq(1, N)
        ]
    end),
    {Label, <<"{V[1]}">>, <<"{...}">>}.

% get_mapped_range requires the use of tuples in the keys/values so that the
% element selector syntax can be used. This test demonstrates the minimal set
% of keys necessary to exercise the feature.
get_mapped_range_minimal_test() ->
    Vsn = erlfdb_nif:get_default_api_version(),

    if
        Vsn >= 730 ->
            Db = erlfdb_sandbox:open(),
            Tenant = erlfdb_util:create_and_open_test_tenant(Db, [empty]),
            erlfdb:transactional(Tenant, fun(Tx) ->
                erlfdb:set(Tx, <<"a">>, erlfdb_tuple:pack({<<"b">>})),
                erlfdb:set(Tx, erlfdb_tuple:pack({<<"b">>}), <<"c">>)
            end),
            Result = erlfdb:transactional(Tenant, fun(Tx) ->
                erlfdb:get_mapped_range(Tx, <<"a">>, <<"b">>, {<<"{V[0]}">>, <<"{...}">>})
            end),
            ?assertEqual(
                [
                    {{<<"a">>, <<1, $b, 0>>}, {<<1, $b, 0>>, <<1, $b, 1>>}, [
                        {<<1, $b, 0>>, <<"c">>}
                    ]}
                ],
                Result
            );
        true ->
            ok
    end.

get_mapped_range_continuation_test() ->
    Vsn = erlfdb_nif:get_default_api_version(),
    if
        Vsn >= 730 ->
            N = 100,
            Db = erlfdb_sandbox:open(),
            Tenant = erlfdb_util:create_and_open_test_tenant(Db, [empty]),
            erlfdb:transactional(Tenant, fun(Tx) ->
                [
                    begin
                        erlfdb:set(
                            Tx, erlfdb_tuple:pack({<<"a">>, X}), erlfdb_tuple:pack({<<"b">>, X})
                        ),
                        erlfdb:set(
                            Tx, erlfdb_tuple:pack({<<"b">>, X}), erlfdb_tuple:pack({<<"c">>, X})
                        )
                    end
                 || X <- lists:seq(1, N)
                ]
            end),
            Result = erlfdb:transactional(Tenant, fun(Tx) ->
                {Begin, End} = erlfdb_tuple:range({<<"a">>}),
                erlfdb:get_mapped_range(Tx, Begin, End, {<<"{V[0]}">>, <<"{...}">>})
            end),
            ?assertEqual(N, length(Result));
        true ->
            ok
    end.

flush_foregone_futures_test() ->
    Db = erlfdb_sandbox:open(),
    Tenant = erlfdb_util:create_and_open_test_tenant(Db, [empty]),
    erlfdb:transactional(Tenant, fun(Tx) -> erlfdb:set(Tx, <<"hello">>, <<"world">>) end),
    erlfdb:transactional(Tenant, fun(Tx) ->
        case erlfdb:get_last_error() of
            undefined ->
                erlfdb:get(Tx, <<"hello">>),
                timer:sleep(10),
                % Fake not_committed
                erlang:error({erlfdb_error, 1020});
            _ ->
                erlfdb:wait(erlfdb:get(Tx, <<"hello">>))
        end
    end),
    Leaks = fun FlushReady(Acc) ->
        receive
            Msg = {_, ready} ->
                FlushReady([Msg | Acc])
        after 0 ->
            lists:reverse(Acc)
        end
    end(
        []
    ),

    ?assertMatch([], Leaks).

versionstamp_test() ->
    Db = erlfdb_sandbox:open(),
    Tenant = erlfdb_util:create_and_open_test_tenant(Db, [empty]),
    VsFuture = erlfdb:transactional(Tenant, fun(Tx) ->
        Key = erlfdb_tuple:pack_vs(
            {<<"vs">>, {versionstamp, 16#ffffffffffffffff, 16#ffff, 16#ffff}}
        ),
        erlfdb:set_versionstamped_key(Tx, Key, <<"test">>),
        Res = erlfdb:get_versionstamp(Tx),

        % It's important for us to exercise the "foregone future flushing" logic
        % because the future from get_versionstamp only resolves after the commit,
        % similar to the watch future.
        case erlfdb:get_last_error() of
            undefined ->
                % Fake not_committed
                erlang:error({erlfdb_error, 1020});
            _ ->
                ok
        end,
        Res
    end),
    ?assertMatch(
        [{_, <<"test">>}],
        erlfdb:transactional(Tenant, fun(Tx) ->
            {S, E} = erlfdb_tuple:range({<<"vs">>}),
            erlfdb:get_range(Tx, S, E, [{wait, true}])
        end)
    ),

    ?assert(is_binary(erlfdb:wait(VsFuture, [{timeout, 100}]))),
    ok.

watch_test() ->
    Db = erlfdb_sandbox:open(),
    Tenant = erlfdb_util:create_and_open_test_tenant(Db, [empty]),
    {erlfdb_future, MsgRef, _FRef} = erlfdb:transactional(Tenant, fun(Tx) ->
        erlfdb:set(Tx, <<"hello_watch">>, <<"foo">>),
        erlfdb:watch(Tx, <<"hello_watch">>)
    end),
    erlfdb:transactional(Tenant, fun(Tx) -> erlfdb:set(Tx, <<"hello_watch">>, <<"bar">>) end),
    receive
        {MsgRef, ready} ->
            ?assertMatch(
                <<"bar">>,
                erlfdb:transactional(Tenant, fun(Tx) ->
                    erlfdb:wait(erlfdb:get(Tx, <<"hello_watch">>))
                end)
            )
    after 1000 ->
        error(timeout)
    end.

watch_cancel_test() ->
    Db = erlfdb_sandbox:open(),
    Tenant = erlfdb_util:create_and_open_test_tenant(Db, [empty]),
    Future =
        {erlfdb_future, MsgRef, _FRef} = erlfdb:transactional(Tenant, fun(Tx) ->
            erlfdb:set(Tx, <<"hello_watch">>, <<"foo">>),
            erlfdb:watch(Tx, <<"hello_watch">>)
        end),
    ok = erlfdb:cancel(Future, [{flush, true}]),
    erlfdb:transactional(Tenant, fun(Tx) -> erlfdb:set(Tx, <<"hello_watch">>, <<"bar">>) end),
    receive
        {MsgRef, ready} ->
            error(unexpected_ready)
    after 100 ->
        ok
    end.

watch_to_test() ->
    Db = erlfdb_sandbox:open(),
    Tenant = erlfdb_util:create_and_open_test_tenant(Db, [empty]),

    ResultRef = make_ref(),
    Self = self(),
    Pid = spawn_link(fun() ->
        fun Loop(MsgRef) ->
            receive
                {NewRef, new} ->
                    Loop(NewRef);
                {MsgRef, ready} ->
                    Result = erlfdb:transactional(Tenant, fun(Tx) ->
                        erlfdb:wait(erlfdb:get(Tx, <<"hello_watch">>))
                    end),
                    Self ! {ResultRef, Result}
            after 1000 ->
                error(timeout)
            end
        end(
            undefined
        )
    end),

    {erlfdb_future, MsgRef, _FRef} = erlfdb:transactional(Tenant, fun(Tx) ->
        erlfdb:set(Tx, <<"hello_watch">>, <<"foo">>),
        erlfdb:watch(Tx, <<"hello_watch">>, [{to, Pid}])
    end),
    Pid ! {MsgRef, new},

    erlfdb:transactional(Tenant, fun(Tx) -> erlfdb:set(Tx, <<"hello_watch">>, <<"bar">>) end),

    receive
        {ResultRef, Result} ->
            ?assertMatch(<<"bar">>, Result)
    after 2000 ->
        error(timeout)
    end.

range_iterator_test() ->
    Db = erlfdb_sandbox:open(),
    Tenant = erlfdb_util:create_and_open_test_tenant(Db, [empty]),
    KVs = create_range(Tenant, <<"range_iterator_test">>, 3),
    {StartKey, EndKey} = erlfdb_tuple:range({<<"range_iterator_test">>}),

    UnpackRows = fun(R) ->
        [{erlfdb_tuple:unpack(K), erlfdb_tuple:unpack(V)} || {K, V} <- R]
    end,

    % Single-page GetRange
    ?assertMatch(
        KVs,
        erlfdb:transactional(Tenant, fun(Tx) ->
            Iterator = erlfdb_range_iterator:start(Tx, StartKey, EndKey, []),
            {halt, [Rows], Iterator1} = erlfdb_iterator:next(Iterator),
            erlfdb_iterator:stop(Iterator1),
            UnpackRows(Rows)
        end)
    ),

    % Reverse GetRange - returned page is reversed, this is consistent with the FDB API
    ?assertEqual(
        lists:reverse(lists:sublist(KVs, 2, 2)),
        erlfdb:transactional(Tenant, fun(Tx) ->
            Iterator = erlfdb_range_iterator:start(Tx, StartKey, EndKey, [
                {limit, 2}, {reverse, true}
            ]),
            {halt, [Rows], Iterator1} = erlfdb_iterator:next(Iterator),
            erlfdb_iterator:stop(Iterator1),
            UnpackRows(Rows)
        end)
    ),

    % Multi-page GetRange
    ?assertMatch(
        KVs,
        erlfdb:transactional(Tenant, fun(Tx) ->
            Iterator = erlfdb_range_iterator:start(Tx, StartKey, EndKey, [{target_bytes, 1}]),
            {cont, [[Row1]], Iterator1} = erlfdb_iterator:next(Iterator),
            {cont, [[Row2]], Iterator2} = erlfdb_iterator:next(Iterator1),
            {cont, [[Row3]], Iterator3} = erlfdb_iterator:next(Iterator2),
            {halt, Iterator4} = erlfdb_iterator:next(Iterator3),
            erlfdb_iterator:stop(Iterator4),
            UnpackRows([Row1, Row2, Row3])
        end)
    ),

    % Run
    ?assertMatch(
        KVs,
        erlfdb:transactional(Tenant, fun(Tx) ->
            Iterator = erlfdb_range_iterator:start(Tx, StartKey, EndKey),
            {[Rows], Iterator1} = erlfdb_iterator:run(Iterator),
            ok = erlfdb_iterator:stop(Iterator1),
            UnpackRows(Rows)
        end)
    ),

    % Pipeline
    ?assertMatch(
        KVs,
        erlfdb:transactional(Tenant, fun(Tx) ->
            IteratorA = erlfdb_range_iterator:start(Tx, StartKey, EndKey, [{target_bytes, 1}]),
            IteratorB = erlfdb_range_iterator:start(Tx, StartKey, EndKey),
            [{[[RowA1], [RowA2], [RowA3]], IteratorA1}, {[RowsB], IteratorB1}] = erlfdb_iterator:pipeline(
                [IteratorA, IteratorB]
            ),
            ok = erlfdb_iterator:stop(IteratorA1),
            ok = erlfdb_iterator:stop(IteratorB1),
            RowsB = RowsA = [RowA1, RowA2, RowA3],
            UnpackRows(RowsA)
        end)
    ),

    % Early Cancel
    ?assertMatch(
        ok,
        erlfdb:transactional(Tenant, fun(Tx) ->
            Iterator = erlfdb_range_iterator:start(Tx, StartKey, EndKey, [{target_bytes, 1}]),
            {cont, [[_Row1]], Iterator1} = erlfdb_iterator:next(Iterator),
            {_, State} = erlfdb_iterator:module_state(Iterator1),
            Future = erlfdb_range_iterator:get_future(State),
            true = is_tuple(Future),
            ok = erlfdb_iterator:stop(Iterator1)
        end)
    ),

    % GetMappedRange
    Vsn = erlfdb_nif:get_default_api_version(),

    if
        Vsn >= 730 ->
            Mapper = create_mapping_on_range(
                Tenant, <<"range_iterator_test">>, 3, <<"hello world">>
            ),
            MStartKey = erlfdb_tuple:pack({<<"range_iterator_test">>, 1}),
            MEndKey = erlfdb_key:strinc(erlfdb_tuple:pack({<<"range_iterator_test">>, 3})),

            ?assertMatch(
                [<<"hello world">>, <<"hello world">>, <<"hello world">>],
                erlfdb:transactional(Tenant, fun(Tx) ->
                    Iterator = erlfdb_range_iterator:start(Tx, MStartKey, MEndKey, [
                        {mapper, erlfdb_tuple:pack(Mapper)}, {target_bytes, 10}
                    ]),
                    {cont, [[{{_PKey, _PValue}, {_SKeyBegin, _SKeyEnd}, [{_Key, Message1}]}]],
                        Iterator1} = erlfdb_iterator:next(
                        Iterator
                    ),
                    {cont, [[{{_PKey1, _PValue1}, {_SKeyBegin1, _SKeyEnd1}, [{_Key1, Message2}]}]],
                        Iterator2} = erlfdb_iterator:next(Iterator1),
                    {cont, [[{{_PKey2, _PValue2}, {_SKeyBegin2, _SKeyEnd2}, [{_Key2, Message3}]}]],
                        Iterator3} = erlfdb_iterator:next(Iterator2),
                    {halt, Iterator4} = erlfdb_iterator:next(Iterator3),
                    erlfdb_iterator:stop(Iterator4),
                    [Message1, Message2, Message3]
                end)
            );
        true ->
            ok
    end.

%% erlfdb_directory_cache tests

directory_cache_create_or_open_test() ->
    Db = erlfdb_sandbox:open(),
    Tenant = erlfdb_util:create_and_open_test_tenant(Db, [empty]),
    Root = erlfdb_directory:root(),
    Table = erlfdb_directory_cache:new(dir_cache_create_or_open),
    Path = [<<"dir_cache_create_or_open">>],

    Node = erlfdb_directory_cache:create_or_open(Table, Tenant, Root, Path),
    ?assertEqual([{utf8, <<"dir_cache_create_or_open">>}], erlfdb_directory:get_path(Node)).

directory_cache_open_returns_cached_node_test() ->
    Db = erlfdb_sandbox:open(),
    Tenant = erlfdb_util:create_and_open_test_tenant(Db, [empty]),
    Root = erlfdb_directory:root(),
    Table = erlfdb_directory_cache:new(dir_cache_open_cached),
    Path = [<<"dir_cache_open_cached">>],

    % Seed the directory in FDB, then open twice via cache.
    erlfdb_directory:create_or_open(Tenant, Root, Path),
    Node1 = erlfdb_directory_cache:open(Table, Tenant, Root, Path),
    Node2 = erlfdb_directory_cache:open(Table, Tenant, Root, Path),

    % Both calls must return the same term — the second is a cache hit.
    ?assertEqual(Node1, Node2).

directory_cache_invalidate_test() ->
    Db = erlfdb_sandbox:open(),
    Tenant = erlfdb_util:create_and_open_test_tenant(Db, [empty]),
    Root = erlfdb_directory:root(),
    Table = erlfdb_directory_cache:new(dir_cache_invalidate),
    Path = [<<"dir_cache_invalidate">>],

    Node1 = erlfdb_directory_cache:create_or_open(Table, Tenant, Root, Path),

    % Evict and re-resolve from FDB — should get an equivalent node.
    erlfdb_directory_cache:invalidate(Table, Root, Path),
    Node2 = erlfdb_directory_cache:create_or_open(Table, Tenant, Root, Path),

    ?assertEqual(erlfdb_directory:get_name(Node1), erlfdb_directory:get_name(Node2)),
    ?assertEqual(erlfdb_directory:get_path(Node1), erlfdb_directory:get_path(Node2)).

directory_cache_open_missing_test() ->
    Db = erlfdb_sandbox:open(),
    Tenant = erlfdb_util:create_and_open_test_tenant(Db, [empty]),
    Root = erlfdb_directory:root(),
    Table = erlfdb_directory_cache:new(dir_cache_open_missing),
    Path = [<<"dir_cache_open_missing_nonexistent">>],

    ?assertError(
        {erlfdb_directory, {open_error, path_missing, _}},
        erlfdb_directory_cache:open(Table, Tenant, Root, Path)
    ).

directory_cache_purge_all_test() ->
    Db = erlfdb_sandbox:open(),
    Tenant = erlfdb_util:create_and_open_test_tenant(Db, [empty]),
    Root = erlfdb_directory:root(),
    Table = erlfdb_directory_cache:new(dir_cache_purge_all),

    erlfdb_directory_cache:create_or_open(Table, Tenant, Root, [<<"purge_all_a">>]),
    erlfdb_directory_cache:create_or_open(Table, Tenant, Root, [<<"purge_all_b">>]),
    ?assertEqual(2, ets:info(Table, size)),

    erlfdb_directory_cache:purge(Table),
    ?assertEqual(0, ets:info(Table, size)).

directory_cache_purge_ttl_test() ->
    Db = erlfdb_sandbox:open(),
    Tenant = erlfdb_util:create_and_open_test_tenant(Db, [empty]),
    Root = erlfdb_directory:root(),
    Table = erlfdb_directory_cache:new(dir_cache_purge_ttl),

    erlfdb_directory_cache:create_or_open(Table, Tenant, Root, [<<"purge_ttl_old">>]),
    timer:sleep(50),
    erlfdb_directory_cache:create_or_open(Table, Tenant, Root, [<<"purge_ttl_new">>]),
    ?assertEqual(2, ets:info(Table, size)),

    % Purge entries older than 25ms — the first entry is ~50ms old, the second is fresh.
    erlfdb_directory_cache:purge(Table, 25),
    ?assertEqual(1, ets:info(Table, size)),

    % The surviving entry must be the recently-cached one.
    Surviving = erlfdb_directory_cache:open(Table, Tenant, Root, [<<"purge_ttl_new">>]),
    ?assertEqual([{utf8, <<"purge_ttl_new">>}], erlfdb_directory:get_path(Surviving)).

directory_cache_purge_keeps_fresh_test() ->
    Db = erlfdb_sandbox:open(),
    Tenant = erlfdb_util:create_and_open_test_tenant(Db, [empty]),
    Root = erlfdb_directory:root(),
    Table = erlfdb_directory_cache:new(dir_cache_purge_fresh),

    erlfdb_directory_cache:create_or_open(Table, Tenant, Root, [<<"purge_fresh">>]),

    % Purge with a generous TTL — nothing should be evicted.
    erlfdb_directory_cache:purge(Table, 60000),
    ?assertEqual(1, ets:info(Table, size)).

directory_cache_store_equivalent_to_open_test() ->
    Db = erlfdb_sandbox:open(),
    Tenant = erlfdb_util:create_and_open_test_tenant(Db, [empty]),
    Root = erlfdb_directory:root(),
    Path = [<<"dir_cache_store">>],

    % Resolve the node directly from FDB (simulating post-transaction store).
    Node = erlfdb_directory:create_or_open(Tenant, Root, Path),

    % Populate the cache manually via store, then retrieve via open.
    % If store computes the same key as open_with_cache, open will hit the
    % cache and return the identical term rather than going back to FDB.
    TableA = erlfdb_directory_cache:new(dir_cache_store_a),
    erlfdb_directory_cache:store(TableA, Root, Node),
    FromCache = erlfdb_directory_cache:open(TableA, Tenant, Root, Path),
    ?assertEqual(Node, FromCache),

    % Cross-check: a cache populated by open_with_cache must also be
    % retrievable by a subsequent store-then-open round-trip.
    TableB = erlfdb_directory_cache:new(dir_cache_store_b),
    _WarmUp = erlfdb_directory_cache:open(TableB, Tenant, Root, Path),
    erlfdb_directory_cache:store(TableB, Root, Node),
    FromCacheB = erlfdb_directory_cache:open(TableB, Tenant, Root, Path),
    ?assertEqual(Node, FromCacheB).

get_set_get(DbOrTenant) ->
    Key = gen_key(8),
    Val = crypto:strong_rand_bytes(8),
    erlfdb:transactional(DbOrTenant, fun(Tx) ->
        ?assertEqual(not_found, erlfdb:wait(erlfdb:get(Tx, Key)))
    end),
    erlfdb:transactional(DbOrTenant, fun(Tx) ->
        ?assertEqual(ok, erlfdb:set(Tx, Key, Val))
    end),
    erlfdb:transactional(DbOrTenant, fun(Tx) ->
        ?assertEqual(Val, erlfdb:wait(erlfdb:get(Tx, Key)))
    end).

gen_key(Size) when is_integer(Size), Size > 1 ->
    RandBin = crypto:strong_rand_bytes(Size - 1),
    <<0, RandBin/binary>>.
