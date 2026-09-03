# Hamilton API stress test

- Target: `https://hamilton-blog-xiv5.onrender.com`
- Window: 2026-08-23T19:36:50.385932+00:00 → 2026-08-23T19:39:22.983473+00:00 (152.6s)
- Requests: **77724** (77724 ok, 0 errors, 0.00% error rate)
- Throughput: **509.8 req/s**, **2851.8 KiB/s**
- Latency ms: min 71.2 · p50 **111.4** · p95 **305.9** · p99 427.9 · max 1048.2
- Status codes: `{'200': 75375, '404': 2349}`

## Endpoints

| Endpoint | N | RPS | p50 | p95 | p99 | errors | KiB/s |
|---|---:|---:|---:|---:|---:|---:|---:|
| blog_comments | 11580 | 76.2 | 111.1 | 303.0 | 413.6 | 0.00% | 1.1 |
| blog_doc | 32612 | 215.0 | 114.6 | 310.1 | 427.4 | 0.00% | 2545.4 |
| blog_index | 17172 | 112.6 | 110.2 | 304.7 | 428.1 | 0.00% | 315.0 |
| hello | 9352 | 61.7 | 105.6 | 298.2 | 443.7 | 0.00% | 1.1 |
| hello_name | 4659 | 30.6 | 104.8 | 299.6 | 427.1 | 0.00% | 0.6 |
| not_found | 2349 | 15.7 | 108.2 | 304.6 | 455.0 | 0.00% | 1.4 |

## Phases

- **warmup**: 8 req, 6.9 rps, p50 168.0 ms, p95 238.3 ms, errors 0.00%
- **c1**: 155 req, 9.9 rps, p50 92.8 ms, p95 201.4 ms, errors 0.00%
- **c8**: 1423 req, 89.3 rps, p50 82.6 ms, p95 109.3 ms, errors 0.00%
- **c18**: 3235 req, 202.0 rps, p50 82.6 ms, p95 108.5 ms, errors 0.00%
- **c32**: 6381 req, 352.9 rps, p50 83.2 ms, p95 112.8 ms, errors 0.00%
- **c50**: 10927 req, 543.7 rps, p50 83.5 ms, p95 117.1 ms, errors 0.00%
- **c100**: 19269 req, 842.5 rps, p50 107.4 ms, p95 184.2 ms, errors 0.00%
- **c150**: 18038 req, 863.5 rps, p50 175.8 ms, p95 273.7 ms, errors 0.00%
- **c200**: 18288 req, 862.0 rps, p50 239.5 ms, p95 374.2 ms, errors 0.00%

## Ceiling

- Baseline `c1` c=1: p95 201.4 ms, 9.9 rps (9.87 rps/worker)
- Last linear `c100` c=100: p95 184.2 ms, 842.5 rps
- **Inflection `c150` c=150**: efficiency drop; p95 273.7 ms, 863.5 rps (5.76 rps/worker)

## Network vs worker (curl, same-region)

- reused connect_ms: p50 0.0 ms, p95 0.9 ms
- reused tls_ms: p50 0.0 ms, p95 9.0 ms
- reused ttfb_ms: p50 157.2 ms, p95 260.2 ms
- reused total_ms: p50 157.3 ms, p95 260.2 ms
