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
    Vsn = erlfdb_nif:get_max_api_version(),
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

    Vsn = erlfdb_nif:get_max_api_version(),

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

    Vsn = erlfdb_nif:get_max_api_version(),

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
    Vsn = erlfdb_nif:get_max_api_version(),

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
    Vsn = erlfdb_nif:get_max_api_version(),
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
    after 1000 ->
        error(timeout)
    end.

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
