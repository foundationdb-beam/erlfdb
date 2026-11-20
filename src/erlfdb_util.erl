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

-module(erlfdb_util).

-define(DOCATTRS, ?OTP_RELEASE >= 27).

-if(?DOCATTRS).
-moduledoc hidden.
-endif.

-export([
    fdbcli/1,

    get_test_db/0,
    get_test_db/1,

    init_test_cluster/1,

    get/2,
    get/3,

    repr/1,

    debug_cluster/1,
    debug_cluster/3
]).

% Some systems are unable to compute the shared machine id without root,
% so we'll provide a hardcoded machine id for our managed fdbserver
-define(TEST_CLUSTER_MACHINE_ID, ?MODULE_STRING).

get_test_db() ->
    get_test_db([]).

get_test_db(Options) ->
    {ok, ClusterFile} = init_test_cluster(Options),
    erlfdb:open(ClusterFile).

init_test_cluster(Options) ->
    % Hack to ensure erlfdb app environment is loaded during unit tests
    ok = application:ensure_started(erlfdb),

    {ok, CWD} = file:get_cwd(),
    DefaultDir = filename:join(CWD, ".erlfdb"),
    Dir = ?MODULE:get(Options, dir, DefaultDir),

    case application:get_env(erlfdb, test_cluster_file) of
        {ok, system_default} ->
            {ok, <<>>};
        _ ->
            case persistent_term:get({erlfdb, test_cluster_file, Dir}, undefined) of
                undefined ->
                    init_test_cluster_int(Dir, Options);
                ClusterFile ->
                    {ok, ClusterFile}
            end
    end.

get(List, Key) ->
    get(List, Key, undefined).

get(List, Key, Default) ->
    case lists:keyfind(Key, 1, List) of
        {Key, Value} -> Value;
        _ -> Default
    end.

repr(Bin) when is_binary(Bin) ->
    [$'] ++
        lists:map(
            fun(C) ->
                case C of
                    9 -> "\\t";
                    10 -> "\\n";
                    13 -> "\\r";
                    39 -> "\\'";
                    92 -> "\\\\";
                    _ when C >= 32, C =< 126 -> C;
                    _ -> io_lib:format("\\x~2.16.0b", [C])
                end
            end,
            binary_to_list(Bin)
        ) ++ [$'].

debug_cluster(Tx) ->
    debug_cluster(Tx, <<>>, <<16#FE, 16#FF, 16#FF>>).

debug_cluster(Tx, Start, End) ->
    lists:foreach(
        fun({Key, Val}) ->
            io:format(standard_error, "~s => ~s~n", [
                string:pad(erlfdb_util:repr(Key), 60),
                repr(Val)
            ])
        end,
        erlfdb:wait(erlfdb:get_range(Tx, Start, End))
    ).

init_test_cluster_int(Dir, Options) ->
    DefaultIpAddr = {127, 0, 0, 1},
    DefaultPort = get_available_port(),

    IpAddr = ?MODULE:get(Options, ip_addr, DefaultIpAddr),
    Port = ?MODULE:get(Options, port, DefaultPort),
    ClusterName = ?MODULE:get(Options, cluster_name, <<"erlfdbtest">>),
    ClusterId = ?MODULE:get(Options, cluster_id, <<"erlfdbtest">>),

    DefaultClusterFile = filename:join(Dir, <<"erlfdb.cluster">>),
    ClusterFile = ?MODULE:get(Options, cluster_file, DefaultClusterFile),

    write_cluster_file(ClusterFile, ClusterName, ClusterId, IpAddr, Port),

    FDBServerBin = find_fdbserver_bin(Options),

    {FDBPid, _} = spawn_monitor(fun() ->
        % Open the fdbserver port
        FDBPortName = {spawn_executable, FDBServerBin},
        FDBPortArgs = [
            <<"-p">>,
            ip_port_to_str(IpAddr, Port),
            <<"-C">>,
            ClusterFile,
            <<"-d">>,
            Dir,
            <<"-L">>,
            Dir,
            <<"-i">>,
            <<?TEST_CLUSTER_MACHINE_ID>>
        ],
        FDBPortOpts = [{args, FDBPortArgs}],
        FDBServer = erlang:open_port(FDBPortName, FDBPortOpts),
        {os_pid, FDBPid} = erlang:port_info(FDBServer, os_pid),

        % Open the monitor pid
        MonitorPath = get_monitor_path(),
        ErlPid = os:getpid(),

        MonitorPortName = {spawn_executable, MonitorPath},
        MonitorPortArgs = [{args, [ErlPid, integer_to_binary(FDBPid)]}],
        Monitor = erlang:open_port(MonitorPortName, MonitorPortArgs),

        init_fdb_db(ClusterFile, Options),

        receive
            {wait_for_init, ParentPid} ->
                ParentPid ! {initialized, self()}
        after 5000 ->
            true = erlang:port_close(FDBServer),
            true = erlang:port_close(Monitor),
            erlang:error(fdb_parent_died)
        end,

        port_loop(FDBServer, Monitor),

        true = erlang:port_close(FDBServer),
        true = erlang:port_close(Monitor)
    end),

    FDBPid ! {wait_for_init, self()},
    receive
        {initialized, FDBPid} ->
            ok;
        Msg ->
            erlang:error({fdbserver_error, Msg})
    end,

    persistent_term:put({erlfdb, test_cluster_file, Dir}, ClusterFile),

    {ok, ClusterFile}.

get_available_port() ->
    {ok, Socket} = gen_tcp:listen(0, []),
    {ok, Port} = inet:port(Socket),
    ok = gen_tcp:close(Socket),
    Port.

find_fdbserver_bin(Options) ->
    Locations =
        case ?MODULE:get(Options, fdbserver_bin) of
            undefined ->
                [
                    <<"/usr/sbin/fdbserver">>,
                    <<"/usr/local/bin/fdbserver">>,
                    <<"/usr/local/sbin/fdbserver">>,
                    <<"/usr/local/libexec/fdbserver">>
                ];
            Else ->
                [Else]
        end,
    case lists:filter(fun filelib:is_file/1, Locations) of
        [Path | _] -> Path;
        [] -> erlang:error(fdbserver_bin_not_found)
    end.

write_cluster_file(FileName, ClusterName, ClusterId, IpAddr, Port) ->
    Args = [ClusterName, ClusterId, ip_port_to_str(IpAddr, Port)],
    Contents = io_lib:format("~s:~s@~s~n", Args),
    ok = filelib:ensure_dir(FileName),
    ok = file:write_file(FileName, iolist_to_binary(Contents)).

get_monitor_path() ->
    PrivDir =
        case code:priv_dir(erlfdb) of
            {error, _} ->
                EbinDir = filename:dirname(code:which(?MODULE)),
                AppPath = filename:dirname(EbinDir),
                filename:join(AppPath, "priv");
            Path ->
                Path
        end,
    filename:join(PrivDir, "monitor.py").

% Look for fdbcli on PATH, but also check /usr/local/bin explicitly
% since that is the common location.
fdbcli(Options) ->
    case ?MODULE:get(Options, fdbcli_bin, false) of
        false ->
            case os:find_executable("fdbcli") of
                false ->
                    case os:find_executable("fdbcli", "/usr/local/bin") of
                        false ->
                            erlang:error(fdbcli_not_found);
                        Exec ->
                            Exec
                    end;
                _Exec ->
                    "fdbcli"
            end;
        C ->
            C
    end.

init_fdb_db(ClusterFile, Options) ->
    FDBCli = fdbcli(Options),
    Storage = get_storage(),
    Fmt =
        "~s -C ~s --exec \"configure new single ~s\"",
    Cmd = lists:flatten(io_lib:format(Fmt, [FDBCli, ClusterFile, Storage])),
    case os:cmd(Cmd) of
        "Database created" ++ _ -> ok;
        "ERROR: Database already exists!" ++ _ -> ok;
        Msg -> erlang:error({fdb_init_error, Msg})
    end.

get_storage() ->
    Vsn = erlfdb_nif:get_max_api_version(),
    if
        Vsn >= 730 ->
            "ssd-redwood-1";
        true ->
            "ssd"
    end.

port_loop(FDBServer, Monitor) ->
    receive
        close ->
            ok;
        {FDBServer, {data, "ZoneId set to " ?TEST_CLUSTER_MACHINE_ID ", dcId to [not set]\n"}} ->
            % Silence start message
            port_loop(FDBServer, Monitor);
        {FDBServer, {data, "FDBD joined cluster.\n"}} ->
            % Silence start message
            port_loop(FDBServer, Monitor);
        {Port, {data, Msg}} when Port == FDBServer orelse Port == Monitor ->
            io:format(standard_error, "~p", [Msg]),
            port_loop(FDBServer, Monitor);
        Error ->
            erlang:exit({fdb_cluster_error, Error})
    end.

ip_port_to_str({I1, I2, I3, I4}, Port) ->
    Fmt = "~b.~b.~b.~b:~b",
    iolist_to_binary(io_lib:format(Fmt, [I1, I2, I3, I4, Port])).
