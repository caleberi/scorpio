# Hamilton API stress test

- Target: `https://hamilton-blog-xiv5.onrender.com`
- Window: 2026-08-23T19:16:56.174005+00:00 → 2026-08-23T19:17:49.794752+00:00 (53.6s)
- Requests: **5798** (5798 ok, 0 errors, 0.00% error rate)
- Throughput: **108.6 req/s**, **602.5 KiB/s**
- Latency ms: min 70.7 · p50 **81.7** · p95 **109.0** · p99 238.9 · max 361.0
- Status codes: `{'200': 5637, '404': 161}`

## Endpoints

| Endpoint | N | RPS | p50 | p95 | p99 | errors | KiB/s |
|---|---:|---:|---:|---:|---:|---:|---:|
| blog_comments | 872 | 16.6 | 83.5 | 123.5 | 225.1 | 0.00% | 0.2 |
| blog_doc | 2432 | 45.6 | 82.1 | 108.4 | 245.5 | 0.00% | 534.5 |
| blog_index | 1286 | 25.3 | 80.4 | 106.9 | 200.2 | 0.00% | 70.8 |
| hello | 699 | 13.7 | 80.4 | 106.1 | 200.5 | 0.00% | 0.3 |
| hello_name | 348 | 6.6 | 80.7 | 109.9 | 248.8 | 0.00% | 0.1 |
| not_found | 161 | 3.0 | 80.0 | 110.8 | 207.8 | 0.00% | 0.3 |

## Phases

- **warmup**: 8 req, 6.5 rps, p50 228.0 ms, p95 262.0 ms
- **c2**: 212 req, 21.8 rps, p50 80.9 ms, p95 222.7 ms
- **c6**: 933 req, 66.9 rps, p50 82.7 ms, p95 108.2 ms
- **c12**: 2177 req, 136.1 rps, p50 81.0 ms, p95 107.5 ms
- **c18**: 2468 req, 204.0 rps, p50 82.2 ms, p95 109.1 ms
