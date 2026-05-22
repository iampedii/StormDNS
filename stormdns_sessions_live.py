#!/usr/bin/env python3
from __future__ import annotations

import argparse
import curses
import os
import re
import shutil
import subprocess
import sys
import time
from collections import deque
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Deque, Dict, Iterable, List, Optional, Sequence, Tuple


DEFAULT_CONTAINERS = [
    "stormdns-1",
    "stormdns-2",
    "stormdns-3",
    "stormdns-4",
    "stormdns-5",
    "stormdns-6",
    "stormdns-7",
    "stormdns-8",
]
PROXY_UNIT = "stormdns-proxy.service"
SPARK_CHARS = "._-:=+*#%@"
STATS_RE = re.compile(
    r"b(?P<idx>\d+)=(?P<backend>\S+)\s+"
    r"active=(?P<active>-?\d+)\s+"
    r"sent=(?P<sent>\d+)\s+"
    r"resp=(?P<resp>\d+)\s+"
    r"timeout=(?P<timeout>\d+)\s+"
    r"accept=(?P<accept>\d+)\s+"
    r"busy=(?P<busy>\d+)"
)


@dataclass
class BackendStats:
    backend: str = "-"
    active: int = 0
    sent: int = 0
    resp: int = 0
    timeout: int = 0
    accept: int = 0
    busy: int = 0
    full_recent: int = 0
    cpu: str = "-"
    mem: str = "-"
    net: str = "-"


@dataclass
class DashboardSample:
    created_at: float
    timestamp: str
    stats: Dict[str, BackendStats]
    totals: Dict[str, float]
    net: Dict[str, object]
    last_line: str


def run(cmd: Sequence[str], timeout: int = 5) -> str:
    try:
        return subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=timeout,
            check=False,
        ).stdout
    except (subprocess.SubprocessError, OSError):
        return ""


def latest_proxy_stats(proxy_unit: str) -> Tuple[Dict[int, BackendStats], Dict[str, BackendStats], str]:
    out = run(["journalctl", "-u", proxy_unit, "-n", "80", "--no-pager"], timeout=5)
    stats_line = ""
    for line in out.splitlines():
        if " stats " in line and " b1=" in line:
            stats_line = line

    stats_by_index: Dict[int, BackendStats] = {}
    stats_by_backend: Dict[str, BackendStats] = {}
    for match in STATS_RE.finditer(stats_line):
        idx = int(match.group("idx"))
        stats = BackendStats(
            backend=match.group("backend"),
            active=int(match.group("active")),
            sent=int(match.group("sent")),
            resp=int(match.group("resp")),
            timeout=int(match.group("timeout")),
            accept=int(match.group("accept")),
            busy=int(match.group("busy")),
        )
        stats_by_index[idx] = stats
        stats_by_backend[stats.backend] = stats
    return stats_by_index, stats_by_backend, stats_line


def docker_stats(containers: List[str]) -> Dict[str, Dict[str, str]]:
    out = run(
        ["docker", "stats", "--no-stream", "--format", "{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}"]
        + containers,
        timeout=8,
    )
    values: Dict[str, Dict[str, str]] = {}
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) != 4:
            continue
        values[parts[0]] = {
            "cpu": parts[1],
            "mem": parts[2],
            "net": parts[3],
        }
    return values


def docker_containers() -> List[str]:
    out = run(["docker", "ps", "--format", "{{.Names}}"], timeout=5)
    containers = []
    for line in out.splitlines():
        name = line.strip()
        match = re.fullmatch(r"stormdns-(\d+)", name)
        if match:
            containers.append((int(match.group(1)), name))
    containers.sort()
    return [name for _, name in containers]


def docker_container_ips(containers: List[str]) -> Dict[str, str]:
    out = run(
        [
            "docker",
            "inspect",
            "--format",
            "{{.Name}}\t{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}",
        ]
        + containers,
        timeout=8,
    )
    values: Dict[str, str] = {}
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) != 2:
            continue
        name = parts[0].lstrip("/")
        values[name] = parts[1]
    return values


def recent_session_full(container: str, window: int) -> int:
    out = run(["docker", "logs", "--since", f"{window}s", "--tail", "1000", container], timeout=8)
    return out.count("Session Table Full")


def parse_interfaces(raw: str) -> Optional[set]:
    value = raw.strip()
    if not value or value.lower() in ("auto", "all", "*"):
        return None
    return {item.strip() for item in value.split(",") if item.strip()}


def read_counter(path: str) -> Optional[int]:
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            return int(handle.read().strip())
    except (OSError, ValueError):
        return None


def read_sysfs_netdev(selected_interfaces: Optional[set]) -> Tuple[int, int, Dict[str, Tuple[int, int]]]:
    rx_total = 0
    tx_total = 0
    ifaces: Dict[str, Tuple[int, int]] = {}
    try:
        names = os.listdir("/sys/class/net")
    except OSError:
        return rx_total, tx_total, ifaces

    for name in names:
        if name == "lo":
            continue
        if selected_interfaces is not None and name not in selected_interfaces:
            continue
        base = f"/sys/class/net/{name}/statistics"
        rx_bytes = read_counter(f"{base}/rx_bytes")
        tx_bytes = read_counter(f"{base}/tx_bytes")
        if rx_bytes is None or tx_bytes is None:
            continue
        rx_total += rx_bytes
        tx_total += tx_bytes
        ifaces[name] = (rx_bytes, tx_bytes)
    return rx_total, tx_total, ifaces


def read_proc_netdev(selected_interfaces: Optional[set]) -> Tuple[int, int, Dict[str, Tuple[int, int]]]:
    rx_total = 0
    tx_total = 0
    ifaces: Dict[str, Tuple[int, int]] = {}
    try:
        with open("/proc/net/dev", "r", encoding="utf-8", errors="replace") as handle:
            lines = handle.readlines()[2:]
    except OSError:
        return rx_total, tx_total, ifaces

    for line in lines:
        if ":" not in line:
            continue
        iface, data = line.split(":", 1)
        name = iface.strip()
        if name == "lo":
            continue
        if selected_interfaces is not None and name not in selected_interfaces:
            continue
        parts = data.split()
        if len(parts) < 16:
            continue
        rx_bytes = int(parts[0])
        tx_bytes = int(parts[8])
        rx_total += rx_bytes
        tx_total += tx_bytes
        ifaces[name] = (rx_bytes, tx_bytes)
    return rx_total, tx_total, ifaces


def read_netdev(selected_interfaces: Optional[set]) -> Tuple[int, int, Dict[str, Tuple[int, int]]]:
    rx_total, tx_total, ifaces = read_sysfs_netdev(selected_interfaces)
    if ifaces:
        return rx_total, tx_total, ifaces
    return read_proc_netdev(selected_interfaces)


def clear() -> None:
    if sys.stdout.isatty():
        print("\033[2J\033[H", end="")


def fmt_int(value: object) -> str:
    try:
        return f"{int(round(float(value))):,}"
    except (TypeError, ValueError):
        return str(value)


def human_int(value: object) -> str:
    if value is None:
        return "n/a"
    try:
        n = float(value)
    except (TypeError, ValueError):
        return str(value)
    for suffix in ("", "K", "M", "B"):
        if abs(n) < 1000:
            return f"{n:.0f}{suffix}"
        n /= 1000.0
    return f"{n:.1f}T"


def human_bytes(value: object) -> str:
    if value is None:
        return "n/a"
    try:
        n = float(value)
    except (TypeError, ValueError):
        return str(value)
    for suffix in ("B", "KiB", "MiB", "GiB", "TiB"):
        if abs(n) < 1024:
            return f"{n:.1f}{suffix}" if suffix != "B" else f"{n:.0f}{suffix}"
        n /= 1024.0
    return f"{n:.1f}PiB"


def human_rate(value: object) -> str:
    return f"{human_bytes(value)}/s"


def rate(current: float, previous: float, elapsed: float) -> float:
    return max(0.0, (current - previous) / max(elapsed, 0.001))


def spark(values: Iterable[float], width: int) -> str:
    if width <= 0:
        return ""
    vals = list(values)[-width:]
    if not vals:
        return ""
    maxv = max(vals)
    if maxv <= 0:
        return SPARK_CHARS[0] * len(vals)
    return "".join(SPARK_CHARS[min(len(SPARK_CHARS) - 1, int((value / maxv) * (len(SPARK_CHARS) - 1)))] for value in vals)


def fit(value: object, width: int) -> str:
    text = str(value)
    if len(text) <= width:
        return text.ljust(width)
    if width <= 1:
        return text[:width]
    return (text[: width - 1] + "~").ljust(width)


def bar(value: int, max_value: int, width: int) -> str:
    if width <= 0:
        return ""
    if max_value <= 0:
        return "." * width
    used = int(round((max(value, 0) / max_value) * width))
    used = max(0, min(width, used))
    return "#" * used + "." * (width - used)


def totals_from_stats(stats: Dict[str, BackendStats]) -> Dict[str, float]:
    return {
        "active_sessions": float(sum(max(0, s.active) for s in stats.values())),
        "accepted_sessions": float(sum(s.accept for s in stats.values())),
        "sent": float(sum(s.sent for s in stats.values())),
        "responses": float(sum(s.resp for s in stats.values())),
        "busy": float(sum(s.busy for s in stats.values())),
        "timeouts": float(sum(s.timeout for s in stats.values())),
        "full_recent": float(sum(s.full_recent for s in stats.values())),
    }


def collect_sample(
    containers: List[str],
    log_window: int,
    proxy_unit: str,
    selected_interfaces: Optional[set],
    previous: Optional[DashboardSample],
) -> DashboardSample:
    stats_by_index, stats_by_backend, last_line = latest_proxy_stats(proxy_unit)
    resource_stats = docker_stats(containers)
    container_ips = docker_container_ips(containers)
    stats: Dict[str, BackendStats] = {}

    for idx, container in enumerate(containers, start=1):
        backend = ""
        if container_ips.get(container):
            backend = f"{container_ips[container]}:53"
        if backend:
            stat = stats_by_backend.get(backend, BackendStats(backend=backend))
        else:
            stat = stats_by_index.get(idx, BackendStats(backend=backend or "-"))
        resources = resource_stats.get(container, {})
        stat.cpu = resources.get("cpu", "-")
        stat.mem = resources.get("mem", "-")
        stat.net = resources.get("net", "-")
        stat.full_recent = recent_session_full(container, log_window)
        stats[container] = stat

    current_time = time.monotonic()
    elapsed = max(current_time - previous.created_at, 0.001) if previous else 0.001
    totals = totals_from_stats(stats)
    previous_totals = previous.totals if previous else totals
    totals["accepted_per_sec"] = rate(
        totals["accepted_sessions"],
        previous_totals.get("accepted_sessions", totals["accepted_sessions"]),
        elapsed,
    )
    totals["sent_per_sec"] = rate(totals["sent"], previous_totals.get("sent", totals["sent"]), elapsed)
    totals["responses_per_sec"] = rate(
        totals["responses"],
        previous_totals.get("responses", totals["responses"]),
        elapsed,
    )
    totals["timeout_per_sec"] = rate(
        totals["timeouts"],
        previous_totals.get("timeouts", totals["timeouts"]),
        elapsed,
    )

    rx_total, tx_total, iface_counters = read_netdev(selected_interfaces)
    previous_net = previous.net if previous else {}
    previous_rx = float(previous_net.get("rx_total", rx_total))
    previous_tx = float(previous_net.get("tx_total", tx_total))
    previous_iface_counters = previous_net.get("iface_counters", {})
    if not isinstance(previous_iface_counters, dict):
        previous_iface_counters = {}

    iface_rates = []
    for name, (rx_bytes, tx_bytes) in iface_counters.items():
        prev_rx, prev_tx = previous_iface_counters.get(name, (rx_bytes, tx_bytes))
        iface_rates.append(
            {
                "name": name,
                "rx_total": rx_bytes,
                "tx_total": tx_bytes,
                "rx_rate": rate(float(rx_bytes), float(prev_rx), elapsed),
                "tx_rate": rate(float(tx_bytes), float(prev_tx), elapsed),
            }
        )
    iface_rates.sort(key=lambda item: float(item["rx_rate"]) + float(item["tx_rate"]), reverse=True)
    net = {
        "rx_total": rx_total,
        "tx_total": tx_total,
        "rx_rate": rate(float(rx_total), previous_rx, elapsed),
        "tx_rate": rate(float(tx_total), previous_tx, elapsed),
        "iface_counters": iface_counters,
        "iface_rates": iface_rates,
    }

    return DashboardSample(
        created_at=current_time,
        timestamp=datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC"),
        stats=stats,
        totals=totals,
        net=net,
        last_line=last_line,
    )


def backend_rows(sample: DashboardSample, containers: List[str], log_window: int) -> Tuple[List[str], List[List[str]]]:
    headers = [
        "Container",
        "Backend",
        "Sessions",
        "Accepted",
        "Busy",
        "Timeout",
        f"Full/{log_window}s",
        "CPU",
        "Memory",
        "Net I/O",
    ]
    rows = []
    for container in containers:
        stat = sample.stats.get(container, BackendStats())
        rows.append(
            [
                container,
                stat.backend,
                fmt_int(stat.active),
                fmt_int(stat.accept),
                fmt_int(stat.busy),
                fmt_int(stat.timeout),
                fmt_int(stat.full_recent),
                stat.cpu,
                stat.mem,
                stat.net,
            ]
        )
    return headers, rows


def render_plain(
    sample: DashboardSample,
    history: Deque[DashboardSample],
    containers: List[str],
    log_window: int,
    proxy_unit: str,
) -> None:
    clear()
    totals = sample.totals
    net = sample.net
    print(f"StormDNS sessions dashboard | {sample.timestamp}")
    print(f"Proxy: {proxy_unit}")
    print(
        "Total sessions: "
        f"current={fmt_int(totals['active_sessions'])} "
        f"accepted={fmt_int(totals['accepted_sessions'])} "
        f"accepted/s={totals['accepted_per_sec']:.1f} "
        f"sent/s={totals['sent_per_sec']:.1f} "
        f"resp/s={totals['responses_per_sec']:.1f} "
        f"busy={fmt_int(totals['busy'])} "
        f"timeouts={fmt_int(totals['timeouts'])} "
        f"session_full_last_{log_window}s={fmt_int(totals['full_recent'])}"
    )
    print(
        "System traffic: "
        f"rx={human_rate(net['rx_rate'])} tx={human_rate(net['tx_rate'])} "
        f"total_rx={human_bytes(net['rx_total'])} total_tx={human_bytes(net['tx_total'])}"
    )
    top_ifaces = net.get("iface_rates", [])
    if top_ifaces:
        iface_text = "  ".join(
            f"{item['name']}:rx {human_rate(item['rx_rate'])} tx {human_rate(item['tx_rate'])}"
            for item in top_ifaces[:4]
        )
        print(f"Interfaces: {iface_text}")
    print()
    print(f"sessions   {spark((h.totals['active_sessions'] for h in history), 60)}")
    print(f"accept/s   {spark((h.totals['accepted_per_sec'] for h in history), 60)}")
    print(f"rx/s       {spark((float(h.net['rx_rate']) for h in history), 60)}")
    print(f"tx/s       {spark((float(h.net['tx_rate']) for h in history), 60)}")
    print()

    headers, rows = backend_rows(sample, containers, log_window)
    widths = [len(header) for header in headers]
    for row in rows:
        for idx, value in enumerate(row):
            widths[idx] = max(widths[idx], len(value))

    print("  ".join(header.ljust(widths[idx]) for idx, header in enumerate(headers)))
    print("  ".join("-" * widths[idx] for idx in range(len(headers))))
    for row in rows:
        print("  ".join(value.ljust(widths[idx]) for idx, value in enumerate(row)))

    if not sample.last_line:
        print()
        print("No proxy stats line found yet. Wait up to 30 seconds after proxy start.")
    sys.stdout.flush()


def add_line(stdscr, row: int, text: str, attr: int = 0) -> int:
    height, width = stdscr.getmaxyx()
    if row >= height or width <= 1:
        return row + 1
    clean = text.replace("\t", " ")
    stdscr.addnstr(row, 0, clean.ljust(width), width - 1, attr)
    return row + 1


def render_tui(
    stdscr,
    sample: DashboardSample,
    history: Deque[DashboardSample],
    containers: List[str],
    log_window: int,
    proxy_unit: str,
) -> None:
    stdscr.erase()
    try:
        curses.curs_set(0)
    except curses.error:
        pass

    height, width = stdscr.getmaxyx()
    chart_width = max(8, width - 27)
    totals = sample.totals
    net = sample.net
    hist = list(history)
    row = 0

    row = add_line(stdscr, row, f"StormDNS session TUI | {sample.timestamp}", curses.A_BOLD)
    row = add_line(stdscr, row, f"Proxy {proxy_unit} | containers {len(containers)} | q quits")
    row = add_line(
        stdscr,
        row,
        "Total sessions "
        f"current {fmt_int(totals['active_sessions'])}  "
        f"accepted {fmt_int(totals['accepted_sessions'])}  "
        f"accepted/s {totals['accepted_per_sec']:.1f}  "
        f"sent/s {totals['sent_per_sec']:.1f}  "
        f"resp/s {totals['responses_per_sec']:.1f}",
        curses.A_BOLD,
    )
    row = add_line(
        stdscr,
        row,
        "Proxy pressure "
        f"busy {fmt_int(totals['busy'])}  "
        f"timeouts {fmt_int(totals['timeouts'])} ({totals['timeout_per_sec']:.1f}/s)  "
        f"session-full/{log_window}s {fmt_int(totals['full_recent'])}",
    )
    row = add_line(
        stdscr,
        row,
        "System traffic "
        f"rx {human_rate(net['rx_rate'])}  tx {human_rate(net['tx_rate'])}  "
        f"total rx {human_bytes(net['rx_total'])}  total tx {human_bytes(net['tx_total'])}",
        curses.A_BOLD,
    )
    iface_rates = net.get("iface_rates", [])
    if iface_rates:
        iface_text = "  ".join(
            f"{item['name']}: {human_rate(item['rx_rate'])} down / {human_rate(item['tx_rate'])} up"
            for item in iface_rates[:3]
        )
        row = add_line(stdscr, row, f"Top interfaces {iface_text}")
    else:
        row = add_line(stdscr, row, "Top interfaces n/a")
    row = add_line(stdscr, row, "")

    chart_specs = [
        ("sessions", (h.totals["active_sessions"] for h in hist), fmt_int(totals["active_sessions"])),
        ("accept/s", (h.totals["accepted_per_sec"] for h in hist), f"{totals['accepted_per_sec']:.1f}/s"),
        ("rx/s", (float(h.net["rx_rate"]) for h in hist), human_rate(net["rx_rate"])),
        ("tx/s", (float(h.net["tx_rate"]) for h in hist), human_rate(net["tx_rate"])),
        ("timeouts/s", (h.totals["timeout_per_sec"] for h in hist), f"{totals['timeout_per_sec']:.1f}/s"),
        ("full/win", (h.totals["full_recent"] for h in hist), fmt_int(totals["full_recent"])),
    ]
    for label, values, current in chart_specs:
        chart = spark(values, chart_width)
        row = add_line(stdscr, row, f"{label:<10} {chart:<{chart_width}} {current:>12}")
    row = add_line(stdscr, row, "")

    if not sample.last_line:
        row = add_line(
            stdscr,
            row,
            "No proxy stats line found yet. Wait up to 30 seconds after proxy start.",
            curses.A_REVERSE,
        )

    row = add_line(stdscr, row, "Backends", curses.A_BOLD)
    max_active = max([1] + [max(0, stat.active) for stat in sample.stats.values()])
    bar_width = min(18, max(6, width // 8))
    header = (
        f"{'Container':<12} {'Backend':<18} {'Sess':>6}  "
        f"{'Load':<{bar_width}} {'Accepted':>10} {'Busy':>6} "
        f"{'Timeout':>8} {'Full':>6} {'CPU':>7} {'Memory':<14} {'Net I/O':<18}"
    )
    row = add_line(stdscr, row, header, curses.A_UNDERLINE)

    for index, container in enumerate(containers):
        if row >= height - 2:
            remaining = len(containers) - index
            if remaining > 0:
                row = add_line(stdscr, row, f"... {remaining} more backends hidden by terminal height", curses.A_DIM)
            break
        stat = sample.stats.get(container, BackendStats())
        line = (
            f"{fit(container, 12)} {fit(stat.backend, 18)} {fmt_int(stat.active):>6}  "
            f"{bar(stat.active, max_active, bar_width)} {fmt_int(stat.accept):>10} {fmt_int(stat.busy):>6} "
            f"{fmt_int(stat.timeout):>8} {fmt_int(stat.full_recent):>6} {fit(stat.cpu, 7)} "
            f"{fit(stat.mem, 14)} {fit(stat.net, 18)}"
        )
        attr = curses.A_NORMAL
        if stat.full_recent or stat.timeout:
            attr = curses.A_BOLD
        row = add_line(stdscr, row, line, attr)

    add_line(stdscr, height - 1, "q quits | --plain for text output | system traffic excludes lo", curses.A_DIM)
    stdscr.refresh()


def sleep_with_quit(stdscr, seconds: float) -> bool:
    deadline = time.monotonic() + max(0.0, seconds)
    while time.monotonic() < deadline:
        key = stdscr.getch()
        if key in (ord("q"), ord("Q")):
            return True
        time.sleep(0.05)
    return False


def run_curses_dashboard(args: argparse.Namespace, containers: List[str], selected_interfaces: Optional[set]) -> None:
    def loop(stdscr) -> None:
        try:
            curses.use_default_colors()
        except curses.error:
            pass
        stdscr.nodelay(True)
        stdscr.keypad(True)
        history: Deque[DashboardSample] = deque(maxlen=args.history)
        previous: Optional[DashboardSample] = None
        while True:
            sample = collect_sample(containers, args.log_window, args.proxy_unit, selected_interfaces, previous)
            history.append(sample)
            render_tui(stdscr, sample, history, containers, args.log_window, args.proxy_unit)
            previous = sample
            if args.once or sleep_with_quit(stdscr, args.interval):
                return

    curses.wrapper(loop)


def run_plain_dashboard(args: argparse.Namespace, containers: List[str], selected_interfaces: Optional[set]) -> None:
    history: Deque[DashboardSample] = deque(maxlen=args.history)
    previous: Optional[DashboardSample] = None
    while True:
        sample = collect_sample(containers, args.log_window, args.proxy_unit, selected_interfaces, previous)
        history.append(sample)
        render_plain(sample, history, containers, args.log_window, args.proxy_unit)
        previous = sample
        if args.once:
            return
        time.sleep(args.interval)


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Realtime StormDNS session, traffic, and backend TUI")
    parser.add_argument("--interval", type=float, default=5.0, help="refresh interval seconds")
    parser.add_argument("--log-window", type=int, default=60, help="session-full log window seconds")
    parser.add_argument("--history", type=int, default=120, help="number of samples to keep for charts")
    parser.add_argument("--plain", action="store_true", help="print text dashboard instead of curses TUI")
    parser.add_argument("--once", action="store_true", help="render one update and exit")
    parser.add_argument("--proxy-unit", default=PROXY_UNIT, help=f"proxy systemd unit (default: {PROXY_UNIT})")
    parser.add_argument(
        "--interfaces",
        default="auto",
        help="comma-separated system interfaces for traffic totals, or auto/all for every non-lo interface",
    )
    parser.add_argument(
        "--containers",
        default="auto",
        help="comma-separated container names in backend order, or auto",
    )
    return parser


def resolve_containers(raw: str) -> List[str]:
    if raw.strip().lower() == "auto":
        containers = docker_containers()
        if containers:
            return containers
        return DEFAULT_CONTAINERS
    return [container.strip() for container in raw.split(",") if container.strip()]


def main() -> int:
    parser = build_arg_parser()
    args = parser.parse_args()
    args.interval = max(0.5, args.interval)
    args.log_window = max(1, args.log_window)
    args.history = max(2, args.history)

    if shutil.which("docker") is None:
        raise SystemExit("docker command not found")
    if shutil.which("journalctl") is None:
        raise SystemExit("journalctl command not found")

    containers = resolve_containers(args.containers)
    if not containers:
        raise SystemExit("no containers configured")

    selected_interfaces = parse_interfaces(args.interfaces)
    if args.plain or not sys.stdout.isatty():
        run_plain_dashboard(args, containers, selected_interfaces)
    else:
        try:
            run_curses_dashboard(args, containers, selected_interfaces)
        except curses.error as exc:
            print(f"curses unavailable ({exc}); falling back to --plain", file=sys.stderr)
            run_plain_dashboard(args, containers, selected_interfaces)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print()
