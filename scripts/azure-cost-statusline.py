#!/usr/bin/env python3
import datetime as dt
import glob
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(os.environ.get("CLAUDE_CONFIG_DIR") or pathlib.Path.home() / ".claude")
CONFIG_PATH = ROOT / "azure-cost.json"
CACHE_PATH = ROOT / "azure-cost-cache.json"
LOCK_PATH = ROOT / "azure-cost-refresh.lock"
ESTIMATE_PATH = ROOT / "azure-cost-estimate.json"
REFRESH_SECONDS = 3600
LOCK_TIMEOUT_SECONDS = 120
# Azure Retail Prices API, GPT-5.6 Sol Data Zone Standard, USD per 1M tokens.
PRICE_RANGES = {
    "sol": {
        "input_tokens": (4.40, 11.00),
        "cache_creation_input_tokens": (5.50, 11.00),
        "cache_read_input_tokens": (0.44, 1.10),
        "output_tokens": (22.00, 41.25),
    },
    "astra": {
        "input_tokens": (11.00, 24.00),
        "cache_creation_input_tokens": (13.75, 30.00),
        "cache_read_input_tokens": (1.10, 2.40),
        "output_tokens": (55.00, 90.00),
    },
}


# A transcript records whatever alias the proxy exposes, which is a tier name
# on a default install (opus/fable/haiku) and may be a model name on a custom
# one. Both have to resolve to a price table; a tier with no table (haiku/luna)
# is simply left out of the estimate.
PRICE_ALIASES = {"sol": "sol", "opus": "sol", "astra": "astra", "fable": "astra"}


def price_family(model_name):
    lowered = model_name.lower()
    for token, family in PRICE_ALIASES.items():
        if token in lowered:
            return family
    return None


def write_cache(value):
    fd, temporary = tempfile.mkstemp(dir=ROOT, prefix="azure-cost-cache-", text=True)
    with os.fdopen(fd, "w") as file:
        json.dump(value, file)
    os.replace(temporary, CACHE_PATH)


def retry_after_seconds(stderr):
    """Seconds Azure asked us to wait, when it said so."""
    match = re.search(r"retry-after[^0-9]{0,20}(\d+)", stderr or "", re.IGNORECASE)
    if not match:
        return None
    return max(1, min(int(match.group(1)), 900))


def parse_cost(response):
    properties = response["properties"]
    indexes = {column["name"]: i for i, column in enumerate(properties["columns"])}
    rows = properties.get("rows", [])
    return (
        sum(float(row[indexes["Cost"]]) for row in rows),
        str(rows[0][indexes["Currency"]]) if rows else "USD",
    )


def load_estimate_state(transcript_path):
    """Totals carried over from earlier renders of this same transcript."""
    empty = (
        {model: {name: 0 for name in prices} for model, prices in PRICE_RANGES.items()},
        set(),
        0,
    )
    try:
        state = json.loads(ESTIMATE_PATH.read_text())
    except (OSError, ValueError):
        return empty
    if state.get("path") != str(transcript_path):
        return empty
    offset = int(state.get("offset", 0))
    try:
        if offset > pathlib.Path(transcript_path).stat().st_size:
            # Transcript shrank, so it is not the file we counted. Start over.
            return empty
    except OSError:
        return empty
    totals = empty[0]
    for model, counts in (state.get("totals") or {}).items():
        if model in totals:
            for name in totals[model]:
                totals[model][name] = int(counts.get(name, 0) or 0)
    return totals, set(state.get("seen") or []), offset


def save_estimate_state(transcript_path, totals, seen, offset):
    fd, temporary = tempfile.mkstemp(dir=ROOT, prefix="azure-cost-estimate-", text=True)
    with os.fdopen(fd, "w") as file:
        json.dump(
            {"path": str(transcript_path), "offset": offset, "totals": totals, "seen": sorted(seen)},
            file,
        )
    os.replace(temporary, ESTIMATE_PATH)


def render_session_estimate(transcript_path):
    # Transcripts are append-only and reach tens of MB in a long session, while
    # the statusline re-renders every few hundred ms. Parsing the whole file
    # each time would delay the cost line this wrapper exists to print, so only
    # the bytes appended since the last render are read.
    totals, seen, offset = load_estimate_state(transcript_path)
    try:
        with open(transcript_path) as transcript:
            transcript.seek(offset)
            for line in transcript:
                try:
                    message = json.loads(line).get("message") or {}
                    usage = message.get("usage") or {}
                except (AttributeError, ValueError):
                    continue
                message_id = message.get("id")
                if message_id and message_id in seen:
                    continue
                if message_id:
                    seen.add(message_id)
                model = price_family(str(message.get("model", "")))
                if not model:
                    continue
                for name in totals[model]:
                    try:
                        totals[model][name] += int(usage.get(name, 0) or 0)
                    except (AttributeError, TypeError, ValueError):
                        continue
            offset = transcript.tell()
    except (OSError, TypeError, ValueError):
        return None
    try:
        save_estimate_state(transcript_path, totals, seen, offset)
    except OSError:
        pass

    def estimate(model):
        usage = totals[model]
        prices = PRICE_RANGES[model]
        tokens = sum(usage.values())
        low = sum(usage[name] * prices[name][0] for name in usage) / 1_000_000
        high = sum(usage[name] * prices[name][1] for name in usage) / 1_000_000
        return tokens, low, high

    estimates = {model: estimate(model) for model in totals}
    if not any(tokens for tokens, _, _ in estimates.values()):
        return None

    def render(model, values):
        tokens, low, high = values
        count = f"{tokens / 1_000_000:.2f}M" if tokens >= 1_000_000 else f"{tokens / 1_000:.1f}K"
        return f"Azure est. {model}: USD {low:,.2f}–{high:,.2f} · {count} tokens"

    active = [(model, values) for model, values in estimates.items() if values[0]]
    lines = [render(model, values) for model, values in active]
    if len(active) > 1:
        combined = tuple(sum(values[index] for _, values in active) for index in range(3))
        lines.append(render("total", combined))
    return "\n".join(lines)


def load_cache():
    try:
        return json.loads(CACHE_PATH.read_text())
    except (OSError, ValueError):
        return None


def cache_is_stale(cache):
    if not cache:
        return True
    try:
        if "next_retry_at" in cache:
            return dt.datetime.now(dt.timezone.utc) >= dt.datetime.fromisoformat(cache["next_retry_at"])
        updated = dt.datetime.fromisoformat(cache["updated_at"])
        return (dt.datetime.now(dt.timezone.utc) - updated).total_seconds() >= REFRESH_SECONDS
    except (KeyError, TypeError, ValueError):
        return True


def render_cost(cache, now_timestamp=None, stale=None):
    if not cache:
        return "Azure OpenAI MTD: loading"
    if cache.get("error") and "cost" not in cache:
        return f"Azure cost: {cache['error']}"
    stale = cache_is_stale(cache) if stale is None else stale
    updated = dt.datetime.fromisoformat(cache["updated_at"]).astimezone()
    suffix = f" · posted {updated:%m-%d %H:%M}"
    if stale or cache.get("error"):
        suffix += " · stale"
    if cache.get("error"):
        suffix += f" · {cache['error']}"
    return f"Azure OpenAI MTD: {cache['currency']} {cache['cost']:,.2f}{suffix}"


def hud_path():
    candidates = glob.glob(str(ROOT / "plugins/cache/*/claude-hud/*/dist/index.js"))
    if not candidates:
        raise FileNotFoundError("claude-hud dist/index.js not found")

    def version(path):
        raw = pathlib.Path(path).parent.parent.name
        try:
            return tuple(int(part) for part in raw.split("."))
        except ValueError:
            return (0,)

    return max(candidates, key=version)


def terminal_columns():
    raw = (os.environ.get("COLUMNS") or "").strip()
    try:
        return max(1, int(raw) - 4)
    except ValueError:
        return 116


def run_hud(stdin_data):
    """Render claude-hud, or nothing at all.

    The cost line is the reason this wrapper exists, so no claude-hud failure
    may reach main(): a missing plugin, a node binary somewhere other than
    Homebrew, or a hung render would otherwise take the whole statusline down.
    """
    node = shutil.which("node") or "/opt/homebrew/bin/node"
    env = {**os.environ, "COLUMNS": str(terminal_columns())}
    try:
        result = subprocess.run(
            [node, hud_path()],
            input=stdin_data,
            text=True,
            capture_output=True,
            env=env,
            timeout=4,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    return result.stdout


def lock_is_stale():
    try:
        age = dt.datetime.now().timestamp() - LOCK_PATH.stat().st_mtime
    except OSError:
        return False
    return age > LOCK_TIMEOUT_SECONDS


def refresh():
    try:
        lock_fd = os.open(LOCK_PATH, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    except FileExistsError:
        # A refresh killed mid-flight (SIGKILL, reboot) leaves the lock behind,
        # and without this the cost figure would never update again.
        if not lock_is_stale():
            return
        LOCK_PATH.unlink(missing_ok=True)
        try:
            lock_fd = os.open(LOCK_PATH, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        except FileExistsError:
            return
    os.close(lock_fd)
    try:
        config = json.loads(CONFIG_PATH.read_text())
        resource_id = config["resource_id"].rstrip("/")
        if "your-" in resource_id:
            # install-alias.sh seeds the example config, and querying its
            # placeholder resource group would fail every retry window for the
            # life of the install. Say so instead, and check back rarely.
            write_cache({
                "error": "not configured",
                "next_retry_at": (dt.datetime.now(dt.timezone.utc) + dt.timedelta(hours=6)).isoformat(),
            })
            return
        # Cost Management is queried at the narrowest scope the account has rights to.
        # A subscription-scope query needs a subscription-level role; with only a
        # resource-group role Azure answers RBACAccessDenied, so default to the
        # resource group taken from resource_id and let config override it.
        scope = config.get("scope") or "/".join(resource_id.split("/")[:5])
        url = (
            f"https://management.azure.com{scope}/providers/"
            "Microsoft.CostManagement/query?api-version=2025-03-01"
        )
        body = {
            "type": "ActualCost",
            "timeframe": "MonthToDate",
            "dataset": {
                "granularity": "None",
                "aggregation": {"totalCost": {"name": "Cost", "function": "Sum"}},
                "filter": {
                    "dimensions": {
                        "name": "ResourceId",
                        "operator": "In",
                        "values": [resource_id],
                    }
                },
            },
        }
        result = subprocess.run(
            ["az", "rest", "--method", "post", "--url", url, "--body", json.dumps(body)],
            text=True,
            capture_output=True,
            timeout=45,
            check=False,
        )
        if result.returncode:
            message = result.stderr.lower()
            error = "throttled" if "429" in message or "too many requests" in message else "auth required" if "login" in message or "authorization" in message else "unavailable"
            value = load_cache() or {}
            if error == "throttled":
                # Client-type throttling clears in seconds, but an exhausted
                # hourly quota returns 429 for the rest of the hour, and a fixed
                # short retry would hammer it there. Start at the short wait and
                # double it while throttles keep coming.
                streak = int(value.get("throttle_streak", 0) or 0) + 1
                seconds = retry_after_seconds(result.stderr) or min(60 * 2 ** (streak - 1), 900)
                value["throttle_streak"] = streak
            else:
                seconds = 900
                value.pop("throttle_streak", None)
            value.update({
                "error": error,
                "next_retry_at": (dt.datetime.now(dt.timezone.utc) + dt.timedelta(seconds=seconds)).isoformat(),
            })
        else:
            cost, currency = parse_cost(json.loads(result.stdout))
            value = {
                "cost": cost,
                "currency": currency,
                "updated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
            }
        write_cache(value)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        pass
    finally:
        LOCK_PATH.unlink(missing_ok=True)


def maybe_refresh(cache):
    if not cache_is_stale(cache) or (LOCK_PATH.exists() and not lock_is_stale()):
        return
    subprocess.Popen(
        [sys.executable, __file__, "--refresh"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def main(args):
    if args == ["--refresh"]:
        refresh()
        return
    stdin_data = sys.stdin.read()
    hud = run_hud(stdin_data)
    if hud:
        sys.stdout.write(hud)
        if not hud.endswith("\n"):
            sys.stdout.write("\n")
    try:
        transcript_path = json.loads(stdin_data).get("transcript_path")
    except (AttributeError, ValueError):
        transcript_path = None
    estimate = render_session_estimate(transcript_path)
    if estimate:
        print(estimate)
    cache = load_cache()
    maybe_refresh(cache)
    print(render_cost(cache))


if __name__ == "__main__":
    main(sys.argv[1:])
