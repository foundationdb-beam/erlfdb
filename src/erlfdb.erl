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

-module(erlfdb).

-define(DOCATTRS, ?OTP_RELEASE >= 27).

-if(?DOCATTRS).
-moduledoc """
The primary API for interacting with a FoundationDB database.

Please refer to the [FoundationDB C API documentation](https://apple.github.io/foundationdb/api-c.html)
for the full specification of the functions we use. In this module documentation,
we won't duplicate all the content from the C API docs. Instead, we'll point out any differences
where relevant, and provide usage examples.

You will usually be interacting with erlfdb functions in the proximity of an
[FDB Transaction](https://apple.github.io/foundationdb/developer-guide.html#transaction-basics).
This example shows a basic transaction. See `transactional/2` for more.

<!-- tabs-open -->

### Erlang

```erlang
% Writes to <<"foo">> if it doesn't exist, and keeps track of the number of times we do so.
1> Db = erlfdb:open().
2> erlfdb:transactional(Db, fun(Tx) ->
..   Future = erlfdb:get(Tx, <<"foo">>),
..   case erlfdb:wait(Future) of
..       not_found ->
..           erlfdb:add(Tx, <<"count">>, 1),
..           erlfdb:set(Tx, <<"foo">>, <<"bar">>);
..       _Val ->
..           ok
..   end
.. end).
```

### Elixir

```elixir
# Writes to "foo" if it doesn't exist, and keeps track of the number of times we do so.
iex> db = :erlfdb.open()
iex> :erlfdb.transactional(db, fn tx ->
...>
...>   val = tx
...>         |> :erlfdb.get("foo")
...>         |> :erlfdb.wait()
...>
...>   case val do
...>       :not_found ->
...>           :erlfdb.add(tx, "count", 1)
...>           :erlfdb.set(tx, "foo", "bar")
...>       _val ->
...>           :ok
...>   end
...> end).
```

<!-- tabs-close -->
""".
-endif.

-compile({no_auto_import, [get/1]}).

-export([
    open/0,
    open/1,
    open/2,
    open_all/0,
    open_all/1,
    open_all/2,

    open_tenant/2,

    create_database/0,
    create_database/1,

    create_transaction/1,
    tenant_create_transaction/1,

    transactional/2,
    snapshot/1,

    % Db/Tx configuration
    set_option/2,
    set_option/3,

    % Lifecycle Management
    commit/1,
    reset/1,
    cancel/1,
    cancel/2,

    % Future Specific functions
    is_ready/1,
    get/1,
    get_error/1,
    block_until_ready/1,
    wait/1,
    wait/2,
    wait_for_any/1,
    wait_for_any/2,
    wait_for_all/1,
    wait_for_all/2,

    wait_for_all_interleaving/2,
    wait_for_all_interleaving/3,

    % Data retrieval
    get/2,
    get_ss/2,

    get_key/2,
    get_key_ss/2,

    get_range/3,
    get_range/4,

    get_range_startswith/2,
    get_range_startswith/3,

    get_mapped_range/4,
    get_mapped_range/5,

    get_range_split_points/4,

    fold_range/5,
    fold_range/6,

    fold_range_future/4,
    fold_mapped_range_future/4,
    fold_range_wait/4,
    fold_range_wait/5,

    % Data modifications
    set/3,
    clear/2,
    clear_range/3,
    clear_range_startswith/2,

    % Atomic operations
    add/3,
    bit_and/3,
    bit_or/3,
    bit_xor/3,
    min/3,
    max/3,
    byte_min/3,
    byte_max/3,
    set_versionstamped_key/3,
    set_versionstamped_value/3,
    atomic_op/4,

    % Watches
    watch/2,
    watch/3,
    get_and_watch/2,
    set_and_watch/3,
    clear_and_watch/2,

    % Conflict ranges
    add_read_conflict_key/2,
    add_read_conflict_range/3,
    add_write_conflict_key/2,
    add_write_conflict_range/3,
    add_conflict_range/4,

    % Transaction versioning
    set_read_version/2,
    get_read_version/1,
    get_committed_version/1,
    get_versionstamp/1,
    get_versionstamp/2,

    % Transaction size info
    get_approximate_size/1,

    % Transaction status
    get_next_tx_id/1,
    is_read_only/1,
    has_watches/1,
    get_writes_allowed/1,

    % Locality and Statistics
    get_main_thread_busyness/1,
    get_client_status/1,
    get_addresses_for_key/2,
    get_estimated_range_size/3,

    % Get conflict information
    get_conflicting_keys/1,

    % Misc
    on_error/2,
    error_predicate/2,
    get_last_error/0,
    get_error_string/1
]).

-export_type([
    atomic_mode/0,
    atomic_operand/0,
    cluster_filename/0,
    database/0,
    database_option/0,
    error/0,
    error_predicate/0,
    fold_future/0,
    fold_option/0,
    future/0,
    future_ready_message/0,
    get_versionstamp_option/0,
    key/0,
    key_selector/0,
    kv/0,
    mapped_kv/0,
    mapper/0,
    open_option/0,
    result/0,
    snapshot/0,
    tenant/0,
    tenant_name/0,
    transaction/0,
    transaction_future_ready_message/0,
    transaction_option/0,
    value/0,
    version/0,
    wait_option/0,
    watch_future_ready_message/0,
    watch_option/0
]).

-define(IS_FUTURE, {erlfdb_future, _, _}).
-define(IS_FOLD_FUTURE, {fold_future, _, _}).
-define(IS_DB, {erlfdb_database, _}).
-define(IS_TENANT, {erlfdb_tenant, _}).
-define(IS_TX, {erlfdb_transaction, _}).
-define(IS_SS, {erlfdb_snapshot, _}).
-define(GET_TX(SS), element(2, SS)).
-define(ERLFDB_ERROR, '$erlfdb_error').

-record(fold_st, {
    start_key,
    end_key,
    mapper,
    limit,
    target_bytes,
    streaming_mode,
    iteration,
    snapshot,
    reverse,
    from,
    idx
}).

-record(fold_future, {
    st,
    future
}).

-type atomic_mode() :: erlfdb_nif:atomic_mode().
-type atomic_operand() :: erlfdb_nif:atomic_operand().
-type cluster_filename() :: binary().
-type database() :: erlfdb_nif:database().
-type database_option() :: erlfdb_nif:database_option().
-type error() :: erlfdb_nif:error().
-type error_predicate() :: erlfdb_nif:error_predicate().
-type fold_future() :: #fold_future{}.
-type fold_option() ::
    {reverse, boolean() | integer()}
    | {limit, non_neg_integer()}
    | {target_bytes, non_neg_integer()}
    | {streaming_mode, atom()}
    | {iteration, pos_integer()}
    | {snapshot, boolean()}
    | {mapper, binary()}
    | {wait, true | false | interleaving}.
-type split_option() ::
    {chunk_size, non_neg_integer()}.
-type future() :: erlfdb_nif:future().
-type future_ready_message() :: transaction_future_ready_message() | watch_future_ready_message().
-type get_versionstamp_option() ::
    {to, pid()}.
-type key() :: erlfdb_nif:key().
-type kv() :: {key(), value()}.
-type key_selector() :: erlfdb_nif:key_selector().
-type open_option() :: {dist, scheduler_id | cluster_file}.
-type result() :: erlfdb_nif:future_result().
-type mapped_kv() :: {kv(), {key(), key()}, list(kv())}.
-type mapper() :: tuple().
-type snapshot() :: {erlfdb_snapshot, transaction()}.
-type tenant() :: erlfdb_nif:tenant().
-type tenant_name() :: binary().
-type transaction() :: erlfdb_nif:transaction().
-type transaction_future_ready_message() :: {{reference(), reference()}, ready}.
-type transaction_option() :: erlfdb_nif:transaction_option().
-type value() :: erlfdb_nif:value().
-type version() :: erlfdb_nif:version().
-type wait_option() :: {timeout, non_neg_integer() | infinity} | {with_index, boolean()}.
-type watch_future_ready_message() :: {reference(), ready}.
-type watch_option() ::
    {to, pid()}.

-if(?DOCATTRS).
-doc """
Opens a database using the [default cluster file](https://apple.github.io/foundationdb/administration.html#default-cluster-file).

See `open/2` for more.
""".
-endif.
-spec open() -> database().
open() ->
    open(<<>>).

-if(?DOCATTRS).
-doc """
Opens a database using the provided cluster file string.

See `open/2` for more.
""".
-endif.
-spec open(cluster_filename()) -> database().
open(ClusterFile) ->
    open(ClusterFile, []).

-if(?DOCATTRS).
-doc """
Opens a database using the provided cluster file string.

*C API function*: [`fdb_create_database`](https://apple.github.io/foundationdb/api-c.html#c.fdb_create_database)

`open/2` will lazily create and store a number of database objects based on the configuration
options provided. For optimal performance, your application should call `open/2` when a `t:database/0` object is
needed. Doing so will ensure even distribution of work among client threads when using the
[`client_threads_per_version`](thread-design.html) network option.

## Options

  - `dist`: Provides a work distribution stategy, which defaults to `scheduler_id`.

### Work distribution with the `dist` option

It's usually desirable for the application to create a certain number of database objects that can be re-used
across many transactions. The `dist` option provides some common strategies for doing so. If you want to implement
your own, use `create_database/1` directly instead.

  - `scheduler_id`: (default) A new database object will be created for each scheduler id in the running system for each unique
    cluster file.  This strategy does not claim that a particular item of work will remain on a scheduler -- only
    that the scheduler_id itself is helpful in distributing work in a roughly even fashion.
  - `cluster_file`: A new database object will be created for each unique cluster file provided. This option is not
    compatible with `client_threads_per_version` > 1.

""".
-endif.
-spec open(cluster_filename(), list(open_option())) -> database().
open(ClusterFile, Options) ->
    Key =
        case proplists:get_value(dist, Options, scheduler_id) of
            scheduler_id ->
                Sid = erlang:system_info(scheduler_id),
                open_dist_key(scheduler_id, {ClusterFile, Sid});
            cluster_file ->
                open_dist_key(cluster_file, ClusterFile)
        end,
    open_with_key(Key, ClusterFile).

-if(?DOCATTRS).
-doc """
Creates database objects equal to the number of online schedulers, using the
[default cluster file](https://apple.github.io/foundationdb/administration.html#default-cluster-file).

See `open_all/2` for more.
""".
-endif.
-spec open_all() -> list(database()).
open_all() ->
    open_all(<<>>, []).

-if(?DOCATTRS).
-doc """
Creates database objects equal to the number of online schedulers.

See `open_all/2` for more.
""".
-endif.
-spec open_all(cluster_filename()) -> list(database()).
open_all(ClusterFile) ->
    open_all(ClusterFile, []).

-if(?DOCATTRS).
-doc """
Creates all database objects according to the work distribution strategy.

*C API function*: [`fdb_create_database`](https://apple.github.io/foundationdb/api-c.html#c.fdb_create_database)

**Why is this useful?** Due to the use of `m:persistent_term` by `open/2`, it can be beneficial to create all database
objects shortly after startup, when the runtime system is fresh and the number of processes is low. Calling this function
during your application start-up will ensure that you are in compliance with the [Best Practices for Using Persistent Terms](https://www.erlang.org/doc/apps/erts/persistent_term.html#module-best-practices-for-using-persistent-terms).
""".
-endif.
-spec open_all(cluster_filename(), list(open_option())) -> list(database()).
open_all(ClusterFile, Options) ->
    Keys =
        case proplists:get_value(dist, Options, scheduler_id) of
            scheduler_id ->
                N = erlang:system_info(schedulers_online),
                [open_dist_key(scheduler_id, {ClusterFile, Sid}) || Sid <- lists:seq(1, N)];
            cluster_file ->
                [open_dist_key(cluster_file, ClusterFile)]
        end,
    [open_with_key(Key, ClusterFile) || Key <- Keys].

-if(?DOCATTRS).
-doc """
Opens a handle to the [Tenant](https://apple.github.io/foundationdb/tenants.html).

*C API function*: [`fdb_database_open_tenant`](https://apple.github.io/foundationdb/api-c.html#c.fdb_database_open_tenant)
""".
-endif.
-spec open_tenant(database(), tenant_name()) -> tenant().
open_tenant(?IS_DB = Db, TenantName) ->
    erlfdb_nif:database_open_tenant(Db, TenantName).

-if(?DOCATTRS).
-doc """
Creates a database object, which serves as a handle to the FoundationDB server, using the [default cluster file](https://apple.github.io/foundationdb/administration.html#default-cluster-file).

*C API function*: [`fdb_create_database`](https://apple.github.io/foundationdb/api-c.html#c.fdb_create_database)
""".
-endif.
-spec create_database() -> database().
create_database() ->
    create_database(<<>>).

-if(?DOCATTRS).
-doc """
Creates a database object, which serves as a handle to the FoundationDB server, using the provided cluster file string.

*C API function*: [`fdb_create_database`](https://apple.github.io/foundationdb/api-c.html#c.fdb_create_database)
""".
-endif.
-spec create_database(cluster_filename()) -> database().
create_database(ClusterFile) ->
    erlfdb_nif:create_database(ClusterFile).

-if(?DOCATTRS).
-doc """
Creates a transaction from a database.

The caller is responsible for calling
`commit/1` when appropriate and implementing any retry behavior.

*C API function*: [`fdb_database_create_transaction`](https://apple.github.io/foundationdb/api-c.html#c.fdb_database_create_transaction)

> #### Tip {: .tip}
>
> Use `transactional/2` instead.
""".
-endif.
-spec create_transaction(database()) -> transaction().
create_transaction(?IS_DB = Db) ->
    erlfdb_nif:database_create_transaction(Db).

-if(?DOCATTRS).
-doc """
Creates a transaction from an open tenant.

The caller is responsible for calling
`commit/` when appropriate and implementing any retry behavior.

*C API function*: [`fdb_tenant_create_transaction`](https://apple.github.io/foundationdb/api-c.html#c.fdb_tenant_create_transaction)

> #### Tip {: .tip}
>
> Use `transactional/2` instead.
""".
-endif.
-spec tenant_create_transaction(tenant()) -> transaction().
tenant_create_transaction(?IS_TENANT = Tenant) ->
    erlfdb_nif:tenant_create_transaction(Tenant).

-if(?DOCATTRS).
-doc """
Executes the provided 1-arity function in a transaction.

You'll use the other erlfdb functions inside a transaction to safely achieve interesting
behavior in your application. The [FoundationDB Transaction Manifesto](https://apple.github.io/foundationdb/transaction-manifesto.html)
is a good starting point for understanding the why and how. Some examples are below.

## Transaction Commit and Error Handling

The provided 1-arity function is executed, and when it returns, erlfdb inspects the transaction is
for its read-only status. If read-only, control returns to the caller immediately.
Otherwise, the transaction is committed to the database with `commit/1`.
In both cases, the return value from the provided function is returned to
the caller after the transaction has been completed.

An error can be encountered during the transaction (for example, when a key conflict is detected by the FDB Server).
If it is an error code that FoundationDB recommends as eligible for retry, your function will be executed
again. For this reason, **your function should have no side-effects**. Logging, sending messages,
and updates to an ets table that exist in your transaction function will execute multiple times when a key
conflict is encountered. Moreover, if your transaction has any branching logic, such side effects can be misleading or harmful.

Imagine a transaction to be a pure function that receives the entire database as input and returns the entire database
as output. If your function's implementation is [purely functional](https://en.wikipedia.org/wiki/Purely_functional_programming) under
this point of view, then it is safe.

The transaction will be executed repeatedly as needed until either (a) it is completed successfully, and control flow returns to the
caller, or (b) a non-retriable error is thrown. A transaction timeout is an example of a non-retriable error, but
by default, the timeout is set to `infinity`.

*C API functions*:

- For the commit, [`fdb_transaction_commit`](https://apple.github.io/foundationdb/api-c.html#c.fdb_transaction_commit).
- For the retry behavior, [`fdb_transaction_on_error`](https://apple.github.io/foundationdb/api-c.html#c.fdb_transaction_on_error).

## Arguments

  * `Db` / `Tenant`: The context under which the transaction is created.
  * `UserFun`: 1-arity function to be executed with FDB transactional
    semantics. The transaction (`t:transaction/0`) is provided as the argument to the function.

## Examples

Using a database as the transactional context:

```erlang
1> Db = erlfdb:open().
2> erlfdb:transactional(Db, fun(Tx) ->
..     not_found = erlfdb:wait(erlfdb:get(Tx, <<"hello">>)),
..     erlfdb:set(Tx, <<"hello">>, <<"world">>)
.. end).
```

Using a tenant as the transactional context:

```erlang
1> Db = erlfdb:open().
2> Tenant = erlfdb:open_tenant(Db, <<"some-org">>)
2> erlfdb:transactional(Tenant, fun(Tx) ->
..     not_found = erlfdb:wait(erlfdb:get(Tx, <<"hello">>)),
..     erlfdb:set(Tx, <<"hello">>, <<"world">>)
.. end).
```

Performing non-trivial logic inside a transaction:

```erlang
1> Db = erlfdb:open().
2> erlfdb:set(Db, <<"toggle">>, <<"off">>).
3> erlfdb:transactional(Db, fun(Tx) ->
..     case erlfdb:wait(erlfdb:get(Tx, <<"toggle">>)) of
..         <<"off">> ->
..             erlfdb:set(Tx, <<"toggle">>, <<"on">>),
..             off_to_on;
..         <<"on">> ->
..             erlfdb:set(Tx, <<"toggle">>, <<"off">>),
..             on_to_off
..     end
.. end).
```
""".
-endif.
-spec transactional(database() | tenant() | transaction() | snapshot(), function()) -> any().
transactional(?IS_DB = Db, UserFun) when is_function(UserFun, 1) ->
    clear_erlfdb_error(),
    Tx = create_transaction(Db),
    do_transaction(Tx, UserFun, 0);
transactional(?IS_TENANT = Tenant, UserFun) when is_function(UserFun, 1) ->
    clear_erlfdb_error(),
    Tx = tenant_create_transaction(Tenant),
    do_transaction(Tx, UserFun, 0);
transactional(?IS_TX = Tx, UserFun) when is_function(UserFun, 1) ->
    UserFun(Tx);
transactional(?IS_SS = SS, UserFun) when is_function(UserFun, 1) ->
    UserFun(SS).

-if(?DOCATTRS).
-doc """
Use this to modify a transaction so that operations on the returned object are
performed as [Snapshot Reads](https://apple.github.io/foundationdb/developer-guide.html#snapshot-reads).

## Example

```erlang
1> Db = erlfdb:open().
2> erlfdb:transactional(Db, fun(Tx) ->
..     SS = erlfdb:snapshot(Tx),
..     F1 = erlfdb:get(Tx, <<"strictly serializable read">>),
..     F2 = erlfdb:get(SS, <<"snapshot isolation read">>),
..     erlfdb:wait_for_all([F1, F2])
.. end).
```
""".
-endif.
-spec snapshot(transaction() | snapshot()) -> snapshot().
snapshot(?IS_TX = Tx) ->
    {erlfdb_snapshot, Tx};
snapshot(?IS_SS = SS) ->
    SS.

-if(?DOCATTRS).
-doc """
Equivalent to `set_option(DbOrTx, Option, <<>>)`.
""".
-endif.
-spec set_option(database() | transaction(), database_option() | transaction_option()) -> ok.
set_option(DbOrTx, Option) ->
    set_option(DbOrTx, Option, <<>>).

-if(?DOCATTRS).
-doc """
Sets a valued option on a database or transaction.

*C API functions*:

- For a `t:database/0`, [`fdb_database_set_option](https://apple.github.io/foundationdb/api-c.html#c.fdb_database_set_option)
- For a `t:transaction/0, [`fdb_transaction_set_option`](https://apple.github.io/foundationdb/api-c.html#c.fdb_transaction_set_option)
""".
-endif.
-spec set_option(database() | transaction(), database_option() | transaction_option(), binary()) ->
    ok.
set_option(?IS_DB = Db, DbOption, Value) ->
    erlfdb_nif:database_set_option(Db, DbOption, Value);
set_option(?IS_TX = Tx, TxOption, Value) ->
    erlfdb_nif:transaction_set_option(Tx, TxOption, Value).

-if(?DOCATTRS).
-doc """
Commits a transaction.

*C API function*: [`fdb_transaction_commit`](https://apple.github.io/foundationdb/api-c.html#c.fdb_transaction_commit)

> #### Tip {: .tip}
>
> Use `transactional/2` instead.
""".
-endif.
-spec commit(transaction()) -> future().
commit(?IS_TX = Tx) ->
    erlfdb_nif:transaction_commit(Tx).

-if(?DOCATTRS).
-doc """
Resets a transaction.

*C API function*: [`fdb_transaction_reset`](https://apple.github.io/foundationdb/api-c.html#c.fdb_transaction_reset)

> #### Tip {: .tip}
>
> Use `transactional/2` instead.
""".
-endif.
-spec reset(transaction()) -> ok.
reset(?IS_TX = Tx) ->
    ok = erlfdb_nif:transaction_reset(Tx).

-if(?DOCATTRS).
-doc """
Cancels a future or a transaction.

*C API functions*:

- For a `t:transaction/0`, [`fdb_transaction_cancel`](https://apple.github.io/foundationdb/api-c.html#c.fdb_transaction_cancel)
- For a `t:future/0` or `t:fold_future/0`, [`fdb_future_cancel`](https://apple.github.io/foundationdb/api-c.html#c.fdb_future_cancel)
""".
-endif.
-spec cancel(fold_future() | future() | transaction()) -> ok.
cancel(?IS_FOLD_FUTURE = FoldInfo) ->
    cancel(FoldInfo, []);
cancel(?IS_FUTURE = Future) ->
    cancel(Future, []);
cancel(?IS_TX = Tx) ->
    ok = erlfdb_nif:transaction_cancel(Tx).

-if(?DOCATTRS).
-doc """
Cancels a future.

If `[{flush, true}]` is provided, the calling process's
mailbox is cleared of any messages from this future. Defaults to `false`.

*C API functions*:

- For a `t:transaction/0`, [`fdb_transaction_cancel`](https://apple.github.io/foundationdb/api-c.html#c.fdb_transaction_cancel)
- For a `t:future/0` or `t:fold_future/0`, [`fdb_future_cancel`](https://apple.github.io/foundationdb/api-c.html#c.fdb_future_cancel)
""".
-endif.
-spec cancel(fold_future() | future(), [{flush, boolean()}] | []) -> ok.
cancel(?IS_FOLD_FUTURE = FoldInfo, Options) ->
    #fold_future{future = Future} = FoldInfo,
    cancel(Future, Options);
cancel(?IS_FUTURE = Future, Options) ->
    ok = erlfdb_nif:future_cancel(Future),
    case erlfdb_util:get(Options, flush, false) of
        true -> flush_future_message(Future);
        false -> ok
    end.

-if(?DOCATTRS).
-doc """
Returns `true` if the future is ready. That is, its result can be retrieved
immediately.

*C API function*: [`fdb_future_is_ready`](https://apple.github.io/foundationdb/api-c.html#c.fdb_future_is_ready)

> #### Tip {: .tip}
>
> Use one of the `wait*` functions instead, such as `wait/1`.
""".
-endif.
-spec is_ready(future()) -> boolean().
is_ready(?IS_FUTURE = Future) ->
    erlfdb_nif:future_is_ready(Future).

-if(?DOCATTRS).
-doc """
Returns `ok` if future is ready and not in an error state, and an `t:error/0` otherwise.

*C API function*: [`fdb_future_get_error`](https://apple.github.io/foundationdb/api-c.html#c.fdb_future_get_error)

> #### Tip {: .tip}
>
> Use one of the `wait*` functions instead, such as `wait/1`.
""".
-endif.
-spec get_error(future()) -> ok | error().
get_error(?IS_FUTURE = Future) ->
    erlfdb_nif:future_get_error(Future).

-if(?DOCATTRS).
-doc """
Returns the result of a ready future.

*C API functions*: [`fdb_future_get_*`](https://apple.github.io/foundationdb/api-c.html#c.fdb_future_get_int64)

> #### Tip {: .tip}
>
> Use one of the `wait*` functions instead, such as `wait/1`.
""".
-endif.
-spec get(future()) -> result().
get(?IS_FUTURE = Future) ->
    erlfdb_nif:future_get(Future).

-if(?DOCATTRS).
-doc """
Blocks the calling process until the future is ready.

*C API function*: [`fdb_future_block_until_ready`](https://apple.github.io/foundationdb/api-c.html#c.fdb_future_block_until_ready)

> #### Tip {: .tip}
>
> Use one of the `wait*` functions instead, such as `wait/1`.
""".
-endif.
-spec block_until_ready(future()) -> ok.
block_until_ready(?IS_FUTURE = Future) ->
    {erlfdb_future, MsgRef, _FRef} = Future,
    receive
        {MsgRef, ready} -> ok;
        {{_TxRef, MsgRef}, ready} -> ok
    end.

-if(?DOCATTRS).
-doc """
Equivalent to `wait(Future, [])`.
""".
-endif.
-spec wait(future() | result()) -> result().
wait(?IS_FUTURE = Future) ->
    wait(Future, []);
wait(Ready) ->
    Ready.

-if(?DOCATTRS).
-doc """
Waits for future to be ready, and returns the result.

If first argument is not a future, then simply return the first argument.

## Examples

`wait/2` is typically used inside a transaction:

```erlang
1> Db = erlfdb:open().
2> erlfdb:transactional(Db, fun(Tx) ->
..     erlfdb:wait(erlfdb:get(Tx, <<"hello">>)),
.. end).
```
""".
-endif.
-spec wait(future() | result(), [wait_option()]) -> result().
wait(?IS_FUTURE = Future, Options) ->
    case is_ready(Future) of
        true ->
            Result = get(Future),
            % Flush ready message if already sent
            flush_future_message(Future),
            Result;
        false ->
            Timeout = erlfdb_util:get(Options, timeout, infinity),
            {erlfdb_future, MsgRef, _Res} = Future,
            receive
                {MsgRef, ready} -> get(Future);
                {{_TxRef, MsgRef}, ready} -> get(Future)
            after Timeout ->
                erlang:error({timeout, Future})
            end
    end;
wait(Ready, _) ->
    Ready.

-if(?DOCATTRS).
-doc """
Equivalent to `wait_for_any(Futures, [])`.
""".
-endif.
-spec wait_for_any([future()]) -> future().
wait_for_any(Futures) ->
    wait_for_any(Futures, []).

-if(?DOCATTRS).
-doc """
Waits for one of the provided futures in the list to enter ready state. When
such a future is found, return it. The result of that future must be retrieved
by the caller with `get/1`.

## Examples

`wait_for_any/2` returns a future. It will typically be the future that is the first
to resolve, but that is not guaranteed:

```erlang
1> Db = erlfdb:open().
2> erlfdb:transactional(Db, fun(Tx) ->
..     T = erlfdb:get(Tx, <<"tortoise">>)),
..     H = erlfdb:get(Tx, <<"hare">>)),
..     Winner = erlfdb:wait_for_any([T, H]),
..     erlfdb:get(Winner)
.. end).
```
""".
-endif.
-spec wait_for_any([future()], [wait_option()]) -> future().
wait_for_any(Futures, Options) ->
    wait_for_any(Futures, Options, []).

-spec wait_for_any([future()], [wait_option()], list()) -> future().
wait_for_any(Futures, Options, ResendQ) ->
    Timeout = erlfdb_util:get(Options, timeout, infinity),
    receive
        {FutureKey, ready} = Msg when is_reference(FutureKey) orelse is_tuple(FutureKey) ->
            case lists:keyfind(FutureKey, 2, Futures) of
                ?IS_FUTURE = Future ->
                    lists:foreach(
                        fun(M) ->
                            self() ! M
                        end,
                        ResendQ
                    ),
                    Future;
                _ ->
                    wait_for_any(Futures, Options, [Msg | ResendQ])
            end
    after Timeout ->
        lists:foreach(
            fun(M) ->
                self() ! M
            end,
            ResendQ
        ),
        erlang:error({timeout, Futures})
    end.

-if(?DOCATTRS).
-doc """
Equivalent to `wait_for_all(Futures, [])`.
""".
-endif.
-spec wait_for_all([future() | result()]) -> list(result()).
wait_for_all(Futures) ->
    wait_for_all(Futures, []).

-if(?DOCATTRS).
-doc """
Waits for each future and returns all results. The order of the results
is guaranteed to match the order of the futures.

## Examples

`wait_for_all/2` returns the results from all futures:

```erlang
1> Db = erlfdb:open().
2> erlfdb:transactional(Db, fun(Tx) ->
..     T = erlfdb:get(Tx, <<"tortoise">>)),
..     H = erlfdb:get(Tx, <<"hare">>)),
..     erlfdb:wait_for_all([T, H])
.. end).
```
""".
-endif.
-spec wait_for_all([future() | result()], [wait_option()]) -> list(result()).
wait_for_all(Futures, Options) ->
    % Same as wait for all. We might want to
    % handle timeouts here so we have a single
    % timeout for all future waiting.
    lists:map(
        fun(Future) ->
            wait(Future, Options)
        end,
        Futures
    ).

-if(?DOCATTRS).
-doc """
Equivalent to `wait_for_all_interleaving(Tx, Futures, [])`.
""".
-endif.
-spec wait_for_all_interleaving(transaction() | snapshot(), [fold_future() | future()]) ->
    list().
wait_for_all_interleaving(Tx, Futures) ->
    wait_for_all_interleaving(Tx, Futures, []).

-if(?DOCATTRS).
-doc """
Experimental. Waits for all futures and returns all results. The order of the results
is guaranteed to match the order of the futures. Uses an interleaving approach,
which is described below.

A future of type `t:fold_future/0` may require multiple round trips to the database
server. When provided more than one, the requests to the database
are pipelined so that the server can optimize retrieval of keys. In this interleaving
approach, the client sends all known requests to the server as quickly as possible.

This is an experimental optimization of `wait_for_all/1`, and
is functionally equivalent.

## Examples

Imagine a large set of users stored with prefix `<<"user/">>` and a large set of blog
posts stored with prefix `<<"post/">>`. We can retrieve all users and posts
efficiently with `wait_for_all_interleaving/2`:

```erlang
1> Db = erlfdb:open().
2> erlfdb:transactional(Db, fun(Tx) ->
..     UsersF = erlfdb:get_range_startswith(Tx, <<"user/">>, [{wait, false}])),
..     PostsF = erlfdb:get_range_startswith(Tx, <<"post/">>, [{wait, false}])),
..     erlfdb:wait_for_all_interleaving(Tx, [UsersF, PostsF])
.. end).
```
""".
-endif.
-spec wait_for_all_interleaving(transaction() | snapshot(), [fold_future() | future()], [
    wait_option()
]) ->
    list().
wait_for_all_interleaving(Tx, Futures, Options) ->
    % Our fold function uses the indices in the fold_st to accumulate results into the tuple accumulator.
    % The 'get_range's will accumulate the list results, and 'get's will be singular values.
    Fun = fun
        ({X, Idx}, AccTuple) when is_list(X) ->
            setelement(Idx, AccTuple, [X | element(Idx, AccTuple)]);
        ({X, Idx}, AccTuple) ->
            setelement(Idx, AccTuple, X)
    end,
    Acc = list_to_tuple(lists:duplicate(length(Futures), [])),

    % 'fold_st's are created where they don't already exist (e.g. from a 'get').
    % All are tagged with an index.
    FFs = lists:map(
        fun
            ({?IS_FOLD_FUTURE = FF = #fold_future{st = St}, Idx}) ->
                FF#fold_future{st = St#fold_st{idx = Idx}};
            ({Future, Idx}) ->
                #fold_future{future = Future, st = #fold_st{from = Future, idx = Idx}}
        end,
        lists:zip(Futures, lists:seq(1, length(Futures)))
    ),

    Result = wait_and_apply(
        Tx, FFs, Fun, Acc, lists:keystore(with_index, 1, Options, {with_index, true})
    ),

    lists:map(
        fun
            (R) when is_list(R) -> lists:flatten(lists:reverse(R));
            (R) -> R
        end,
        tuple_to_list(Result)
    ).

-if(?DOCATTRS).
-doc """
Gets a value from the database.

When used inside a `transactional/2`, the return is a `t:future/0`.

*C API function*: [`fdb_transaction_get`](https://apple.github.io/foundationdb/api-c.html#c.fdb_transaction_get)

## Examples

Using a `t:database/0` as input, the value is retrieved:

```erlang
1> Db = erlfdb:open().
3> <<"world">> = erlfdb:get(Db, <<"hello">>).
```

Using a `t:transaction/0` as input, you must wait on the `t:future/0`:

```erlang
1> Db = erlfdb:open().
2> erlfdb:transactional(Db, fun(Tx) ->
..     Future = erlfdb:get(Tx, <<"hello">>),
..     <<"world">> = erlfdb:wait(Future)
.. end).
```
""".
-endif.
-spec get(database() | transaction() | snapshot(), key()) -> future() | result().
get(?IS_DB = Db, Key) ->
    transactional(Db, fun(Tx) ->
        wait(get(Tx, Key))
    end);
get(?IS_TX = Tx, Key) ->
    erlfdb_nif:transaction_get(Tx, Key, false);
get(?IS_SS = SS, Key) ->
    get_ss(?GET_TX(SS), Key).

-if(?DOCATTRS).
-doc """
With snapshot isolation, gets a value from the database.

*C API function*: [`fdb_transaction_get`](https://apple.github.io/foundationdb/api-c.html#c.fdb_transaction_get)
""".
-endif.
-spec get_ss(transaction() | snapshot(), key()) -> future().
get_ss(?IS_TX = Tx, Key) ->
    erlfdb_nif:transaction_get(Tx, Key, true);
get_ss(?IS_SS = SS, Key) ->
    get_ss(?GET_TX(SS), Key).

-if(?DOCATTRS).
-doc """
Resolves a `t:key_selector/0` against the keys in the database.

*C API function*: [`fdb_transaction_get_key`](https://apple.github.io/foundationdb/api-c.html#c.fdb_transaction_get_key)
""".
-endif.
-spec get_key(database() | transaction() | snapshot(), key_selector()) -> future() | key().
get_key(?IS_DB = Db, Key) ->
    transactional(Db, fun(Tx) ->
        wait(get_key(Tx, Key))
    end);
get_key(?IS_TX = Tx, Key) ->
    erlfdb_nif:transaction_get_key(Tx, Key, false);
get_key(?IS_SS = SS, Key) ->
    get_key_ss(?GET_TX(SS), Key).

-if(?DOCATTRS).
-doc """
With snapshot isolation, resolves a `t:key_selector/0` against the keys in the database.

*C API function*: [`fdb_transaction_get_key`](https://apple.github.io/foundationdb/api-c.html#c.fdb_transaction_get_key)
""".
-endif.
-spec get_key_ss(transaction(), key_selector()) -> future() | key().
get_key_ss(?IS_TX = Tx, Key) ->
    erlfdb_nif:transaction_get_key(Tx, Key, true).

-if(?DOCATTRS).
-doc """
Gets a range of key-value pairs from the database.

This function never returns a `t:fold_future/0`. Use `[{wait, false}]` with `get_raange/4` if you
want future semantics.

*C API function*: [`fdb_transaction_get_range`](https://apple.github.io/foundationdb/api-c.html#c.fdb_transaction_get_range)

## Examples

Gets all key-value pairs that are between keys `<<"user/0">>` and `<<"user/1">>`. No key with prefix `<<"user/1">>` will be
returned. (right side exclusive)

```erlang
1> Db = erlfdb:open().
2> erlfdb:get_range(DB, <<"user/0">>, <<"user/1">>).
```
""".
-endif.
-spec get_range(database() | transaction(), key(), key()) -> list(kv()).
get_range(DbOrTx, StartKey, EndKey) ->
    get_range(DbOrTx, StartKey, EndKey, []).

-if(?DOCATTRS).
-doc """
Gets a range of key-value pairs from the database.

*C API function*: [`fdb_transaction_get_range`](https://apple.github.io/foundationdb/api-c.html#c.fdb_transaction_get_range)

## Wait option

A `wait` option can be provided with the following effect:

- When `true`, the result is waited upon and returned.
- When `false`, a `t:fold_future/0` is returned, and the result can be retrieved with `wait_for_all_interleaving/2`.
- Experimental: When `interleaving`, `get_range_split_points/4` is used to divide the range and the futures are waited upon with `wait_for_all_interleaving/2`.
  The flattened result is returned.

Default is `true`.

## Examples

Gets all key-value pairs that are between keys `<<"user/0">>` and `<<"user/1">>`. No key with prefix `<<"user/1">>` will be
returned. (left-inclusive, right-exclusive)

```erlang
1> Db = erlfdb:open().
2> erlfdb:transactional(Db, fun(Tx) ->
..     Future = erlfdb:get_range(Tx, <<"user/0">>, <<"user/1">>, [{wait, false}]),
..     [Result] = erlfdb:wait_for_all_interleaving(Tx, [Future]),
..     Result
.. end).
```
""".
-endif.
-spec get_range(database() | transaction(), key(), key(), [fold_option()]) ->
    fold_future() | list(mapped_kv()) | list(kv()).
get_range(?IS_DB = Db, StartKey, EndKey, Options) ->
    transactional(Db, fun(Tx) ->
        get_range(Tx, StartKey, EndKey, Options)
    end);
get_range(?IS_TX = Tx, StartKey, EndKey, Options) ->
    case erlfdb_util:get(Options, wait, true) of
        true ->
            Fun = fun(Rows, Acc) -> [Rows | Acc] end,
            Chunks = folding_get_range_and_wait(Tx, StartKey, EndKey, Fun, [], Options),
            lists:flatten(lists:reverse(Chunks));
        false ->
            fold_range_future(Tx, StartKey, EndKey, Options);
        interleaving ->
            SplitPoints = erlfdb:wait(
                get_range_split_points(
                    Tx, StartKey, EndKey, Options
                )
            ),
            Ranges = erlfdb_key:list_to_ranges(SplitPoints),

            Futures = [fold_range_future(Tx, SK, EK, Options) || {SK, EK} <- Ranges],
            Result = wait_for_all_interleaving(Tx, Futures),
            lists:flatten(Result)
    end;
get_range(?IS_SS = SS, StartKey, EndKey, Options) ->
    get_range(?GET_TX(SS), StartKey, EndKey, [{snapshot, true} | Options]).

-if(?DOCATTRS).
-doc """
Gets a range of key-value pairs from the database that begin with the given prefix.

This function never returns a `t:fold_future/0`. If you want future semantics, use `[{wait, false}]`
with `get_raange_startswith/3`.

*C API function*: [`fdb_transaction_get_range`](https://apple.github.io/foundationdb/api-c.html#c.fdb_transaction_get_range)
""".
-endif.
-spec get_range_startswith(database() | transaction(), key()) -> list(kv()).
get_range_startswith(DbOrTx, Prefix) ->
    get_range_startswith(DbOrTx, Prefix, []).

-if(?DOCATTRS).
-doc """
Equivalent to `get_range(Tx, Prefix, erlfdb_key:strinc(Prefix), Options).`
""".
-endif.
-spec get_range_startswith(database() | transaction(), key(), [fold_option()]) ->
    fold_future() | list(mapped_kv()) | list(kv()).
get_range_startswith(DbOrTx, Prefix, Options) ->
    get_range(DbOrTx, Prefix, erlfdb_key:strinc(Prefix), Options).

-if(?DOCATTRS).
-doc """
Equivalent to `get_mapped_range(Tx, StartKey, EndKey, []).`

This function never returns a `t:fold_future/0`. Use `[{wait, false}]` with `get_mapped_range/5` if you
want future semantics.
""".
-endif.
-spec get_mapped_range(database() | transaction(), key(), key(), mapper()) -> list(mapped_kv()).
get_mapped_range(DbOrTx, StartKey, EndKey, Mapper) ->
    get_mapped_range(DbOrTx, StartKey, EndKey, Mapper, []).

-if(?DOCATTRS).
-doc """
Experimental. A two-stage GetRange operation that uses the first retrieved list of key-value pairs
to do a secondary lookup.

To use this function, any keys or values defined by the mapper MUST be encoded with the FoundationDB Tuple layer.
Use `m:erlfdb_tuple` for this.

The `t:mapper/0` is an Erlang tuple that describes the Mapper specification as detailed by
[Everything about GetMappedRange](https://github.com/apple/foundationdb/wiki/Everything-about-GetMappedRange).

*C API function*: [`fdb_transaction_get_range`](https://apple.github.io/foundationdb/api-c.html#c.fdb_transaction_get_range)

## Motivation

GetMappedRange was created to support a common pattern when implementing indexed lookups. It can allow your Layer to
follow a single level of indirection: reading one key and then "hopping" over to read the key pointed to by that key.
Instead of doing so with 2 separate waits in your transaction, GetMappedRange sends the small mapping operation to
the FoundationDB server so that it may do it for us. In doing so, we effectively perform 2 chained gets with
a single network round trip between client and server.

[Data Modeling with Indirection](https://apple.github.io/foundationdb/data-modeling.html#indirection)

## Examples

Here is a minimal example. First we set up the following key-value pairs in the database:

```
(a, {b})
({b}, c)
```

Let's create our kvs:

```erlang
1> Db = erlfdb:open().
2> erlfdb:transactional(Db, fun(Tx) ->
..    erlfdb:set(Tx, <<"a">>, erlfdb_tuple:pack({<<"b">>})),
..    erlfdb:set(Tx, erlfdb_tuple:pack({<<"b">>}), <<"c">>)
.. end).
```

Now, we can retrieve the `<<"c">>` value in a single shot:

```erlang
3> Result = erlfdb:transactional(Tenant, fun(Tx) ->
..     erlfdb:get_mapped_range(
..         Tx,
..         <<"a">>,
..         erlfdb_key:strinc(<<"a">>),
..         {<<"{V[0]}">>, <<"{...}">>},
..         []
..     )
.. end).
```

The `Result` includes **both** of our setup key-value pairs using only a single network round-trip to
the FoundationDB server.
""".
-endif.
-spec get_mapped_range(database() | transaction(), key(), key(), mapper(), [fold_option()]) ->
    fold_future() | list(mapped_kv()).
get_mapped_range(DbOrTx, StartKey, EndKey, Mapper, Options) ->
    get_range(
        DbOrTx,
        StartKey,
        EndKey,
        lists:keystore(mapper, 1, Options, {mapper, erlfdb_tuple:pack(Mapper)})
    ).

-if(?DOCATTRS).
-doc """
Returns a list of keys that can split the given range into (roughly) equally sized chunks based on chunk_size.

*C API function*: [`fdb_transaction_get_range_split_points`](https://apple.github.io/foundationdb/api-c.html#c.fdb_transaction_get_range_split_points)
""".
-endif.
-spec get_range_split_points(database() | transaction(), key(), key(), [split_option()]) ->
    future() | list(key()).
get_range_split_points(?IS_DB = Db, StartKey, EndKey, Options) ->
    transactional(Db, fun(Tx) ->
        Future = get_range_split_points(Tx, StartKey, EndKey, Options),
        wait(Future)
    end);
get_range_split_points(?IS_TX = Tx, StartKey, EndKey, Options) ->
    % 10M
    ChunkSize = erlfdb_util:get(Options, chunk_size, 10000000),
    erlfdb_nif:transaction_get_range_split_points(Tx, StartKey, EndKey, ChunkSize).

-if(?DOCATTRS).
-doc """
Equivalent to `fold_range(DbOrTex, StartKey, EndKey, Fun, [])`.
""".
-endif.
-spec fold_range(database() | transaction(), key(), key(), function(), any()) -> any().
fold_range(DbOrTx, StartKey, EndKey, Fun, Acc) ->
    fold_range(DbOrTx, StartKey, EndKey, Fun, Acc, []).

-if(?DOCATTRS).
-doc """
Gets a range of key-value pairs. Executes a reducing function as the pairs are retrieved.

> #### Tip {: .tip}
>
> Use `get_range/5` with `wait_for_all_interleaving/2` instead.
""".
-endif.
-spec fold_range(database() | transaction(), key(), key(), function(), any(), [fold_option()]) ->
    any().
fold_range(?IS_DB = Db, StartKey, EndKey, Fun, Acc, Options) ->
    transactional(Db, fun(Tx) ->
        fold_range(Tx, StartKey, EndKey, Fun, Acc, Options)
    end);
fold_range(?IS_TX = Tx, StartKey, EndKey, Fun, Acc, Options) ->
    folding_get_range_and_wait(
        Tx,
        StartKey,
        EndKey,
        fun(Rows, InnerAcc) ->
            lists:foldl(Fun, InnerAcc, Rows)
        end,
        Acc,
        Options
    );
fold_range(?IS_SS = SS, StartKey, EndKey, Fun, Acc, Options) ->
    SSOptions = [{snapshot, true} | Options],
    fold_range(?GET_TX(SS), StartKey, EndKey, Fun, Acc, SSOptions).

-if(?DOCATTRS).
-doc """
Deprecated. Gets a `t:fold_future/0` from a key range.

> #### Tip {: .tip}
>
> Use `get_range/5` with option `[{wait, false}]` instead.
""".
-endif.
-spec fold_range_future(transaction() | snapshot(), key(), key(), [fold_option()]) -> fold_future().
fold_range_future(?IS_TX = Tx, StartKey, EndKey, Options) ->
    St = options_to_fold_st(StartKey, EndKey, Options),
    folding_get_future(Tx, St);
fold_range_future(?IS_SS = SS, StartKey, EndKey, Options) ->
    SSOptions = [{snapshot, true} | Options],
    fold_range_future(?GET_TX(SS), StartKey, EndKey, SSOptions).

-if(?DOCATTRS).
-doc """
Deprecated. Equivalent to `fold_mapped_range_future(Tx, StartKey, EndKey, Mapper, [])`.
""".
-endif.
-spec fold_mapped_range_future(transaction(), key(), key(), mapper()) -> any().
fold_mapped_range_future(Tx, StartKey, EndKey, Mapper) ->
    fold_mapped_range_future(Tx, StartKey, EndKey, Mapper, []).

-if(?DOCATTRS).
-doc """
Deprecated. Gets a `t:fold_future/0` from a mapped key range.

> #### Tip {: .tip}
>
> Use `get_mapped_range/5` with option `[{wait, false}]` instead.
""".
-endif.
-spec fold_mapped_range_future(transaction(), key(), key(), mapper(), [fold_option()]) ->
    any().
fold_mapped_range_future(Tx, StartKey, EndKey, Mapper, Options) ->
    fold_range_future(
        Tx,
        StartKey,
        EndKey,
        lists:keystore(mapper, 1, Options, {mapper, erlfdb_tuple:pack(Mapper)})
    ).

-if(?DOCATTRS).
-doc """
Deprecated. Equivalent to `fold_range_wait(Tx, FF, Fun, Acc, [])`.
""".
-endif.
-spec fold_range_wait(transaction() | snapshot(), fold_future(), function(), any()) -> any().
fold_range_wait(Tx, FF, Fun, Acc) ->
    fold_range_wait(Tx, FF, Fun, Acc, []).

-if(?DOCATTRS).
-doc """
Retrieves results from a `t:fold_future/0`. Executes a reducing function as the pairs are retrieved.

> #### Tip {: .tip}
>
> Use `wait_for_all_interleaving/2` instead.
""".
-endif.
-spec fold_range_wait(transaction() | snapshot(), fold_future(), function(), any(), [wait_option()]) ->
    any().
fold_range_wait(?IS_TX = Tx, ?IS_FOLD_FUTURE = FF, Fun, Acc, Options) ->
    wait_and_apply(Tx, [FF], Fun, Acc, Options);
fold_range_wait(?IS_SS = SS, ?IS_FOLD_FUTURE = FF, Fun, Acc, Options) ->
    fold_range_wait(?GET_TX(SS), FF, Fun, Acc, Options).

-if(?DOCATTRS).
-doc """
Sets a key to the given value.

*C API function*: [`fdb_transaction_set`](https://apple.github.io/foundationdb/api-c.html#c.fdb_transaction_set)

## Examples

In a transaction with a single operation:

```erlang
1> Db = erlfdb:open().
2> erlfdb:set(Db, <<"hello">>, <<"world">>).
```

In a transaction with many operations:

```erlang
1> Db = erlfdb:open().
2> erlfdb:transactional(Db, fun(Tx) ->
..     erlfdb:set(Tx, <<"hello">>, <<"world">>),
..     erlfdb:set(Tx, <<"foo">>, <<"bar">>)
.. end).
```
""".
-endif.
-spec set(database() | transaction() | snapshot(), key(), value()) -> ok.
set(?IS_DB = Db, Key, Value) ->
    transactional(Db, fun(Tx) ->
        set(Tx, Key, Value)
    end);
set(?IS_TX = Tx, Key, Value) ->
    erlfdb_nif:transaction_set(Tx, Key, Value);
set(?IS_SS = SS, Key, Value) ->
    set(?GET_TX(SS), Key, Value).

-if(?DOCATTRS).
-doc """
Clears a key in the database.

*C API function*: [`fdb_transaction_clear`](https://apple.github.io/foundationdb/api-c.html#c.fdb_transaction_clear)

## Examples

In a transaction with a single operation:

```erlang
1> Db = erlfdb:open().
2> erlfdb:clear(Db, <<"hello">>).
```

In a transaction with many operations:

```erlang
1> Db = erlfdb:open().
2> erlfdb:transactional(Db, fun(Tx) ->
..     erlfdb:clear(Tx, <<"hello">>),
..     erlfdb:clear(Tx, <<"foo">>)
.. end).
```
""".
-endif.
-spec clear(database() | transaction() | snapshot(), key()) -> ok.
clear(?IS_DB = Db, Key) ->
    transactional(Db, fun(Tx) ->
        clear(Tx, Key)
    end);
clear(?IS_TX = Tx, Key) ->
    erlfdb_nif:transaction_clear(Tx, Key);
clear(?IS_SS = SS, Key) ->
    clear(?GET_TX(SS), Key).

-if(?DOCATTRS).
-doc """
Clears a range of keys in the database.

Reminder: FoundationDB keys are ordered such that a single operation can work on many keys, as long as they are in a
contiguous range.

*C API function*: [`fdb_transaction_clear_range`](https://apple.github.io/foundationdb/api-c.html#c.fdb_transaction_clear_range)

## Examples

Clears all keys with prefix `<<"user/0">>` In a transaction with a single operation:

```erlang
1> Db = erlfdb:open().
2> erlfdb:clear_range(Db, <<"user/0">>, <<"user/1">>).
```

(!!) Clears all keys in the entire database (!!):

```erlang
1> Db = erlfdb:open().
2> erlfdb:clear_range(Db, <<>>, <<16#FF>>).
```
""".
-endif.
-spec clear_range(database() | transaction() | snapshot(), key(), key()) -> ok.
clear_range(?IS_DB = Db, StartKey, EndKey) ->
    transactional(Db, fun(Tx) ->
        clear_range(Tx, StartKey, EndKey)
    end);
clear_range(?IS_TX = Tx, StartKey, EndKey) ->
    erlfdb_nif:transaction_clear_range(Tx, StartKey, EndKey);
clear_range(?IS_SS = SS, StartKey, EndKey) ->
    clear_range(?GET_TX(SS), StartKey, EndKey).

-if(?DOCATTRS).
-doc """
Equivalent to `clear_range(DbOrTx, Prefix, erlfdb_key:strinc(Prefix)).`

*C API function*: [`fdb_transaction_clear_range`](https://apple.github.io/foundationdb/api-c.html#c.fdb_transaction_clear_range)
""".
-endif.
-spec clear_range_startswith(database() | transaction() | snapshot(), key()) -> ok.
clear_range_startswith(?IS_DB = Db, Prefix) ->
    transactional(Db, fun(Tx) ->
        clear_range_startswith(Tx, Prefix)
    end);
clear_range_startswith(?IS_TX = Tx, Prefix) ->
    EndKey = erlfdb_key:strinc(Prefix),
    erlfdb_nif:transaction_clear_range(Tx, Prefix, EndKey);
clear_range_startswith(?IS_SS = SS, Prefix) ->
    clear_range_startswith(?GET_TX(SS), Prefix).

-if(?DOCATTRS).
-doc """
Performs an atomic add on the value in the database.

*C API function*: [`fdb_transaction_atomic_op`](https://apple.github.io/foundationdb/api-c.html#c.fdb_transaction_atomic_op)

See `FDBMutationType.FDB_MUTATION_TYPE_ADD`.
""".
-endif.
-spec add(database() | transaction() | snapshot(), key(), atomic_operand()) -> ok.
add(DbOrTx, Key, Param) ->
    atomic_op(DbOrTx, Key, Param, add).

-if(?DOCATTRS).
-doc """
Performs an atomic bitwise 'and' on the value in the database.

*C API function*: [`fdb_transaction_atomic_op`](https://apple.github.io/foundationdb/api-c.html#c.fdb_transaction_atomic_op)

See `FDBMutationType.FDB_MUTATION_TYPE_AND`.
""".
-endif.
-spec bit_and(database() | transaction() | snapshot(), key(), atomic_operand()) -> ok.
bit_and(DbOrTx, Key, Param) ->
    atomic_op(DbOrTx, Key, Param, bit_and).

-if(?DOCATTRS).
-doc """
Performs an atomic bitwise 'or' on the value in the database.

*C API function*: [`fdb_transaction_atomic_op`](https://apple.github.io/foundationdb/api-c.html#c.fdb_transaction_atomic_op)

See `FDBMutationType.FDB_MUTATION_TYPE_OR`.
""".
-endif.
-spec bit_or(database() | transaction() | snapshot(), key(), atomic_operand()) -> ok.
bit_or(DbOrTx, Key, Param) ->
    atomic_op(DbOrTx, Key, Param, bit_or).

-if(?DOCATTRS).
-doc """
Performs an atomic bitwise 'xor' on the value in the database.

*C API function*: [`fdb_transaction_atomic_op`](https://apple.github.io/foundationdb/api-c.html#c.fdb_transaction_atomic_op)

See `FDBMutationType.FDB_MUTATION_TYPE_XOR`.
""".
-endif.
-spec bit_xor(database() | transaction() | snapshot(), key(), atomic_operand()) -> ok.
bit_xor(DbOrTx, Key, Param) ->
    atomic_op(DbOrTx, Key, Param, bit_xor).

-if(?DOCATTRS).
-doc """
Performs an atomic minimum on the value in the database.

*C API function*: [`fdb_transaction_atomic_op`](https://apple.github.io/foundationdb/api-c.html#c.fdb_transaction_atomic_op)

See `FDBMutationType.FDB_MUTATION_TYPE_MIN`.
""".
-endif.
-spec min(database() | transaction() | snapshot(), key(), atomic_operand()) -> ok.
min(DbOrTx, Key, Param) ->
    atomic_op(DbOrTx, Key, Param, min).

-if(?DOCATTRS).
-doc """
Performs an atomic maximum on the value in the database.

*C API function*: [`fdb_transaction_atomic_op`](https://apple.github.io/foundationdb/api-c.html#c.fdb_transaction_atomic_op)

See `FDBMutationType.FDB_MUTATION_TYPE_MAX`.
""".
-endif.
-spec max(database() | transaction() | snapshot(), key(), atomic_operand()) -> ok.
max(DbOrTx, Key, Param) ->
    atomic_op(DbOrTx, Key, Param, max).

-if(?DOCATTRS).
-doc """
Performs an atomic lexocogrpahic minimum on the value in the database.

*C API function*: [`fdb_transaction_atomic_op`](https://apple.github.io/foundationdb/api-c.html#c.fdb_transaction_atomic_op)

See `FDBMutationType.FDB_MUTATION_TYPE_BYTE_MIN`.
""".
-endif.
-spec byte_min(database() | transaction() | snapshot(), key(), atomic_operand()) -> ok.
byte_min(DbOrTx, Key, Param) ->
    atomic_op(DbOrTx, Key, Param, byte_min).

-if(?DOCATTRS).
-doc """
Performs an atomic lexocogrpahic maximum on the value in the database.

*C API function*: [`fdb_transaction_atomic_op`](https://apple.github.io/foundationdb/api-c.html#c.fdb_transaction_atomic_op)

See `FDBMutationType.FDB_MUTATION_TYPE_BYTE_MAX`.
""".
-endif.
-spec byte_max(database() | transaction() | snapshot(), key(), atomic_operand()) -> ok.
byte_max(DbOrTx, Key, Param) ->
    atomic_op(DbOrTx, Key, Param, byte_max).

-if(?DOCATTRS).
-doc """
Transforms key using a versionstamp for the transaction.

*C API function*: [`fdb_transaction_atomic_op`](https://apple.github.io/foundationdb/api-c.html#c.fdb_transaction_atomic_op)

See `FDBMutationType.FDB_MUTATION_TYPE_SET_VERSIONSTAMPED_KEY`.
""".
-endif.
-spec set_versionstamped_key(database() | transaction() | snapshot(), key(), atomic_operand()) ->
    ok.
set_versionstamped_key(DbOrTx, Key, Param) ->
    atomic_op(DbOrTx, Key, Param, set_versionstamped_key).

-if(?DOCATTRS).
-doc """
Transforms param using a versionstamp for the transaction.

*C API function*: [`fdb_transaction_atomic_op`](https://apple.github.io/foundationdb/api-c.html#c.fdb_transaction_atomic_op)

See `FDBMutationType.FDB_MUTATION_TYPE_SET_VERSIONSTAMPED_VALUE`.
""".
-endif.
-spec set_versionstamped_value(database() | transaction() | snapshot(), key(), atomic_operand()) ->
    ok.
set_versionstamped_value(DbOrTx, Key, Param) ->
    atomic_op(DbOrTx, Key, Param, set_versionstamped_value).

-if(?DOCATTRS).
-doc """
Performs one of the available atomic operations.

*C API function*: [`fdb_transaction_atomic_op`](https://apple.github.io/foundationdb/api-c.html#c.fdb_transaction_atomic_op)
""".
-endif.
-spec atomic_op(database() | transaction() | snapshot(), key(), atomic_operand(), atomic_mode()) ->
    ok.
atomic_op(?IS_DB = Db, Key, Param, Op) ->
    transactional(Db, fun(Tx) ->
        atomic_op(Tx, Key, Param, Op)
    end);
atomic_op(?IS_TX = Tx, Key, Param, Op) ->
    erlfdb_nif:transaction_atomic_op(Tx, Key, Param, Op);
atomic_op(?IS_SS = SS, Key, Param, Op) ->
    atomic_op(?GET_TX(SS), Key, Param, Op).

-if(?DOCATTRS).
-doc """
Equivalent to `watch(DbOrTx, Key, []).`
""".
-endif.
-spec watch(database() | transaction() | snapshot(), key()) -> future().
watch(DbTxSS, Key) ->
    watch(DbTxSS, Key, []).

-if(?DOCATTRS).
-doc """
Creates a watch on a key.

[An Overview how Watches Work](https://github.com/apple/foundationdb/wiki/An-Overview-how-Watches-Work)

*C API function*: [`fdb_transaction_watch`](https://apple.github.io/foundationdb/api-c.html#c.fdb_transaction_watch)

## Options

  - `to`: The local pid to which the `t:watch_future_ready_message/0` should be sent. Defaults to `self()`.

## Examples

In this example, when `wait/1` returns, the value at the key `<<"hello">>` has changed. We must then do a `get/2` if we
want to know what the value is.

```erlang
1> Db = erlfdb:open().
2> Watch = erlfdb:watch(Db, <<"hello">>).
3> ok = erlfdb:wait(Watch).
4> erlfdb:get(Db, <<"hello">>).
```

In this example, we rely on the future's `ready` message to be delivered to our calling process. This form of the
ready message (`t:watch_future_ready_message/0`) is valid only for futures created by `watch/2` and `watch/3`.

```erlang
1> Db = erlfdb:open(),
2> Watch = erlfdb:watch(Db, <<"hello">>).
3> receive
..    {_Ref, ready} ->
..        erlfdb:get(Db, <<"hello">>)
.. end
```
""".
-endif.
-spec watch(database() | transaction() | snapshot(), key(), list(watch_option())) -> future().
watch(?IS_DB = Db, Key, Options) ->
    transactional(Db, fun(Tx) ->
        watch(Tx, Key, Options)
    end);
watch(?IS_TX = Tx, Key, Options) ->
    To = proplists:get_value(to, Options, self()),
    erlfdb_nif:transaction_watch(Tx, Key, To);
watch(?IS_SS = SS, Key, Options) ->
    watch(?GET_TX(SS), Key, Options).

-if(?DOCATTRS).
-doc """
Does both a `get/2` and `watch/2` in a transaction.
""".
-endif.
-spec get_and_watch(database(), key()) -> {result(), future()}.
get_and_watch(?IS_DB = Db, Key) ->
    transactional(Db, fun(Tx) ->
        KeyFuture = get(Tx, Key),
        WatchFuture = watch(Tx, Key),
        {wait(KeyFuture), WatchFuture}
    end).

-if(?DOCATTRS).
-doc """
Does both a `set/3` and `watch/2` in a transaction.
""".
-endif.
-spec set_and_watch(database(), key(), value()) -> future().
set_and_watch(?IS_DB = Db, Key, Value) ->
    transactional(Db, fun(Tx) ->
        set(Tx, Key, Value),
        watch(Tx, Key)
    end).

-if(?DOCATTRS).
-doc """
Does both a `clear/2` and `watch/2` in a transaction.
""".
-endif.
-spec clear_and_watch(database(), key()) -> future().
clear_and_watch(?IS_DB = Db, Key) ->
    transactional(Db, fun(Tx) ->
        clear(Tx, Key),
        watch(Tx, Key)
    end).

-if(?DOCATTRS).
-doc """
Adds a read conflict to the transaction without actually reading the key.

This is not needed in simple cases.

*C API function*: [`fdb_transaction_add_conflict_range`](https://apple.github.io/foundationdb/api-c.html#c.fdb_transaction_add_conflict_range)
""".
-endif.
-spec add_read_conflict_key(transaction() | snapshot(), key()) -> ok.
add_read_conflict_key(TxObj, Key) ->
    add_read_conflict_range(TxObj, Key, <<Key/binary, 16#00>>).

-if(?DOCATTRS).
-doc """
Adds a read conflict to the transaction without actually reading the range.

This is not needed in simple cases.

*C API function*: [`fdb_transaction_add_conflict_range`](https://apple.github.io/foundationdb/api-c.html#c.fdb_transaction_add_conflict_range)
""".
-endif.
-spec add_read_conflict_range(transaction() | snapshot(), key(), key()) -> ok.
add_read_conflict_range(TxObj, StartKey, EndKey) ->
    add_conflict_range(TxObj, StartKey, EndKey, read).

-if(?DOCATTRS).
-doc """
Adds a write conflict to the transaction without actually writing to the key.

This is not needed in simple cases.

*C API function*: [`fdb_transaction_add_conflict_range`](https://apple.github.io/foundationdb/api-c.html#c.fdb_transaction_add_conflict_range)
""".
-endif.
-spec add_write_conflict_key(transaction() | snapshot(), key()) -> ok.
add_write_conflict_key(TxObj, Key) ->
    add_write_conflict_range(TxObj, Key, <<Key/binary, 16#00>>).

-if(?DOCATTRS).
-doc """
Adds a write conflict to the transaction without actually writing to the range.

This is not needed in simple cases.

*C API function*: [`fdb_transaction_add_conflict_range`](https://apple.github.io/foundationdb/api-c.html#c.fdb_transaction_add_conflict_range)
""".
-endif.
-spec add_write_conflict_range(transaction() | snapshot(), key(), key()) -> ok.
add_write_conflict_range(TxObj, StartKey, EndKey) ->
    add_conflict_range(TxObj, StartKey, EndKey, write).

-if(?DOCATTRS).
-doc """
Adds a conflict to the transaction without actually performing the associated action.

This is not needed in simple cases.

*C API function*: [`fdb_transaction_add_conflict_range`](https://apple.github.io/foundationdb/api-c.html#c.fdb_transaction_add_conflict_range)
""".
-endif.
-spec add_conflict_range(transaction() | snapshot(), key(), key(), read | write) -> ok.
add_conflict_range(?IS_TX = Tx, StartKey, EndKey, Type) ->
    erlfdb_nif:transaction_add_conflict_range(Tx, StartKey, EndKey, Type);
add_conflict_range(?IS_SS = SS, StartKey, EndKey, Type) ->
    add_conflict_range(?GET_TX(SS), StartKey, EndKey, Type).

-if(?DOCATTRS).
-doc """
Sets the snapshot read version used by a transaction.

This is not needed in simple cases.

*C API function*: [`fdb_transaction_set_read_version`](https://apple.github.io/foundationdb/api-c.html#c.fdb_transaction_set_read_version)
""".
-endif.
-spec set_read_version(transaction() | snapshot(), version()) -> ok.
set_read_version(?IS_TX = Tx, Version) ->
    erlfdb_nif:transaction_set_read_version(Tx, Version);
set_read_version(?IS_SS = SS, Version) ->
    set_read_version(?GET_TX(SS), Version).

-if(?DOCATTRS).
-doc """
Gets the snapshot read version used by a transaction.

This is not needed in simple cases.

*C API function*: [`fdb_transaction_get_read_version`](https://apple.github.io/foundationdb/api-c.html#c.fdb_transaction_get_read_version)
""".
-endif.
-spec get_read_version(transaction() | snapshot()) -> future().
get_read_version(?IS_TX = Tx) ->
    erlfdb_nif:transaction_get_read_version(Tx);
get_read_version(?IS_SS = SS) ->
    get_read_version(?GET_TX(SS)).

-if(?DOCATTRS).
-doc """
Retrieves the database version number at which a given transaction was committed.

This is not needed in simple cases. Not compatible with `transactional/2`.

*C API function*: [`fdb_transaction_get_committed_version`](https://apple.github.io/foundationdb/api-c.html#c.fdb_transaction_get_committed_version)
""".
-endif.
-spec get_committed_version(transaction() | snapshot()) -> version().
get_committed_version(?IS_TX = Tx) ->
    erlfdb_nif:transaction_get_committed_version(Tx);
get_committed_version(?IS_SS = SS) ->
    get_committed_version(?GET_TX(SS)).

-if(?DOCATTRS).
-doc """
Equivalent to `get_versionstamp(Tx).`
""".
-endif.
get_versionstamp(Tx) ->
    get_versionstamp(Tx, []).

-if(?DOCATTRS).
-doc """
Gets the versionstamp value that was used by any versionstamp operations in this transaction.

This is not needed in simple cases.

## Options

  - `to`: The local pid to which the `t:watch_future_ready_message/0` should be sent. Defaults to `self()`.

*C API function*: [`fdb_transaction_get_versionstamp`](https://apple.github.io/foundationdb/api-c.html#c.fdb_transaction_get_versionstamp)
""".
-endif.
-spec get_versionstamp(transaction() | snapshot(), list(get_versionstamp_option())) -> future().
get_versionstamp(?IS_TX = Tx, Options) ->
    To = proplists:get_value(to, Options, self()),
    erlfdb_nif:transaction_get_versionstamp(Tx, To);
get_versionstamp(?IS_SS = SS, Options) ->
    get_versionstamp(?GET_TX(SS), Options).

-if(?DOCATTRS).
-doc """
Gets the approximate transaction size so far.

*C API function*: [`fdb_transaction_get_approximate_size`](https://apple.github.io/foundationdb/api-c.html#c.fdb_transaction_get_approximate_size)
""".
-endif.
-spec get_approximate_size(transaction() | snapshot()) -> future().
get_approximate_size(?IS_TX = Tx) ->
    erlfdb_nif:transaction_get_approximate_size(Tx);
get_approximate_size(?IS_SS = SS) ->
    get_approximate_size(?GET_TX(SS)).

-if(?DOCATTRS).
-doc """
Gets a local auto-incrementing integer for this transaction.

Each time this function is executed, a local counter on the transaction is incremented,
and the value returned.

This integer is useful in combination with versionstamps to ensure uniqueness
of versionstamped keys and values for your transaction.

## Examples

```erlang
1> erlfdb:transactional(Db, fun(Tx) ->
..
..   Key1 = erlfdb_tuple:pack_vs({<<"sample">>,
..          {versionstamp, 16#ffffffffffffffff, 16#ffff, erlfdb:get_next_tx_id(Tx)}}),
..   erlfdb:set_versionstamped_key(Key1, <<"hello">>),
..
..   Key2 = erlfdb_tuple:pack_vs({<<"sample">>,
..          {versionstamp, 16#ffffffffffffffff, 16#ffff, erlfdb:get_next_tx_id(Tx)}}),
..   erlfdb:set_versionstamped_key(Key2, <<"world">>)
..
.. end)
```

Without `get_next_tx_id`, the versionstamped keys generated at commit time would collide, because
exactly one versionstamp is created at commit time.
""".
-endif.
-spec get_next_tx_id(transaction() | snapshot()) -> non_neg_integer().
get_next_tx_id(?IS_TX = Tx) ->
    erlfdb_nif:transaction_get_next_tx_id(Tx);
get_next_tx_id(?IS_SS = SS) ->
    get_next_tx_id(?GET_TX(SS)).

-if(?DOCATTRS).
-doc """
Returns true if all operations on the transaction up until now have been reads.
""".
-endif.
-spec is_read_only(transaction() | snapshot()) -> boolean().
is_read_only(?IS_TX = Tx) ->
    erlfdb_nif:transaction_is_read_only(Tx);
is_read_only(?IS_SS = SS) ->
    is_read_only(?GET_TX(SS)).

-if(?DOCATTRS).
-doc """
Returns true if at least one operation on the transaction up until now has been a watch.
""".
-endif.
-spec has_watches(transaction() | snapshot()) -> boolean().
has_watches(?IS_TX = Tx) ->
    erlfdb_nif:transaction_has_watches(Tx);
has_watches(?IS_SS = SS) ->
    has_watches(?GET_TX(SS)).

-if(?DOCATTRS).
-doc """
Returns false if `disallow_writes` was set on the transaction.
""".
-endif.
-spec get_writes_allowed(transaction() | snapshot()) -> boolean().
get_writes_allowed(?IS_TX = Tx) ->
    erlfdb_nif:transaction_get_writes_allowed(Tx);
get_writes_allowed(?IS_SS = SS) ->
    get_writes_allowed(?GET_TX(SS)).

-if(?DOCATTRS).
-doc """
Returns a value where 0 indicates that the client is idle and 1 (or larger) indicates that the client is saturated. By default, this value is updated every second.

*C API function*: [`fdb_database_get_main_thread_busyness`](https://apple.github.io/foundationdb/api-c.html#c.fdb_database_get_main_thread_busyness)
""".
-endif.
-spec get_main_thread_busyness(database()) -> float().
get_main_thread_busyness(?IS_DB = Db) ->
    erlfdb_nif:database_get_main_thread_busyness(Db).

-if(?DOCATTRS).
-doc """
Returns a JSON binary-string containing database client-side status information.

*C API function*: [`fdb_database_get_client_status`](https://apple.github.io/foundationdb/api-c.html#c.fdb_database_get_client_status)
""".
-endif.
-spec get_client_status(database()) -> future().
get_client_status(?IS_DB = Db) ->
    erlfdb_nif:database_get_client_status(Db).

-if(?DOCATTRS).
-doc """
Returns a list of public network addresses as strings, one for each of the storage servers responsible for storing key_name and its associated value.

*C API function*: [`fdb_transaction_get_addresses_for_key`](https://apple.github.io/foundationdb/api-c.html#c.fdb_transaction_get_addresses_for_key)
""".
-endif.
-spec get_addresses_for_key(database() | transaction() | snapshot(), key()) -> future() | result().
get_addresses_for_key(?IS_DB = Db, Key) ->
    transactional(Db, fun(Tx) ->
        wait(get_addresses_for_key(Tx, Key))
    end);
get_addresses_for_key(?IS_TX = Tx, Key) ->
    erlfdb_nif:transaction_get_addresses_for_key(Tx, Key);
get_addresses_for_key(?IS_SS = SS, Key) ->
    get_addresses_for_key(?GET_TX(SS), Key).

-if(?DOCATTRS).
-doc """
Returns an estimated byte size of the key range.

*C API function*: [`fdb_transaction_get_estimated_range_size_bytes`](https://apple.github.io/foundationdb/api-c.html#c.fdb_transaction_get_estimated_range_size_bytes)
""".
-endif.
-spec get_estimated_range_size(transaction() | snapshot(), key(), key()) -> future().
get_estimated_range_size(?IS_TX = Tx, StartKey, EndKey) ->
    erlfdb_nif:transaction_get_estimated_range_size(Tx, StartKey, EndKey);
get_estimated_range_size(?IS_SS = SS, StartKey, EndKey) ->
    erlfdb_nif:transaction_get_estimated_range_size(?GET_TX(SS), StartKey, EndKey).

-if(?DOCATTRS).
-doc """
Gets any conflicting keys on this transaction.
""".
-endif.
-spec get_conflicting_keys(transaction()) -> any().
get_conflicting_keys(?IS_TX = Tx) ->
    StartKey = <<16#FF, 16#FF, "/transaction/conflicting_keys/">>,
    EndKey = <<16#FF, 16#FF, "/transaction/conflicting_keys/", 16#FF>>,
    get_range(Tx, StartKey, EndKey).

-if(?DOCATTRS).
-doc """
Implements the recommended retry and backoff behavior for a transaction.

*C API function*: [`fdb_transaction_on_error`](https://apple.github.io/foundationdb/api-c.html#c.fdb_transaction_on_error)

> #### Tip {: .tip}
>
> Use `transactional/2` instead.
""".
-endif.
-spec on_error(transaction() | snapshot(), error() | integer()) -> future().
on_error(?IS_TX = Tx, {erlfdb_error, ErrorCode}) ->
    on_error(Tx, ErrorCode);
on_error(?IS_TX = Tx, ErrorCode) ->
    erlfdb_nif:transaction_on_error(Tx, ErrorCode);
on_error(?IS_SS = SS, Error) ->
    on_error(?GET_TX(SS), Error).

-if(?DOCATTRS).
-doc """
Evaluates a predicate against an error code.

*C API function*: [`fdb_error_predicate`](https://apple.github.io/foundationdb/api-c.html#c.fdb_error_predicate)
""".
-endif.
-spec error_predicate(error_predicate(), error() | integer()) -> boolean().
error_predicate(Predicate, {erlfdb_error, ErrorCode}) ->
    error_predicate(Predicate, ErrorCode);
error_predicate(Predicate, ErrorCode) ->
    erlfdb_nif:error_predicate(Predicate, ErrorCode).

-if(?DOCATTRS).
-doc """
Gets the last error stored by erlfdb in the process dictionary.
""".
-endif.
-spec get_last_error() -> error() | undefined.
get_last_error() ->
    erlang:get(?ERLFDB_ERROR).

-if(?DOCATTRS).
-doc """
Returns a (somewhat) human-readable English message from an error code.

*C API function*: [`fdb_get_error`](https://apple.github.io/foundationdb/api-c.html#c.fdb_get_error)
""".
-endif.
-spec get_error_string(integer()) -> binary().
get_error_string(ErrorCode) when is_integer(ErrorCode) ->
    erlfdb_nif:get_error(ErrorCode).

-spec clear_erlfdb_error() -> ok.
clear_erlfdb_error() ->
    put(?ERLFDB_ERROR, undefined).

-spec do_transaction(transaction(), function(), integer()) -> any().
do_transaction(?IS_TX = Tx, UserFun, Depth) ->
    try
        Ret = UserFun(Tx),
        case is_read_only(Tx) andalso not has_watches(Tx) of
            true -> ok;
            false -> wait(commit(Tx), [{timeout, infinity}])
        end,
        Ret
    catch
        error:{erlfdb_error, Code} ->
            put(?ERLFDB_ERROR, Code),
            wait(on_error(Tx, Code), [{timeout, infinity}]),
            if
                Depth == 0 ->
                    Result = do_transaction(Tx, UserFun, Depth + 1),

                    % Entering a Depth >=1 signals that previously attempted
                    % futures may still have ready messages in the message
                    % queue. We'll flush them out here, allowing others to
                    % be tail calls.
                    flush_transaction_ready_messages(Tx),

                    Result;
                true ->
                    do_transaction(Tx, UserFun, Depth + 1)
            end
    end.

-spec folding_get_range_and_wait(transaction(), key(), key(), function(), any(), [fold_option()]) ->
    any().
folding_get_range_and_wait(?IS_TX = Tx, StartKey, EndKey, Fun, Acc, Options) ->
    St = options_to_fold_st(StartKey, EndKey, Options),
    fold_interleaving_and_wait(Tx, [St], Fun, Acc, Options).

-spec fold_interleaving_and_wait(transaction(), [#fold_st{}], function(), any(), [wait_option()]) ->
    any().
fold_interleaving_and_wait(Tx, Sts = [#fold_st{} | _], Fun, Acc, Options) ->
    FFs = [folding_get_future(Tx, St) || St = #fold_st{} <- Sts],

    wait_and_apply(Tx, FFs, Fun, Acc, Options).

-spec wait_and_apply(
    transaction() | snapshot(), [fold_future()], function(), any(), [
        wait_option()
    ]
) -> any().
wait_and_apply(Tx, FFs, Fun, Acc, Options) ->
    Sts = [St || #fold_future{st = St} <- FFs],

    {NewSts, NewAcc} = lists:foldl(
        fun
            (#fold_future{future = undefined}, {Sts0, Acc0}) ->
                {Sts0, Acc0};
            (FF, {Sts0, Acc0}) ->
                #fold_future{future = Future, st = St0} = FF,
                #fold_st{from = From0} = St0,
                Result = wait(Future, Options),
                case handle_fold_st_result(FF, Result) of
                    {ResultTuple, NewSt = #fold_st{from = From0}} ->
                        folding_apply(
                            lists:keyreplace(From0, #fold_st.from, Sts0, NewSt),
                            From0,
                            ResultTuple,
                            Fun,
                            Acc0,
                            Options
                        );
                    ResultTuple ->
                        folding_apply(Sts0, From0, ResultTuple, Fun, Acc0, Options)
                end
        end,
        {Sts, Acc},
        FFs
    ),

    case NewSts of
        [] ->
            NewAcc;
        _ ->
            fold_interleaving_and_wait(Tx, NewSts, Fun, NewAcc, Options)
    end.

handle_fold_st_result(?IS_FOLD_FUTURE = FF, {RawRows, Count, HasMore}) ->
    #fold_future{st = St} = FF,
    #fold_st{
        start_key = StartKey,
        end_key = EndKey,
        limit = Limit,
        iteration = Iteration,
        reverse = Reverse
    } = St,

    Count = length(RawRows),

    % If our limit is within the current set of
    % rows we need to truncate the list
    Rows =
        if
            Limit == 0 orelse Limit > Count -> RawRows;
            true -> lists:sublist(RawRows, Limit)
        end,

    % Determine if we have more rows to iterate
    Recurse = (Rows /= []) and (Limit == 0 orelse Limit > Count) and HasMore,

    if
        not Recurse ->
            {done, Rows};
        true ->
            LastKey = get_last_key(Rows, St),
            {NewStartKey, NewEndKey} =
                case Reverse /= 0 of
                    true ->
                        {StartKey, erlfdb_key:first_greater_or_equal(LastKey)};
                    false ->
                        {erlfdb_key:first_greater_than(LastKey), EndKey}
                end,
            NewSt = St#fold_st{
                start_key = NewStartKey,
                end_key = NewEndKey,
                limit =
                    if
                        Limit == 0 -> 0;
                        true -> Limit - Count
                    end,
                iteration = Iteration + 1
            },
            {{more, Rows}, NewSt}
    end;
handle_fold_st_result(?IS_FOLD_FUTURE, Result) ->
    {done, Result}.

-spec folding_apply(list(#fold_st{}), future(), {more | done, any()}, function(), any(), [
    wait_option()
]) -> {list(#fold_st{}), any()}.
folding_apply(Sts0, Ref0, {more, Result0}, Fun, Acc0, Options) ->
    #fold_st{idx = Idx} = lists:keyfind(Ref0, #fold_st.from, Sts0),
    {Sts0, (fold_wrap(Fun, Idx, Options))(Result0, Acc0)};
folding_apply(Sts0, Ref0, {done, Result0}, Fun, Acc0, Options) ->
    {value, #fold_st{idx = Idx}, Sts1} = lists:keytake(Ref0, #fold_st.from, Sts0),
    {Sts1, (fold_wrap(Fun, Idx, Options))(Result0, Acc0)}.

-spec fold_wrap(function(), undefined | non_neg_integer(), [wait_option()]) -> function().
fold_wrap(Fun, Idx, Options) ->
    case proplists:get_value(with_index, Options, false) of
        false ->
            Fun;
        true ->
            fun(X, Acc) -> Fun({X, Idx}, Acc) end
    end.

-spec get_last_key(list(), #fold_st{}) -> key().
get_last_key(Rows, #fold_st{mapper = undefined}) ->
    {K, _V} = lists:last(Rows),
    K;
get_last_key(Rows, #fold_st{mapper = _Mapper}) ->
    {KV, _, _} = lists:last(Rows),
    {K, _} = KV,
    K.

-spec folding_get_future(transaction(), #fold_st{}) -> fold_future().
folding_get_future(?IS_TX = Tx, #fold_st{mapper = undefined} = St) ->
    #fold_st{
        start_key = StartKey,
        end_key = EndKey,
        limit = Limit,
        target_bytes = TargetBytes,
        streaming_mode = StreamingMode,
        iteration = Iteration,
        snapshot = Snapshot,
        reverse = Reverse
    } = St,

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

    NewSt =
        case St of
            #fold_st{from = undefined} -> St#fold_st{from = Future};
            _ -> St
        end,

    #fold_future{st = NewSt, future = Future};
folding_get_future(?IS_TX = Tx, #fold_st{} = St) ->
    #fold_st{
        start_key = StartKey,
        end_key = EndKey,
        mapper = Mapper,
        limit = Limit,
        target_bytes = TargetBytes,
        streaming_mode = StreamingMode,
        iteration = Iteration,
        snapshot = Snapshot,
        reverse = Reverse
    } = St,

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

    NewSt =
        case St of
            #fold_st{from = undefined} -> St#fold_st{from = Future};
            _ -> St
        end,

    #fold_future{st = NewSt, future = Future}.

-spec options_to_fold_st(key(), key(), [fold_option()]) -> #fold_st{}.
options_to_fold_st(StartKey, EndKey, Options) ->
    Reverse =
        case erlfdb_util:get(Options, reverse, false) of
            true -> 1;
            false -> 0;
            I when is_integer(I) -> I
        end,
    #fold_st{
        mapper = erlfdb_util:get(Options, mapper),
        start_key = erlfdb_key:to_selector(StartKey),
        end_key = erlfdb_key:to_selector(EndKey),
        limit = erlfdb_util:get(Options, limit, 0),
        target_bytes = erlfdb_util:get(Options, target_bytes, 0),
        streaming_mode = erlfdb_util:get(Options, streaming_mode, want_all),
        iteration = erlfdb_util:get(Options, iteration, 1),
        snapshot = erlfdb_util:get(Options, snapshot, false),
        reverse = Reverse,
        from = undefined
    }.

-spec flush_future_message(future()) -> ok.
flush_future_message(?IS_FUTURE = Future) ->
    erlfdb_nif:future_silence(Future),
    {erlfdb_future, MsgRef, _Res} = Future,
    receive
        {MsgRef, ready} -> ok;
        {{_TxRef, MsgRef}, ready} -> ok
    after 0 -> ok
    end.

flush_transaction_ready_messages({erlfdb_transaction, TxRef} = Tx) ->
    receive
        {{TxRef, _}, ready} ->
            flush_transaction_ready_messages(Tx)
    after 0 ->
        ok
    end.

open_dist_key(Type, UidData) ->
    {?MODULE, open, Type, UidData}.

open_with_key(Key, ClusterFile) ->
    case persistent_term:get(Key, undefined) of
        undefined ->
            Db = create_database(ClusterFile),
            persistent_term:put(Key, Db),
            Db;
        Db ->
            Db
    end.
