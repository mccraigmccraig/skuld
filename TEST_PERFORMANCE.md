# Test Performance Analysis

## Summary

634 tests run in ~0.5 seconds. While this seems slow given Skuld's ~0.7μs per-operation overhead, the slowness is **not Skuld** - it's JIT compilation and test infrastructure.

## Breakdown

### Raw Skuld Performance

```
100k Skuld ops: ~66ms (0.66 μs/op)
```

A typical `State.get -> State.put -> return` computation takes less than 1 microsecond.

### Where Test Time Goes

| Category              | Time       | Notes                                  |
|-----------------------|------------|----------------------------------------|
| Per-module JIT warmup | ~400ms     | 28 modules × ~15ms avg first-test cost |
| Genuinely slow tests  | ~50ms      | Timeouts, process spawning, Agent ops  |
| Fast tests (600+)     | ~6ms       | 0.00-0.01ms each once warmed up        |
| **Total**             | **~500ms** |                                        |

### Evidence

Running with `--trace` shows the pattern clearly:

```
# First test in module - pays JIT cost
* test bracket/3 releases resource when use throws (51.1ms)

# Subsequent tests - sub-millisecond  
* test bracket/3 nested brackets release inner (0.04ms)
* test bracket/3 preserves use error (0.00ms)
```

### Async vs Sync

```bash
mix test                  # 0.6s (async coordination overhead)
mix test --max-cases=1    # 0.5s (serial, slightly faster)
```

Async coordination adds ~100ms overhead for this test suite.

## Fast Test Profile

Tests that do genuinely slow operations (timeouts, process spawning) are tagged with `@tag :slow`. To run only fast tests:

```bash
mix test --exclude slow
```

This skips tests that:
- Wait for actual timeouts
- Spawn processes/agents for integration testing
- Do other inherently slow operations

## Conclusion

Skuld is fast (~0.7μs/op). Test suite overhead is dominated by unavoidable JIT compilation. The ~0.5s total runtime for 634 tests is reasonable and not worth optimizing further.
