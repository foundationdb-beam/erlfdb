-module(erlfdb_range_iterator).
-behaviour(erlfdb_iterator).

-define(DOCATTRS, ?OTP_RELEASE >= 27).

-if(?DOCATTRS).
-moduledoc """
An iterator interface over GetRange and GetMappedRange.

The iterator is an alternative implmentation to `erlfdb:get_range/4` and
`erlfdb:wait_for_all_interleaving/3`. The database mechanics are equivalent,
but the iterator allows you to control when each wait actually happens.

Remember that FoundationDB transaction execution time is limited to 5 seconds,
so you must take care not to delay your iteration.

To use the iterator,

1. `erlfdb_range_iterator:start/4`: Sends the first GetRange request to the
   database server.
2. `erlfdb_iterator.next/1`: Waits for the result of the GetRange request.
   Then issues another GetRange request to the database server.
3. `erlfdb_iterator.stop/1`: Cancels the active future, if one exists.
""".
-endif.

-export([start/3, start/4, get_future/1]).
-export([handle_next/1, handle_stop/1]).

-record(state, {
    tx,
    start_key,
    end_key,
    mapper,
    limit,
    target_bytes,
    streaming_mode,
    iteration,
    snapshot,
    reverse,
    future
}).

-type state() :: #state{}.
-type page() :: list(erlfdb:kv()) | list(erlfdb:mapped_kv()).

-export_type([page/0]).

-if(?DOCATTRS).
-doc """
Starts the iterator.

Equivalent to `start(Tx, StartKey, EndKey, [])`.
""".
-endif.
-spec start(erlfdb:transaction(), erlfdb:key(), erlfdb:key()) ->
    erlfdb_iterator:iterator().
start(Tx, StartKey, EndKey) ->
    start(Tx, StartKey, EndKey, []).

-if(?DOCATTRS).
-doc """
Starts the iterator.

Sends the first GetRange request to the database server.
""".
-endif.
-spec start(erlfdb:transaction(), erlfdb:key(), erlfdb:key(), [erlfdb:fold_option()]) ->
    erlfdb_iterator:iterator().
start(Tx, StartKey, EndKey, Options) ->
    State = new_state(Tx, StartKey, EndKey, Options),
    State1 = send_get_range(State),
    erlfdb_iterator:new(?MODULE, State1).

-spec handle_next(state()) ->
    {halt, state()} | {cont, [page()], state()}.
handle_next(State = #state{future = undefined}) ->
    {halt, State};
handle_next(State = #state{}) ->
    #state{future = Future} = State,
    Result = erlfdb:wait(Future, []),
    handle_result(Result, State).

-spec handle_stop(state()) -> ok.
handle_stop(_State = #state{future = undefined}) ->
    ok;
handle_stop(_State = #state{future = Future}) ->
    erlfdb:cancel(Future),
    ok.

-if(?DOCATTRS).
-doc """
Gets the active future from the iterator's internal state.

You needn't call this function for normal use of the iterator.
""".
-endif.
-spec get_future(state()) -> undefined | erlfdb:future().
get_future(#state{future = Future}) -> Future.

handle_result({RawRows, Count, HasMore}, State = #state{}) ->
    #state{limit = Limit} = State,
    % If our limit is within the current set of
    % rows we need to truncate the list
    Rows =
        if
            Limit == 0 orelse Limit > Count -> RawRows;
            true -> lists:sublist(RawRows, Limit)
        end,

    % Determine if we have more rows to iterate
    Recurse = (Rows /= []) and (Limit == 0 orelse Limit > Count) and HasMore,

    State1 = State#state{future = undefined},
    State2 =
        if
            Recurse ->
                LastKey = get_last_key(Rows, State1),
                send_get_range(next_state(LastKey, Count, State1));
            true ->
                State1
        end,

    case {Rows, Recurse} of
        {[], false} ->
            {halt, State2};
        {[], true} ->
            {cont, [], State2};
        {_, false} ->
            {halt, [Rows], State2};
        {_, true} ->
            {cont, [Rows], State2}
    end.

new_state(Tx, StartKey, EndKey, Options) ->
    Reverse =
        case erlfdb_util:get(Options, reverse, false) of
            true -> 1;
            false -> 0;
            I when is_integer(I) -> I
        end,
    Mapper = erlfdb_util:get(Options, mapper),
    ok = assert_mapper(Mapper),
    #state{
        tx = Tx,
        start_key = erlfdb_key:to_selector(StartKey),
        end_key = erlfdb_key:to_selector(EndKey),
        mapper = Mapper,
        limit = erlfdb_util:get(Options, limit, 0),
        target_bytes = erlfdb_util:get(Options, target_bytes, 0),
        streaming_mode = erlfdb_util:get(Options, streaming_mode, want_all),
        iteration = erlfdb_util:get(Options, iteration, 1),
        snapshot = erlfdb_util:get(Options, snapshot, false),
        reverse = Reverse
    }.

assert_mapper(undefined) -> ok;
assert_mapper(Mapper) when is_binary(Mapper) -> ok;
assert_mapper(Mapper) -> erlang:error({badarg, mapper, Mapper}).

next_state(LastKey, Count, State = #state{}) ->
    #state{
        start_key = StartKey,
        end_key = EndKey,
        limit = Limit,
        reverse = Reverse,
        iteration = Iteration
    } = State,
    {NextStartKey, NextEndKey} =
        case Reverse /= 0 of
            true ->
                {StartKey, erlfdb_key:first_greater_or_equal(LastKey)};
            false ->
                {erlfdb_key:first_greater_than(LastKey), EndKey}
        end,
    State#state{
        start_key = NextStartKey,
        end_key = NextEndKey,
        limit = max(0, Limit - Count),
        iteration = Iteration + 1
    }.

send_get_range(State = #state{mapper = undefined}) ->
    #state{
        tx = Tx,
        start_key = StartKey,
        end_key = EndKey,
        limit = Limit,
        target_bytes = TargetBytes,
        streaming_mode = StreamingMode,
        iteration = Iteration,
        snapshot = Snapshot,
        reverse = Reverse
    } = State,
    Future = erlfdb_nif:transaction_get_range(
        Tx,
        StartKey,
        EndKey,
        Limit,
        TargetBytes,
        StreamingMode,
        Iteration,
        Snapshot,
        Reverse
    ),
    State#state{future = Future};
send_get_range(State = #state{mapper = Mapper}) ->
    #state{
        tx = Tx,
        start_key = StartKey,
        end_key = EndKey,
        limit = Limit,
        target_bytes = TargetBytes,
        streaming_mode = StreamingMode,
        iteration = Iteration,
        snapshot = Snapshot,
        reverse = Reverse
    } = State,
    Future = erlfdb_nif:transaction_get_mapped_range(
        Tx,
        StartKey,
        EndKey,
        Mapper,
        Limit,
        TargetBytes,
        StreamingMode,
        Iteration,
        Snapshot,
        Reverse
    ),
    State#state{future = Future}.

get_last_key(Rows, _State = #state{mapper = undefined}) ->
    {K, _V} = lists:last(Rows),
    K;
get_last_key(Rows, _State = #state{}) ->
    {KV, _, _} = lists:last(Rows),
    {K, _} = KV,
    K.
