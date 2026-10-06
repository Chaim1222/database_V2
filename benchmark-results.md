# Migration 0031: isolated synthetic comparison

Server-side times; warmed samples; 400,000 wiki / 380,000 mech rows. This is not a production measurement.

| Operation | 0030 median ms | 0031 median ms |
|---|---:|---:|
| insert_500 | 7.21 | 8.15 |
| unchanged_upsert_500 | 1.81 | 2.51 |
| delete_500 | 0.92 | 1.81 |
| sync_insert_500 | 29.06 | 30.48 |
| sync_replay_500 | 19.59 | 19.89 |
| sync_delete_500 | 6.57 | 7.76 |
| refresh_counts | 69.89 | 64.58 |
| read_5000 | 3.01 | 2.96 |

Parallel writes deliberately hold each transaction 100 ms. Durations include that hold. Lock observations are samples, not exact cumulative waiting time.

```json
{
  "0030": [
    {
      "writer_ms": [
        109.502,
        114.947,
        114.36,
        113.944
      ],
      "max_observed_lock_waiters": 0,
      "lock_samples": 4,
      "intentional_hold_ms": 100
    },
    {
      "writer_ms": [
        116.804,
        115.941,
        108.936,
        114.537
      ],
      "max_observed_lock_waiters": 0,
      "lock_samples": 4,
      "intentional_hold_ms": 100
    },
    {
      "writer_ms": [
        110.9,
        112.906,
        111.556,
        116.228
      ],
      "max_observed_lock_waiters": 0,
      "lock_samples": 4,
      "intentional_hold_ms": 100
    }
  ],
  "0031": [
    {
      "writer_ms": [
        218.296,
        116.756,
        397.782,
        295.911
      ],
      "max_observed_lock_waiters": 3,
      "lock_samples": 9,
      "intentional_hold_ms": 100
    },
    {
      "writer_ms": [
        216.839,
        314.47,
        115.948,
        394.312
      ],
      "max_observed_lock_waiters": 3,
      "lock_samples": 9,
      "intentional_hold_ms": 100
    },
    {
      "writer_ms": [
        117.491,
        216.384,
        394.796,
        300.491
      ],
      "max_observed_lock_waiters": 3,
      "lock_samples": 9,
      "intentional_hold_ms": 100
    }
  ]
}
```

Counts and counters stayed correct after rollback. No production connection, real titles, Supabase secrets or migrations were used against a live database. Estimates in 0030 remain estimates; timing does not prove production suitability.