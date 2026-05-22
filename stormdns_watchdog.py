#!/usr/bin/env python3
"""
StormDNS watchdog for the docker backend fleet and proxy service.

It watches:
  - all containers matching STORMDNS_WATCHDOG_CONTAINER_PATTERN
  - docker health/running state
  - direct backend UDP DNS responses, when dig is available
  - recent StormDNS backend logs for queue/session overload signals
  - stormdns-proxy.service activity and matching journal errors

Actions are intentionally conservative and cooldown guarded. A backend is
restarted only when a threshold is crossed or repeated health/probe failures
are observed.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple


DEFAULT_CONTAINER_PATTERN = r"^stormdns-\d+$"
DEFAULT_PROXY_UNIT = "stormdns-proxy.service"
DEFAULT_STATE_PATH = "/run/stormdns-watchdog/state.json"
DEFAULT_CONFIG_PATH = "/root/server_config.toml"

LOG_PATTERNS = {
    "request_queue": re.compile(
        r"Request Queue (?:Overloaded|Saturated|Watchdog Triggered)",
        re.IGNORECASE,
    ),
    "deferred_queue": re.compile(
        r"Deferred Session Queue Overloaded",
        re.IGNORECASE,
    ),
    "session_table_full": re.compile(
        r"Session Table Full(?: Request)?",
        re.IGNORECASE,
    ),
    "session_full_recovery": re.compile(
        r"Session Table Full Recovery",
        re.IGNORECASE,
    ),
    "panic_or_fatal": re.compile(
        r"Packet Handler Panic Recovered|Deferred Session Worker Panic|\bpanic\b|\bfatal\b",
        re.IGNORECASE,
    ),
}


@dataclass
class Settings:
    interval: int
    log_window: int
    cooldown: int
    health_fail_threshold: int
    dns_fail_threshold: int
    queue_threshold: int
    deferred_threshold: int
    session_threshold: int
    panic_threshold: int
    container_pattern: str
    proxy_unit: str
    state_path: Path
    config_path: Path
    dns_probe: bool
    dry_run: bool


@dataclass
class ContainerInfo:
    name: str
    status: str = "unknown"
    health: str = "unknown"
    restart_count: str = "0"
    ip: str = ""


@dataclass
class WatchdogState:
    health_failures: Dict[str, int] = field(default_factory=dict)
    dns_failures: Dict[str, int] = field(default_factory=dict)
    last_action: Dict[str, float] = field(default_factory=dict)


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")


def log(level: str, message: str) -> None:
    print(f"{utc_now()} [{level}] {message}", flush=True)


def run_cmd(args: List[str], timeout: int = 10) -> Tuple[int, str]:
    try:
        proc = subprocess.run(
            args,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=timeout,
            check=False,
        )
        return proc.returncode, proc.stdout
    except subprocess.TimeoutExpired as exc:
        return 124, (exc.stdout or "") + f"\ncommand timed out: {' '.join(args)}"
    except OSError as exc:
        return 127, f"{exc}"


def load_state(path: Path) -> WatchdogState:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return WatchdogState()
    return WatchdogState(
        health_failures={str(k): int(v) for k, v in raw.get("health_failures", {}).items()},
        dns_failures={str(k): int(v) for k, v in raw.get("dns_failures", {}).items()},
        last_action={str(k): float(v) for k, v in raw.get("last_action", {}).items()},
    )


def save_state(path: Path, state: WatchdogState) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(
        json.dumps(
            {
                "health_failures": state.health_failures,
                "dns_failures": state.dns_failures,
                "last_action": state.last_action,
            },
            sort_keys=True,
        ),
        encoding="utf-8",
    )
    tmp.replace(path)


def first_tunnel_domain(path: Path) -> str:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return "v.whitedns.space"
    match = re.search(r"^\s*DOMAIN\s*=\s*\[(.*?)\]", text, re.M | re.S)
    if not match:
        return "v.whitedns.space"
    values = re.findall(r'"([^"]+)"', match.group(1))
    return values[0].strip(".") if values else "v.whitedns.space"


def discover_container_names(pattern: re.Pattern[str]) -> List[str]:
    code, out = run_cmd(["docker", "ps", "-a", "--format", "{{.Names}}"], timeout=8)
    if code != 0:
        log("ERROR", f"docker ps failed: {out.strip()}")
        return []
    names = [line.strip() for line in out.splitlines() if pattern.match(line.strip())]
    return sorted(names, key=container_sort_key)


def container_sort_key(name: str) -> Tuple[int, str]:
    match = re.search(r"(\d+)$", name)
    if match:
        return int(match.group(1)), name
    return 0, name


def inspect_containers(names: Iterable[str]) -> Dict[str, ContainerInfo]:
    names = list(names)
    if not names:
        return {}
    fmt = (
        "{{.Name}}\t{{.State.Status}}\t"
        "{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}\t"
        "{{.RestartCount}}\t{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}"
    )
    code, out = run_cmd(["docker", "inspect", "--format", fmt] + names, timeout=15)
    if code != 0:
        log("ERROR", f"docker inspect failed: {out.strip()}")
        return {name: ContainerInfo(name=name) for name in names}

    values: Dict[str, ContainerInfo] = {}
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) < 5:
            continue
        name = parts[0].lstrip("/")
        values[name] = ContainerInfo(
            name=name,
            status=parts[1],
            health=parts[2],
            restart_count=parts[3],
            ip=parts[4],
        )
    for name in names:
        values.setdefault(name, ContainerInfo(name=name))
    return values


def count_log_patterns(text: str) -> Dict[str, int]:
    counts = {key: len(pattern.findall(text)) for key, pattern in LOG_PATTERNS.items()}
    # Recovery means the server cleaned old sessions and did not remain full.
    # Do not let recovery-only lines trigger the session threshold.
    counts["session_table_full_hard"] = max(
        0,
        counts["session_table_full"] - counts["session_full_recovery"],
    )
    return counts


def recent_container_log_counts(name: str, window: int) -> Dict[str, int]:
    code, out = run_cmd(
        ["docker", "logs", "--since", f"{window}s", "--tail", "500", name],
        timeout=12,
    )
    if code != 0:
        log("WARN", f"{name}: docker logs failed: {out.strip()}")
        return {}
    return count_log_patterns(out)


def recent_proxy_log_counts(unit: str, window: int) -> Dict[str, int]:
    code, out = run_cmd(
        ["journalctl", "-u", unit, "--since", f"{window} seconds ago", "--no-pager", "-n", "500"],
        timeout=12,
    )
    if code != 0:
        log("WARN", f"{unit}: journalctl failed: {out.strip()}")
        return {}
    return count_log_patterns(out)


def probe_dns(ip: str, domain: str) -> bool:
    if not ip or shutil.which("dig") is None:
        return True
    code, out = run_cmd(
        ["dig", "+time=1", "+tries=1", f"@{ip}", f"test.{domain}", "A"],
        timeout=4,
    )
    return code == 0 and "status: NOERROR" in out


def in_cooldown(target: str, settings: Settings, state: WatchdogState) -> bool:
    last = state.last_action.get(target, 0)
    remaining = int(settings.cooldown - (time.time() - last))
    if remaining > 0:
        log("INFO", f"{target}: action suppressed by cooldown ({remaining}s remaining)")
        return True
    return False


def run_action(target: str, cmd: List[str], settings: Settings, state: WatchdogState, reason: str) -> None:
    if in_cooldown(target, settings, state):
        return

    log("WARN", f"{target}: action={cmd[0]} reason={reason}")
    state.last_action[target] = time.time()
    if settings.dry_run:
        log("INFO", f"{target}: dry-run, skipped command: {' '.join(cmd)}")
        return

    code, out = run_cmd(cmd, timeout=40)
    if code == 0:
        log("WARN", f"{target}: action completed: {' '.join(cmd)}")
    else:
        log("ERROR", f"{target}: action failed ({code}): {out.strip()}")


def restart_container(name: str, settings: Settings, state: WatchdogState, reason: str) -> None:
    run_action(name, ["docker", "restart", "--time", "10", name], settings, state, reason)
    state.health_failures.pop(name, None)
    state.dns_failures.pop(name, None)


def start_container(name: str, settings: Settings, state: WatchdogState, reason: str) -> None:
    run_action(name, ["docker", "start", name], settings, state, reason)
    state.health_failures.pop(name, None)
    state.dns_failures.pop(name, None)


def restart_proxy(settings: Settings, state: WatchdogState, reason: str) -> None:
    run_action(
        settings.proxy_unit,
        ["systemctl", "restart", settings.proxy_unit],
        settings,
        state,
        reason,
    )


def evaluate_log_counts(target: str, counts: Dict[str, int], settings: Settings) -> Optional[str]:
    if not counts:
        return None
    panic_count = counts.get("panic_or_fatal", 0)
    hard_session = counts.get("session_table_full_hard", 0)
    queue_count = counts.get("request_queue", 0)
    deferred_count = counts.get("deferred_queue", 0)

    if panic_count >= settings.panic_threshold:
        return f"panic/fatal logs={panic_count}"
    if hard_session >= settings.session_threshold:
        return f"session table full logs={hard_session}"
    if deferred_count >= settings.deferred_threshold:
        return f"deferred session queue overload logs={deferred_count}"
    if queue_count >= settings.queue_threshold:
        return f"request queue overload logs={queue_count}"

    details = []
    for key in ("request_queue", "deferred_queue", "session_table_full_hard", "session_full_recovery", "panic_or_fatal"):
        if counts.get(key, 0):
            details.append(f"{key}={counts[key]}")
    if details:
        log("INFO", f"{target}: observed below threshold: {', '.join(details)}")
    return None


def check_container(info: ContainerInfo, settings: Settings, state: WatchdogState, probe_domain: str) -> None:
    name = info.name

    if info.status != "running":
        state.health_failures[name] = state.health_failures.get(name, 0) + 1
        start_container(name, settings, state, f"container status={info.status}")
        return

    if info.health not in ("healthy", "none"):
        failures = state.health_failures.get(name, 0) + 1
        state.health_failures[name] = failures
        log("WARN", f"{name}: health={info.health} failure_count={failures}/{settings.health_fail_threshold}")
        if failures >= settings.health_fail_threshold:
            restart_container(name, settings, state, f"docker health={info.health}")
            return
    else:
        state.health_failures.pop(name, None)

    if settings.dns_probe and info.ip:
        if probe_dns(info.ip, probe_domain):
            state.dns_failures.pop(name, None)
        else:
            failures = state.dns_failures.get(name, 0) + 1
            state.dns_failures[name] = failures
            log("WARN", f"{name}: DNS probe failed for {info.ip} failure_count={failures}/{settings.dns_fail_threshold}")
            if failures >= settings.dns_fail_threshold:
                restart_container(name, settings, state, f"DNS probe failed for {info.ip}")
                return

    counts = recent_container_log_counts(name, settings.log_window)
    reason = evaluate_log_counts(name, counts, settings)
    if reason:
        restart_container(name, settings, state, reason)


def check_proxy(settings: Settings, state: WatchdogState) -> None:
    code, out = run_cmd(["systemctl", "is-active", settings.proxy_unit], timeout=5)
    active = out.strip()
    if code != 0 or active != "active":
        restart_proxy(settings, state, f"proxy service state={active or code}")
        return

    counts = recent_proxy_log_counts(settings.proxy_unit, settings.log_window)
    reason = evaluate_log_counts(settings.proxy_unit, counts, settings)
    if reason:
        restart_proxy(settings, state, reason)


def run_once(settings: Settings, state: WatchdogState) -> None:
    pattern = re.compile(settings.container_pattern)
    names = discover_container_names(pattern)
    if not names:
        log("ERROR", f"no containers matched pattern {settings.container_pattern!r}")
    else:
        probe_domain = first_tunnel_domain(settings.config_path)
        infos = inspect_containers(names)
        for name in names:
            check_container(infos[name], settings, state, probe_domain)

    check_proxy(settings, state)
    save_state(settings.state_path, state)


def env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError:
        log("WARN", f"{name}={raw!r} is not an integer; using {default}")
        return default


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="StormDNS docker/container watchdog")
    parser.add_argument("--once", action="store_true", help="run one check and exit")
    parser.add_argument("--dry-run", action="store_true", default=os.environ.get("STORMDNS_WATCHDOG_DRY_RUN") == "1")
    parser.add_argument("--no-dns-probe", action="store_true", help="disable direct backend DNS probes")
    parser.add_argument("--interval", type=int, default=env_int("STORMDNS_WATCHDOG_INTERVAL", 15))
    parser.add_argument("--log-window", type=int, default=env_int("STORMDNS_WATCHDOG_LOG_WINDOW", 120))
    parser.add_argument("--cooldown", type=int, default=env_int("STORMDNS_WATCHDOG_COOLDOWN", 600))
    parser.add_argument("--health-fail-threshold", type=int, default=env_int("STORMDNS_WATCHDOG_HEALTH_FAILS", 2))
    parser.add_argument("--dns-fail-threshold", type=int, default=env_int("STORMDNS_WATCHDOG_DNS_FAILS", 2))
    parser.add_argument("--queue-threshold", type=int, default=env_int("STORMDNS_WATCHDOG_QUEUE_THRESHOLD", 3))
    parser.add_argument("--deferred-threshold", type=int, default=env_int("STORMDNS_WATCHDOG_DEFERRED_THRESHOLD", 3))
    parser.add_argument("--session-threshold", type=int, default=env_int("STORMDNS_WATCHDOG_SESSION_THRESHOLD", 1))
    parser.add_argument("--panic-threshold", type=int, default=env_int("STORMDNS_WATCHDOG_PANIC_THRESHOLD", 1))
    parser.add_argument(
        "--container-pattern",
        default=os.environ.get("STORMDNS_WATCHDOG_CONTAINER_PATTERN", DEFAULT_CONTAINER_PATTERN),
    )
    parser.add_argument("--proxy-unit", default=os.environ.get("STORMDNS_WATCHDOG_PROXY_UNIT", DEFAULT_PROXY_UNIT))
    parser.add_argument("--state-path", default=os.environ.get("STORMDNS_WATCHDOG_STATE", DEFAULT_STATE_PATH))
    parser.add_argument("--config", default=os.environ.get("STORMDNS_WATCHDOG_CONFIG", DEFAULT_CONFIG_PATH))
    return parser.parse_args()


def build_settings(args: argparse.Namespace) -> Settings:
    return Settings(
        interval=max(5, args.interval),
        log_window=max(30, args.log_window),
        cooldown=max(60, args.cooldown),
        health_fail_threshold=max(1, args.health_fail_threshold),
        dns_fail_threshold=max(1, args.dns_fail_threshold),
        queue_threshold=max(1, args.queue_threshold),
        deferred_threshold=max(1, args.deferred_threshold),
        session_threshold=max(1, args.session_threshold),
        panic_threshold=max(1, args.panic_threshold),
        container_pattern=args.container_pattern,
        proxy_unit=args.proxy_unit,
        state_path=Path(args.state_path),
        config_path=Path(args.config),
        dns_probe=not args.no_dns_probe,
        dry_run=bool(args.dry_run),
    )


def main() -> int:
    args = parse_args()
    settings = build_settings(args)
    state = load_state(settings.state_path)

    log(
        "INFO",
        "started "
        f"interval={settings.interval}s log_window={settings.log_window}s cooldown={settings.cooldown}s "
        f"queue_threshold={settings.queue_threshold} session_threshold={settings.session_threshold} "
        f"dns_probe={settings.dns_probe} dry_run={settings.dry_run}",
    )

    while True:
        try:
            run_once(settings, state)
        except Exception as exc:  # noqa: BLE001 - watchdog must keep running
            log("ERROR", f"watchdog loop error: {exc}")
        if args.once:
            return 0
        time.sleep(settings.interval)


if __name__ == "__main__":
    sys.exit(main())
