-module(jms).

-export([start/0]).

-define(CF, <<"/Users/jstimpson/dev/ex_fdbmonitor/.ex_fdbmonitor/dev.0/etc/fdb.cluster">>).

start() ->
    Db = erlfdb:open(?CF),
    N = 11000,
    io:format("Setting keys~n"),
    [erlfdb:set(Db, erlfdb_tuple:pack({<<"foo">>, X}), <<"bar">>) || X <- lists:seq(1, N)],
    io:format("Creating watches~n"),
    Watches = [erlfdb:watch(Db, erlfdb_tuple:pack({<<"foo">>, X})) || X <- lists:seq(1, N)],
    Watches.
