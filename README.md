# An Erlang Binding to FoundationDB

[![CI](https://github.com/foundationdb-beam/erlfdb/actions/workflows/ci.yml/badge.svg)](https://github.com/foundationdb-beam/erlfdb/actions/workflows/ci.yml)

An Erlang library that wraps the [FoundationDB C API](https://apple.github.io/foundationdb/api-c.html) with a NIF.

We also provide a conforming implementation of the [Tuple] and [Directory] layers.

[Tuple]: https://github.com/apple/foundationdb/blob/master/design/tuple.md
[Directory]: https://apple.github.io/foundationdb/developer-guide.html#directories

This project originated as [apache/couchdb-erlfdb](https://github.com/apache/couchdb-erlfdb). This fork
was created in early 2024 to continue development.

## Dependencies

Refer to FoundationDB's [Getting Started on Linux] or [Getting Started on macOS].

[Getting Started on Linux]: https://apple.github.io/foundationdb/getting-started-linux.html
[Getting Started on macOS]: https://apple.github.io/foundationdb/getting-started-mac.html

Install the foundationdb-clients package to run erlfdb as a client to an existing
FoundationDB database.

Install the foundationdb-server package for running a test fdbserver on your local device.
This package is required to run the unit tests.

## Usage

<!-- tabs-open -->

### Erlang's rebar3

Add erlfdb as a dependency in your Erlang project's rebar.config:

```erlang
% rebar.config
{deps, [
    {erlfdb, "1.0.0"}
]}.
```

### Elixir's Mix

Add erlfdb as a dependency in your Elixir project's mix.exs:

```elixir
# mix.exs
defp deps do
  [
    {:erlfdb, "~> 1.0"}
  ]
end
```

<!-- tabs-close -->

### Example

A simple example showing how to open a database and read and write keys.

See the [erlfdb Documentation](https://hexdocs.pm/erlfdb/erlfdb.html) for more.

<!-- tabs-open -->

### Erlang

```erlang
1> Db = erlfdb:open(<<"/usr/local/etc/foundationdb/fdb.cluster">>).
{erlfdb_database,#Ref<0.2859661758.3941466120.85406>}
2> ok = erlfdb:set(Db, <<"foo">>, <<"bar">>).
ok
3> erlfdb:get(Db, <<"foo">>).
<<"bar">>
4> erlfdb:get(Db, <<"bar">>).
not_found
```

### Elixir

```elixir
iex> db = :erlfdb.open("/usr/local/etc/foundationdb/fdb.cluster")
{:erlfdb_database, #Reference<0.2859661758.3941466120.85406>}
iex> :ok = :erlfdb.set(db, "foo", "bar")
:ok
iex> :erlfdb.get(db, "foo")
"bar"
iex> :erlfdb.get(db, "bar")
:not_found
```

<!-- tabs-close -->

## Binding Tester

FoundationDB has a custom binding tester that can be used to test whether
changes have broken compatibility. The GitHub Action runs the Binding Tester
against the most recent supported version of FoundationDB.

## Developing erlfdb

### Building

    $ rebar3 compile

### Testing

    # rebar3 eunit

### Bypassing dependency checks

When you execute a rebar command, erlfdb attempts to detect the version of the fdbcli
installed on your system. If it cannot be detected, the rebar command is aborted.

To disable the abort, use `ERLFDB_ASSERT_FDBCLI=0`. For example, you can safely use
this for the `fmt` command, which does not do a compile action.

```bash
ERLFDB_ASSERT_FDBCLI=0 rebar3 fmt
```
