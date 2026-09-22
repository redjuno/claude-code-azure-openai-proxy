#!/usr/bin/env python3
import datetime as dt
import glob
import hashlib
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
ESTIMATE_PREFIX = "azure-cost-estimate-"
# Persisted ids only guard against the same message id arriving in a later
# slice, so a bounded tail is enough and keeps the per-render write small.
SEEN_LIMIT = 1000
ESTIMATE_TTL_SECONDS = 7 * 24 * 3600
# Straight from config/azure-cost.example.json. Matched as whole path segments,
# so a real resource group named e.g. "rg-your-team" is not mistaken for one.
PLACEHOLDER_SEGMENTS = {"your-subscription-id", "your-resource-group", "your-azure-openai-account"}
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
    match = re.search(r"(?<!-ms)\bretry-after\s*:\s*(\d+)", stderr or "", re.IGNORECASE)
    if not match:
        return None
    return max(1, min(int(match.group(1)), 900))


def parse_cost(response):
    properties = response["properties"]
    indexes = {column["name"]: i for i, column in enumerate(properties["columns"])}
    rows = properties.get("rows", [])
    return (
        sum(float(row[indexes["Cost"]]) for row in rows),
        str(rows[0][indexes["Currency"]]) if rows else None,
    )


def estimate_path(transcript_path):
    digest = hashlib.sha256(str(transcript_path).encode()).hexdigest()[:16]
    return ROOT / f"{ESTIMATE_PREFIX}{digest}.json"


def load_estimate_state(transcript_path):
    """Totals carried over from earlier renders of this same transcript."""
    empty = (
        {model: {name: 0 for name in prices} for model, prices in PRICE_RANGES.items()},
        [],
        0,
    )
    try:
        state = json.loads(estimate_path(transcript_path).read_text())
        if not isinstance(state, dict) or state.get("path") != str(transcript_path):
            return empty
        offset = int(state.get("offset", 0))
        if offset < 0 or offset > pathlib.Path(transcript_path).stat().st_size:
            # Transcript shrank, so it is not the file we counted. Start over.
            return empty
        totals = empty[0]
        for model, counts in (state.get("totals") or {}).items():
            if model in totals:
                for name in totals[model]:
                    totals[model][name] = int(counts.get(name, 0) or 0)
        seen = [str(item) for item in (state.get("seen") or [])]
    except Exception:
        # This file is written by whatever version of the script ran last, and
        # a shape we cannot read is worth no more than a fresh count.
        return empty
    return totals, seen, offset


def save_estimate_state(transcript_path, totals, seen, offset):
    fd, temporary = tempfile.mkstemp(dir=ROOT, prefix=ESTIMATE_PREFIX, text=True)
    with os.fdopen(fd, "w") as file:
        json.dump(
            {
                "path": str(transcript_path),
                "offset": offset,
                "totals": totals,
                "seen": seen[-SEEN_LIMIT:],
            },
            file,
        )
    os.replace(temporary, estimate_path(transcript_path))
    prune_estimate_state()


def prune_estimate_state():
    """Drop state for transcripts nobody has rendered in a week."""
    cutoff = dt.datetime.now().timestamp() - ESTIMATE_TTL_SECONDS
    for stale in ROOT.glob(f"{ESTIMATE_PREFIX}*"):
        try:
            if stale.stat().st_mtime < cutoff:
                stale.unlink(missing_ok=True)
        except OSError:
            continue


def render_session_estimate(transcript_path):
    # Transcripts are append-only and reach tens of MB in a long session, while
    # the statusline re-renders every few hundred ms. Parsing the whole file
    # each time would delay the cost line this wrapper exists to print, so only
    # the bytes appended since the last render are read.
    totals, seen, offset = load_estimate_state(transcript_path)
    recent = set(seen)
    try:
        # Opened as bytes: in text mode universal newlines rewrite \r\n, and the
        # offset we record would drift a byte per line against the real file.
        with open(transcript_path, "rb") as transcript:
            transcript.seek(offset)
            while True:
                raw = transcript.readline()
                if not raw:
                    break
                if not raw.endswith(b"\n"):
                    # Claude Code is mid-append. Leave the offset before this
                    # partial line so the finished record is read next time.
                    break
                offset += len(raw)
                line = raw.decode("utf-8", "replace")
                try:
                    message = json.loads(line).get("message") or {}
                    usage = message.get("usage") or {}
                except (AttributeError, ValueError):
                    continue
                message_id = message.get("id")
                if message_id and message_id in recent:
                    continue
                if message_id:
                    recent.add(message_id)
                    seen.append(message_id)
                model = price_family(str(message.get("model", "")))
                if not model:
                    continue
                for name in totals[model]:
                    try:
                        totals[model][name] += int(usage.get(name, 0) or 0)
                    except (AttributeError, TypeError, ValueError):
                        continue
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
        cache = json.loads(CACHE_PATH.read_text())
    except (OSError, ValueError):
        return None
    # This file survives upgrades of the script, so treat any shape it does not
    # recognise as no cache at all rather than letting it reach render_cost.
    return cache if isinstance(cache, dict) else None


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


def render_cost(cache, stale=None):
    if not cache:
        return "Azure OpenAI MTD: loading"
    if cache.get("cost") is None:
        return f"Azure cost: {cache.get('error') or 'loading'}"
    stale = cache_is_stale(cache) if stale is None else stale
    suffix = ""
    try:
        updated = dt.datetime.fromisoformat(cache["updated_at"]).astimezone()
        suffix = f" · posted {updated:%m-%d %H:%M}"
    except (KeyError, TypeError, ValueError):
        pass
    if stale or cache.get("error"):
        suffix += " · stale"
    if cache.get("error"):
        suffix += f" · {cache['error']}"
    currency = cache.get("currency")
    if not currency:
        # Cost Management returns no rows until the month's first usage is
        # posted. Naming a currency there would be inventing one.
        return f"Azure OpenAI MTD: nothing posted yet{suffix}"
    try:
        return f"Azure OpenAI MTD: {currency} {float(cache['cost']):,.2f}{suffix}"
    except (TypeError, ValueError):
        return "Azure cost: unavailable"


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
        pass
    # Claude Code does not export COLUMNS to a statusline command, so without
    # this every terminal would be rendered at one hardcoded width.
    return max(1, shutil.get_terminal_size(fallback=(120, 24)).columns - 4)


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


def take_lock():
    """Claim the refresh lock, stamped so only this process releases it."""
    token = f"{os.getpid()}:{dt.datetime.now().timestamp()}"
    try:
        lock_fd = os.open(LOCK_PATH, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    except OSError as error:
        if not isinstance(error, FileExistsError):
            # Unwritable config dir: nothing here can be recovered, and a
            # traceback on stderr helps nobody at statusline cadence.
            return None
        # A refresh killed mid-flight (SIGKILL, reboot) leaves the lock behind,
        # and without this the cost figure would never update again. Whoever
        # wins the re-create keeps it; the losers back off rather than deleting
        # the winner's fresh lock and running a second query alongside it.
        if not lock_is_stale():
            return None
        try:
            LOCK_PATH.unlink()
            lock_fd = os.open(LOCK_PATH, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        except OSError:
            return None
    with os.fdopen(lock_fd, "w") as lock_file:
        lock_file.write(token)
    return token


def release_lock(token):
    """Release only our own lock, never one a stale-lock stealer replaced."""
    try:
        if LOCK_PATH.read_text() == token:
            LOCK_PATH.unlink(missing_ok=True)
    except OSError:
        pass


def refresh():
    token = take_lock()
    if token is None:
        return
    try:
        config = json.loads(CONFIG_PATH.read_text())
        resource_id = (config.get("resource_id") or "").rstrip("/") if isinstance(config, dict) else ""
        parts = resource_id.split("/")
        # A truncated id still splits into a subscription scope, which is the
        # RBACAccessDenied case this default exists to avoid, so require the
        # resource group and the account to actually be there.
        well_formed = (
            len(parts) >= 9
            and resource_id.startswith("/subscriptions/")
            and parts[3].lower() == "resourcegroups"
            and all(parts[i] for i in (2, 4, 8))
        )
        if not well_formed or set(parts) & PLACEHOLDER_SEGMENTS:
            # install-alias.sh seeds the example config, and a placeholder or
            # malformed resource id would fail every retry window for the life
            # of the install. Say so instead, and check back rarely.
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
                escalating = min(60 * 2 ** (streak - 1), 900)
                hinted = retry_after_seconds(result.stderr)
                # A 15s client-type hint is right for the first throttle, but
                # repeats mean the hourly quota is gone and the hint would pin
                # us to a retry-per-15s for the rest of the hour.
                seconds = escalating if streak > 1 else (hinted or escalating)
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
    except Exception:
        # Anything at all: without a cache entry the figure stays stale, so
        # maybe_refresh() would spawn another refresh on every render — several
        # a second with az missing or azure-cost.json holding the wrong shape.
        try:
            stored = load_cache() or {}
            stored.pop("throttle_streak", None)
            stored.update({
                "error": "unavailable",
                "next_retry_at": (dt.datetime.now(dt.timezone.utc) + dt.timedelta(minutes=15)).isoformat(),
            })
            write_cache(stored)
        except OSError:
            pass
    finally:
        release_lock(token)


def maybe_refresh(cache):
    if not cache_is_stale(cache) or (LOCK_PATH.exists() and not lock_is_stale()):
        return
    if not os.access(ROOT, os.W_OK):
        # A refresh could neither lock nor cache, so it would fail the same way
        # on every render — several forks a second for the whole session.
        return
    try:
        subprocess.Popen(
            [sys.executable, __file__, "--refresh"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError:
        pass


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
