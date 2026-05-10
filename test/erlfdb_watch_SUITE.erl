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

-module(erlfdb_watch_SUITE).

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
    watch_fires_on_change/1,
    watch_cancel/1,
    clear_and_watch/1,
    watch_with_to_pid/1
]).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        watch_fires_on_change,
        watch_cancel,
        clear_and_watch,
        watch_with_to_pid
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

watch_fires_on_change(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Key = erlfdb_test_util:dir_key(Config, {<<"wk">>}),
    {erlfdb_future, MsgRef, _} = erlfdb:transactional(Db, fun(Tx) ->
        erlfdb:set(Tx, Key, <<"v1">>),
        erlfdb:watch(Tx, Key)
    end),
    erlfdb:transactional(Db, fun(Tx) ->
        erlfdb:set(Tx, Key, <<"v2">>)
    end),
    receive
        {MsgRef, ready} ->
            Val = erlfdb:transactional(Db, fun(Tx) ->
                erlfdb:wait(erlfdb:get(Tx, Key))
            end),
            ?assertEqual(<<"v2">>, Val)
    after 5000 ->
        error(watch_timeout)
    end.

watch_cancel(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Key = erlfdb_test_util:dir_key(Config, {<<"wkc">>}),
    Future =
        {erlfdb_future, MsgRef, _} = erlfdb:transactional(Db, fun(Tx) ->
            erlfdb:set(Tx, Key, <<"v1">>),
            erlfdb:watch(Tx, Key)
        end),
    ok = erlfdb:cancel(Future, [{flush, true}]),
    erlfdb:transactional(Db, fun(Tx) ->
        erlfdb:set(Tx, Key, <<"v2">>)
    end),
    receive
        {MsgRef, ready} ->
            error(unexpected_watch_fired)
    after 500 ->
        ok
    end.

clear_and_watch(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Key = erlfdb_test_util:dir_key(Config, {<<"caw">>}),
    erlfdb:transactional(Db, fun(Tx) -> erlfdb:set(Tx, Key, <<"v1">>) end),
    %% clear_and_watch/2 only accepts a Db handle (not a Tx).
    {erlfdb_future, MsgRef, _} = erlfdb:clear_and_watch(Db, Key),
    erlfdb:transactional(Db, fun(Tx) ->
        erlfdb:set(Tx, Key, <<"v2">>)
    end),
    receive
        {MsgRef, ready} -> ok
    after 5000 ->
        error(clear_and_watch_timeout)
    end.

watch_with_to_pid(Config) ->
    Db = erlfdb_test_util:get_db(Config),
    Key = erlfdb_test_util:dir_key(Config, {<<"wtp">>}),
    ResultRef = make_ref(),
    Self = self(),

    %% Spawn a listener that waits for the watch message.
    Listener = spawn_link(fun() ->
        fun Loop(MsgRef) ->
            receive
                {NewRef, new} ->
                    Loop(NewRef);
                {MsgRef, ready} ->
                    Val = erlfdb:transactional(Db, fun(Tx) ->
                        erlfdb:wait(erlfdb:get(Tx, Key))
                    end),
                    Self ! {ResultRef, Val}
            after 5000 ->
                error(watch_to_pid_timeout)
            end
        end(
            undefined
        )
    end),

    {erlfdb_future, MsgRef, _} = erlfdb:transactional(Db, fun(Tx) ->
        erlfdb:set(Tx, Key, <<"initial">>),
        erlfdb:watch(Tx, Key, [{to, Listener}])
    end),
    Listener ! {MsgRef, new},

    erlfdb:transactional(Db, fun(Tx) ->
        erlfdb:set(Tx, Key, <<"updated">>)
    end),

    receive
        {ResultRef, Val} ->
            ?assertEqual(<<"updated">>, Val)
    after 5000 ->
        error(watch_to_pid_result_timeout)
    end.
