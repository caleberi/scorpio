#!/usr/bin/env python3
"""Closed-loop HTTP stress test for the Hamilton / scorpio API.

Discovers packed slugs from GET /blog, ramps concurrency, and writes a
self-contained HTML report with latency, throughput, and size charts.

Example:
    python3 scripts/stress_test.py \\
        --base-url https://hamilton-blog-xiv5.onrender.com \\
        --output benchmarks/stress
"""

from __future__ import annotations

import argparse
import json
import math
import random
import statistics
import subprocess
import threading
import time
from collections import Counter, defaultdict
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from html import escape
from pathlib import Path
from urllib.parse import quote

import requests

DEFAULT_BASE = "https://hamilton-blog-xiv5.onrender.com"
USER_AGENT = "HamiltonStressTest/1.0 (+https://github.com/caleberi/scorpio)"

# Read-only mix. Comment writes are opt-in so a live deploy is not polluted.
DEFAULT_MIX = (
    ("hello", 0.12),
    ("hello_name", 0.06),
    ("blog_index", 0.22),
    ("blog_doc", 0.42),
    ("blog_comments", 0.15),
    ("not_found", 0.03),
)


@dataclass
class Sample:
    t: float
    latency_ms: float
    status: int
    endpoint: str
    method: str
    bytes_in: int
    ok: bool
    error: str = ""
    phase: str = ""
    ttfb_ms: float = 0.0
    concurrency: int = 0


@dataclass
class Phase:
    name: str
    concurrency: int
    duration_s: float


@dataclass
class RunConfig:
    base_url: str
    phases: list[Phase]
    timeout_s: float
    mix: tuple[tuple[str, float], ...]
    warmup: int
    abort_error_rate: float = 0.25
    abort_p95_mult: float = 2.5
    hello_only: bool = False


def percentile(values: list[float], p: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    rank = (len(ordered) - 1) * (p / 100.0)
    lo = int(math.floor(rank))
    hi = min(lo + 1, len(ordered) - 1)
    frac = rank - lo
    return ordered[lo] * (1.0 - frac) + ordered[hi] * frac


def summarize(samples: list[Sample]) -> dict:
    lat = [s.latency_ms for s in samples]
    ok = [s for s in samples if s.ok]
    err = [s for s in samples if not s.ok]
    if not samples:
        return {
            "count": 0,
            "ok": 0,
            "errors": 0,
            "error_rate": 0.0,
            "rps": 0.0,
            "bytes": 0,
        }
    span = max(s.t for s in samples) - min(s.t for s in samples)
    duration = span if span > 0 else max(s.latency_ms for s in samples) / 1000.0
    total_bytes = sum(s.bytes_in for s in samples)
    return {
        "count": len(samples),
        "ok": len(ok),
        "errors": len(err),
        "error_rate": len(err) / len(samples),
        "rps": len(samples) / duration if duration else 0.0,
        "bytes": total_bytes,
        "throughput_kib_s": (total_bytes / 1024.0) / duration if duration else 0.0,
        "latency_ms": {
            "min": min(lat),
            "mean": statistics.fmean(lat),
            "stdev": statistics.pstdev(lat) if len(lat) > 1 else 0.0,
            "p50": percentile(lat, 50),
            "p90": percentile(lat, 90),
            "p95": percentile(lat, 95),
            "p99": percentile(lat, 99),
            "max": max(lat),
        },
        "status_codes": dict(sorted(Counter(s.status for s in samples).items())),
    }


def compact_samples(samples: list[Sample], limit: int = 12000) -> list[dict]:
    if len(samples) <= limit:
        return [asdict(s) for s in samples]
    errors = [s for s in samples if not s.ok]
    oks = [s for s in samples if s.ok]
    budget = max(limit - len(errors), 500)
    stride = max(1, math.ceil(len(oks) / budget))
    kept = errors + oks[::stride]
    return [asdict(s) for s in kept]


def latency_series(samples: list[Sample], bucket_s: float = 1.0) -> list[dict]:
    if not samples:
        return []
    last = max(s.t for s in samples)
    n = int(math.ceil(last / bucket_s)) + 1
    buckets: list[list[Sample]] = [[] for _ in range(n)]
    for s in samples:
        buckets[min(int(s.t / bucket_s), n - 1)].append(s)
    out = []
    for i, group in enumerate(buckets):
        stats = summarize(group)
        lat = stats.get("latency_ms") or {}
        out.append(
            {
                "t": i * bucket_s,
                "count": stats["count"],
                "rps": stats["count"] / bucket_s,
                "errors": stats["errors"],
                "p50": lat.get("p50"),
                "p95": lat.get("p95"),
                "p99": lat.get("p99"),
                "concurrency": max((s.concurrency for s in group), default=0),
            }
        )
    return out


def analyze_ceiling(phases: list[Phase], by_phase: dict[str, dict]) -> dict:
    rows = []
    for phase in phases:
        if phase.name == "warmup" or phase.name not in by_phase:
            continue
        stats = by_phase[phase.name]
        lat = stats.get("latency_ms") or {}
        rps = stats.get("rps") or 0.0
        rows.append(
            {
                "name": phase.name,
                "concurrency": phase.concurrency,
                "count": stats["count"],
                "rps": rps,
                "rps_per_worker": rps / phase.concurrency if phase.concurrency else 0.0,
                "p50": lat.get("p50"),
                "p95": lat.get("p95"),
                "p99": lat.get("p99"),
                "error_rate": stats["error_rate"],
            }
        )
    if not rows:
        return {"rows": [], "inflection": None, "last_linear": None, "baseline": None}

    baseline = rows[0]
    base_p95 = baseline.get("p95") or 0.0
    base_eff = baseline.get("rps_per_worker") or 0.0
    inflection = None
    last_linear = baseline
    for prev, row in zip(rows, rows[1:]):
        p95 = row.get("p95") or 0.0
        prev_p95 = prev.get("p95") or 0.0
        climbed = base_p95 > 0 and p95 >= 1.5 * base_p95 and p95 >= 1.25 * prev_p95
        stalled = row["rps"] + 1e-6 < prev["rps"] * 0.97 and row["concurrency"] > prev["concurrency"]
        inefficient = base_eff > 0 and row["rps_per_worker"] < 0.65 * base_eff
        if climbed or stalled or inefficient:
            inflection = {
                **row,
                "reason": "p95 climbed" if climbed else ("throughput stalled" if stalled else "efficiency drop"),
            }
            break
        last_linear = row
    return {
        "baseline": baseline,
        "last_linear": last_linear,
        "inflection": inflection,
        "rows": rows,
    }


def probe_network(base_url: str, n: int = 12) -> dict:
    url = base_url.rstrip("/") + "/hello"
    fmt = "%{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total} %{http_code}\\n"

    def parse_line(line: str) -> dict | None:
        parts = line.strip().split()
        if len(parts) < 6:
            return None
        dns, connect, tls, ttfb, total, code = parts[:6]
        return {
            "dns_ms": float(dns) * 1000,
            "connect_ms": float(connect) * 1000,
            "tls_ms": float(tls) * 1000,
            "ttfb_ms": float(ttfb) * 1000,
            "total_ms": float(total) * 1000,
            "status": int(code) if code.isdigit() else 0,
        }

    cold: list[dict] = []
    for _ in range(min(n, 8)):
        raw = subprocess.check_output(
            ["curl", "-sS", "-o", "/dev/null", "-w", fmt, "--http1.1", "-A", USER_AGENT, url],
            text=True,
        )
        parsed = parse_line(raw)
        if parsed:
            cold.append(parsed)

    reused_cmd = ["curl", "-sS", "-o", "/dev/null", "-w", fmt, "--http1.1", "-A", USER_AGENT]
    reused_cmd.extend([url] * n)
    reused: list[dict] = []
    raw = subprocess.check_output(reused_cmd, text=True)
    for line in raw.splitlines():
        parsed = parse_line(line)
        if parsed:
            reused.append(parsed)

    def pack(rows: list[dict]) -> dict:
        if not rows:
            return {}
        keys = ("dns_ms", "connect_ms", "tls_ms", "ttfb_ms", "total_ms")
        return {
            k: {
                "min": min(r[k] for r in rows),
                "p50": percentile([r[k] for r in rows], 50),
                "p95": percentile([r[k] for r in rows], 95),
                "mean": statistics.fmean(r[k] for r in rows),
            }
            for k in keys
        }

    return {
        "url": url,
        "client": {
            "note": "This runner is in us-west-2 (Oregon). Cloudflare edge observed as PDX.",
            "expected_tcp_rtt_ms": "1-5 if origin is also Oregon",
        },
        "cold": pack(cold),
        "reused": pack(reused),
        "samples_cold": cold,
        "samples_reused": reused,
    }


class StressClient:
    def __init__(self, config: RunConfig) -> None:
        self.config = config
        self.base = config.base_url.rstrip("/")
        self.slugs: list[str] = []
        self.samples: list[Sample] = []
        self.lock = threading.Lock()
        self.stop = threading.Event()
        self.phase_name = "warmup"
        self.started_at = 0.0
        self.names = ("hamilton", "scorpio", "reader", "zig", "render")
        self.current_concurrency = 0
        self.aborted_at: str | None = None
        self.abort_reason = ""

    def discover(self) -> None:
        res = requests.get(
            f"{self.base}/blog",
            timeout=self.config.timeout_s,
            headers={"User-Agent": USER_AGENT},
        )
        res.raise_for_status()
        docs = res.json().get("documents") or []
        self.slugs = [d["slug"] for d in docs if d.get("slug")]
        if not self.slugs:
            raise RuntimeError("GET /blog returned no document slugs")

    def _pick(self) -> tuple[str, str, str]:
        roll = random.random()
        acc = 0.0
        mix = (("hello", 1.0),) if self.config.hello_only else self.config.mix
        kind = mix[-1][0]
        for name, weight in mix:
            acc += weight
            if roll <= acc:
                kind = name
                break
        slug = random.choice(self.slugs)
        if kind == "hello":
            return "GET", "/hello", "hello"
        if kind == "hello_name":
            return "GET", f"/hello/{random.choice(self.names)}", "hello_name"
        if kind == "blog_index":
            return "GET", "/blog", "blog_index"
        if kind == "blog_doc":
            return "GET", "/blog/" + quote(slug, safe="/"), "blog_doc"
        if kind == "blog_comments":
            return "GET", "/blog/" + quote(slug, safe="/") + "/comments", "blog_comments"
        return "GET", "/blog/does-not-exist/missing-post", "not_found"

    def _one(self, session: requests.Session) -> Sample:
        method, path, endpoint = self._pick()
        url = self.base + path
        t0 = time.perf_counter()
        status = 0
        nbytes = 0
        err = ""
        ok = False
        ttfb_ms = 0.0
        try:
            res = session.request(
                method,
                url,
                timeout=self.config.timeout_s,
                headers={"User-Agent": USER_AGENT, "Accept": "application/json"},
            )
            status = res.status_code
            ttfb_ms = res.elapsed.total_seconds() * 1000.0
            nbytes = len(res.content)
            expected = {200, 204} if endpoint != "not_found" else {404}
            ok = status in expected
            if not ok:
                err = f"HTTP {status}"
        except requests.RequestException as exc:
            err = type(exc).__name__
        latency = (time.perf_counter() - t0) * 1000.0
        return Sample(
            t=time.perf_counter() - self.started_at,
            latency_ms=latency,
            status=status,
            endpoint=endpoint,
            method=method,
            bytes_in=nbytes,
            ok=ok,
            error=err,
            phase=self.phase_name,
            ttfb_ms=ttfb_ms,
            concurrency=self.current_concurrency,
        )

    def _worker(self) -> None:
        session = requests.Session()
        adapter = requests.adapters.HTTPAdapter(pool_connections=4, pool_maxsize=4, max_retries=0)
        session.mount("https://", adapter)
        session.mount("http://", adapter)
        try:
            while not self.stop.is_set():
                sample = self._one(session)
                with self.lock:
                    self.samples.append(sample)
        finally:
            session.close()

    def warmup(self) -> None:
        session = requests.Session()
        self.phase_name = "warmup"
        for _ in range(self.config.warmup):
            sample = self._one(session)
            with self.lock:
                self.samples.append(sample)
        session.close()

    def run(self) -> dict:
        self.discover()
        self.started_at = time.perf_counter()
        wall_start = datetime.now(timezone.utc)
        self.warmup()

        workers: list[threading.Thread] = []
        baseline_p95: float | None = None
        ran_phases: list[Phase] = []
        try:
            for phase in self.config.phases:
                self.phase_name = phase.name
                self.current_concurrency = phase.concurrency
                needed = phase.concurrency - len(workers)
                for _ in range(max(0, needed)):
                    thread = threading.Thread(target=self._worker, daemon=True)
                    thread.start()
                    workers.append(thread)
                print(
                    f"phase={phase.name} concurrency={phase.concurrency} duration={phase.duration_s:.0f}s",
                    flush=True,
                )
                deadline = time.time() + phase.duration_s
                while time.time() < deadline:
                    time.sleep(0.25)
                ran_phases.append(phase)
                with self.lock:
                    phase_samples = [s for s in self.samples if s.phase == phase.name]
                stats = summarize(phase_samples)
                lat = stats.get("latency_ms") or {}
                p95 = lat.get("p95")
                print(
                    f"  n={stats['count']} rps={stats['rps']:.1f} p50={lat.get('p50')} "
                    f"p95={p95} errors={stats['error_rate']*100:.1f}%",
                    flush=True,
                )
                if phase.name in {"warmup"}:
                    continue
                if baseline_p95 is None and p95:
                    baseline_p95 = p95
                    continue
                if stats["error_rate"] >= self.config.abort_error_rate and stats["count"] >= 20:
                    self.aborted_at = phase.name
                    self.abort_reason = (
                        f"error rate {stats['error_rate']*100:.1f}% >= "
                        f"{self.config.abort_error_rate*100:.0f}% at {phase.name}"
                    )
                    break
                if (
                    baseline_p95
                    and p95
                    and p95 >= baseline_p95 * self.config.abort_p95_mult
                    and stats["count"] >= 20
                ):
                    self.aborted_at = phase.name
                    self.abort_reason = (
                        f"p95 {p95:.0f}ms >= {self.config.abort_p95_mult:.1f}x "
                        f"baseline {baseline_p95:.0f}ms at {phase.name}"
                    )
                    break
        finally:
            self.stop.set()
            join_deadline = time.time() + self.config.timeout_s + 2
            for thread in workers:
                remaining = join_deadline - time.time()
                if remaining <= 0:
                    break
                thread.join(timeout=remaining)

        wall_end = datetime.now(timezone.utc)
        samples = list(self.samples)
        by_endpoint: dict[str, list[Sample]] = defaultdict(list)
        by_phase: dict[str, list[Sample]] = defaultdict(list)
        for sample in samples:
            by_endpoint[sample.endpoint].append(sample)
            by_phase[sample.phase].append(sample)
        phase_stats = {k: summarize(v) for k, v in by_phase.items()}
        return {
            "target": self.base,
            "started_at": wall_start.isoformat(),
            "finished_at": wall_end.isoformat(),
            "duration_s": (wall_end - wall_start).total_seconds(),
            "slugs": self.slugs,
            "phases": [asdict(p) for p in ran_phases],
            "warmup": self.config.warmup,
            "timeout_s": self.config.timeout_s,
            "aborted_at": self.aborted_at,
            "abort_reason": self.abort_reason,
            "hello_only": self.config.hello_only,
            "overall": summarize(samples),
            "by_endpoint": {k: summarize(v) for k, v in sorted(by_endpoint.items())},
            "by_phase": phase_stats,
            "ceiling": analyze_ceiling(ran_phases, phase_stats),
            "series": latency_series(samples),
            "samples": compact_samples(samples),
        }


def _nice_max(value: float) -> float:
    if value <= 0:
        return 1.0
    exp = 10 ** math.floor(math.log10(value))
    for mult in (1, 2, 2.5, 5, 10):
        if value <= mult * exp:
            return mult * exp
    return 10 * exp


def _svg_axes(
    width: int,
    height: int,
    pad_l: int,
    pad_r: int,
    pad_t: int,
    pad_b: int,
    xmax: float,
    ymax: float,
    xlabel: str,
    ylabel: str,
    title: str,
) -> tuple[str, float, float, float, float]:
    plot_w = width - pad_l - pad_r
    plot_h = height - pad_t - pad_b
    xticks = 5
    yticks = 5
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" '
        f'role="img" aria-label="{escape(title)}">',
        f'<rect width="{width}" height="{height}" fill="#0f1419" rx="10"/>',
        f'<text x="{pad_l}" y="22" fill="#e8eef4" font-size="14" font-family="ui-sans-serif,system-ui">'
        f"{escape(title)}</text>",
        f'<text x="{pad_l + plot_w / 2}" y="{height - 8}" text-anchor="middle" fill="#8b9aab" '
        f'font-size="11" font-family="ui-sans-serif,system-ui">{escape(xlabel)}</text>',
        f'<text transform="translate(14 {pad_t + plot_h / 2}) rotate(-90)" text-anchor="middle" '
        f'fill="#8b9aab" font-size="11" font-family="ui-sans-serif,system-ui">{escape(ylabel)}</text>',
    ]
    for i in range(xticks + 1):
        x = pad_l + plot_w * i / xticks
        label = xmax * i / xticks
        parts.append(f'<line x1="{x:.1f}" y1="{pad_t}" x2="{x:.1f}" y2="{pad_t + plot_h}" stroke="#243040"/>')
        parts.append(
            f'<text x="{x:.1f}" y="{pad_t + plot_h + 16}" text-anchor="middle" fill="#8b9aab" '
            f'font-size="10" font-family="ui-sans-serif,system-ui">{label:.0f}</text>'
        )
    for i in range(yticks + 1):
        y = pad_t + plot_h - plot_h * i / yticks
        label = ymax * i / yticks
        parts.append(f'<line x1="{pad_l}" y1="{y:.1f}" x2="{pad_l + plot_w}" y2="{y:.1f}" stroke="#243040"/>')
        parts.append(
            f'<text x="{pad_l - 8}" y="{y + 3:.1f}" text-anchor="end" fill="#8b9aab" '
            f'font-size="10" font-family="ui-sans-serif,system-ui">{label:.0f}</text>'
        )
    return "\n".join(parts), pad_l, pad_t, plot_w, plot_h


def svg_scatter_lines(
    samples: list[dict],
    title: str,
    width: int = 720,
    height: int = 280,
) -> str:
    if not samples:
        return f"<p>{escape(title)}: no samples</p>"
    xs = [s["t"] for s in samples]
    ys = [s["latency_ms"] for s in samples]
    xmax = _nice_max(max(xs) if xs else 1)
    # Cap the y-axis at p99.5 so a single cold-start outlier does not squash the plot.
    cap = percentile(ys, 99.5) or max(ys)
    ymax = _nice_max(max(cap * 1.15, 1))
    head, ox, oy, pw, ph = _svg_axes(width, height, 56, 18, 36, 42, xmax, ymax, "time (s)", "latency (ms)", title)

    # Downsample scatter for SVG size.
    step = max(1, len(samples) // 800)
    dots = []
    for s in samples[::step]:
        x = ox + (s["t"] / xmax) * pw
        y = oy + ph - (min(s["latency_ms"], ymax) / ymax) * ph
        color = "#3dd68c" if s["ok"] else "#ff5d5d"
        dots.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="1.6" fill="{color}" fill-opacity="0.55"/>')

    def rolling(p: float, window: float = 3.0) -> list[tuple[float, float]]:
        ordered = sorted(samples, key=lambda s: s["t"])
        out: list[tuple[float, float]] = []
        lo = 0
        for i, s in enumerate(ordered):
            while ordered[lo]["t"] < s["t"] - window:
                lo += 1
            window_vals = [ordered[j]["latency_ms"] for j in range(lo, i + 1)]
            val = percentile(window_vals, p)
            if val is not None:
                out.append((s["t"], val))
        return out

    def polyline(points: list[tuple[float, float]], color: str, width_px: float = 1.8) -> str:
        if len(points) < 2:
            return ""
        stride = max(1, len(points) // 400)
        pts = []
        for t, v in points[::stride]:
            x = ox + (t / xmax) * pw
            y = oy + ph - (min(v, ymax) / ymax) * ph
            pts.append(f"{x:.1f},{y:.1f}")
        return f'<polyline fill="none" stroke="{color}" stroke-width="{width_px}" points="{" ".join(pts)}"/>'

    body = [
        head,
        *dots,
        polyline(rolling(50), "#7eb6ff", 2.0),
        polyline(rolling(95), "#f5c14a", 2.0),
        f'<circle cx="{ox + 12}" cy="{oy + 14}" r="3" fill="#3dd68c"/><text x="{ox + 20}" y="{oy + 18}" '
        f'fill="#c5d0db" font-size="11" font-family="ui-sans-serif,system-ui">ok</text>',
        f'<circle cx="{ox + 56}" cy="{oy + 14}" r="3" fill="#ff5d5d"/><text x="{ox + 64}" y="{oy + 18}" '
        f'fill="#c5d0db" font-size="11" font-family="ui-sans-serif,system-ui">error</text>',
        f'<line x1="{ox + 118}" y1="{oy + 14}" x2="{ox + 138}" y2="{oy + 14}" stroke="#7eb6ff" stroke-width="2"/>'
        f'<text x="{ox + 144}" y="{oy + 18}" fill="#c5d0db" font-size="11" font-family="ui-sans-serif,system-ui">p50</text>',
        f'<line x1="{ox + 184}" y1="{oy + 14}" x2="{ox + 204}" y2="{oy + 14}" stroke="#f5c14a" stroke-width="2"/>'
        f'<text x="{ox + 210}" y="{oy + 18}" fill="#c5d0db" font-size="11" font-family="ui-sans-serif,system-ui">p95</text>',
        "</svg>",
    ]
    return "\n".join(body)


def svg_bars(
    labels: list[str],
    series: list[tuple[str, list[float], str]],
    title: str,
    ylabel: str,
    width: int = 720,
    height: int = 280,
) -> str:
    if not labels:
        return f"<p>{escape(title)}: no data</p>"
    ymax = _nice_max(max((v for _, vals, _ in series for v in vals), default=1) * 1.15)
    head, ox, oy, pw, ph = _svg_axes(width, height, 56, 18, 36, 64, len(labels), ymax, "", ylabel, title)
    group_w = pw / len(labels)
    n = max(len(series), 1)
    bar_w = group_w / (n + 1.4)
    parts = [head]
    for i, label in enumerate(labels):
        for j, (name, vals, color) in enumerate(series):
            val = vals[i] if i < len(vals) else 0.0
            h = (val / ymax) * ph if ymax else 0
            x = ox + i * group_w + (j + 0.4) * bar_w
            y = oy + ph - h
            parts.append(
                f'<rect x="{x:.1f}" y="{y:.1f}" width="{bar_w:.1f}" height="{h:.1f}" fill="{color}" rx="2">'
                f"<title>{escape(name)} {escape(label)}: {val:.1f}</title></rect>"
            )
        parts.append(
            f'<text x="{ox + i * group_w + group_w / 2:.1f}" y="{oy + ph + 18}" text-anchor="middle" '
            f'fill="#8b9aab" font-size="10" font-family="ui-sans-serif,system-ui">{escape(label)}</text>'
        )
    legend_x = ox
    for name, _, color in series:
        parts.append(f'<rect x="{legend_x}" y="{oy + ph + 30}" width="10" height="10" fill="{color}" rx="2"/>')
        parts.append(
            f'<text x="{legend_x + 14}" y="{oy + ph + 39}" fill="#c5d0db" font-size="11" '
            f'font-family="ui-sans-serif,system-ui">{escape(name)}</text>'
        )
        legend_x += 12 + 8 * len(name)
    parts.append("</svg>")
    return "\n".join(parts)


def svg_histogram(values: list[float], title: str, width: int = 720, height: int = 260, bins: int = 24) -> str:
    if not values:
        return f"<p>{escape(title)}: no data</p>"
    lo, hi = min(values), percentile(values, 99) or max(values)
    if hi <= lo:
        hi = lo + 1
    width_bin = (hi - lo) / bins
    counts = [0] * bins
    for v in values:
        idx = min(int((min(v, hi) - lo) / width_bin), bins - 1)
        counts[idx] += 1
    ymax = _nice_max(max(counts))
    head, ox, oy, pw, ph = _svg_axes(width, height, 56, 18, 36, 42, hi, ymax, "latency (ms)", "count", title)
    parts = [head]
    bw = pw / bins
    for i, count in enumerate(counts):
        h = (count / ymax) * ph if ymax else 0
        x = ox + i * bw
        y = oy + ph - h
        parts.append(
            f'<rect x="{x:.1f}" y="{y:.1f}" width="{max(bw - 1, 1):.1f}" height="{h:.1f}" fill="#5b8def" rx="1"/>'
        )
    parts.append("</svg>")
    return "\n".join(parts)


def svg_line(
    points: list[tuple[float, float]],
    title: str,
    xlabel: str,
    ylabel: str,
    color: str = "#3dd68c",
    width: int = 720,
    height: int = 240,
) -> str:
    if not points:
        return f"<p>{escape(title)}: no data</p>"
    xmax = _nice_max(max(x for x, _ in points))
    ymax = _nice_max(max(y for _, y in points) * 1.15 if points else 1)
    head, ox, oy, pw, ph = _svg_axes(width, height, 56, 18, 36, 42, xmax, ymax, xlabel, ylabel, title)
    coords = []
    area = [f"{ox:.1f},{oy + ph:.1f}"]
    for x, y in points:
        px = ox + (x / xmax) * pw
        py = oy + ph - (y / ymax) * ph
        coords.append(f"{px:.1f},{py:.1f}")
        area.append(f"{px:.1f},{py:.1f}")
    area.append(f"{ox + pw:.1f},{oy + ph:.1f}")
    return "\n".join(
        [
            head,
            f'<polyline fill="#3dd68c22" stroke="none" points="{" ".join(area)}"/>',
            f'<polyline fill="none" stroke="{color}" stroke-width="2" points="{" ".join(coords)}"/>',
            "</svg>",
        ]
    )


def bucket_series(samples: list[dict], key: str, bucket_s: float = 1.0) -> list[tuple[float, float]]:
    if not samples:
        return []
    last = max(s["t"] for s in samples)
    n = int(math.ceil(last / bucket_s)) + 1
    buckets = [0.0] * n
    counts = [0] * n
    for s in samples:
        i = min(int(s["t"] / bucket_s), n - 1)
        if key == "rps":
            counts[i] += 1
        elif key == "errors":
            counts[i] += 0 if s["ok"] else 1
        elif key == "kib_s":
            buckets[i] += s["bytes_in"] / 1024.0
            counts[i] += 1
    out = []
    for i in range(n):
        t = i * bucket_s
        if key == "rps":
            out.append((t, counts[i] / bucket_s))
        elif key == "errors":
            out.append((t, counts[i] / bucket_s))
        else:
            out.append((t, buckets[i] / bucket_s))
    return out


def fmt(value: float | None, digits: int = 1, suffix: str = "") -> str:
    if value is None:
        return "—"
    return f"{value:,.{digits}f}{suffix}"


def render_report(data: dict) -> str:
    overall = data["overall"]
    lat = overall.get("latency_ms") or {}
    samples = data["samples"]
    endpoints = list(data["by_endpoint"].keys())
    p50s = [data["by_endpoint"][e]["latency_ms"]["p50"] or 0 for e in endpoints]
    p95s = [data["by_endpoint"][e]["latency_ms"]["p95"] or 0 for e in endpoints]
    rps_e = [data["by_endpoint"][e]["rps"] for e in endpoints]
    kib_e = [data["by_endpoint"][e]["throughput_kib_s"] for e in endpoints]
    err_e = [data["by_endpoint"][e]["error_rate"] * 100 for e in endpoints]
    phases = [p["name"] for p in data["phases"] if p["name"] in data["by_phase"]]
    if "warmup" in data["by_phase"]:
        phases = ["warmup", *phases]
    phase_p95 = [(data["by_phase"][p].get("latency_ms") or {}).get("p95") or 0 for p in phases]
    phase_rps = [data["by_phase"][p]["rps"] for p in phases]
    status_labels = [str(k) for k in overall.get("status_codes", {})]
    status_vals = [float(v) for v in overall.get("status_codes", {}).values()]

    ceiling = data.get("ceiling") or {}
    inf = ceiling.get("inflection")
    last_linear = ceiling.get("last_linear") or {}
    cards = [
        ("Requests", f"{overall['count']:,}"),
        ("Throughput", fmt(overall["rps"], 1, " rps")),
        ("p50 latency", fmt(lat.get("p50"), 1, " ms")),
        ("p95 latency", fmt(lat.get("p95"), 1, " ms")),
        ("p99 latency", fmt(lat.get("p99"), 1, " ms")),
        ("Error rate", fmt(overall["error_rate"] * 100, 2, "%")),
        ("Transfer", fmt(overall["throughput_kib_s"], 1, " KiB/s")),
        ("Duration", fmt(data["duration_s"], 1, " s")),
        ("Last linear", f"c={last_linear.get('concurrency', '—')} / {fmt(last_linear.get('rps'), 0, ' rps')}"),
        ("Inflection", f"c={inf['concurrency']} ({inf['reason']})" if inf else "not reached"),
    ]
    card_html = "".join(
        f'<div class="card"><div class="k">{escape(k)}</div><div class="v">{escape(v)}</div></div>' for k, v in cards
    )

    def table(title: str, rows: dict[str, dict]) -> str:
        body = []
        for name, stats in rows.items():
            l = stats.get("latency_ms") or {}
            body.append(
                "<tr>"
                f"<td>{escape(name)}</td>"
                f"<td>{stats['count']}</td>"
                f"<td>{fmt(stats['rps'])}</td>"
                f"<td>{fmt(l.get('p50'))}</td>"
                f"<td>{fmt(l.get('p95'))}</td>"
                f"<td>{fmt(l.get('p99'))}</td>"
                f"<td>{fmt(l.get('max'))}</td>"
                f"<td>{fmt(stats['error_rate'] * 100, 2)}%</td>"
                f"<td>{fmt(stats['throughput_kib_s'])}</td>"
                "</tr>"
            )
        return (
            f"<h2>{escape(title)}</h2>"
            "<table><thead><tr><th>Name</th><th>N</th><th>RPS</th><th>p50 ms</th>"
            "<th>p95 ms</th><th>p99 ms</th><th>max ms</th><th>errors</th>"
            "<th>KiB/s</th></tr></thead><tbody>"
            + "".join(body)
            + "</tbody></table>"
        )

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8"/>
  <title>Hamilton API stress test</title>
  <style>
    :root {{ color-scheme: dark; }}
    body {{
      margin: 0; font-family: ui-sans-serif, system-ui, sans-serif;
      background: #0b0f14; color: #e8eef4;
    }}
    main {{ max-width: 1100px; margin: 0 auto; padding: 28px 20px 64px; }}
    h1 {{ font-size: 1.6rem; margin: 0 0 6px; }}
    .sub {{ color: #8b9aab; margin-bottom: 22px; }}
    .cards {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 10px; }}
    .card {{ background: #151b22; border: 1px solid #243040; border-radius: 10px; padding: 12px 14px; }}
    .k {{ color: #8b9aab; font-size: 12px; }}
    .v {{ font-size: 1.15rem; margin-top: 4px; }}
    .grid {{ display: grid; grid-template-columns: 1fr; gap: 16px; margin: 22px 0; }}
    .panel {{ background: #151b22; border: 1px solid #243040; border-radius: 12px; padding: 8px; }}
    table {{ width: 100%; border-collapse: collapse; margin: 8px 0 24px; font-size: 13px; }}
    th, td {{ text-align: left; padding: 8px 10px; border-bottom: 1px solid #243040; }}
    th {{ color: #8b9aab; font-weight: 600; }}
    a {{ color: #7eb6ff; }}
    code {{ color: #f5c14a; }}
  </style>
</head>
<body>
<main>
  <h1>Hamilton API stress test</h1>
  <p class="sub">
    Target <a href="{escape(data['target'])}">{escape(data['target'])}</a>
    · {escape(data['started_at'])} → {escape(data['finished_at'])}
    · {len(data['slugs'])} packed slugs
    · closed-loop ramp
  </p>
  <div class="cards">{card_html}</div>
  <div class="grid">
    <div class="panel">{svg_scatter_lines(samples, "Latency over time")}</div>
    <div class="panel">{svg_line(bucket_series(samples, "rps"), "Throughput over time", "time (s)", "requests / s")}</div>
    <div class="panel">{svg_line(bucket_series(samples, "kib_s"), "Transfer speed over time", "time (s)", "KiB / s", "#f5c14a")}</div>
    <div class="panel">{svg_histogram([s["latency_ms"] for s in samples], "Latency distribution")}</div>
    <div class="panel">{svg_bars(endpoints, [("p50", p50s, "#7eb6ff"), ("p95", p95s, "#f5c14a")], "Latency by endpoint", "ms")}</div>
    <div class="panel">{svg_bars(endpoints, [("rps", rps_e, "#3dd68c")], "Observed request rate by endpoint", "req / s")}</div>
    <div class="panel">{svg_bars(endpoints, [("KiB/s", kib_e, "#c084fc")], "Transfer speed by endpoint", "KiB / s")}</div>
    <div class="panel">{svg_bars(endpoints, [("error %", err_e, "#ff5d5d")], "Error rate by endpoint", "%")}</div>
    <div class="panel">{svg_bars(phases, [("p95 ms", phase_p95, "#f5c14a"), ("rps", phase_rps, "#3dd68c")], "Phase: latency vs throughput", "value")}</div>
    <div class="panel">{svg_bars(
        [str(r["concurrency"]) for r in (ceiling.get("rows") or [])],
        [
            ("p50", [r.get("p50") or 0 for r in (ceiling.get("rows") or [])], "#7eb6ff"),
            ("p95", [r.get("p95") or 0 for r in (ceiling.get("rows") or [])], "#f5c14a"),
        ],
        "Latency vs concurrency (the ceiling curve)",
        "ms",
    )}</div>
    <div class="panel">{svg_bars(
        [str(r["concurrency"]) for r in (ceiling.get("rows") or [])],
        [
            ("rps", [r.get("rps") or 0 for r in (ceiling.get("rows") or [])], "#3dd68c"),
            ("ideal", [
                ((ceiling.get("baseline") or {}).get("rps_per_worker") or 0) * r["concurrency"]
                for r in (ceiling.get("rows") or [])
            ], "#8b9aab"),
        ],
        "Throughput vs concurrency (vs linear ideal)",
        "req / s",
    )}</div>
    <div class="panel">{svg_line(
        [(p["t"], p.get("p95") or 0) for p in (data.get("series") or [])],
        "Rolling p95 (1s) — free-tier CPU throttle shows up as a late climb",
        "time (s)",
        "p95 ms",
        "#f5c14a",
    )}</div>
    <div class="panel">{svg_bars(status_labels, [("count", status_vals, "#5b8def")], "HTTP status codes", "count")}</div>
  </div>
  {table("By endpoint", data["by_endpoint"])}
  {table("By phase", data["by_phase"])}
  <h2>Notes</h2>
  <ul>
    <li>Closed-loop workers: each thread issues the next request only after the previous response.</li>
    <li>Mix is read-only: <code>/hello</code>, <code>/blog</code>, document GET, comments GET, plus a small 404 probe.</li>
    <li>Latency scatter is clipped to p99.5 so a Render cold-start does not flatten the rest of the series.</li>
    <li>This runner is in us-west-2 (Oregon) with Cloudflare edge PDX — same region as a default Render origin. The ~80ms floor is TTFB, not WAN RTT (TCP connect is 1–2ms).</li>
    <li>Ceiling hunt ramps past 18 until p95 climbs or rps/worker drops. Abort if error rate or p95 blows past the baseline.</li>
    <li>A multi-minute sustain is more likely to expose Render free-tier burstable-CPU capping (0.1 CPU) than a 53s burst.</li>
    <li>Aborted at: {escape(str(data.get("aborted_at") or "no"))} {escape(data.get("abort_reason") or "")}</li>
  </ul>
</main>
</body>
</html>
"""


def write_summary_md(data: dict) -> str:
    o = data["overall"]
    lat = o.get("latency_ms") or {}
    lines = [
        "# Hamilton API stress test",
        "",
        f"- Target: `{data['target']}`",
        f"- Window: {data['started_at']} → {data['finished_at']} ({data['duration_s']:.1f}s)",
        f"- Requests: **{o['count']}** ({o['ok']} ok, {o['errors']} errors, {o['error_rate']*100:.2f}% error rate)",
        f"- Throughput: **{o['rps']:.1f} req/s**, **{o['throughput_kib_s']:.1f} KiB/s**",
        f"- Latency ms: min {lat.get('min', 0):.1f} · p50 **{lat.get('p50', 0):.1f}** · p95 **{lat.get('p95', 0):.1f}** · p99 {lat.get('p99', 0):.1f} · max {lat.get('max', 0):.1f}",
        f"- Status codes: `{o.get('status_codes', {})}`",
        "",
        "## Endpoints",
        "",
        "| Endpoint | N | RPS | p50 | p95 | p99 | errors | KiB/s |",
        "|---|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for name, stats in data["by_endpoint"].items():
        l = stats.get("latency_ms") or {}
        lines.append(
            f"| {name} | {stats['count']} | {stats['rps']:.1f} | {l.get('p50', 0):.1f} | "
            f"{l.get('p95', 0):.1f} | {l.get('p99', 0):.1f} | {stats['error_rate']*100:.2f}% | "
            f"{stats['throughput_kib_s']:.1f} |"
        )
    lines += ["", "## Phases", ""]
    for name, stats in data["by_phase"].items():
        l = stats.get("latency_ms") or {}
        lines.append(
            f"- **{name}**: {stats['count']} req, {stats['rps']:.1f} rps, "
            f"p50 {l.get('p50', 0):.1f} ms, p95 {l.get('p95', 0):.1f} ms, "
            f"errors {stats['error_rate']*100:.2f}%"
        )
    ceiling = data.get("ceiling") or {}
    if ceiling.get("rows"):
        lines += ["", "## Ceiling", ""]
        if ceiling.get("baseline"):
            b = ceiling["baseline"]
            lines.append(
                f"- Baseline `{b['name']}` c={b['concurrency']}: "
                f"p95 {b.get('p95') or 0:.1f} ms, {b['rps']:.1f} rps "
                f"({b['rps_per_worker']:.2f} rps/worker)"
            )
        if ceiling.get("last_linear"):
            lin = ceiling["last_linear"]
            lines.append(
                f"- Last linear `{lin['name']}` c={lin['concurrency']}: "
                f"p95 {lin.get('p95') or 0:.1f} ms, {lin['rps']:.1f} rps"
            )
        if ceiling.get("inflection"):
            inf = ceiling["inflection"]
            lines.append(
                f"- **Inflection `{inf['name']}` c={inf['concurrency']}**: "
                f"{inf['reason']}; p95 {inf.get('p95') or 0:.1f} ms, {inf['rps']:.1f} rps "
                f"({inf['rps_per_worker']:.2f} rps/worker)"
            )
        else:
            lines.append("- Inflection not reached in this ramp.")
        if data.get("aborted_at"):
            lines.append(f"- Ramp aborted at `{data['aborted_at']}`: {data.get('abort_reason')}")
    net = data.get("network") or {}
    reused = net.get("reused") or {}
    if reused:
        lines += ["", "## Network vs worker (curl, same-region)", ""]
        for key in ("connect_ms", "tls_ms", "ttfb_ms", "total_ms"):
            row = reused.get(key) or {}
            lines.append(f"- reused {key}: p50 {row.get('p50', 0):.1f} ms, p95 {row.get('p95', 0):.1f} ms")
    lines.append("")
    return "\n".join(lines)


def write_pngs(data: dict, out_dir: Path) -> list[Path]:
    try:
        import matplotlib

        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        return []

    samples = data["samples"]
    endpoints = list(data["by_endpoint"].keys())
    phases = [p["name"] for p in data["phases"] if p["name"] in data["by_phase"]]
    if "warmup" in data["by_phase"]:
        phases = ["warmup", *phases]
    graphs = out_dir / "graphs"
    graphs.mkdir(parents=True, exist_ok=True)
    written: list[Path] = []

    plt.rcParams.update(
        {
            "figure.facecolor": "#0f1419",
            "axes.facecolor": "#151b22",
            "axes.edgecolor": "#243040",
            "axes.labelcolor": "#c5d0db",
            "text.color": "#e8eef4",
            "xtick.color": "#8b9aab",
            "ytick.color": "#8b9aab",
            "grid.color": "#243040",
            "font.size": 10,
        }
    )

    def save(fig, name: str) -> None:
        path = graphs / name
        fig.tight_layout()
        fig.savefig(path, dpi=140, bbox_inches="tight")
        plt.close(fig)
        written.append(path)

    fig, ax = plt.subplots(figsize=(10.2, 3.8))
    ok = [s for s in samples if s["ok"]]
    err = [s for s in samples if not s["ok"]]
    if ok:
        ax.scatter([s["t"] for s in ok], [s["latency_ms"] for s in ok], s=4, c="#3dd68c", alpha=0.35, label="ok")
    if err:
        ax.scatter([s["t"] for s in err], [s["latency_ms"] for s in err], s=8, c="#ff5d5d", alpha=0.8, label="error")
    cap = percentile([s["latency_ms"] for s in samples], 99.5) or 1
    ax.set_ylim(0, cap * 1.2)
    ax.set_title("Latency over time")
    ax.set_xlabel("time (s)")
    ax.set_ylabel("latency (ms)")
    ax.grid(True, alpha=0.5)
    ax.legend(loc="upper right")
    save(fig, "latency-over-time.png")

    rps = bucket_series(samples, "rps")
    fig, ax = plt.subplots(figsize=(10.2, 3.4))
    ax.fill_between([x for x, _ in rps], [y for _, y in rps], color="#3dd68c", alpha=0.25)
    ax.plot([x for x, _ in rps], [y for _, y in rps], color="#3dd68c")
    ax.set_title("Throughput over time")
    ax.set_xlabel("time (s)")
    ax.set_ylabel("requests / s")
    ax.grid(True, alpha=0.5)
    save(fig, "throughput-over-time.png")

    kib = bucket_series(samples, "kib_s")
    fig, ax = plt.subplots(figsize=(10.2, 3.4))
    ax.fill_between([x for x, _ in kib], [y for _, y in kib], color="#f5c14a", alpha=0.25)
    ax.plot([x for x, _ in kib], [y for _, y in kib], color="#f5c14a")
    ax.set_title("Transfer speed over time")
    ax.set_xlabel("time (s)")
    ax.set_ylabel("KiB / s")
    ax.grid(True, alpha=0.5)
    save(fig, "transfer-speed-over-time.png")

    fig, ax = plt.subplots(figsize=(10.2, 3.4))
    vals = [s["latency_ms"] for s in samples]
    hi = percentile(vals, 99) or max(vals)
    ax.hist([v for v in vals if v <= hi], bins=28, color="#5b8def", edgecolor="#0f1419")
    ax.set_title("Latency distribution")
    ax.set_xlabel("latency (ms)")
    ax.set_ylabel("count")
    ax.grid(True, axis="y", alpha=0.5)
    save(fig, "latency-histogram.png")

    fig, ax = plt.subplots(figsize=(10.2, 3.8))
    x = range(len(endpoints))
    p50 = [data["by_endpoint"][e]["latency_ms"]["p50"] or 0 for e in endpoints]
    p95 = [data["by_endpoint"][e]["latency_ms"]["p95"] or 0 for e in endpoints]
    ax.bar([i - 0.18 for i in x], p50, width=0.36, color="#7eb6ff", label="p50")
    ax.bar([i + 0.18 for i in x], p95, width=0.36, color="#f5c14a", label="p95")
    ax.set_xticks(list(x))
    ax.set_xticklabels(endpoints, rotation=20, ha="right")
    ax.set_title("Latency by endpoint")
    ax.set_ylabel("ms")
    ax.legend()
    ax.grid(True, axis="y", alpha=0.5)
    save(fig, "latency-by-endpoint.png")

    fig, ax = plt.subplots(figsize=(10.2, 3.6))
    ax.bar(endpoints, [data["by_endpoint"][e]["rps"] for e in endpoints], color="#3dd68c")
    ax.set_title("Observed request rate by endpoint")
    ax.set_ylabel("req / s")
    ax.tick_params(axis="x", rotation=20)
    ax.grid(True, axis="y", alpha=0.5)
    save(fig, "rps-by-endpoint.png")

    fig, ax = plt.subplots(figsize=(10.2, 3.6))
    ax.bar(endpoints, [data["by_endpoint"][e]["throughput_kib_s"] for e in endpoints], color="#c084fc")
    ax.set_title("Transfer speed by endpoint")
    ax.set_ylabel("KiB / s")
    ax.tick_params(axis="x", rotation=20)
    ax.grid(True, axis="y", alpha=0.5)
    save(fig, "transfer-by-endpoint.png")

    fig, ax = plt.subplots(figsize=(10.2, 3.6))
    x = range(len(phases))
    ax.bar([i - 0.18 for i in x], [data["by_phase"][p]["latency_ms"]["p95"] or 0 for p in phases], width=0.36, color="#f5c14a", label="p95 ms")
    ax.bar([i + 0.18 for i in x], [data["by_phase"][p]["rps"] for p in phases], width=0.36, color="#3dd68c", label="rps")
    ax.set_xticks(list(x))
    ax.set_xticklabels(phases)
    ax.set_title("Phase: p95 latency vs throughput")
    ax.legend()
    ax.grid(True, axis="y", alpha=0.5)
    save(fig, "phase-latency-vs-throughput.png")

    ceiling = data.get("ceiling") or {}
    rows = ceiling.get("rows") or []
    if rows:
        conc = [r["concurrency"] for r in rows]
        fig, ax1 = plt.subplots(figsize=(10.2, 3.8))
        ax1.plot(conc, [r.get("p50") or 0 for r in rows], color="#7eb6ff", marker="o", label="p50")
        ax1.plot(conc, [r.get("p95") or 0 for r in rows], color="#f5c14a", marker="o", label="p95")
        ax1.set_xlabel("concurrency")
        ax1.set_ylabel("latency (ms)")
        ax2 = ax1.twinx()
        ax2.plot(conc, [r["rps"] for r in rows], color="#3dd68c", marker="s", label="rps")
        baseline = ceiling.get("baseline") or rows[0]
        ideal = [(baseline.get("rps_per_worker") or 0) * c for c in conc]
        ax2.plot(conc, ideal, color="#3dd68c", linestyle="--", alpha=0.6, label="linear ideal rps")
        ax2.set_ylabel("requests / s")
        ax1.set_title("Ceiling hunt: latency and throughput vs concurrency")
        lines1, labels1 = ax1.get_legend_handles_labels()
        lines2, labels2 = ax2.get_legend_handles_labels()
        ax1.legend(lines1 + lines2, labels1 + labels2, loc="upper left")
        ax1.grid(True, alpha=0.5)
        inf = ceiling.get("inflection")
        if inf:
            ax1.axvline(inf["concurrency"], color="#ff5d5d", linestyle=":", alpha=0.8)
        save(fig, "ceiling-vs-concurrency.png")

        fig, ax = plt.subplots(figsize=(10.2, 3.4))
        ax.plot(conc, [r["rps_per_worker"] for r in rows], color="#c084fc", marker="o")
        ax.set_title("Efficiency: requests/s per worker")
        ax.set_xlabel("concurrency")
        ax.set_ylabel("rps / worker")
        ax.grid(True, alpha=0.5)
        save(fig, "efficiency-per-worker.png")

    series = data.get("series") or []
    if series:
        fig, ax = plt.subplots(figsize=(10.2, 3.6))
        ax.plot([p["t"] for p in series], [p.get("p50") or 0 for p in series], color="#7eb6ff", label="p50")
        ax.plot([p["t"] for p in series], [p.get("p95") or 0 for p in series], color="#f5c14a", label="p95")
        ax.set_title("Rolling latency (1s buckets) — watch free-tier throttle")
        ax.set_xlabel("time (s)")
        ax.set_ylabel("ms")
        ax.legend()
        ax.grid(True, alpha=0.5)
        save(fig, "rolling-latency.png")

    net = data.get("network") or {}
    reused = net.get("reused") or {}
    cold = net.get("cold") or {}
    if reused:
        labels = ["dns", "connect", "tls", "ttfb", "total"]
        fig, ax = plt.subplots(figsize=(10.2, 3.6))
        x = range(len(labels))
        if cold:
            ax.bar([i - 0.18 for i in x], [cold[k]["p50"] for k in ("dns_ms", "connect_ms", "tls_ms", "ttfb_ms", "total_ms")], width=0.36, color="#8b9aab", label="cold p50")
        ax.bar([i + 0.18 for i in x], [reused[k]["p50"] for k in ("dns_ms", "connect_ms", "tls_ms", "ttfb_ms", "total_ms")], width=0.36, color="#7eb6ff", label="reused p50")
        ax.set_xticks(list(x))
        ax.set_xticklabels(labels)
        ax.set_ylabel("ms")
        ax.set_title("Network vs worker: curl timing (same-region client)")
        ax.legend()
        ax.grid(True, axis="y", alpha=0.5)
        save(fig, "network-breakdown.png")

    codes = data["overall"].get("status_codes") or {}
    fig, ax = plt.subplots(figsize=(7.2, 3.4))
    ax.bar([str(k) for k in codes], list(codes.values()), color="#5b8def")
    ax.set_title("HTTP status codes")
    ax.set_ylabel("count")
    ax.grid(True, axis="y", alpha=0.5)
    save(fig, "status-codes.png")

    return written


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Stress-test a running Hamilton API")
    parser.add_argument("--base-url", default=DEFAULT_BASE)
    parser.add_argument("--output", default="benchmarks/stress")
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--warmup", type=int, default=8)
    parser.add_argument(
        "--profile",
        choices=("quick", "default", "heavy", "ceiling", "sustain"),
        default="default",
        help="ceiling ramps 1→200; sustain holds high concurrency for minutes",
    )
    parser.add_argument("--concurrency", type=int, default=50, help="Hold level for --profile sustain")
    parser.add_argument("--duration", type=float, default=240.0, help="Seconds to hold for --profile sustain")
    parser.add_argument("--hello-only", action="store_true", help="Hit only GET /hello to isolate worker CPU")
    parser.add_argument(
        "--replay",
        metavar="RESULTS_JSON",
        help="Rebuild report and graphs from a previous results.json without hitting the server",
    )
    return parser.parse_args()


def phases_for(profile: str, concurrency: int = 50, duration: float = 240.0) -> list[Phase]:
    if profile == "quick":
        return [
            Phase("c2", 2, 8),
            Phase("c6", 6, 10),
            Phase("c10", 10, 8),
        ]
    if profile == "heavy":
        return [
            Phase("c2", 2, 12),
            Phase("c8", 8, 18),
            Phase("c16", 16, 22),
            Phase("c24", 24, 16),
        ]
    if profile == "ceiling":
        return [
            Phase("c1", 1, 16),
            Phase("c8", 8, 16),
            Phase("c18", 18, 16),
            Phase("c32", 32, 18),
            Phase("c50", 50, 20),
            Phase("c100", 100, 22),
            Phase("c150", 150, 20),
            Phase("c200", 200, 20),
        ]
    if profile == "sustain":
        return [
            Phase("c1", 1, 12),
            Phase(f"c{concurrency}", concurrency, duration),
        ]
    return [
        Phase("c2", 2, 10),
        Phase("c6", 6, 14),
        Phase("c12", 12, 16),
        Phase("c18", 18, 12),
    ]


def write_outputs(data: dict, out: Path) -> None:
    out.mkdir(parents=True, exist_ok=True)
    payload = dict(data)
    # Keep the committed JSON readable for small runs; compact for ceiling/sustain dumps.
    if len(payload.get("samples") or []) > 4000:
        (out / "results.json").write_text(json.dumps(payload, separators=(",", ":")), encoding="utf-8")
    else:
        (out / "results.json").write_text(json.dumps(payload, indent=2), encoding="utf-8")
    (out / "report.html").write_text(render_report(data), encoding="utf-8")
    (out / "summary.md").write_text(write_summary_md(data), encoding="utf-8")
    pngs = write_pngs(data, out)
    print(write_summary_md(data))
    print(f"wrote {out / 'report.html'}", flush=True)
    for path in pngs:
        print(f"wrote {path}", flush=True)


def main() -> int:
    args = parse_args()
    out = Path(args.output)
    if args.replay:
        data = json.loads(Path(args.replay).read_text(encoding="utf-8"))
        print(f"replay={args.replay} target={data.get('target')}", flush=True)
    else:
        config = RunConfig(
            base_url=args.base_url,
            phases=phases_for(args.profile, args.concurrency, args.duration),
            timeout_s=args.timeout,
            mix=DEFAULT_MIX,
            warmup=args.warmup,
            hello_only=args.hello_only,
        )
        print(f"target={config.base_url} profile={args.profile} hello_only={args.hello_only}", flush=True)
        print("probing connect/tls/ttfb (curl)...", flush=True)
        network = probe_network(config.base_url)
        data = StressClient(config).run()
        data["network"] = network
        data["profile"] = args.profile
    write_outputs(data, out)
    overall = data["overall"]
    lat = overall.get("latency_ms") or {}
    print(
        f"RESULT count={overall['count']} rps={overall['rps']:.1f} "
        f"p50={lat.get('p50'):.1f} p95={lat.get('p95'):.1f} errors={overall['error_rate']*100:.2f}%",
        flush=True,
    )
    return 0 if overall["error_rate"] < 0.15 else 2


if __name__ == "__main__":
    raise SystemExit(main())
