"""Unit tests for the offline rule model. They do not compile or run MQL5."""

import unittest

from xau_demo_model import (  # noqa: E402
    entry_window_fresh,
    EXPIRY_BARS,
    Bar,
    Item,
    SignalBook,
    account_allowed,
    adverse_pnl,
    apply_close,
    build_stops,
    can_send,
    catchup_too_wide,
    classify_startup,
    daily_loss_hit,
    environment_allowed,
    apply_day_streak,
    is_gold_symbol,
    lot_allowed,
    make_comment,
    mark_sent,
    may_flatten,
    replay_today_closes,
    restart_same_day,
    risk_allows,
    risk_total,
    roll_lot010_day,
    roll_server_day,
    spread_ok,
    state_filename,
)


def stub_profit(direction, volume, open_price, close_price):
    """$1 price move on 1.00 lot is $100. Test stub only, not a live quote."""
    sign = 1 if direction == 1 else -1
    return sign * (close_price - open_price) * 100.0 * volume


def bar(time, high, low, close, fast, slow, atr=2.0, open_=None):
    return Bar(time, close if open_ is None else open_, high, low, close, fast, slow, atr)


class SymbolTests(unittest.TestCase):
    def test_suffixes(self):
        self.assertTrue(is_gold_symbol("XAUUSD"))
        self.assertTrue(is_gold_symbol("xauusd.m"))
        self.assertTrue(is_gold_symbol("XAUUSDm"))
        self.assertTrue(is_gold_symbol("XAUUSD.pro"))
        self.assertTrue(is_gold_symbol("XAUUSD#"))
        self.assertFalse(is_gold_symbol("EURUSD"))
        self.assertFalse(is_gold_symbol("GOLD"))
        self.assertFalse(is_gold_symbol("XXAUUSD"))
        self.assertFalse(is_gold_symbol("XAUUSD "))
        self.assertFalse(is_gold_symbol(""))

    def test_comment_length(self):
        text = make_comment(99999999, 9999999999)
        self.assertLessEqual(len(text), 31)
        self.assertTrue(text.startswith("XD1:99999999:"))
        with self.assertRaises(ValueError):
            make_comment(0, 1)
        with self.assertRaises(ValueError):
            make_comment(100000000, 1)


class AccountTests(unittest.TestCase):
    def test_real_chart_refused_and_tester_netting_refused(self):
        self.assertFalse(account_allowed(False, "real", "hedge", "USD"))
        self.assertFalse(account_allowed(False, "contest", "hedge", "USD"))
        self.assertFalse(account_allowed(False, "demo", "netting", "USD"))
        self.assertFalse(account_allowed(True, "demo", "netting", "USD"))
        self.assertFalse(account_allowed(False, "demo", "hedge", "EUR"))
        self.assertTrue(account_allowed(False, "demo", "hedge", "USD"))
        self.assertTrue(account_allowed(True, "real", "hedge", "USD"))


class StopRiskTests(unittest.TestCase):
    def test_stop_is_not_pulled_closer(self):
        # Ask 100, bid 99.8, ATR 2 → raw distance 3 → SL 97.
        sl, tp = build_stops(1, 100.0, 2.0, 99.8, 100.0, 0.2, 0.01)
        self.assertAlmostEqual(sl, 97.0)
        self.assertAlmostEqual(tp, 106.0)
        self.assertGreaterEqual(100.0 - sl, 3.0)

    def test_broker_distance_widens_then_risk_can_skip(self):
        # Raw SL would be 99.7, but the broker requires 0.50 beyond the bid.
        stops = build_stops(1, 100.0, 0.2, 99.9, 100.0, 0.50, 0.01)
        self.assertIsNotNone(stops)
        sl, _tp = stops
        self.assertLessEqual(sl, 99.4)
        self.assertGreater(100.0 - sl, 0.3)
        # Stub: 0.01 lot loses $1 per $1. Distance about 0.6 → loss 0.6, plus buffer.
        total = risk_total(1, 100.0, sl, 0.01, 0.01, 30, 1.0, stub_profit)
        self.assertIsNotNone(total)
        # A wide gold stop is refused when the stub loss exceeds $10.
        wide = build_stops(1, 2400.0, 20.0, 2399.5, 2400.0, 0.2, 0.01)
        self.assertIsNotNone(wide)
        wide_sl, _wide_tp = wide
        wide_total = risk_total(1, 2400.0, wide_sl, 0.01, 0.01, 30, 1.0, stub_profit)
        self.assertFalse(risk_allows(wide_total))
        self.assertGreater(wide_total, 10.0)

    def test_small_risk_passes_and_spread_is_not_a_second_addend(self):
        sl, _tp = build_stops(1, 100.0, 2.0, 99.8, 100.0, 0.2, 0.01)
        total = risk_total(1, 100.0, sl, 0.01, 0.01, 0, 0.0, stub_profit)
        # Distance 3, 0.01 lot, stub $1 per $1 → $3. No extra spread term exists.
        self.assertAlmostEqual(total, 3.0)
        self.assertTrue(risk_allows(total))
        with_slip = risk_total(1, 100.0, sl, 0.01, 0.01, 50, 1.0, stub_profit)
        # 50 points * 0.01 = 0.50 price = $0.50, plus $1 commission → 4.50.
        self.assertAlmostEqual(with_slip, 4.50)

    def test_sell_stop_aligns_away(self):
        sl, tp = build_stops(-1, 100.0, 2.0, 99.8, 100.0, 0.2, 0.01)
        self.assertGreaterEqual(sl, 103.0)
        self.assertLessEqual(tp, 94.0)

    def test_tick_alignment_buy_moves_down(self):
        sl, _tp = build_stops(1, 100.006, 2.0, 99.8, 100.006, 0.0, 0.01)
        self.assertLessEqual(sl, 100.006 - 3.0)
        self.assertAlmostEqual(sl, int(sl * 100) / 100.0)


class VolumeSpreadTests(unittest.TestCase):
    def test_lot_constraints(self):
        self.assertTrue(lot_allowed(0.01, 0.01, 50, 0.01, 0, 0))
        self.assertFalse(lot_allowed(0.02, 0.01, 50, 0.01, 0, 0))
        self.assertFalse(lot_allowed(0.01, 0.10, 50, 0.01, 0, 0))
        self.assertFalse(lot_allowed(0.01, 0.01, 50, 0.03, 0, 0))
        self.assertFalse(lot_allowed(0.01, 0.01, 0.009, 0.01, 0, 0))
        self.assertFalse(lot_allowed(0.01, 0.01, 50, 0.01, 0.01, 0.01))
        self.assertFalse(lot_allowed(0.01, 0, 50, 0.01, 0, 0))

    def test_spread_uses_price(self):
        self.assertTrue(spread_ok(2400.0, 2400.3, 0.50))
        self.assertFalse(spread_ok(2400.0, 2400.8, 0.50))
        self.assertFalse(spread_ok(0, 1, 0.50))
        self.assertFalse(spread_ok(10, 9, 0.50))


class DailyTests(unittest.TestCase):
    def test_floating_profit_does_not_hide_realized_loss(self):
        self.assertAlmostEqual(adverse_pnl(-8.0, 5.0), -8.0)
        self.assertAlmostEqual(adverse_pnl(-8.0, -3.0), -11.0)
        self.assertFalse(daily_loss_hit(-8.0, 5.0))
        self.assertTrue(daily_loss_hit(-8.0, -3.0))
        self.assertTrue(daily_loss_hit(-10.0, 4.0))

    def test_new_day_clears_daily_halt_only(self):
        daily, streak = roll_server_day(True, True)
        self.assertFalse(daily)
        self.assertTrue(streak)

    def test_streak(self):
        streak, halt = apply_close(0, 0, -1)
        self.assertEqual((streak, halt), (1, 0))
        streak, halt = apply_close(streak, halt, 0)
        self.assertEqual((streak, halt), (1, 0))
        streak, halt = apply_close(streak, halt, 2)
        self.assertEqual((streak, halt), (0, 0))
        streak, halt = apply_close(0, 0, -1)
        streak, halt = apply_close(streak, halt, -0.2)
        self.assertEqual((streak, halt), (2, 1))
        streak, halt = apply_close(streak, halt, 5)
        self.assertEqual((streak, halt), (2, 1))


class OwnershipTests(unittest.TestCase):
    def test_empty_adopt_and_refuse(self):
        decision, _fresh = classify_startup([], "", "", 26011421, "XAUUSD", False)
        self.assertEqual(decision, "empty")
        own = Item("10", 26011421, "XAUUSD", "XD1:26011421:100")
        decision, _fresh = classify_startup([own], "10", "", 26011421, "XAUUSD", False)
        self.assertEqual(decision, "adopt")
        manual = Item("11", 0, "XAUUSD", "")
        decision, _fresh = classify_startup([manual], "", "", 26011421, "XAUUSD", False)
        self.assertEqual(decision, "refuse")
        same_magic = Item("12", 26011421, "XAUUSD", "manual")
        decision, _fresh = classify_startup([same_magic], "", "", 26011421, "XAUUSD", False)
        self.assertEqual(decision, "refuse")
        prefixed = Item("13", 26011421, "XAUUSD", "XD1:26011421:5")
        decision, _fresh = classify_startup([prefixed], "", "", 26011421, "XAUUSD", False)
        self.assertEqual(decision, "refuse")

    def test_fresh_inflight_and_flatten_guard(self):
        fresh = Item("20", 26011421, "XAUUSD", "XD1:26011421:100")
        decision, found = classify_startup(
            [fresh], "", "XD1:26011421:100", 26011421, "XAUUSD", True
        )
        self.assertEqual(decision, "fresh")
        self.assertEqual(len(found), 1)
        adopted = Item("10", 26011421, "XAUUSD", "XD1:26011421:100", preexisting=True)
        self.assertFalse(may_flatten(adopted, set(), 26011421, "XAUUSD"))
        self.assertFalse(may_flatten(adopted, {"10"}, 26011421, "XAUUSD"))
        created = Item("20", 26011421, "XAUUSD", "XD1:26011421:100", preexisting=False)
        self.assertTrue(may_flatten(created, {"20"}, 26011421, "XAUUSD"))
        self.assertFalse(may_flatten(created, {"21"}, 26011421, "XAUUSD"))
        other = Item("20", 26011421, "EURUSD", "XD1:26011421:100")
        self.assertFalse(may_flatten(other, {"20"}, 26011421, "XAUUSD"))


class SignalTests(unittest.TestCase):
    def test_unusable_indicator_bar_is_skipped(self):
        book = SignalBook(attach_bar=1000, last_closed=900)
        action = book.process(bar(1000, 11, 9, 10, 10, 8, atr=0), 1100, False, False)
        self.assertEqual(action, "skip")
        self.assertEqual(book.last_closed, 1000)
        self.assertEqual(book.process(bar(1100, 11, 9.5, 10.2, 10, 8), 1200, False, False), "arm")

    def test_pre_attachment_bar_is_ignored(self):
        book = SignalBook(attach_bar=1000, last_closed=900)
        action = book.process(bar(900, 11, 9, 10.2, 10, 8), 1000, True, False)
        self.assertEqual(action, "ignore")
        self.assertEqual(book.state, "idle")

    def test_buy_setup_breakout_and_single_use(self):
        book = SignalBook(attach_bar=1000, last_closed=900)
        self.assertEqual(book.process(bar(1000, 11, 9.5, 10.2, 10, 8), 1100, False, False), "arm")
        # Wick through the high does not count. Close is still below the setup high.
        self.assertEqual(book.process(bar(1100, 12, 10, 10.8, 10, 8), 1200, False, False), "none")
        self.assertEqual(book.process(bar(1200, 12, 10, 11.2, 10, 8, atr=2.5), 1300, True, False), "enter")
        self.assertEqual(book.entry_bar, 1300)
        self.assertEqual(book.signal_atr, 2.5)
        self.assertNotEqual(book.entry_bar, 1200)
        # The setup is spent. A later bar while the window is open expires it
        # if entry did not happen before the next close.
        self.assertEqual(book.process(bar(1300, 12, 10, 11.4, 10, 8), 1400, False, False), "invalidate")
        self.assertEqual(book.state, "idle")

    def test_sell_and_close_must_stay_beyond_ema50(self):
        book = SignalBook(attach_bar=1000, last_closed=900)
        # Downtrend, but the close is still above EMA50, so this is not a setup.
        self.assertEqual(book.process(bar(1000, 10.6, 8, 10.5, 9, 10), 1100, False, False), "none")
        self.assertEqual(book.process(bar(1100, 10.2, 8.4, 8.8, 9, 10), 1200, False, False), "arm")
        self.assertEqual(book.direction, -1)
        self.assertEqual(book.setup_low, 8.4)
        # A lower wick does not count. The close must be beyond the setup low.
        self.assertEqual(book.process(bar(1200, 9, 8.0, 8.5, 9, 10), 1300, True, False), "none")
        self.assertEqual(book.process(bar(1300, 9, 7.9, 8.3, 9, 10), 1400, True, False), "enter")
        self.assertEqual(book.entry_bar, 1400)

    def test_trend_flip_does_not_rearm_same_bar(self):
        book = SignalBook(attach_bar=1000, last_closed=900)
        book.process(bar(1000, 11, 9.5, 10.2, 10, 8), 1100, False, False)
        # This bar would qualify as a sell setup, but it is only allowed to cancel.
        action = book.process(bar(1100, 10.2, 8, 8.8, 9, 10), 1200, True, False)
        self.assertEqual(action, "invalidate")
        self.assertEqual(book.state, "idle")
        self.assertEqual(book.events[-1], ("invalidate", "trend"))

    def test_expiry(self):
        book = SignalBook(attach_bar=1000, last_closed=900)
        book.process(bar(1000, 11, 9.5, 10.2, 10, 8), 1100, False, False)
        action = "none"
        for i in range(1, EXPIRY_BARS + 2):
            action = book.process(
                bar(1000 + i * 100, 10.8, 10.0, 10.4, 10, 8),
                1000 + (i + 1) * 100,
                False,
                False,
            )
        self.assertEqual(action, "expire")
        self.assertEqual(book.state, "idle")

    def test_missed_window_and_gap(self):
        book = SignalBook(attach_bar=1000, last_closed=900)
        book.process(bar(1000, 11, 9.5, 10.2, 10, 8), 1100, False, False)
        action = book.process(bar(1100, 12, 10, 11.2, 10, 8), 1200, False, False)
        self.assertEqual(action, "invalidate")
        self.assertEqual(book.state, "idle")
        book.process(bar(1200, 11, 9.5, 10.2, 10, 8), 1300, False, False)
        self.assertEqual(book.state, "armed")
        self.assertTrue(catchup_too_wide(49))
        self.assertFalse(catchup_too_wide(48))
        book.drop_gap()
        self.assertEqual(book.state, "idle")

    def test_exposure_blocks_new_setup(self):
        book = SignalBook(attach_bar=1000, last_closed=900)
        book.process(bar(1000, 11, 9.5, 10.2, 10, 8), 1100, False, False)
        action = book.process(bar(1100, 12, 10, 11.4, 10, 8), 1200, True, True)
        self.assertEqual(action, "invalidate")
        self.assertEqual(book.state, "idle")

    def test_one_send_per_bar(self):
        consumed = None
        self.assertEqual(
            can_send(consumed, 1300, False, 0, False, False, False, True, True, True),
            "send",
        )
        consumed = mark_sent(1300)
        self.assertEqual(
            can_send(consumed, 1300, False, 0, False, False, False, True, True, True),
            "consumed",
        )
        self.assertEqual(
            can_send(None, 1300, True, 0, False, False, False, True, True, True),
            "exposure",
        )
        self.assertEqual(
            can_send(None, 1300, False, 0, True, False, False, True, True, True),
            "halt",
        )
        self.assertEqual(
            can_send(None, 1300, False, 0, False, False, False, False, True, True),
            "spread",
        )
        self.assertEqual(
            can_send(None, 1300, False, 0, False, False, False, True, False, True),
            "risk",
        )
        self.assertTrue(entry_window_fresh(1300, 1300))
        self.assertTrue(entry_window_fresh(1420, 1300))
        self.assertFalse(entry_window_fresh(1421, 1300))


class VariantGateTests(unittest.TestCase):
    def test_trade_cap_boundaries_do_not_move_the_daily_halt(self):
        self.assertTrue(risk_allows(10.0, 10.0))
        self.assertFalse(risk_allows(10.01, 10.0))
        self.assertFalse(risk_allows(14.88, 10.0))
        self.assertTrue(risk_allows(14.88, 30.0))
        self.assertTrue(risk_allows(30.0, 30.0))
        self.assertFalse(risk_allows(30.01, 30.0))
        self.assertFalse(risk_allows(47.75, 30.0))
        self.assertTrue(daily_loss_hit(-10.0, 0.0))
        self.assertFalse(daily_loss_hit(-9.99, 0.0))
        self.assertTrue(daily_loss_hit(-30.0, 0.0))
        self.assertGreater(30.0, 10.0)

    def test_tester30_refuses_every_chart_and_keeps_hedge_usd(self):
        for mode in ("demo", "real", "contest"):
            self.assertFalse(environment_allowed("tester30", False, mode, "hedge", "USD"))
        self.assertTrue(environment_allowed("tester30", True, "demo", "hedge", "USD"))
        self.assertTrue(environment_allowed("tester30", True, "real", "hedge", "USD"))
        self.assertFalse(environment_allowed("tester30", True, "demo", "netting", "USD"))
        self.assertFalse(environment_allowed("tester30", True, "demo", "hedge", "EUR"))
        self.assertTrue(environment_allowed("demo10", False, "demo", "hedge", "USD"))
        self.assertFalse(environment_allowed("demo10", False, "real", "hedge", "USD"))

    def test_state_files_and_comments_stay_apart(self):
        self.assertNotEqual(state_filename("demo10", "99"), state_filename("tester30", "99"))
        self.assertTrue(state_filename("demo10", "99").startswith("XauDemoSafe_"))
        self.assertTrue(state_filename("tester30", "99").startswith("XauTest30_"))
        demo = make_comment(26011421, 1000, "XD1")
        other = make_comment(26011430, 1000, "XT30")
        self.assertLessEqual(len(other), 31)
        self.assertFalse(other.startswith("XD1:"))
        self.assertFalse(demo.startswith("XT30:"))
        item = Item("10", 26011430, "XAUUSD", other)
        decision, _fresh = classify_startup([item], "10", "", 26011430, "XAUUSD", False, tag="XT30")
        self.assertEqual(decision, "adopt")
        decision, _fresh = classify_startup([item], "10", "", 26011430, "XAUUSD", False, tag="XD1")
        self.assertEqual(decision, "refuse")
        self.assertFalse(may_flatten(item, {"10"}, 26011430, "XAUUSD", tag="XD1"))
        self.assertTrue(may_flatten(item, {"10"}, 26011430, "XAUUSD", tag="XT30"))


class Lot010Tests(unittest.TestCase):
    def test_point_one_lot_respects_step_and_minimum(self):
        self.assertTrue(lot_allowed(0.10, 0.01, 50, 0.01, 0, 0, required=0.10))
        self.assertTrue(lot_allowed(0.10, 0.10, 50, 0.10, 0, 0, required=0.10))
        self.assertFalse(lot_allowed(0.01, 0.01, 50, 0.01, 0, 0, required=0.10))
        self.assertFalse(lot_allowed(0.10, 0.20, 50, 0.01, 0, 0, required=0.10))
        self.assertFalse(lot_allowed(0.10, 0.01, 50, 0.03, 0, 0, required=0.10))
        self.assertFalse(environment_allowed("r50lot010", False, "demo", "hedge", "USD"))
        self.assertFalse(environment_allowed("r50lot010", False, "real", "hedge", "USD"))
        self.assertTrue(environment_allowed("r50lot010", True, "demo", "hedge", "USD"))
        self.assertFalse(environment_allowed("r50lot010", True, "demo", "netting", "USD"))

    def test_fixed_fee_is_not_multiplied_and_cap_stays_50(self):
        # Price P/L scales with lot. The configured commission is added once.
        # An old 0.01 figure such as 22.88 must not be multiplied by 10 and treated as exact.
        small = risk_total(1, 100.0, 97.0, 0.01, 0.01, 0, 1.0, stub_profit)
        large = risk_total(1, 100.0, 97.0, 0.10, 0.01, 0, 1.0, stub_profit)
        self.assertAlmostEqual(small, 4.0)
        self.assertAlmostEqual(large, 31.0)
        self.assertNotAlmostEqual(large, small * 10)
        self.assertTrue(risk_allows(50.0, 50.0))
        self.assertFalse(risk_allows(50.01, 50.0))
        self.assertTrue(risk_allows(large, 50.0))
        self.assertFalse(risk_allows(300.0, 50.0))
        self.assertFalse(risk_allows(50.0, 30.0))

    def test_three_same_day_losses_pause_and_do_not_survive_the_day(self):
        streak, halt = apply_day_streak(0, 0, -1)
        streak, halt = apply_day_streak(streak, halt, -1)
        self.assertEqual((streak, halt), (2, 0))
        streak, halt = apply_day_streak(streak, halt, 0)
        self.assertEqual((streak, halt), (2, 0))
        streak, halt = apply_day_streak(streak, halt, 2)
        self.assertEqual((streak, halt), (0, 0))
        streak, halt = replay_today_closes([-1, -1, -1])
        self.assertEqual((streak, halt), (3, 1))
        streak, halt = apply_day_streak(streak, halt, 5)
        self.assertEqual((streak, halt), (3, 1))
        # Yesterday's two losses are not in today's list.
        self.assertEqual(replay_today_closes([]), (0, 0))
        daily, streak_halt, prot, streak = roll_lot010_day(True, True, True, 3)
        self.assertEqual((daily, streak_halt, prot, streak), (False, False, True, 0))
        # Same-day restart keeps a saved pause even if today's history is missing.
        streak, halt, daily_halt = restart_same_day(True, True, [])
        self.assertEqual((streak, halt, daily_halt), (0, 1, True))
        streak, halt, daily_halt = restart_same_day(False, False, [-5, -1, -0.2])
        self.assertEqual((streak, halt, daily_halt), (3, 1, False))

    def test_lot010_state_is_not_adopted_by_older_variants(self):
        self.assertNotEqual(state_filename("r50lot010", "7"), state_filename("demo10", "7"))
        self.assertNotEqual(state_filename("r50lot010", "7"), state_filename("tester30", "7"))
        comment = make_comment(26011450, 1000, "R050")
        self.assertLessEqual(len(comment), 31)
        item = Item("8", 26011450, "XAUUSD", comment)
        decision, _fresh = classify_startup([item], "8", "", 26011450, "XAUUSD", False, tag="R050")
        self.assertEqual(decision, "adopt")
        decision, _fresh = classify_startup([item], "8", "", 26011450, "XAUUSD", False, tag="XT30")
        self.assertEqual(decision, "refuse")
        decision, _fresh = classify_startup([item], "8", "", 26011450, "XAUUSD", False, tag="XD1")
        self.assertEqual(decision, "refuse")


class R300D500Tests(unittest.TestCase):
    def test_trade_cap_300_and_daily_trigger_500(self):
        self.assertTrue(risk_allows(300.0, 300.0))
        self.assertFalse(risk_allows(300.01, 300.0))
        self.assertTrue(risk_allows(139.80, 300.0))
        self.assertFalse(risk_allows(468.50, 300.0))
        self.assertTrue(daily_loss_hit(-500.0, 0.0, cap=500.0))
        self.assertFalse(daily_loss_hit(-499.99, 0.0, cap=500.0))
        self.assertTrue(daily_loss_hit(-500.0, 20.0, cap=500.0))
        self.assertFalse(daily_loss_hit(-400.0, 0.0, cap=500.0))
        daily, streak_halt, prot, streak = roll_lot010_day(True, True, True, 3)
        self.assertEqual((daily, streak_halt, prot, streak), (False, False, True, 0))
        self.assertEqual(replay_today_closes([-1, -1]), (2, 0))
        self.assertEqual(replay_today_closes([-1, -1, -1]), (3, 1))

    def test_r300_state_is_separate_and_charts_are_refused(self):
        self.assertFalse(environment_allowed("r300d500", False, "demo", "hedge", "USD"))
        self.assertFalse(environment_allowed("r300d500", False, "real", "hedge", "USD"))
        self.assertTrue(environment_allowed("r300d500", True, "demo", "hedge", "USD"))
        self.assertFalse(environment_allowed("r300d500", True, "demo", "netting", "USD"))
        name = state_filename("r300d500", "9")
        self.assertTrue(name.startswith("XauR300D500_"))
        self.assertNotEqual(name, state_filename("r50lot010", "9"))
        self.assertNotEqual(name, state_filename("tester30", "9"))
        self.assertNotEqual(name, state_filename("demo10", "9"))
        comment = make_comment(26011500, 1000, "R300")
        self.assertLessEqual(len(comment), 31)
        item = Item("9", 26011500, "XAUUSD", comment)
        decision, _fresh = classify_startup([item], "9", "", 26011500, "XAUUSD", False, tag="R300")
        self.assertEqual(decision, "adopt")
        for tag in ("R050", "XT30", "XD1"):
            decision, _fresh = classify_startup([item], "9", "", 26011500, "XAUUSD", False, tag=tag)
            self.assertEqual(decision, "refuse")


if __name__ == "__main__":
    unittest.main()
