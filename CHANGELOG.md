# Changelog for v0.x

## v0.2.1 (TBD)

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
