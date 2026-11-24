"""Static checks on the new EA source. This does not compile MQL5."""

import hashlib
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
EA = ROOT / "Experts" / "XauUsdDemoSafeEA.mq5"
TESTER = ROOT / "Experts" / "XauUsdTesterOnly30.mq5"
ORIGINAL = {
    "Experts/XauUsdDemoSafeEA.mq5": "fa8cea4edd199d7f1c84d7a07626ee6908ece944d26cf7f1e74e0e9a5ada7783",
    "Experts/XauUsdTesterOnly30.mq5": "0288a9e7bbf67ce406f8112878f442738a9d8d3333a243a802e3963e1859790c",
    "Experts/XauUsdR50D100L3Lot010.mq5": "921f9b8dc7cce346767825dfa306800d21acf8f4619629de8cf066872aabaf80",
    "Experts/EmaPullbackEA.mq5": "fc6daf208a62019b61cb1d94cd16131b4402c7a83fa38a3d9328cd61e0b5a906",
    "Include/EmaPullback/Risk.mqh": "fc96a36d978fde2fba1a6baf449ddddd914d25e2e2cf63f2ea5b0eb140e0768d",
    "Include/EmaPullback/Signal.mqh": "f73b3f25ccc711d04a254adbf8a45142558a80af54d2728a0cdeba01fef58ef6",
    "Include/EmaPullback/Trade.mqh": "e1145097a98fe4cc2e485aeea99ccdc44d151b455e4c6d05b8a0c0c518c937ef",
    "LICENSE": "4187d48d6c116b35d7895dabcbc4913972170a7eb5305a6ca5ee2cd3cec1e18f",
    "README.md": "5c7aa0817cbd3cf2d2cb4d7a059575595a1be808560e29db03919d07c5e3e020",
}


def strip_mql(text: str) -> str:
    out = []
    i = 0
    while i < len(text):
        if text.startswith("//", i):
            i = text.find("\n", i)
            if i < 0:
                break
            continue
        if text.startswith("/*", i):
            end = text.find("*/", i + 2)
            i = len(text) if end < 0 else end + 2
            continue
        quote = text[i]
        if quote in ("'", '"'):
            i += 1
            while i < len(text):
                if text[i] == "\\":
                    i += 2
                    continue
                if text[i] == quote:
                    i += 1
                    break
                i += 1
            continue
        out.append(text[i])
        i += 1
    return "".join(out)


class SourceTests(unittest.TestCase):
    def test_original_files_are_unchanged(self):
        for rel, digest in ORIGINAL.items():
            data = (ROOT / rel).read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), digest, rel)

    def test_new_ea_is_standalone_and_has_no_compiled_blob(self):
        text = EA.read_text(encoding="utf-8")
        self.assertNotIn("#include", text)
        self.assertFalse(list(ROOT.rglob("*.ex5")))
        code = strip_mql(text)
        self.assertEqual(code.count("{"), code.count("}"))
        self.assertEqual(code.count("("), code.count(")"))

    def test_safety_gates_are_present_and_dangerous_calls_are_absent(self):
        text = EA.read_text(encoding="utf-8")
        for token in (
            "WebRequest",
            "#import",
            "wininet",
            "socket",
            "PositionModify",
            "TRADE_ACTION_CLOSE_BY",
            "DLL",
        ):
            self.assertNotIn(token, text)
        for token in (
            "OrderCalcProfit",
            "ACCOUNT_TRADE_MODE_DEMO",
            "ACCOUNT_MARGIN_MODE_RETAIL_HEDGING",
            "PERIOD_H1",
            "DEAL_FEE",
            "DEAL_SWAP",
            "DEAL_COMMISSION",
            "POSITION_IDENTIFIER",
            "SYMBOL_TRADE_FREEZE_LEVEL",
            "SYMBOL_TRADE_STOPS_LEVEL",
            "SYMBOL_VOLUME_LIMIT",
            "XAUUSD",
            "XD1:",
            "0.01",
            "iMA(_Symbol, PERIOD_H1, 20",
            "iMA(_Symbol, PERIOD_H1, 50",
            "iATR(_Symbol, PERIOD_H1, 14)",
        ):
            self.assertIn(token, text)
        self.assertIn("ServerNow() - bar > 120", text)
        self.assertNotIn("AllowReal", text)
        self.assertNotIn("InpLots", text)

    def test_original_ea_is_still_the_old_strategy(self):
        old = (ROOT / "Experts" / "EmaPullbackEA.mq5").read_text(encoding="utf-8")
        self.assertIn("InpFastEMA       = 21", old)
        self.assertNotIn("XauUsdDemoSafe", old)

    def test_tester30_is_isolated_and_does_not_move_other_caps(self):
        demo = EA.read_text(encoding="utf-8")
        tester = TESTER.read_text(encoding="utf-8")
        self.assertNotEqual(demo, tester)
        self.assertIn("#define RISK_CAP       10.0", demo)
        self.assertIn("#define DAILY_CAP      10.0", demo)
        self.assertNotIn("TesterOnly30", demo)
        self.assertNotIn("XauTest30_", demo)
        self.assertIn("#define RISK_CAP       30.0", tester)
        self.assertIn("#define DAILY_CAP      10.0", tester)
        self.assertIn("variant=TesterOnly30 riskCap=30 dailyCap=10", tester)
        self.assertIn("XauTest30_", tester)
        self.assertIn("TesterOnly30|", tester)
        self.assertIn("XT30:", tester)
        self.assertNotIn("XD1:", tester)
        self.assertNotIn("XauDemoSafe_", tester)
        self.assertIn("if(!MQLInfoInteger(MQL_TESTER))", tester)
        self.assertIn("计划风险含缓冲超过 30 美元", tester)
        self.assertIn("当日不利盈亏达到 10 美元", tester)
        self.assertNotIn("当日不利盈亏达到 30 美元", tester)
        self.assertIn("STREAK_CAP     2", tester)
        self.assertIn("0.01", tester)
        self.assertNotIn("InpAllowChart", tester)
        self.assertNotIn("WebRequest", tester)
        self.assertNotIn("#include", tester)
        code = strip_mql(tester)
        self.assertEqual(code.count("{"), code.count("}"))
        self.assertEqual(code.count("("), code.count(")"))

    def test_lot010_changes_only_lot_daily_pause_and_same_day_streak(self):
        path = ROOT / "Experts" / "XauUsdR50D100L3Lot010.mq5"
        text = path.read_text(encoding="utf-8")
        self.assertIn("#define LOT            0.10", text)
        self.assertIn("#define RISK_CAP       50.0", text)
        self.assertIn("#define DAILY_CAP      100.0", text)
        self.assertIn("#define STREAK_CAP     3", text)
        self.assertIn("variant=R50D100L3Lot010 riskCap=50 dailyCap=100 streakCap=3 lot=0.10", text)
        self.assertIn("XauR50Lot010_", text)
        self.assertIn("R050:", text)
        self.assertIn("if(!MQLInfoInteger(MQL_TESTER))", text)
        self.assertIn("计划风险含缓冲超过 50 美元", text)
        self.assertIn("当日不利盈亏达到 100 美元", text)
        self.assertIn("保护性停止不解除", text)
        self.assertNotIn("RISK_CAP       30.0", text)
        self.assertNotIn("riskCap=30", text)
        self.assertNotIn("超过 30 美元", text)
        self.assertNotIn("XauDemoSafe_", text)
        self.assertNotIn("XauTest30_", text)
        self.assertNotIn("XauLot010_", text)
        self.assertNotIn("XD1:", text)
        self.assertNotIn("XT30:", text)
        self.assertNotIn("L010:", text)
        self.assertNotIn("当日不利盈亏达到 10 美元", text)
        self.assertNotIn("WebRequest", text)
        self.assertNotIn("#include", text)
        self.assertEqual(text.count("g_st.protHalt = 0"), 1)
        code = strip_mql(text)
        self.assertEqual(code.count("{"), code.count("}"))
        self.assertEqual(code.count("("), code.count(")"))

    def test_r300_d500_changes_only_the_two_dollar_caps(self):
        path = ROOT / "Experts" / "XauUsdR300D500L3Lot010.mq5"
        text = path.read_text(encoding="utf-8")
        self.assertIn("#define LOT            0.10", text)
        self.assertIn("#define RISK_CAP       300.0", text)
        self.assertIn("#define DAILY_CAP      500.0", text)
        self.assertIn("#define STREAK_CAP     3", text)
        self.assertIn("variant=R300D500L3Lot010 riskCap=300 dailyCap=500 streakCap=3 lot=0.10", text)
        self.assertIn("XauR300D500_", text)
        self.assertIn("R300:", text)
        self.assertIn("if(!MQLInfoInteger(MQL_TESTER))", text)
        self.assertIn("计划风险含缓冲超过 300 美元", text)
        self.assertIn("当日不利盈亏达到 500 美元", text)
        self.assertIn("保护性停止不解除", text)
        self.assertIn("iMA(_Symbol, PERIOD_H1, 20", text)
        self.assertIn("iMA(_Symbol, PERIOD_H1, 50", text)
        self.assertIn("iATR(_Symbol, PERIOD_H1, 14)", text)
        self.assertNotIn("RISK_CAP       50.0", text)
        self.assertNotIn("DAILY_CAP      100.0", text)
        self.assertNotIn("riskCap=50", text)
        self.assertNotIn("dailyCap=100", text)
        self.assertNotIn("超过 50 美元", text)
        self.assertNotIn("达到 100 美元", text)
        self.assertNotIn("XauR50Lot010_", text)
        self.assertNotIn("R050:", text)
        self.assertNotIn("XauDemoSafe_", text)
        self.assertNotIn("XauTest30_", text)
        self.assertNotIn("WebRequest", text)
        self.assertNotIn("#include", text)
        self.assertEqual(text.count("g_st.protHalt = 0"), 1)
        code = strip_mql(text)
        self.assertEqual(code.count("{"), code.count("}"))
        self.assertEqual(code.count("("), code.count(")"))


if __name__ == "__main__":
    unittest.main()
