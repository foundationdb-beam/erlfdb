-module(erlfdb_range_iterator).

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
2. `erlfdb_range_iterator.next/1`: Waits for the result of the GetRange request.
   Then issues another GetRange request to the database server.
3. `erlfdb_range_iterator.stop/1`: Cancels the active future, if one exists.
""".
-endif.

-export([start/4, next/1, stop/1, get_future/1]).

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

-type state() :: term().
-export_type([state/0]).

-if(?DOCATTRS).
-doc """
Starts the iterator.

Sends the first GetRange request to the database server.
""".
-endif.
-spec start(erlfdb:transaction(), erlfdb:key(), erlfdb:key(), [erlfdb:fold_option()]) ->
    {ok, state()}.
start(Tx, StartKey, EndKey, Options) ->
    State = new_state(Tx, StartKey, EndKey, Options),
    State1 = send_get_range(State),
    {ok, State1}.

-if(?DOCATTRS).
-doc """
Progresses the iterator, returning data that is retrieved.

Waits for the active future, sends the next GetRange request, and returns the data.
""".
-endif.
-spec next(state()) ->
    {done, state()} | {ok, list(erlfdb:kv()) | list(erlfdb:mapped_kv()), state()}.
next(State = #state{future = undefined}) ->
    {done, State};
next(State = #state{}) ->
    #state{future = Future} = State,
    Result = erlfdb:wait(Future, []),
    handle_result(Result, State).

-if(?DOCATTRS).
-doc """
Stops the iterator.

If there is an active future, it is cancelled.
""".
-endif.
-spec stop(state()) -> ok.
stop(_State = #state{future = undefined}) ->
    ok;
stop(_State = #state{future = Future}) ->
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
    {ok, Rows, State2}.

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
