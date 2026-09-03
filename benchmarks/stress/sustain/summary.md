# Hamilton API stress test

- Target: `https://hamilton-blog-xiv5.onrender.com`
- Window: 2026-08-23T19:40:33.075024+00:00 → 2026-08-23T19:44:47.079296+00:00 (254.0s)
- Requests: **135121** (135121 ok, 0 errors, 0.00% error rate)
- Throughput: **532.2 req/s**, **2962.5 KiB/s**
- Latency ms: min 70.3 · p50 **83.1** · p95 **109.4** · p99 204.8 · max 991.7
- Status codes: `{'200': 131115, '404': 4006}`

## Endpoints

| Endpoint | N | RPS | p50 | p95 | p99 | errors | KiB/s |
|---|---:|---:|---:|---:|---:|---:|---:|
| blog_comments | 20275 | 80.9 | 84.3 | 112.5 | 214.8 | 0.00% | 1.2 |
| blog_doc | 56515 | 222.9 | 83.7 | 110.0 | 205.9 | 0.00% | 2632.7 |
| blog_index | 29883 | 117.8 | 82.0 | 108.3 | 203.4 | 0.00% | 329.6 |
| hello | 16261 | 64.1 | 81.5 | 107.2 | 197.6 | 0.00% | 1.2 |
| hello_name | 8181 | 32.6 | 81.6 | 107.6 | 198.4 | 0.00% | 0.6 |
| not_found | 4006 | 15.8 | 82.1 | 108.3 | 198.5 | 0.00% | 1.4 |

## Phases

- **warmup**: 8 req, 9.3 rps, p50 83.5 ms, p95 234.8 ms, errors 0.00%
- **c1**: 125 req, 10.5 rps, p50 82.7 ms, p95 197.4 ms, errors 0.00%
- **c50**: 134988 req, 560.3 rps, p50 83.1 ms, p95 109.4 ms, errors 0.00%

## Ceiling

- Baseline `c1` c=1: p95 197.4 ms, 10.5 rps (10.54 rps/worker)
- Last linear `c50` c=50: p95 109.4 ms, 560.3 rps
- Inflection not reached in this ramp.

## Network vs worker (curl, same-region)

- reused connect_ms: p50 0.0 ms, p95 0.9 ms
- reused tls_ms: p50 0.0 ms, p95 8.7 ms
- reused ttfb_ms: p50 207.1 ms, p95 248.0 ms
- reused total_ms: p50 207.2 ms, p95 248.1 ms
