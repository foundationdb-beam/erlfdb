-module(erlfdb_iterator).

-define(DOCATTRS, ?OTP_RELEASE >= 27).

-if(?DOCATTRS).
-moduledoc """
A generic iterator behaviour, useful for streaming results from the database.
""".
-endif.

-type state() :: term().
-type iterator() :: {module(), state()}.
-type result() :: term().

-callback handle_call(term(), term(), state()) -> {reply, term(), state()}.
-callback handle_next(state()) ->
    {cont, [result()], state()} | {halt, [result()], state()} | {halt, state()}.
-callback handle_stop(state()) -> ok.

-optional_callbacks([handle_call/3]).

-export_type([iterator/0, result/0]).

-export([new/2, next/1, stop/1, run/1, call/2, pipeline/1, module_state/1]).

-if(?DOCATTRS).
-doc """
Creates an iterator.
""".
-endif.
-spec new(module(), state()) -> iterator().
new(Module, State) ->
    {Module, State}.

-if(?DOCATTRS).
-doc """
Executes a handle_call on the iterator.
""".
-endif.
-spec call(iterator(), term()) -> {term(), iterator()}.
call(Iterator, Call) ->
    {Module, State} = module_state(Iterator),
    {reply, Reply, State1} = Module:handle_call(Call, make_ref(), State),
    {Reply, new(Module, State1)}.

-if(?DOCATTRS).
-doc """
Progresses the iterator one step.
""".
-endif.
-spec next(iterator()) ->
    {cont, [result()], iterator()} | {halt, [result()], iterator()} | {halt, iterator()}.
next({Module, State}) ->
    case Module:handle_next(State) of
        {cont, Results, State1} ->
            {cont, Results, {Module, State1}};
        {halt, Results, State1} ->
            {halt, Results, {Module, State1}};
        {halt, State1} ->
            {halt, {Module, State1}}
    end.

-if(?DOCATTRS).
-doc """
Stops the iterator.
""".
-endif.
-spec stop(iterator()) -> ok.
stop({Module, State}) ->
    ok = Module:handle_stop(State).

-if(?DOCATTRS).
-doc """
Runs the iterator to completion.

Returns the list of results and the state of the iterator.

Caller must call `stop/1` to terminate the iterator.
""".
-endif.
-spec run(iterator()) -> {list(result()), iterator()}.
run(Iterator) ->
    [{Result, Iterator1}] = pipeline([Iterator]),
    {Result, Iterator1}.

-if(?DOCATTRS).
-doc """
Runs all iterators to completion.

Caller must call `stop/1` to terminate the iterators.
""".
-endif.
-spec pipeline([iterator()]) -> [{list(result()), iterator()}].
pipeline(List) ->
    Len = length(List),
    Acc = erlang:make_tuple(Len, []),
    IxList = lists:zip(lists:seq(1, Len), List),
    pipeline(IxList, Acc).

-if(?DOCATTRS).
-doc """
Identifies the module and the specific state of the iterator implementation.
""".
-endif.
-spec module_state(iterator()) -> {module(), state()}.
module_state({Module, State}) -> {Module, State}.

pipeline([], Acc) ->
    tuple_to_list(Acc);
pipeline(IxList, Acc) ->
    {Remaining, Acc1} = lists:foldl(
        fun({Ix, Iterator}, {Rem0, Acc0}) ->
            case next(Iterator) of
                {halt, Iterator1} ->
                    ok = stop(Iterator1),
                    AccResults = lists:append(lists:reverse(erlang:element(Ix, Acc0))),
                    {Rem0, erlang:setelement(Ix, Acc0, {AccResults, Iterator1})};
                {halt, [], Iterator1} ->
                    ok = stop(Iterator1),
                    AccResults = lists:append(lists:reverse(erlang:element(Ix, Acc0))),
                    {Rem0, erlang:setelement(Ix, Acc0, {AccResults, Iterator1})};
                {halt, Results, Iterator1} ->
                    ok = stop(Iterator1),
                    AccResults = lists:append(lists:reverse([Results | erlang:element(Ix, Acc0)])),
                    {Rem0, erlang:setelement(Ix, Acc0, {AccResults, Iterator1})};
                {cont, [], Iterator1} ->
                    {[{Ix, Iterator1} | Rem0], Acc0};
                {cont, Results, Iterator1} ->
                    AccResults = erlang:element(Ix, Acc0),
                    {[{Ix, Iterator1} | Rem0], erlang:setelement(Ix, Acc0, [Results | AccResults])}
            end
        end,
        {[], Acc},
        IxList
    ),
    pipeline(lists:reverse(Remaining), Acc1).
