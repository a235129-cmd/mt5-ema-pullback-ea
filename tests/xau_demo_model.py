"""Offline model of the demo-only XAUUSD EA rules.

This is not MQL5 and it does not read live quotes. Dollar examples in tests
use a stub profit function so the arithmetic can be checked without MT5.
"""

from __future__ import annotations

from dataclasses import dataclass, field

COMMENT_MAX = 31
LOT = 0.01
SL_MULT = 1.5
TP_R = 2.0
RISK_CAP = 10.0
DAILY_CAP = 10.0
STREAK_CAP = 2
EXPIRY_BARS = 24
MAX_CATCHUP = 48


def is_gold_symbol(name: str) -> bool:
    if not name:
        return False
    upper = name.upper()
    if not upper.startswith("XAUUSD"):
        return False
    rest = upper[6:]
    allowed = set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-#")
    return all(ch in allowed for ch in rest)


def make_comment(magic: int, setup_bar: int) -> str:
    if magic < 1 or magic > 99999999:
        raise ValueError("magic out of range")
    if setup_bar < 0:
        raise ValueError("setup bar")
    text = f"XD1:{magic}:{setup_bar}"
    if len(text) > COMMENT_MAX:
        raise ValueError("comment longer than 31")
    return text


def comment_prefix(magic: int) -> str:
    return f"XD1:{magic}:"


def account_allowed(is_tester: bool, trade_mode: str, margin_mode: str, currency: str) -> bool:
    """Real charts are refused. The tester is allowed because it does not send
    broker orders. Netting and non-USD are refused in both places.
    """
    if margin_mode != "hedge":
        return False
    if currency != "USD":
        return False
    if is_tester:
        return True
    return trade_mode == "demo"


def align_down(price: float, tick: float) -> float:
    if tick <= 0:
        raise ValueError("tick")
    steps = int((price / tick) + 1e-9)
    # Floor for positive prices. Gold prices are positive.
    if price < 0:
        raise ValueError("price")
    return round(steps * tick, 10)


def align_up(price: float, tick: float) -> float:
    if tick <= 0:
        raise ValueError("tick")
    if price < 0:
        raise ValueError("price")
    steps = (price / tick) - 1e-9
    whole = int(steps)
    if abs(steps - whole) > 1e-8:
        whole += 1
    return round(whole * tick, 10)


def build_stops(direction, entry, atr, bid, ask, min_dist, tick):
    """Return (sl, tp) or None.

    The raw stop is 1.5 ATR from the execution price. Tick alignment and the
    broker minimum distance may only move the stop farther out. They never
    pull it closer to the price to make the dollar risk smaller.
    """
    if direction not in (1, -1):
        return None
    if atr <= 0 or tick <= 0 or entry <= 0 or bid <= 0 or ask < bid:
        return None
    if min_dist < 0:
        return None
    raw = SL_MULT * atr
    if direction == 1:
        sl = align_down(entry - raw, tick)
        limit = bid - min_dist
        if sl > limit:
            sl = align_down(limit, tick)
        if sl <= 0 or sl > entry - raw + 1e-8:
            return None
        dist = entry - sl
        tp = align_up(entry + TP_R * dist, tick)
        tp_floor = bid + min_dist
        if tp < tp_floor:
            tp = align_up(tp_floor, tick)
        if not (sl < bid and tp > entry and dist + 1e-8 >= raw):
            return None
        return (sl, tp)
    sl = align_up(entry + raw, tick)
    limit = ask + min_dist
    if sl < limit:
        sl = align_up(limit, tick)
    if sl < entry + raw - 1e-8:
        return None
    dist = sl - entry
    tp = align_down(entry - TP_R * dist, tick)
    tp_cap = ask - min_dist
    if tp > tp_cap:
        tp = align_down(tp_cap, tick)
    if not (sl > ask and tp < entry and tp > 0 and dist + 1e-8 >= raw):
        return None
    return (sl, tp)


def risk_total(direction, entry, sl, volume, point, slippage_points, commission, profit_fn):
    """Loss at the stop, plus commission, plus extra loss if the stop fills
    worse by `slippage_points`. Spread is not added again: `entry` is already
    the execution side (ask for a buy, bid for a sell) and `sl` is the stop.
    """
    if point < 0 or slippage_points < 0 or commission < 0:
        return None
    base = profit_fn(direction, volume, entry, sl)
    if base is None:
        return None
    slip = slippage_points * point
    worse = sl - slip if direction == 1 else sl + slip
    worse_profit = profit_fn(direction, volume, entry, worse)
    if worse_profit is None:
        return None
    stop_loss = -base
    extra = (-worse_profit) - stop_loss
    if extra < 0:
        extra = 0.0
    total = stop_loss + commission + extra
    return total


def risk_allows(total) -> bool:
    if total is None:
        return False
    return total <= RISK_CAP + 1e-9


def lot_allowed(lot, vmin, vmax, step, volume_limit, open_volume) -> bool:
    if abs(lot - LOT) > 1e-12:
        return False
    if step <= 0 or vmin <= 0:
        return False
    if lot + 1e-12 < vmin:
        return False
    if vmax > 0 and lot > vmax + 1e-12:
        return False
    steps = lot / step
    if abs(steps - round(steps)) > 1e-6:
        return False
    if volume_limit > 0 and open_volume + lot > volume_limit + 1e-12:
        return False
    return True


def spread_ok(bid, ask, max_spread) -> bool:
    if max_spread <= 0 or bid <= 0 or ask < bid:
        return False
    return (ask - bid) <= max_spread + 1e-9


def adverse_pnl(realized, floating) -> float:
    """Floating profit cannot offset a realized loss."""
    return realized + min(0.0, floating)


def daily_loss_hit(realized, floating, cap=DAILY_CAP) -> bool:
    return adverse_pnl(realized, floating) <= -cap + 1e-9


def roll_server_day(daily_halt: bool, streak_halt: bool):
    """A new server day clears only the daily dollar halt."""
    return False, streak_halt


def apply_close(streak: int, streak_halt: int, net: float):
    """A loss increments the streak. A win resets it only before the halt
    locks. A scratch (exactly zero after fees) changes neither.
    """
    if net < 0:
        streak += 1
        if streak >= STREAK_CAP:
            streak_halt = 1
    elif net > 0 and not streak_halt:
        streak = 0
    return streak, streak_halt


@dataclass
class Item:
    id: str
    magic: int
    symbol: str
    comment: str
    kind: str = "position"
    preexisting: bool = False


def classify_startup(items, own_id, pending_comment, magic, symbol, inflight):
    prefix = comment_prefix(magic)
    verified = []
    fresh = []
    foreign = []
    for item in items:
        is_fresh = (
            inflight
            and item.magic == magic
            and item.symbol == symbol
            and pending_comment != ""
            and item.comment == pending_comment
        )
        is_own = (
            (not inflight)
            and own_id != ""
            and item.id == own_id
            and item.magic == magic
            and item.symbol == symbol
            and item.comment.startswith(prefix)
        )
        if is_fresh:
            fresh.append(item)
        elif is_own:
            verified.append(item)
        else:
            foreign.append(item)
    if foreign or len(verified) + len(fresh) > 1:
        return "refuse", fresh
    if len(verified) == 1:
        return "adopt", fresh
    if len(fresh) == 1:
        return "fresh", fresh
    return "empty", fresh


def may_flatten(item: Item, fresh_ids, magic, symbol) -> bool:
    if item.preexisting:
        return False
    if item.id not in fresh_ids:
        return False
    if item.magic != magic or item.symbol != symbol:
        return False
    return item.comment.startswith(comment_prefix(magic))


@dataclass
class Bar:
    time: int
    open: float
    high: float
    low: float
    close: float
    ema_fast: float
    ema_slow: float
    atr: float


@dataclass
class SignalBook:
    attach_bar: int
    expiry: int = EXPIRY_BARS
    last_closed: int | None = None
    state: str = "idle"
    direction: int = 0
    setup_bar: int | None = None
    setup_high: float | None = None
    setup_low: float | None = None
    age: int = 0
    signal_atr: float | None = None
    entry_bar: int | None = None
    events: list = field(default_factory=list)

    def drop_gap(self):
        if self.state != "idle":
            self.events.append(("invalidate", "gap"))
        self.state = "idle"
        self._clear()

    def _clear(self):
        self.direction = 0
        self.setup_bar = None
        self.setup_high = None
        self.setup_low = None
        self.age = 0
        self.signal_atr = None
        self.entry_bar = None

    @staticmethod
    def trend(bar: Bar) -> int:
        if bar.ema_fast > bar.ema_slow:
            return 1
        if bar.ema_fast < bar.ema_slow:
            return -1
        return 0

    def eligible(self, bar_time: int) -> bool:
        if bar_time < self.attach_bar:
            return False
        if self.last_closed is not None and bar_time <= self.last_closed:
            return False
        return True

    def process(self, bar: Bar, next_bar_time: int, allow_entry: bool, blocked: bool):
        if not self.eligible(bar.time):
            self.events.append(("ignore", "watermark"))
            return "ignore"
        if bar.atr <= 0 or bar.ema_fast <= 0 or bar.ema_slow <= 0:
            # A closed bar with unusable values is skipped so later bars can proceed.
            # A missing indicator read is different and is not advanced by the EA.
            self.last_closed = bar.time
            self.events.append(("skip", "indicator"))
            return "skip"
        trend = self.trend(bar)
        self.last_closed = bar.time
        if blocked:
            if self.state != "idle":
                self._clear()
                self.state = "idle"
                self.events.append(("invalidate", "exposure"))
                return "invalidate"
            self.events.append(("none", "exposure"))
            return "none"
        if self.state == "armed":
            self.age += 1
            if trend != self.direction:
                self._clear()
                self.state = "idle"
                self.events.append(("invalidate", "trend"))
                return "invalidate"
            if self.age > self.expiry:
                self._clear()
                self.state = "idle"
                self.events.append(("expire", "expiry"))
                return "expire"
            broke = (self.direction == 1 and bar.close > self.setup_high) or (
                self.direction == -1 and bar.close < self.setup_low
            )
            if broke:
                if allow_entry:
                    self.state = "window"
                    self.signal_atr = bar.atr
                    self.entry_bar = next_bar_time
                    self.events.append(("enter", "breakout"))
                    return "enter"
                self._clear()
                self.state = "idle"
                self.events.append(("invalidate", "missed_window"))
                return "invalidate"
            self.events.append(("none", "wait"))
            return "none"
        if self.state == "window":
            self._clear()
            self.state = "idle"
            self.events.append(("invalidate", "window_expired"))
            return "invalidate"
        if trend == 1 and bar.low <= bar.ema_fast and bar.close > bar.ema_slow:
            self._arm(1, bar)
            return "arm"
        if trend == -1 and bar.high >= bar.ema_fast and bar.close < bar.ema_slow:
            self._arm(-1, bar)
            return "arm"
        self.events.append(("none", "no_setup"))
        return "none"

    def _arm(self, direction: int, bar: Bar):
        self.state = "armed"
        self.direction = direction
        self.setup_bar = bar.time
        self.setup_high = bar.high
        self.setup_low = bar.low
        self.age = 0
        self.signal_atr = None
        self.entry_bar = None
        self.events.append(("arm", "buy" if direction == 1 else "sell"))


def catchup_too_wide(missed_bars: int, limit: int = MAX_CATCHUP) -> bool:
    return missed_bars > limit


def can_send(consumed_bar, bar_time, inflight, exposure, prot_halt, streak_halt, daily_halt, spread_ok_flag, risk_ok_flag, permission_ok):
    if prot_halt:
        return "halt"
    if streak_halt:
        return "streak"
    if daily_halt:
        return "daily"
    if inflight or exposure:
        return "exposure"
    if consumed_bar == bar_time:
        return "consumed"
    if not permission_ok:
        return "permission"
    if not spread_ok_flag:
        return "spread"
    if not risk_ok_flag:
        return "risk"
    return "send"


def mark_sent(bar_time):
    """One attempt consumes the bar before the order is sent."""
    return bar_time


def entry_window_fresh(now: int, bar_open: int, limit: int = 120) -> bool:
    """A restart in the middle of the entry bar must not chase the price."""
    return now >= bar_open and (now - bar_open) <= limit
