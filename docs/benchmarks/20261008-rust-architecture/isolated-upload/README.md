# Isolated upload comparison

Three alternating fresh-seed repetitions, five uploads per app per repetition.
All 15 actual thumbnails per app decoded into pixels. The input is the original
505,420-byte `black_hole.jpg` fixture. See [summary.json](summary.json) for
medians, ranges, derivative sizes and resources; individual results also retain
Rust's legacy avatar-first series, which precedes its actual-thumbnail series.
These measurements are not pooled with the main comparison.

After preparing the reference benchmark, reproduce with:

```sh
mise exec -- python scripts/resource_guard.py \
  --report-dir .build/resource-reports --memory-high-mib 768 --timeout 600 -- \
  python benchmarks/reference/additional.py upload --repetitions 3 \
  --out .build/comparison/isolated-upload-new
```

[Settings and versions](settings.json) · [Resource guard](resource-guard.json).
The guard recorded no memory-high, socket-throttling or OOM events.
