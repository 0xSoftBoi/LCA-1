# Benchmarking

Print the high-level authenticated bridge workload without making performance
claims:

```bash
python3 -m bench.bridge_profile --profile authenticated
```

A measurement manifest must contain `real_backend_active: true` and measured
latency for all four primitive classes before totals can be calculated. Energy
is optional, but the output remains `null` until every primitive has measured
energy.

The output is a primitive sum, not an end-to-end bridge benchmark. Publish only
the latter as a system result.
