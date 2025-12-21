# Changelog

## v0.3.3 (2025-12-21)

### Enhancements

  * (#57) Improve performance of the Tuple layer's encoding and decoding of strings/binaries.
  * (#50) Add support for caller to provide local target pid for watch and get_versionstamp ready messages. (e.g, `erlfdb:watch(Tx, <<"key>>, [{to, Pid}])`)
  * (#61) Add `erlfdb:get_main_thread_busyness/1` and `erlfdb:get_client_status/1`.
 
### Bug fixes

  * (#59) Fix deadlock when canceling a future

## v0.3.2 (2025-06-13)

### Bug fixes

  * Fix type spec for key_selector

## v0.3.1 (2025-04-04)

### Bug fixes

  * Use `external_client_library` instead of `external_client_directory` in default configuration. Using the directory should
    be reserved for when the operator has a collection of libfdb_c isolated from other libraries on the system.

## v0.3 (2025-04-03)

### API Change

  * `erlfdb:open*` functions now retrieve database objects from persistent_term. Operators that wish to maintain their own
    database objects should use `erlfdb:create_database/1` instead.

### Enhancements

  * (#46) Add support for `client_threads_per_version` config. See [FDB Client Threads](thread-design.html) for details.

### New contributors

Thank you to the following new contributors! :)

  * weaversam8

## v0.2.4 (2025-03-23)

### Bug fixes

  * (#43) For OTP >= 26, erlfdb NIF will no longer segfault on VM halt.

## v0.2.3 (2025-03-15)

### Bug fixes

  * (#36) Starting in v0.2.2, the ready message from a get_versionstamp future included
    the ref from the transaction, putting it at risk of being flushed in the after the
    transaction completes. Now, the ready message behaves much like the watch, where it
    is not tied to the transaction ref.
  * Sandboxes can now be specified with a subdirectory, allowing concurrent
    creation (`m:erlfdb_sandbox`)

### Enhancements

 * [Livebook | KvQueue](kv_queue.html): An interactive notebook that
 demonstrates the creation of a durable queue in FoundationDB.

## v0.2.2 (2024-01-16)

### Bug fixes

  * (#31) Previously, erlfdb could leak `{reference(), ready}` messages to the caller if
    the transaction UserFun was executed more than once. We will now flush such messages before
    `transactional/2` returns control to the caller. Watches are unaffected.
  * (#32) Fixed documentation for versionstamps in `m:erlfdb_tuple`.

### Enhancements

  * `m:erlfdb_sandbox`: Creates and starts a database on your local filesystem that is to be
    used as a sandbox. That is, it can be useful for development tasks like tutorials and unit tests.
    It should not be used in a production setting.

### New contributors

Thank you to the following new contributors! :)

* drowzy

## v0.2.1 (2024-11-20)

### Testing

  * The FDB Bindings Tester now runs under GitHub Actions
  * Added macOS GitHub Action

## v0.2.0 (2024-09-21)

### Bug fixes

  * Several type specs in `erlfdb` were corrected.

### Enhancements

  * `erlfdb:wait_for_all_interleaving/2`: Given a list of fold_future() or future(), calling this function will wait
    on the futures at once, and then continue to issue any remaining get_range or get_mapped_range until
    the result set is exhausted. This allows fdbserver to process multiple get_ranges at the same time,
    in a pipelined fashion.
  * `erlfdb:get_range_split_points/4`: Companion to `wait_for_all_interleaving`, this is an fdbserver-supported function
    that will split a given key range into a partitioning set of ranges for which the key-values for each section are
    approximately equal to the provided `chunk_size` option. There are limitations to this, namely that a hard
    maximum of 100 shards can be traversed. The default `chunk_size` is 10000000 (in Bytes).
  * `erlfdb:get_range*`: The default behavior of get_range is now more explicit in the type specs and with the `wait`
    option, with defaults to `true`. A value of `false` will return a fold_future(), and `interleaving` is
    an experimental feature that will use both `get_range_split_points` and `wait_for_all_interleaving` to retrieve the range.
