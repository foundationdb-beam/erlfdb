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

-module(erlfdb_directory_cache).

-export([
    new/0,
    new/1,
    new/2,
    open/3,
    open/4,
    create_or_open/3,
    create_or_open/4,
    store/2,
    store/3,
    invalidate/2,
    invalidate/3,
    purge/0,
    purge/1,
    purge/2
]).

-define(DOCATTRS, ?OTP_RELEASE >= 27).

-if(?DOCATTRS).
-moduledoc """
An ETS-backed cache for `m:erlfdb_directory` nodes.

Opening a directory requires `1 + 2N` sequential round trips to FDB for a
path of depth N. This cache eliminates that cost for repeated opens of the
same path by storing the resolved directory node in an ETS table after the
first lookup.

## Usage

Create one cache at application startup and pass it alongside your
`erlfdb_directory` root wherever directories are opened:

```erlang
% Cache is linked to calling process (ETS)
_ = erlfdb_directory_cache:new(),

Root  = erlfdb_directory:root(),

Dir = erlfdb_directory_cache:create_or_open(Db, Root, [<<"customers">>, CustomerId]),
erlfdb_directory:pack(Dir, {some_field})
```

## Cache invalidation

Directory node names (and therefore subspace prefixes) are immutable once
created - they do not change when data is written, across restarts, or across
reconnects. Invalidation is only needed when a directory is explicitly moved
or removed, and should be performed co-located with that operation:

```erlang
erlfdb_directory:remove(Db, Root, Path),
erlfdb_directory_cache:invalidate(Root, Path)
```

Cache invalidation can be safely executed within an `erlfdb:transactional`
callback because it is idempotent. `ets:delete/2` takes effect immediately and
is not rolled back if the surrounding transaction retries - on each retry,
invalidation simply runs again, and deleting an already-absent key is a no-op.
A spurious eviction from a retried or aborted transaction carries no consistency
penalty: the cache is never a source of truth, only a read-through shortcut, so
any evicted entry is transparently re-populated from FDB on the next access.

## Transaction semantics

Passing a `Db` handle to `open/3,4` or `create_or_open/3,4` is always safe:
the directory operation runs in its own self-contained FDB transaction, and the
cache is populated only after that transaction successfully commits.

Passing a `Tx` handle (inside an outer `erlfdb:transactional` callback) is safe
for `open` and for `create_or_open` when the directory already exists, because a
stable directory's node name does not change between retries. It is **unsafe**
for `create_or_open` when the directory does not yet exist: the High Contention
Allocator assigns a new node name on each transaction attempt, so if the outer
transaction retries, the cache will hold a node name from an attempt that was
never committed.

For that case, perform the directory operation directly and populate the cache
explicitly after the outer transaction commits using `store/2,3`:

```erlang
Node = erlfdb:transactional(Db, fun(Tx) ->
    Dir = erlfdb_directory:create_or_open(Tx, Root, Path),
    %% ... other transactional work ...
    Dir
end),
erlfdb_directory_cache:store(Root, Node)
```

## Concurrency

All operations are safe to call from multiple processes simultaneously. Cache
misses use `ets:insert_new/2` so that only the first writer's result is kept;
concurrent openers for the same path discard their result and return the
winning entry.
""".
-endif.

-if(?DOCATTRS).
-doc """
Creates a new ETS-backed directory cache using `erlfdb_directory_cache` as
the table name. Equivalent to `new(erlfdb_directory_cache, [])`.
""".
-endif.
new() ->
    new(?MODULE, []).

-if(?DOCATTRS).
-doc """
Creates a new ETS-backed directory cache registered publicly with the given name.
Equivalent to `new(Name, [])`.
""".
-endif.
new(Name) ->
    new(Name, []).

-if(?DOCATTRS).
-doc """
Creates a new ETS-backed directory cache registered publicly with the given name.

The table is created as a named, public set with `read_concurrency` enabled so
that concurrent lookups are cheap. The returned value is the ETS table
identifier and can be passed to `open/4`, `create_or_open/4`, `store/3`, and
`invalidate/3`.
""".
-endif.
new(Name, _Options) ->
    ets:new(Name, [
        named_table,
        set,
        public,
        {read_concurrency, true}
    ]).

-if(?DOCATTRS).
-doc """
Opens a directory at `Path` under `Root`, using the default cache table.
Equivalent to `open(erlfdb_directory_cache, TxObj, Root, Path)`.
""".
-endif.
open(TxObj, Root, Path) ->
    open(?MODULE, TxObj, Root, Path).

-if(?DOCATTRS).
-doc """
Opens an existing directory at `Path` under `Root`, returning the cached node
if already known.

On a cache miss the directory is resolved from FDB via `erlfdb_directory:open/3`
and the result is stored in `Table`. Raises `{erlfdb_directory, {open_error,
path_missing, Path}}` if the directory does not exist; errors are not cached.
""".
-endif.
open(Table, TxObj, Root, Path) ->
    open_with_cache(Table, TxObj, Root, Path, fun erlfdb_directory:open/3).

-if(?DOCATTRS).
-doc """
Opens or creates a directory at `Path` under `Root`, using the default cache
table. Equivalent to `create_or_open(erlfdb_directory_cache, TxObj, Root, Path)`.
""".
-endif.
create_or_open(TxObj, Root, Path) ->
    create_or_open(?MODULE, TxObj, Root, Path).

-if(?DOCATTRS).
-doc """
Opens an existing directory at `Path` under `Root`, or creates it if absent,
returning the cached node if already known.

On a cache miss the directory is resolved (and created if necessary) via
`erlfdb_directory:create_or_open/3` and the result is stored in `Table`.
""".
-endif.
create_or_open(Table, TxObj, Root, Path) ->
    open_with_cache(Table, TxObj, Root, Path, fun erlfdb_directory:create_or_open/3).

-if(?DOCATTRS).
-doc """
Stores `Node` in the default cache table under `Root`.
Equivalent to `store(erlfdb_directory_cache, Root, Node)`.
""".
-endif.
store(Root, Node) ->
    store(?MODULE, Root, Node).

-if(?DOCATTRS).
-doc """
Stores a directory `Node` directly in `Table`, bypassing the FDB lookup.

Use this when a directory has been opened or created inside an outer
`erlfdb:transactional` callback that may retry — call `store/2,3` with the
committed node after the transaction returns, rather than letting
`create_or_open/3,4` populate the cache mid-transaction. See the
*Transaction semantics* section in the module documentation.

Unlike the cache miss path in `open/4` and `create_or_open/4`, this function
uses `ets:insert/2` rather than `ets:insert_new/2`, so it overwrites any
previously cached entry for the same path.
""".
-endif.
store(Table, Root, Node) ->
    RootPathLen = length(erlfdb_directory:get_path(Root)),
    AbsPath = erlfdb_directory:get_path(Node),
    RelPath = lists:nthtail(RootPathLen, AbsPath),
    ets:insert(Table, {path_key(Root, RelPath), Node, erlang:monotonic_time(millisecond)}).

-if(?DOCATTRS).
-doc """
Removes the entry for `Path` under `Root` from the default cache table.
Equivalent to `invalidate(erlfdb_directory_cache, Root, Path)`.
""".
-endif.
invalidate(Root, Path) ->
    invalidate(?MODULE, Root, Path).

-if(?DOCATTRS).
-doc """
Removes the entry for `Path` under `Root` from `Table` so that the next
`open/4` or `create_or_open/4` call re-resolves the directory from FDB.

Call this co-located with any `erlfdb_directory:move/4` or
`erlfdb_directory:remove/3` on the same path.
""".
-endif.
invalidate(Table, Root, Path) ->
    ets:delete(Table, path_key(Root, Path)).

-if(?DOCATTRS).
-doc """
Deletes all entries from the default cache table.
Equivalent to `purge(erlfdb_directory_cache, -1)`.
""".
-endif.
purge() ->
    purge(?MODULE, -1).

-if(?DOCATTRS).
-doc """
Deletes all entries from `Table`.
Equivalent to `purge(Table, -1)`.
""".
-endif.
purge(Table) ->
    purge(Table, -1).

-if(?DOCATTRS).
-doc """
Deletes entries from `Table` that were cached more than `Ttl` milliseconds ago.

A `Ttl` of `-1` matches all entries regardless of age, making `purge(Table, -1)`
equivalent to clearing the entire table.

Periodic purging can be scheduled with `timer:apply_interval(Ttl, erlfdb_directory_cache, purge, [Table, Ttl])`.
""".
-endif.
purge(Table, Ttl) ->
    Cutoff = erlang:monotonic_time(millisecond) - Ttl,
    ets:select_delete(Table, [{{'_', '_', '$1'}, [{'<', '$1', Cutoff}], [true]}]).

path_key(Root, Path) ->
    {erlfdb_directory:get_node_prefix(Root), Path}.

open_with_cache(Table, TxObj, Root, Path, Func) ->
    Key = path_key(Root, Path),
    case ets:lookup(Table, Key) of
        [{Key, Node, _CachedAt}] ->
            Node;
        [] ->
            Node = Func(TxObj, Root, Path),
            ets:insert_new(Table, {Key, Node, erlang:monotonic_time(millisecond)}),
            case ets:lookup(Table, Key) of
                [{Key, Cached, _CachedAt}] -> Cached;
                [] -> Node
            end
    end.
