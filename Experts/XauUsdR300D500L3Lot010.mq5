//+------------------------------------------------------------------+
//| XauUsdR300D500L3Lot010.mq5                                        |
//| MIT License. Tester-only 0.10 lot comparison. Does not change   |
//| the delivered 0.01 EAs or the R50 file. Trade cap is 300 USD.    |
//| Daily pause is 500 USD. Same-day streak pause is 3, cleared     |
//| next server day. Not compiled or backtested in this run.        |
//+------------------------------------------------------------------+
#property copyright "MIT License"
#property version   "1.00"
#property description "Tester-only 0.10 lot. Trade cap 300 USD. Daily pause 500. Streak 3. Charts refused."

input group "=== 可调环境参数（假设，不是收益承诺） ==="
input long   InpMagic            = 26011500; // 魔法号，必须是 1 到 99999999
input double InpMaxSpreadPrice   = 0.50;     // 最大点差，按价格而不是点数
input double InpCommissionBuffer = 1.0;      // 往返手续费缓冲（美元，占位）
input int    InpSlippagePoints   = 30;       // 滑点点数：下单偏差和风险缓冲共用
input int    InpExpiryBars       = 24;       // 形态有效的后续已收盘 H1 根数

#define LOT            0.10
#define SL_MULT        1.5
#define TP_R           2.0
#define RISK_CAP       300.0
#define DAILY_CAP      500.0
#define STREAK_CAP     3
#define MAX_CATCHUP    48
#define COMMENT_MAX    31
#define ST_IDLE        0
#define ST_ARMED       1
#define ST_WINDOW      2

struct SState
  {
   int      version;
   uint     loginHash;
   uint     serverHash;
   string   symbol;
   long     magic;
   long     chartId;
   datetime attachBar;
   datetime lastClosed;
   int      setupState;
   int      direction;
   datetime setupBar;
   double   setupHigh;
   double   setupLow;
   int      age;
   double   signalAtr;
   datetime entryBar;
   datetime consumedBar;
   int      entryDir;
   double   intendedSl;
   double   intendedTp;
   string   ownPosId;
   ulong    ownOrder;
   int      inflight;
   int      freshCheck;
   string   pendingComment;
   string   needFlattenId;
   int      streak;
   int      streakHalt;
   int      protHalt;
   int      dailyHalt;
   int      dailyYmd;
   string   knownIds;
   string   completedIds;
   datetime cancelBar;
   int      sawEnd;
  };

SState   g_st;
string   g_file;
int      g_fast = INVALID_HANDLE;
int      g_slow = INVALID_HANDLE;
int      g_atr  = INVALID_HANDLE;
bool     g_ready = false;
bool     g_saveOk = true;
bool     g_historyBlocked = true;
datetime g_skipBar = 0;
string   g_skipKey = "";
double   g_bid = 0;
double   g_ask = 0;
double   g_sl = 0;
double   g_tp = 0;
double   g_risk = 0;

void LogBoth(const string zh, const string en, const string detail);
void ReleaseIndicators();
bool SaveState();
bool LoadState();
void FreshIdentity();
bool ResolveStartup();
void Reconcile();
void ObserveClose();
void RefreshDay();
void CatchUp();
void TrySend();
bool ForeignPresent();

//+------------------------------------------------------------------+
void LogBoth(const string zh, const string en, const string detail)
  {
   string line = TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS);
   line += " | variant=R300D500L3Lot010 riskCap=300 dailyCap=500 streakCap=3 lot=0.10 | " + zh + " | " + en;
   if(StringLen(detail) > 0)
      line += " | " + detail;
   Print(line);
  }

//+------------------------------------------------------------------+
void LogSkip(const string key, const string zh, const string en, const string detail)
  {
   datetime bar = iTime(_Symbol, PERIOD_H1, 0);
   if(bar == g_skipBar && key == g_skipKey)
      return;
   g_skipBar = bar;
   g_skipKey = key;
   LogBoth(zh, en, detail);
  }

//+------------------------------------------------------------------+
string QuoteText()
  {
   MqlTick tk;
   if(!SymbolInfoTick(_Symbol, tk))
      return "symbol=" + _Symbol + " quote=unavailable";
   return StringFormat("symbol=%s bid=%s ask=%s spread=%s",
                       _Symbol,
                       DoubleToString(tk.bid, _Digits),
                       DoubleToString(tk.ask, _Digits),
                       DoubleToString(tk.ask - tk.bid, _Digits));
  }

//+------------------------------------------------------------------+
bool IsTester()
  {
   return (MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_OPTIMIZATION));
  }

//+------------------------------------------------------------------+
datetime ServerNow()
  {
   if(IsTester())
      return TimeCurrent();
   datetime now = TimeTradeServer();
   if(now <= 0)
      now = TimeCurrent();
   return now;
  }

//+------------------------------------------------------------------+
int Ymd(const datetime when)
  {
   MqlDateTime parts;
   TimeToStruct(when, parts);
   return parts.year * 10000 + parts.mon * 100 + parts.day;
  }

//+------------------------------------------------------------------+
datetime DayStart(const datetime when)
  {
   MqlDateTime parts;
   TimeToStruct(when, parts);
   parts.hour = 0;
   parts.min = 0;
   parts.sec = 0;
   return StructToTime(parts);
  }

//+------------------------------------------------------------------+
uint Fnv32(const string text)
  {
   uint hash = 2166136261;
   int length = StringLen(text);
   for(int i = 0; i < length; i++)
     {
      hash ^= (uint)StringGetCharacter(text, i);
      hash *= 16777619;
     }
   return hash;
  }

//+------------------------------------------------------------------+
string StateFileName()
  {
   string seed = "R300D500L3Lot010|"
                 + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "|"
                 + AccountInfoString(ACCOUNT_SERVER) + "|"
                 + _Symbol + "|"
                 + IntegerToString(InpMagic);
   return "XauR300D500_" + StringFormat("%u", Fnv32(seed)) + ".txt";
  }

//+------------------------------------------------------------------+
bool IsGoldSymbol(const string name)
  {
   if(StringLen(name) < 6)
      return false;
   string upper = name;
   StringToUpper(upper);
   if(StringSubstr(upper, 0, 6) != "XAUUSD")
      return false;
   string rest = StringSubstr(upper, 6);
   int length = StringLen(rest);
   for(int i = 0; i < length; i++)
     {
      int ch = StringGetCharacter(rest, i);
      bool ok = (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9')
                || ch == '.' || ch == '_' || ch == '-' || ch == '#';
      if(!ok)
         return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
bool AccountAllowed()
  {
   if(!MQLInfoInteger(MQL_TESTER))
     {
      LogBoth("拒绝启动：R300D500L3Lot010 只能在策略测试器运行。真实图表和模拟图表都不允许，没有开关可以放开",
              "refuse start: R300D500L3Lot010 runs only in the strategy tester. Real and demo charts are blocked, no override",
              "variant=R300D500L3Lot010 riskCap=300 dailyCap=500 streakCap=3 lot=0.10");
      return false;
     }
   long margin = AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(margin != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     {
      LogBoth("拒绝启动：账户不是对冲模式", "refuse start: account is not hedging", "variant=R300D500L3Lot010");
      return false;
     }
   string currency = AccountInfoString(ACCOUNT_CURRENCY);
   if(currency != "USD")
     {
      LogBoth("拒绝启动：账户货币不是美元", "refuse start: account currency is not USD", "variant=R300D500L3Lot010");
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
string Prefix()
  {
   return "R300:" + IntegerToString(g_st.magic) + ":";
  }

//+------------------------------------------------------------------+
string MakeComment(const long magic, const datetime setupBar)
  {
   return "R300:" + IntegerToString(magic) + ":" + IntegerToString((long)setupBar);
  }

//+------------------------------------------------------------------+
bool ListHas(const string list, const string id)
  {
   if(id == "" || list == "")
      return false;
   return (StringFind(";" + list + ";", ";" + id + ";") >= 0);
  }

//+------------------------------------------------------------------+
string ListAppend(string list, const string id)
  {
   if(id == "" || ListHas(list, id))
      return list;
   if(list == "")
      return id;
   return list + ";" + id;
  }

//+------------------------------------------------------------------+
void RememberId(const string id)
  {
   g_st.knownIds = ListAppend(g_st.knownIds, id);
   string parts[];
   int count = StringSplit(g_st.knownIds, (ushort)';', parts);
   if(count <= 80)
      return;
   string trimmed = "";
   for(int i = count - 80; i < count; i++)
      trimmed = ListAppend(trimmed, parts[i]);
   g_st.knownIds = trimmed;
  }

//+------------------------------------------------------------------+
void ClearSetup()
  {
   g_st.direction = 0;
   g_st.setupBar = 0;
   g_st.setupHigh = 0;
   g_st.setupLow = 0;
   g_st.age = 0;
   g_st.signalAtr = 0;
   g_st.entryBar = 0;
  }

//+------------------------------------------------------------------+
void ResetRuntimeState()
  {
   g_st.version = 1;
   g_st.setupState = ST_IDLE;
   g_st.direction = 0;
   g_st.setupBar = 0;
   g_st.setupHigh = 0;
   g_st.setupLow = 0;
   g_st.age = 0;
   g_st.signalAtr = 0;
   g_st.entryBar = 0;
   g_st.consumedBar = 0;
   g_st.entryDir = 0;
   g_st.intendedSl = 0;
   g_st.intendedTp = 0;
   g_st.ownPosId = "";
   g_st.ownOrder = 0;
   g_st.inflight = 0;
   g_st.freshCheck = 0;
   g_st.pendingComment = "";
   g_st.needFlattenId = "";
   g_st.streak = 0;
   g_st.streakHalt = 0;
   g_st.protHalt = 0;
   g_st.dailyHalt = 0;
   g_st.dailyYmd = 0;
   g_st.knownIds = "";
   g_st.completedIds = "";
   g_st.cancelBar = 0;
   g_st.sawEnd = 1;
  }

//+------------------------------------------------------------------+
void FreshIdentity()
  {
   ResetRuntimeState();
   g_st.loginHash = Fnv32(IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)));
   g_st.serverHash = Fnv32(AccountInfoString(ACCOUNT_SERVER));
   g_st.symbol = _Symbol;
   g_st.magic = InpMagic;
   g_st.chartId = ChartID();
   g_st.attachBar = iTime(_Symbol, PERIOD_H1, 0);
   datetime closed = iTime(_Symbol, PERIOD_H1, 1);
   if(closed > 0)
      g_st.lastClosed = closed;
  }

//+------------------------------------------------------------------+
void WriteKV(const int handle, const string key, const string value)
  {
   FileWriteString(handle, key + "=" + value + "\n");
  }

//+------------------------------------------------------------------+
bool SaveState()
  {
   g_st.version = 1;
   g_st.symbol = _Symbol;
   g_st.magic = InpMagic;
   g_st.loginHash = Fnv32(IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)));
   g_st.serverHash = Fnv32(AccountInfoString(ACCOUNT_SERVER));
   if(g_st.chartId == 0)
      g_st.chartId = ChartID();
   string tmp = g_file + ".tmp";
   int handle = FileOpen(tmp, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(handle == INVALID_HANDLE)
     {
      g_saveOk = false;
      LogBoth("状态文件写失败，暂停开新仓", "state file write failed, no new entry", "");
      return false;
     }
   WriteKV(handle, "version", IntegerToString(g_st.version));
   WriteKV(handle, "loginHash", StringFormat("%u", g_st.loginHash));
   WriteKV(handle, "serverHash", StringFormat("%u", g_st.serverHash));
   WriteKV(handle, "symbol", g_st.symbol);
   WriteKV(handle, "magic", IntegerToString(g_st.magic));
   WriteKV(handle, "chartId", IntegerToString(g_st.chartId));
   WriteKV(handle, "attachBar", IntegerToString((long)g_st.attachBar));
   WriteKV(handle, "lastClosed", IntegerToString((long)g_st.lastClosed));
   WriteKV(handle, "setupState", IntegerToString(g_st.setupState));
   WriteKV(handle, "direction", IntegerToString(g_st.direction));
   WriteKV(handle, "setupBar", IntegerToString((long)g_st.setupBar));
   WriteKV(handle, "setupHigh", DoubleToString(g_st.setupHigh, 8));
   WriteKV(handle, "setupLow", DoubleToString(g_st.setupLow, 8));
   WriteKV(handle, "age", IntegerToString(g_st.age));
   WriteKV(handle, "signalAtr", DoubleToString(g_st.signalAtr, 8));
   WriteKV(handle, "entryBar", IntegerToString((long)g_st.entryBar));
   WriteKV(handle, "consumedBar", IntegerToString((long)g_st.consumedBar));
   WriteKV(handle, "entryDir", IntegerToString(g_st.entryDir));
   WriteKV(handle, "intendedSl", DoubleToString(g_st.intendedSl, 8));
   WriteKV(handle, "intendedTp", DoubleToString(g_st.intendedTp, 8));
   WriteKV(handle, "ownPosId", g_st.ownPosId);
   WriteKV(handle, "ownOrder", StringFormat("%I64u", g_st.ownOrder));
   WriteKV(handle, "inflight", IntegerToString(g_st.inflight));
   WriteKV(handle, "freshCheck", IntegerToString(g_st.freshCheck));
   WriteKV(handle, "pendingComment", g_st.pendingComment);
   WriteKV(handle, "needFlattenId", g_st.needFlattenId);
   WriteKV(handle, "streak", IntegerToString(g_st.streak));
   WriteKV(handle, "streakHalt", IntegerToString(g_st.streakHalt));
   WriteKV(handle, "protHalt", IntegerToString(g_st.protHalt));
   WriteKV(handle, "dailyHalt", IntegerToString(g_st.dailyHalt));
   WriteKV(handle, "dailyYmd", IntegerToString(g_st.dailyYmd));
   WriteKV(handle, "knownIds", g_st.knownIds);
   WriteKV(handle, "completedIds", g_st.completedIds);
   WriteKV(handle, "cancelBar", IntegerToString((long)g_st.cancelBar));
   WriteKV(handle, "end", "1");
   FileFlush(handle);
   FileClose(handle);
   if(!FileMove(tmp, 0, g_file, FILE_REWRITE))
     {
      FileDelete(g_file);
      if(!FileMove(tmp, 0, g_file, FILE_REWRITE))
        {
         g_saveOk = false;
         LogBoth("状态文件替换失败，暂停开新仓", "state file replace failed, no new entry", "");
         return false;
        }
     }
   g_saveOk = true;
   return true;
  }

//+------------------------------------------------------------------+
void ApplyKey(const string key, const string value)
  {
   if(key == "version")
      g_st.version = (int)StringToInteger(value);
   else if(key == "loginHash")
      g_st.loginHash = (uint)StringToInteger(value);
   else if(key == "serverHash")
      g_st.serverHash = (uint)StringToInteger(value);
   else if(key == "symbol")
      g_st.symbol = value;
   else if(key == "magic")
      g_st.magic = (long)StringToInteger(value);
   else if(key == "chartId")
      g_st.chartId = (long)StringToInteger(value);
   else if(key == "attachBar")
      g_st.attachBar = (datetime)StringToInteger(value);
   else if(key == "lastClosed")
      g_st.lastClosed = (datetime)StringToInteger(value);
   else if(key == "setupState")
      g_st.setupState = (int)StringToInteger(value);
   else if(key == "direction")
      g_st.direction = (int)StringToInteger(value);
   else if(key == "setupBar")
      g_st.setupBar = (datetime)StringToInteger(value);
   else if(key == "setupHigh")
      g_st.setupHigh = StringToDouble(value);
   else if(key == "setupLow")
      g_st.setupLow = StringToDouble(value);
   else if(key == "age")
      g_st.age = (int)StringToInteger(value);
   else if(key == "signalAtr")
      g_st.signalAtr = StringToDouble(value);
   else if(key == "entryBar")
      g_st.entryBar = (datetime)StringToInteger(value);
   else if(key == "consumedBar")
      g_st.consumedBar = (datetime)StringToInteger(value);
   else if(key == "entryDir")
      g_st.entryDir = (int)StringToInteger(value);
   else if(key == "intendedSl")
      g_st.intendedSl = StringToDouble(value);
   else if(key == "intendedTp")
      g_st.intendedTp = StringToDouble(value);
   else if(key == "ownPosId")
      g_st.ownPosId = value;
   else if(key == "ownOrder")
      g_st.ownOrder = (ulong)StringToInteger(value);
   else if(key == "inflight")
      g_st.inflight = (int)StringToInteger(value);
   else if(key == "freshCheck")
      g_st.freshCheck = (int)StringToInteger(value);
   else if(key == "pendingComment")
      g_st.pendingComment = value;
   else if(key == "needFlattenId")
      g_st.needFlattenId = value;
   else if(key == "streak")
      g_st.streak = (int)StringToInteger(value);
   else if(key == "streakHalt")
      g_st.streakHalt = (int)StringToInteger(value);
   else if(key == "protHalt")
      g_st.protHalt = (int)StringToInteger(value);
   else if(key == "dailyHalt")
      g_st.dailyHalt = (int)StringToInteger(value);
   else if(key == "dailyYmd")
      g_st.dailyYmd = (int)StringToInteger(value);
   else if(key == "knownIds")
      g_st.knownIds = value;
   else if(key == "completedIds")
      g_st.completedIds = value;
   else if(key == "cancelBar")
      g_st.cancelBar = (datetime)StringToInteger(value);
   else if(key == "end")
      g_st.sawEnd = (int)StringToInteger(value);
  }

//+------------------------------------------------------------------+
bool IdentityMatches()
  {
   uint loginHash = Fnv32(IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)));
   uint serverHash = Fnv32(AccountInfoString(ACCOUNT_SERVER));
   return g_st.version == 1
          && g_st.sawEnd == 1
          && g_st.symbol == _Symbol
          && g_st.magic == InpMagic
          && g_st.loginHash == loginHash
          && g_st.serverHash == serverHash
          && g_st.attachBar > 0;
  }

//+------------------------------------------------------------------+
bool LoadState()
  {
   ResetRuntimeState();
   g_st.sawEnd = 0;
   if(!FileIsExist(g_file))
     {
      FreshIdentity();
      return true;
     }
   int handle = FileOpen(g_file, FILE_READ | FILE_TXT | FILE_ANSI);
   if(handle == INVALID_HANDLE)
     {
      LogBoth("状态文件打不开", "state file cannot be opened", g_file);
      return false;
     }
   while(!FileIsEnding(handle))
     {
      string line = FileReadString(handle);
      StringReplace(line, "\r", "");
      int eq = StringFind(line, "=");
      if(eq < 1)
         continue;
      ApplyKey(StringSubstr(line, 0, eq), StringSubstr(line, eq + 1));
     }
   FileClose(handle);
   if(!IdentityMatches())
     {
      LogBoth("状态文件与当前账户、品种或魔法号不一致，或文件不完整",
              "state file does not match this account, symbol or magic, or is incomplete",
              g_file);
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
int ExposureTotal()
  {
   return PositionsTotal() + OrdersTotal();
  }

//+------------------------------------------------------------------+
double AlignDown(const double price, const double tick)
  {
   if(tick <= 0 || price <= 0)
      return 0;
   return MathFloor(price / tick + 1e-9) * tick;
  }

//+------------------------------------------------------------------+
double AlignUp(const double price, const double tick)
  {
   if(tick <= 0 || price <= 0)
      return 0;
   double steps = price / tick - 1e-9;
   double whole = MathFloor(steps);
   if(MathAbs(steps - whole) > 1e-8)
      whole += 1.0;
   return whole * tick;
  }

//+------------------------------------------------------------------+
double MinStopDistance()
  {
   long stops = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freeze = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   long points = stops;
   if(freeze > points)
      points = freeze;
   if(points < 0)
      points = 0;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0)
      return 0;
   return (points + 1) * point;
  }

//+------------------------------------------------------------------+
bool BuildStops(const int direction, const double entry, const double atr,
                const double bid, const double ask, const double minDist,
                const double tick, double &sl, double &tp)
  {
   sl = 0;
   tp = 0;
   if(direction != 1 && direction != -1)
      return false;
   if(atr <= 0 || tick <= 0 || entry <= 0 || bid <= 0 || ask < bid || minDist < 0)
      return false;
   double raw = SL_MULT * atr;
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double limit = 0;
   double dist = 0;
   if(direction == 1)
     {
      sl = AlignDown(entry - raw, tick);
      limit = bid - minDist;
      if(sl > limit)
         sl = AlignDown(limit, tick);
      sl = NormalizeDouble(sl, digits);
      if(sl > entry - raw + 1e-8)
         sl = NormalizeDouble(AlignDown(sl - tick, tick), digits);
      if(sl <= 0 || sl > entry - raw + 1e-8)
         return false;
      dist = entry - sl;
      tp = AlignUp(entry + TP_R * dist, tick);
      double floorPrice = bid + minDist;
      if(tp < floorPrice)
         tp = AlignUp(floorPrice, tick);
      tp = NormalizeDouble(tp, digits);
      if(!(sl < bid && tp > entry && dist + 1e-8 >= raw))
         return false;
      return true;
     }
   sl = AlignUp(entry + raw, tick);
   limit = ask + minDist;
   if(sl < limit)
      sl = AlignUp(limit, tick);
   sl = NormalizeDouble(sl, digits);
   if(sl < entry + raw - 1e-8)
      sl = NormalizeDouble(AlignUp(sl + tick, tick), digits);
   if(sl < entry + raw - 1e-8)
      return false;
   dist = sl - entry;
   tp = AlignDown(entry - TP_R * dist, tick);
   double cap = ask - minDist;
   if(tp > cap)
      tp = AlignDown(cap, tick);
   tp = NormalizeDouble(tp, digits);
   if(!(sl > ask && tp < entry && tp > 0 && dist + 1e-8 >= raw))
      return false;
   return true;
  }

//+------------------------------------------------------------------+
bool RiskTotal(const int direction, const double entry, const double sl, double &total)
  {
   total = 0;
   if(direction != 1 && direction != -1)
      return false;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point < 0 || InpSlippagePoints < 0 || InpCommissionBuffer < 0)
      return false;
   ENUM_ORDER_TYPE kind = (direction == 1 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   double base = 0;
   if(!OrderCalcProfit(kind, _Symbol, LOT, entry, sl, base))
      return false;
   double slip = InpSlippagePoints * point;
   double worse = (direction == 1 ? sl - slip : sl + slip);
   double worseProfit = 0;
   if(!OrderCalcProfit(kind, _Symbol, LOT, entry, worse, worseProfit))
      return false;
   double stopLoss = -base;
   double extra = (-worseProfit) - stopLoss;
   if(extra < 0)
      extra = 0;
   total = stopLoss + InpCommissionBuffer + extra;
   return true;
  }

//+------------------------------------------------------------------+
double SymbolOpenVolume()
  {
   double volume = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol)
         volume += PositionGetDouble(POSITION_VOLUME);
     }
   for(int j = OrdersTotal() - 1; j >= 0; j--)
     {
      ulong ticket = OrderGetTicket(j);
      if(ticket == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) == _Symbol)
         volume += OrderGetDouble(ORDER_VOLUME_CURRENT);
     }
   return volume;
  }

//+------------------------------------------------------------------+
bool LotAllowed(string &why)
  {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double limit = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_LIMIT);
   if(step <= 0 || vmin <= 0)
     {
      why = "手数步长或最小手数无效";
      return false;
     }
   if(LOT + 1e-12 < vmin || (vmax > 0 && LOT > vmax + 1e-12))
     {
      why = "0.10 手不在经纪商允许的手数范围内";
      return false;
     }
   double steps = LOT / step;
   if(MathAbs(steps - MathRound(steps)) > 1e-6)
     {
      why = "0.10 手不是手数步长的整数倍";
      return false;
     }
   if(limit > 0 && SymbolOpenVolume() + LOT > limit + 1e-12)
     {
      why = "加上这一手会超过品种持仓量上限";
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
bool SpreadOk(const double bid, const double ask)
  {
   if(InpMaxSpreadPrice <= 0 || bid <= 0 || ask < bid)
      return false;
   return (ask - bid) <= InpMaxSpreadPrice + 1e-9;
  }

//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING FillingMode()
  {
   int mode = (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((mode & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      return ORDER_FILLING_FOK;
   if((mode & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
  }

//+------------------------------------------------------------------+
bool GatesOpen(string &why)
  {
   if(!IsTester())
     {
      if(!TerminalInfoInteger(TERMINAL_CONNECTED))
        {
         why = "终端未连接";
         return false;
        }
      MqlTick tk;
      if(!SymbolInfoTick(_Symbol, tk) || (tk.time > 0 && TimeCurrent() - tk.time > 180))
        {
         why = "报价过旧";
         return false;
        }
     }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
     {
      why = "自动交易没有打开";
      return false;
     }
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
     {
      why = "账户不允许交易";
      return false;
     }
   long tradeMode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(tradeMode != SYMBOL_TRADE_MODE_FULL)
     {
      why = "品种当前不能开新仓";
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
string PosId(const ulong identifier)
  {
   return StringFormat("%I64u", identifier);
  }

//+------------------------------------------------------------------+
bool IsFreshComment(const long magic, const string symbol, const string comment)
  {
   return g_st.inflight == 1
          && magic == g_st.magic
          && symbol == _Symbol
          && g_st.pendingComment != ""
          && comment == g_st.pendingComment;
  }

//+------------------------------------------------------------------+
bool IsVerifiedPosition(const string id, const long magic, const string symbol, const string comment)
  {
   if(g_st.inflight != 0 || g_st.ownPosId == "")
      return false;
   if(id != g_st.ownPosId || magic != g_st.magic || symbol != _Symbol)
      return false;
   return (StringFind(comment, Prefix()) == 0);
  }

//+------------------------------------------------------------------+
bool IsVerifiedOrder(const ulong ticket, const long magic, const string symbol, const string comment)
  {
   if(g_st.inflight != 0 || g_st.ownOrder == 0)
      return false;
   if(ticket != g_st.ownOrder || magic != g_st.magic || symbol != _Symbol)
      return false;
   return (StringFind(comment, Prefix()) == 0);
  }

//+------------------------------------------------------------------+
int ScanStartup(int &foreign, int &verifiedPos, int &freshPos, int &verifiedOrd, int &freshOrd,
                ulong &freshPosTicket, string &freshPosId, ulong &freshOrdTicket)
  {
   foreign = 0;
   verifiedPos = 0;
   freshPos = 0;
   verifiedOrd = 0;
   freshOrd = 0;
   freshPosTicket = 0;
   freshPosId = "";
   freshOrdTicket = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      string id = PosId((ulong)PositionGetInteger(POSITION_IDENTIFIER));
      long magic = PositionGetInteger(POSITION_MAGIC);
      string symbol = PositionGetString(POSITION_SYMBOL);
      string comment = PositionGetString(POSITION_COMMENT);
      if(IsFreshComment(magic, symbol, comment))
        {
         freshPos++;
         freshPosTicket = ticket;
         freshPosId = id;
        }
      else if(IsVerifiedPosition(id, magic, symbol, comment))
         verifiedPos++;
      else
         foreign++;
     }
   for(int j = OrdersTotal() - 1; j >= 0; j--)
     {
      ulong ticket = OrderGetTicket(j);
      if(ticket == 0)
         continue;
      long magic = OrderGetInteger(ORDER_MAGIC);
      string symbol = OrderGetString(ORDER_SYMBOL);
      string comment = OrderGetString(ORDER_COMMENT);
      if(IsFreshComment(magic, symbol, comment))
        {
         freshOrd++;
         freshOrdTicket = ticket;
        }
      else if(IsVerifiedOrder(ticket, magic, symbol, comment))
         verifiedOrd++;
      else
         foreign++;
     }
   return foreign + verifiedPos + freshPos + verifiedOrd + freshOrd;
  }

//+------------------------------------------------------------------+
bool FindPositionById(const string id, ulong &ticket)
  {
   ticket = 0;
   if(id == "")
      return false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong current = PositionGetTicket(i);
      if(current == 0)
         continue;
      string found = PosId((ulong)PositionGetInteger(POSITION_IDENTIFIER));
      if(found == id)
        {
         ticket = current;
         return true;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
bool SelectOrderSafe(const ulong ticket)
  {
   if(ticket == 0 || !OrderSelect(ticket))
      return false;
   return OrderGetString(ORDER_SYMBOL) == _Symbol
          && OrderGetInteger(ORDER_MAGIC) == g_st.magic
          && StringFind(OrderGetString(ORDER_COMMENT), Prefix()) == 0;
  }

//+------------------------------------------------------------------+
bool FindManagedPosition(ulong &ticket, string &id)
  {
   ticket = 0;
   id = "";
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong current = PositionGetTicket(i);
      if(current == 0)
         continue;
      string found = PosId((ulong)PositionGetInteger(POSITION_IDENTIFIER));
      long magic = PositionGetInteger(POSITION_MAGIC);
      string symbol = PositionGetString(POSITION_SYMBOL);
      string comment = PositionGetString(POSITION_COMMENT);
      bool fresh = IsFreshComment(magic, symbol, comment);
      bool verified = IsVerifiedPosition(found, magic, symbol, comment);
      bool flatten = (g_st.needFlattenId != "" && found == g_st.needFlattenId
                      && magic == g_st.magic && symbol == _Symbol
                      && StringFind(comment, Prefix()) == 0);
      if(fresh || verified || flatten)
        {
         ticket = current;
         id = found;
         return true;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
ulong FindManagedOrder()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      long magic = OrderGetInteger(ORDER_MAGIC);
      string symbol = OrderGetString(ORDER_SYMBOL);
      string comment = OrderGetString(ORDER_COMMENT);
      if(IsFreshComment(magic, symbol, comment) || IsVerifiedOrder(ticket, magic, symbol, comment))
         return ticket;
     }
   return 0;
  }

//+------------------------------------------------------------------+
bool ForeignPresent()
  {
   int foreign, verifiedPos, freshPos, verifiedOrd, freshOrd;
   ulong freshPosTicket, freshOrdTicket;
   string freshPosId;
   ScanStartup(foreign, verifiedPos, freshPos, verifiedOrd, freshOrd,
               freshPosTicket, freshPosId, freshOrdTicket);
   return foreign > 0;
  }

//+------------------------------------------------------------------+
bool ManagedExposure()
  {
   ulong ticket;
   string id;
   if(FindManagedPosition(ticket, id))
      return true;
   if(FindManagedOrder() != 0)
      return true;
   return g_st.inflight == 1;
  }

//+------------------------------------------------------------------+
bool SendTrade(MqlTradeRequest &request, MqlTradeResult &result)
  {
   return OrderSend(request, result);
  }

//+------------------------------------------------------------------+
bool CancelManaged(const ulong ticket)
  {
   if(!SelectOrderSafe(ticket))
     {
      LogBoth("撤销前核对失败，没有撤这个单", "cancel check failed, order left untouched", "");
      return false;
     }
   MqlTradeRequest request;
   MqlTradeResult result;
   ZeroMemory(request);
   ZeroMemory(result);
   request.action = TRADE_ACTION_REMOVE;
   request.order = ticket;
   request.symbol = _Symbol;
   request.magic = (ulong)g_st.magic;
   bool sent = SendTrade(request, result);
   LogBoth("尝试撤销本策略挂单", "attempt to cancel own pending order",
           StringFormat("ticket=%I64u sent=%d rc=%u", ticket, sent ? 1 : 0, result.retcode));
   return sent && (result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED);
  }

//+------------------------------------------------------------------+
bool CloseManaged(const ulong ticket)
  {
   if(!PositionSelectByTicket(ticket))
      return false;
   string id = PosId((ulong)PositionGetInteger(POSITION_IDENTIFIER));
   long magic = PositionGetInteger(POSITION_MAGIC);
   string symbol = PositionGetString(POSITION_SYMBOL);
   string comment = PositionGetString(POSITION_COMMENT);
   bool prefixOk = (StringFind(comment, Prefix()) == 0 || comment == "R300flat");
   bool allowed = (id == g_st.needFlattenId && magic == g_st.magic && symbol == _Symbol && prefixOk);
   if(!allowed)
     {
      LogBoth("平仓核对失败，没有平任何单", "close check failed, nothing was closed", "");
      return false;
     }
   long type = PositionGetInteger(POSITION_TYPE);
   double volume = PositionGetDouble(POSITION_VOLUME);
   if(volume <= 0)
      return false;
   MqlTick tk;
   if(!SymbolInfoTick(_Symbol, tk))
      return false;
   MqlTradeRequest request;
   MqlTradeResult result;
   ZeroMemory(request);
   ZeroMemory(result);
   request.action = TRADE_ACTION_DEAL;
   request.position = ticket;
   request.symbol = _Symbol;
   request.volume = volume;
   request.type = (type == POSITION_TYPE_BUY ? ORDER_TYPE_SELL : ORDER_TYPE_BUY);
   request.price = (type == POSITION_TYPE_BUY ? tk.bid : tk.ask);
   request.deviation = (ulong)MathMax(InpSlippagePoints, 0);
   request.magic = (ulong)g_st.magic;
   request.comment = "R300flat";
   request.type_filling = FillingMode();
   request.type_time = ORDER_TIME_GTC;
   bool sent = SendTrade(request, result);
   LogBoth("只平刚才确认属于本 EA 的新仓", "flatten only the confirmed fresh own position",
           StringFormat("ticket=%I64u id=%s vol=%s sent=%d rc=%u %s",
                        ticket, id, DoubleToString(volume, 2), sent ? 1 : 0, result.retcode, QuoteText()));
   return sent && (result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_DONE_PARTIAL);
  }

//+------------------------------------------------------------------+
bool ProtectionOk(const ulong ticket, string &why)
  {
   if(!PositionSelectByTicket(ticket))
     {
      why = "找不到持仓";
      return false;
     }
   string comment = PositionGetString(POSITION_COMMENT);
   if(g_st.pendingComment != "" && comment != g_st.pendingComment)
     {
      why = "持仓注释不是这次下单写下的注释";
      return false;
     }
   if(StringFind(comment, Prefix()) != 0)
     {
      why = "持仓注释前缀不匹配";
      return false;
     }
   double volume = PositionGetDouble(POSITION_VOLUME);
   if(MathAbs(volume - LOT) > 1e-8)
     {
      why = "成交手数不是 0.10";
      return false;
     }
   if(g_st.entryDir != 1 && g_st.entryDir != -1)
     {
      why = "没有记录进场方向";
      return false;
     }
   long type = PositionGetInteger(POSITION_TYPE);
   if((g_st.entryDir == 1 && type != POSITION_TYPE_BUY) ||
      (g_st.entryDir == -1 && type != POSITION_TYPE_SELL))
     {
      why = "持仓方向和信号不一致";
      return false;
     }
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl = PositionGetDouble(POSITION_SL);
   double tp = PositionGetDouble(POSITION_TP);
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick <= 0)
      tick = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(sl <= 0 || tp <= 0 || tick <= 0)
     {
      why = "止损或止盈没有挂上";
      return false;
     }
   if(g_st.entryDir == 1)
     {
      if(!(sl < openPrice && tp > openPrice))
        {
         why = "多单止损或止盈在错误的一侧";
         return false;
        }
      if(sl > g_st.intendedSl + tick)
        {
         why = "多单止损被经纪商改近了";
         return false;
        }
      if(tp < g_st.intendedTp - tick)
        {
         why = "多单止盈被改近了";
         return false;
        }
     }
   else
     {
      if(!(sl > openPrice && tp < openPrice))
        {
         why = "空单止损或止盈在错误的一侧";
         return false;
        }
      if(sl < g_st.intendedSl - tick)
        {
         why = "空单止损被经纪商改近了";
         return false;
        }
      if(tp > g_st.intendedTp + tick)
        {
         why = "空单止盈被改近了";
         return false;
        }
     }
   double distance = MathAbs(openPrice - sl);
   if(g_st.signalAtr <= 0 || distance + tick < SL_MULT * g_st.signalAtr)
     {
      why = "实际止损距离小于 1.5 倍 ATR";
      return false;
     }
   double total = 0;
   if(!RiskTotal(g_st.entryDir, openPrice, sl, total) || total > RISK_CAP + 1e-6)
     {
      why = "按实际成交价重算后的风险超过 300 美元";
      return false;
     }
   g_risk = total;
   return true;
  }

//+------------------------------------------------------------------+
void MarkProtectionFailure(const ulong ticket, const string id, const string why)
  {
   g_st.ownPosId = id;
   RememberId(id);
   g_st.needFlattenId = id;
   g_st.protHalt = 1;
   g_st.freshCheck = 1;
   SaveState();
   LogBoth("保护不合格，停止以后开新仓，并只平这一笔新仓：" + why,
           "protection invalid, halt new entries and flatten only this fresh position: " + why,
           StringFormat("id=%s risk=%s %s", id, DoubleToString(g_risk, 2), QuoteText()));
   CloseManaged(ticket);
  }

//+------------------------------------------------------------------+
void AcceptPosition(const ulong ticket, const string id)
  {
   g_st.ownPosId = id;
   RememberId(id);
   g_st.inflight = 0;
   g_st.freshCheck = 0;
   g_st.needFlattenId = "";
   g_st.ownOrder = 0;
   SaveState();
   LogBoth("新仓保护核对通过，之后不修改它的止损和止盈",
           "fresh position protection accepted, SL and TP will not be modified",
           StringFormat("ticket=%I64u id=%s risk=%s %s", ticket, id, DoubleToString(g_risk, 2), QuoteText()));
  }

//+------------------------------------------------------------------+
void Reconcile()
  {
   if(g_st.needFlattenId != "")
     {
      ulong ticket;
      if(!FindPositionById(g_st.needFlattenId, ticket))
        {
         g_st.needFlattenId = "";
         g_st.freshCheck = 0;
         g_st.inflight = 0;
         SaveState();
         return;
        }
      CloseManaged(ticket);
      return;
     }
   ulong posTicket;
   string posId;
   bool hasPos = FindManagedPosition(posTicket, posId);
   ulong orderTicket = FindManagedOrder();
   if(hasPos && g_st.inflight == 1)
     {
      if(orderTicket != 0)
         CancelManaged(orderTicket);
      string why;
      if(ProtectionOk(posTicket, why))
         AcceptPosition(posTicket, posId);
      else
         MarkProtectionFailure(posTicket, posId, why);
      return;
     }
   if(hasPos)
     {
      if(g_st.ownPosId != posId)
        {
         g_st.ownPosId = posId;
         RememberId(posId);
         SaveState();
        }
      return;
     }
   if(g_st.inflight == 1 && orderTicket != 0)
     {
      datetime bar = iTime(_Symbol, PERIOD_H1, 0);
      if(g_st.entryBar > 0 && bar > g_st.entryBar && g_st.cancelBar != bar)
        {
         g_st.cancelBar = bar;
         SaveState();
         if(CancelManaged(orderTicket) && FindManagedOrder() == 0 && !FindManagedPosition(posTicket, posId))
           {
            g_st.inflight = 0;
            g_st.freshCheck = 0;
            g_st.ownOrder = 0;
            SaveState();
            LogBoth("进场那根 K 线已经走完，未成交的本策略挂单已撤销",
                    "entry bar ended, own unfilled pending order was cancelled",
                    QuoteText());
           }
        }
      return;
     }
   if(g_st.inflight == 1)
     {
      datetime bar = iTime(_Symbol, PERIOD_H1, 0);
      if(g_st.entryBar > 0 && bar > g_st.entryBar)
        {
         g_st.protHalt = 1;
         g_st.inflight = 0;
         g_st.freshCheck = 0;
         g_st.ownOrder = 0;
         SaveState();
         LogBoth("在途下单没有找到持仓或挂单，已永久停止开新仓，没有补发",
                 "in-flight order disappeared, new entries halted permanently, no resend",
                 QuoteText());
        }
     }
  }

//+------------------------------------------------------------------+
double DealMoney(const ulong deal)
  {
   return HistoryDealGetDouble(deal, DEAL_PROFIT)
          + HistoryDealGetDouble(deal, DEAL_SWAP)
          + HistoryDealGetDouble(deal, DEAL_COMMISSION)
          + HistoryDealGetDouble(deal, DEAL_FEE);
  }

//+------------------------------------------------------------------+
bool NetForPosition(const string id, double &net)
  {
   net = 0;
   datetime start = g_st.attachBar - 86400;
   if(start < 0)
      start = 0;
   if(!HistorySelect(start, ServerNow() + 60))
      return false;
   bool found = false;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0)
         continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol)
         continue;
      string dealId = PosId((ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID));
      if(dealId != id)
         continue;
      net += DealMoney(deal);
      found = true;
     }
   return found;
  }

//+------------------------------------------------------------------+
void ApplyCloseResult(const double net, const bool known)
  {
   double used = net;
   if(!known)
      used = -1;
   if(used < 0)
     {
      g_st.streak++;
      if(g_st.streak >= STREAK_CAP)
         g_st.streakHalt = 1;
     }
   else if(used > 0 && g_st.streakHalt == 0)
      g_st.streak = 0;
  }

//+------------------------------------------------------------------+
void ObserveClose()
  {
   string id = g_st.ownPosId;
   if(id == "" && g_st.needFlattenId != "")
      id = g_st.needFlattenId;
   if(id == "")
      return;
   ulong ticket;
   if(FindPositionById(id, ticket))
      return;
   if(FindManagedOrder() != 0)
      return;
   if(g_st.inflight == 1 && g_st.ownPosId == "")
      return;
   if(!ListHas(g_st.completedIds, id))
     {
      double net = 0;
      bool known = NetForPosition(id, net);
      ApplyCloseResult(net, known);
      g_st.completedIds = ListAppend(g_st.completedIds, id);
      RememberId(id);
      LogBoth(known ? "本策略持仓已结束，按成交盈亏、手续费、库存费和费用入账"
                    : "本策略持仓已结束，但读不到盈亏，保守地记成一笔亏损",
              known ? "own position closed, booked profit plus commission swap and fee"
                    : "own position closed, history missing, counted as a loss",
              StringFormat("id=%s net=%s streak=%d halt=%d",
                           id, DoubleToString(known ? net : -1, 2), g_st.streak, g_st.streakHalt));
     }
   g_st.ownPosId = "";
   g_st.needFlattenId = "";
   g_st.freshCheck = 0;
   g_st.inflight = 0;
   g_st.ownOrder = 0;
   SaveState();
  }

//+------------------------------------------------------------------+
double DailyRealized()
  {
   datetime now = ServerNow();
   int today = Ymd(now);
   datetime start = DayStart(now);
   if(!HistorySelect(start, now + 60))
     {
      g_historyBlocked = true;
      return 0;
     }
   g_historyBlocked = false;
   double sum = 0;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0)
         continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol)
         continue;
      string id = PosId((ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID));
      if(!ListHas(g_st.knownIds, id) && id != g_st.ownPosId)
         continue;
      datetime when = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
      if(when < start || Ymd(when) != today)
         continue;
      sum += DealMoney(deal);
     }
   return sum;
  }

//+------------------------------------------------------------------+
double FloatingPnl()
  {
   if(g_st.ownPosId == "")
      return 0;
   ulong ticket;
   if(!FindPositionById(g_st.ownPosId, ticket))
      return 0;
   if(!PositionSelectByTicket(ticket))
      return 0;
   if(PositionGetString(POSITION_SYMBOL) != _Symbol)
      return 0;
   if(PositionGetInteger(POSITION_MAGIC) != g_st.magic)
      return 0;
   return PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
  }

//+------------------------------------------------------------------+
bool PositionNetAndCloseTime(const string id, double &net, datetime &closeTime)
  {
   net = 0;
   closeTime = 0;
   bool found = false;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0)
         continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol)
         continue;
      if(PosId((ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID)) != id)
         continue;
      net += DealMoney(deal);
      datetime when = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
      if(when >= closeTime)
         closeTime = when;
      found = true;
     }
   return found && closeTime > 0;
  }

//+------------------------------------------------------------------+
bool ReplayTodayStreak()
  {
   int today = Ymd(ServerNow());
   datetime from = g_st.attachBar - 86400;
   if(from < 0)
      from = 0;
   if(!HistorySelect(from, ServerNow() + 60))
      return false;
   string parts[];
   int count = 0;
   if(StringLen(g_st.completedIds) > 0)
      count = StringSplit(g_st.completedIds, (ushort)';', parts);
   string ids[];
   datetime times[];
   double nets[];
   ArrayResize(ids, count + 1);
   ArrayResize(times, count + 1);
   ArrayResize(nets, count + 1);
   int n = 0;
   for(int i = 0; i < count; i++)
     {
      if(parts[i] == "")
         continue;
      double net = 0;
      datetime closeTime = 0;
      if(!PositionNetAndCloseTime(parts[i], net, closeTime))
         continue;
      if(Ymd(closeTime) != today)
         continue;
      ids[n] = parts[i];
      times[n] = closeTime;
      nets[n] = net;
      n++;
     }
   for(int a = 1; a < n; a++)
     {
      datetime stamp = times[a];
      double value = nets[a];
      string id = ids[a];
      int b = a;
      while(b > 0 && times[b - 1] > stamp)
        {
         times[b] = times[b - 1];
         nets[b] = nets[b - 1];
         ids[b] = ids[b - 1];
         b--;
        }
      times[b] = stamp;
      nets[b] = value;
      ids[b] = id;
     }
   int streak = 0;
   int halt = 0;
   for(int k = 0; k < n; k++)
     {
      if(nets[k] < 0)
        {
         streak++;
         if(streak >= STREAK_CAP)
            halt = 1;
        }
      else if(nets[k] > 0 && halt == 0)
         streak = 0;
     }
   g_st.streak = streak;
   g_st.streakHalt = halt;
   return true;
  }

//+------------------------------------------------------------------+
void RefreshDay()
  {
   int today = Ymd(ServerNow());
   int streakAtStart = g_st.streak;
   int haltAtStart = g_st.streakHalt;
   int dailyAtStart = g_st.dailyHalt;
   int savedStreakHalt = 0;
   int savedDailyHalt = 0;
   if(g_st.dailyYmd == today)
     {
      savedStreakHalt = g_st.streakHalt;
      savedDailyHalt = g_st.dailyHalt;
     }
   if(g_st.dailyYmd == 0)
      g_st.dailyYmd = today;
   if(today != g_st.dailyYmd)
     {
      g_st.dailyYmd = today;
      g_st.dailyHalt = 0;
      g_st.streak = 0;
      g_st.streakHalt = 0;
      savedStreakHalt = 0;
      savedDailyHalt = 0;
      SaveState();
      LogBoth("服务器日期已切换。当日500美元暂停和当天连亏3笔暂停都已解除，当日连亏计数归零。保护性停止不解除",
              "server day changed. Daily 500 USD pause and same-day 3-loss pause are cleared, today's streak is reset. Protection halt stays",
              StringFormat("day=%d protHalt=%d", today, g_st.protHalt));
     }
   int haltBefore = g_st.streakHalt;
   if(ReplayTodayStreak())
     {
      if(savedStreakHalt)
         g_st.streakHalt = 1;
     }
   if(savedDailyHalt)
      g_st.dailyHalt = 1;
   if(g_st.streak != streakAtStart || g_st.streakHalt != haltAtStart || g_st.dailyHalt != dailyAtStart)
      SaveState();
   if(g_st.streakHalt && !haltBefore)
      LogBoth("当天连续3笔亏损，今天不再开新仓。下一个服务器日期解除并清零当日连亏计数。已有仓位不平",
              "three losing closes today, no new entries today. Next server day clears this pause and today's streak. Open position stays",
              StringFormat("streak=%d", g_st.streak));
   double realized = DailyRealized();
   if(g_historyBlocked)
     {
      LogSkip("history", "读不到今日成交，暂停开新仓", "today's deals cannot be read, no new entry", "");
      return;
     }
   double floating = FloatingPnl();
   double adverse = realized + MathMin(0.0, floating);
   if(adverse <= -DAILY_CAP + 1e-9 && g_st.dailyHalt == 0)
     {
      g_st.dailyHalt = 1;
      SaveState();
      LogBoth("当日不利盈亏达到 500 美元，今天不再开新仓，已有仓位保留原止损止盈。这是暂停新仓的触发值，不是最大亏损保证",
              "daily adverse loss reached 500 USD, no new entries today, existing SL/TP stay. This pause trigger is not a maximum-loss guarantee",
              StringFormat("realized=%s floating=%s adverse=%s",
                           DoubleToString(realized, 2), DoubleToString(floating, 2), DoubleToString(adverse, 2)));
     }
  }

//+------------------------------------------------------------------+
int TrendOf(const double fast, const double slow)
  {
   if(fast > slow)
      return 1;
   if(fast < slow)
      return -1;
   return 0;
  }

//+------------------------------------------------------------------+
bool ReadClosed(const int shift, double &fast, double &slow, double &atr,
                double &high, double &low, double &close)
  {
   if(shift < 1)
      return false;
   if(BarsCalculated(g_fast) < shift + 1 || BarsCalculated(g_slow) < shift + 1 || BarsCalculated(g_atr) < shift + 1)
      return false;
   double fastBuf[1], slowBuf[1], atrBuf[1];
   if(CopyBuffer(g_fast, 0, shift, 1, fastBuf) != 1)
      return false;
   if(CopyBuffer(g_slow, 0, shift, 1, slowBuf) != 1)
      return false;
   if(CopyBuffer(g_atr, 0, shift, 1, atrBuf) != 1)
      return false;
   fast = fastBuf[0];
   slow = slowBuf[0];
   atr = atrBuf[0];
   high = iHigh(_Symbol, PERIOD_H1, shift);
   low = iLow(_Symbol, PERIOD_H1, shift);
   close = iClose(_Symbol, PERIOD_H1, shift);
   return (high > 0 && low > 0 && close > 0);
  }

//+------------------------------------------------------------------+
bool ExposureBlocks()
  {
   if(g_st.protHalt || g_st.streakHalt || g_st.dailyHalt)
      return true;
   if(g_st.inflight || g_st.needFlattenId != "" || g_st.ownPosId != "")
      return true;
   return ManagedExposure() || ForeignPresent();
  }

//+------------------------------------------------------------------+
void DropGap()
  {
   if(g_st.setupState != ST_IDLE)
      LogBoth("离线缺口太大，丢弃未完成形态，不回放中间信号",
              "history gap is too wide, drop the unfinished setup, do not replay",
              QuoteText());
   ClearSetup();
   g_st.setupState = ST_IDLE;
  }

//+------------------------------------------------------------------+
bool ProcessShift(const int shift, const datetime nextBar, const bool allowEntry, const bool blocked)
  {
   datetime barTime = iTime(_Symbol, PERIOD_H1, shift);
   if(barTime <= 0)
      return false;
   if(barTime < g_st.attachBar)
      return true;
   if(g_st.lastClosed > 0 && barTime <= g_st.lastClosed)
      return true;
   double fast, slow, atr, high, low, close;
   if(!ReadClosed(shift, fast, slow, atr, high, low, close))
      return false;
   if(atr <= 0 || fast <= 0 || slow <= 0)
     {
      g_st.lastClosed = barTime;
      LogBoth("这根已收盘 K 线指标无效，跳过，不建立形态",
              "closed bar indicators are unusable, skip, no setup",
              TimeToString(barTime, TIME_DATE | TIME_MINUTES));
      return true;
     }
   int trend = TrendOf(fast, slow);
   g_st.lastClosed = barTime;
   if(blocked)
     {
      if(g_st.setupState != ST_IDLE)
        {
         ClearSetup();
         g_st.setupState = ST_IDLE;
        }
      return true;
     }
   if(g_st.setupState == ST_ARMED)
     {
      g_st.age++;
      if(trend != g_st.direction)
        {
         ClearSetup();
         g_st.setupState = ST_IDLE;
         LogBoth("趋势翻转或走平，形态作废，这根 K 线不另建新形态",
                 "trend flipped or flattened, setup cancelled, this bar does not arm a new one",
                 TimeToString(barTime, TIME_DATE | TIME_MINUTES));
         return true;
        }
      if(g_st.age > InpExpiryBars)
        {
         ClearSetup();
         g_st.setupState = ST_IDLE;
         LogBoth("形态超过有效根数，作废", "setup expired", TimeToString(barTime, TIME_DATE | TIME_MINUTES));
         return true;
        }
      bool broke = (g_st.direction == 1 && close > g_st.setupHigh)
                   || (g_st.direction == -1 && close < g_st.setupLow);
      if(!broke)
         return true;
      if(!allowEntry)
        {
         ClearSetup();
         g_st.setupState = ST_IDLE;
         LogBoth("突破确认时已经错过下一根市价窗口，形态作废",
                 "breakout confirmed after its entry bar, setup cancelled",
                 TimeToString(barTime, TIME_DATE | TIME_MINUTES));
         return true;
        }
      g_st.setupState = ST_WINDOW;
      g_st.signalAtr = atr;
      g_st.entryBar = nextBar;
      LogBoth("已收盘突破确认，只允许在下一根 K 线尝试一次市价",
              "closed-bar breakout confirmed, one market attempt on the next bar only",
              StringFormat("bar=%s next=%s atr=%s",
                           TimeToString(barTime, TIME_DATE | TIME_MINUTES),
                           TimeToString(nextBar, TIME_DATE | TIME_MINUTES),
                           DoubleToString(atr, _Digits)));
      return true;
     }
   if(g_st.setupState == ST_WINDOW)
     {
      ClearSetup();
      g_st.setupState = ST_IDLE;
      LogBoth("进场窗口被下一根收盘带走，形态作废",
              "entry window expired on the following close",
              TimeToString(barTime, TIME_DATE | TIME_MINUTES));
      return true;
     }
   if(trend == 1 && low <= fast && close > slow)
     {
      g_st.setupState = ST_ARMED;
      g_st.direction = 1;
      g_st.setupBar = barTime;
      g_st.setupHigh = high;
      g_st.setupLow = low;
      g_st.age = 0;
      g_st.signalAtr = 0;
      g_st.entryBar = 0;
      LogBoth("多头回踩形态成立，等待之后的收盘突破",
              "buy pullback setup armed, waiting for a later closing breakout",
              TimeToString(barTime, TIME_DATE | TIME_MINUTES));
      return true;
     }
   if(trend == -1 && high >= fast && close < slow)
     {
      g_st.setupState = ST_ARMED;
      g_st.direction = -1;
      g_st.setupBar = barTime;
      g_st.setupHigh = high;
      g_st.setupLow = low;
      g_st.age = 0;
      g_st.signalAtr = 0;
      g_st.entryBar = 0;
      LogBoth("空头回踩形态成立，等待之后的收盘突破",
              "sell pullback setup armed, waiting for a later closing breakout",
              TimeToString(barTime, TIME_DATE | TIME_MINUTES));
     }
   return true;
  }

//+------------------------------------------------------------------+
void CatchUp()
  {
   datetime closed = iTime(_Symbol, PERIOD_H1, 1);
   if(closed <= 0)
      return;
   if(g_st.lastClosed <= 0)
     {
      g_st.lastClosed = closed;
      SaveState();
      LogBoth("没有可靠的已处理水位，从最新已收盘 K 线之后才开始，不回放旧信号",
              "no reliable watermark, start after the latest closed bar, no historical replay",
              TimeToString(closed, TIME_DATE | TIME_MINUTES));
      return;
     }
   if(closed <= g_st.lastClosed)
      return;
   int shiftLast = iBarShift(_Symbol, PERIOD_H1, g_st.lastClosed, true);
   if(shiftLast < 0 || shiftLast - 1 > MAX_CATCHUP)
     {
      DropGap();
      g_st.lastClosed = closed;
      SaveState();
      return;
     }
   bool blocked = ExposureBlocks();
   datetime before = g_st.lastClosed;
   int stateBefore = g_st.setupState;
   bool stuck = false;
   for(int shift = shiftLast - 1; shift >= 1; shift--)
     {
      datetime nextBar = iTime(_Symbol, PERIOD_H1, shift - 1);
      bool allow = (shift == 1);
      if(!ProcessShift(shift, nextBar, allow, blocked))
        {
         stuck = true;
         break;
        }
      blocked = ExposureBlocks();
     }
   if(stuck)
      LogSkip("bars", "收盘 K 线的指标还没准备好，先不推进", "closed-bar indicators are not ready", "");
   if(g_st.lastClosed != before || g_st.setupState != stateBefore)
      SaveState();
  }

//+------------------------------------------------------------------+
void AbandonWindow(const string zh, const string en)
  {
   datetime bar = iTime(_Symbol, PERIOD_H1, 0);
   g_st.consumedBar = bar;
   ClearSetup();
   g_st.setupState = ST_IDLE;
   SaveState();
   LogBoth(zh, en, QuoteText());
  }

//+------------------------------------------------------------------+
bool PrepareOrder(string &why)
  {
   why = "";
   g_risk = 0;
   g_sl = 0;
   g_tp = 0;
   if(!GatesOpen(why))
      return false;
   if(!LotAllowed(why))
      return false;
   MqlTick tk;
   if(!SymbolInfoTick(_Symbol, tk) || tk.bid <= 0 || tk.ask < tk.bid)
     {
      why = "没有有效报价";
      return false;
     }
   if(!SpreadOk(tk.bid, tk.ask))
     {
      why = "点差超过上限，放弃这个形态";
      return false;
     }
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick <= 0)
      tick = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double entry = (g_st.direction == 1 ? tk.ask : tk.bid);
   double sl, tp;
   if(!BuildStops(g_st.direction, entry, g_st.signalAtr, tk.bid, tk.ask, MinStopDistance(), tick, sl, tp))
     {
      why = "止损无法在不缩小距离的前提下满足经纪商限制";
      return false;
     }
   double margin = 0;
   ENUM_ORDER_TYPE kind = (g_st.direction == 1 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   if(!OrderCalcMargin(kind, _Symbol, LOT, entry, margin))
     {
      why = "算不出保证金";
      return false;
     }
   double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(margin <= 0 || free < margin * 2.0)
     {
      why = "可用保证金不足预估保证金的两倍";
      return false;
     }
   double total = 0;
   if(!RiskTotal(g_st.direction, entry, sl, total))
     {
      why = "OrderCalcProfit 失败，跳过";
      return false;
     }
   if(total > RISK_CAP + 1e-9)
     {
      why = "计划风险含缓冲超过 300 美元，跳过";
      g_risk = total;
      g_sl = sl;
      g_tp = tp;
      return false;
     }
   string comment = MakeComment(g_st.magic, g_st.setupBar);
   if(StringLen(comment) > COMMENT_MAX || StringLen(comment) < 8)
     {
      why = "订单注释长度不合法";
      return false;
     }
   g_bid = tk.bid;
   g_ask = tk.ask;
   g_sl = sl;
   g_tp = tp;
   g_risk = total;
   return true;
  }

//+------------------------------------------------------------------+
void SendEntry()
  {
   string comment = MakeComment(g_st.magic, g_st.setupBar);
   g_st.consumedBar = iTime(_Symbol, PERIOD_H1, 0);
   g_st.inflight = 1;
   g_st.freshCheck = 1;
   g_st.pendingComment = comment;
   g_st.entryDir = g_st.direction;
   g_st.intendedSl = g_sl;
   g_st.intendedTp = g_tp;
   g_st.ownOrder = 0;
   g_st.setupState = ST_IDLE;
   if(!SaveState())
     {
      g_st.inflight = 0;
      g_st.freshCheck = 0;
      g_st.pendingComment = "";
      LogBoth("下单前没能保存状态，这笔没有发送", "state was not saved, order was not sent", QuoteText());
      return;
     }
   MqlTradeRequest request;
   MqlTradeResult result;
   ZeroMemory(request);
   ZeroMemory(result);
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = LOT;
   request.type = (g_st.entryDir == 1 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   request.price = (g_st.entryDir == 1 ? g_ask : g_bid);
   request.sl = g_st.intendedSl;
   request.tp = g_st.intendedTp;
   request.deviation = (ulong)MathMax(InpSlippagePoints, 0);
   request.magic = (ulong)g_st.magic;
   request.comment = comment;
   request.type_filling = FillingMode();
   request.type_time = ORDER_TIME_GTC;
   bool sent = SendTrade(request, result);
   LogBoth("发送一次市价单", "send one market order",
           StringFormat("dir=%d vol=%s price=%s sl=%s tp=%s risk=%s sent=%d rc=%u %s",
                        g_st.entryDir, DoubleToString(LOT, 2),
                        DoubleToString(request.price, _Digits),
                        DoubleToString(request.sl, _Digits),
                        DoubleToString(request.tp, _Digits),
                        DoubleToString(g_risk, 2),
                        sent ? 1 : 0, result.retcode, QuoteText()));
   bool accepted = sent && (result.retcode == TRADE_RETCODE_DONE
                            || result.retcode == TRADE_RETCODE_PLACED
                            || result.retcode == TRADE_RETCODE_DONE_PARTIAL);
   if(!accepted)
     {
      ulong ticket;
      string id;
      if(FindManagedPosition(ticket, id) || FindManagedOrder() != 0)
        {
         if(result.order != 0)
            g_st.ownOrder = result.order;
         SaveState();
         Reconcile();
         return;
        }
      g_st.inflight = 0;
      g_st.freshCheck = 0;
      g_st.pendingComment = "";
      g_st.ownOrder = 0;
      SaveState();
      LogBoth("下单被拒绝，不重试，这个形态已经用掉",
              "order rejected, no retry, this setup is spent",
              StringFormat("rc=%u", result.retcode));
      return;
     }
   g_st.ownOrder = result.order;
   SaveState();
   Reconcile();
  }

//+------------------------------------------------------------------+
void TrySend()
  {
   if(g_st.setupState != ST_WINDOW)
      return;
   datetime bar = iTime(_Symbol, PERIOD_H1, 0);
   if(bar <= 0 || g_st.entryBar != bar)
     {
      AbandonWindow("当前不是允许进场的那根 K 线", "current bar is not the entry bar");
      return;
     }
   if(ServerNow() - bar > 120)
     {
      AbandonWindow("进场 K 线已经开始超过 2 分钟，放弃，避免半路追价",
                    "entry bar has been open for more than 2 minutes, skip the late chase");
      return;
     }
   if(g_st.consumedBar == bar || g_st.inflight == 1)
      return;
   if(!g_saveOk)
     {
      AbandonWindow("状态文件不可用，放弃进场", "state file unavailable, entry abandoned");
      return;
     }
   if(g_st.protHalt)
     {
      AbandonWindow("保护性停止仍然有效，不开新仓", "protection halt is active, no new entry");
      return;
     }
   if(g_st.streakHalt)
     {
      AbandonWindow("当天已有3笔连续亏损，今天不再开新仓", "three same-day losing closes, no new entry today");
      return;
     }
   if(g_st.dailyHalt || g_historyBlocked)
     {
      AbandonWindow("当日亏损停止或今日成交读不到，不开新仓",
                    "daily halt or unreadable deals, no new entry");
      return;
     }
   if(ForeignPresent() || ManagedExposure() || g_st.ownPosId != "" || g_st.needFlattenId != "")
     {
      AbandonWindow("已有本策略敞口或账户里有其他单，不开新仓",
                    "own exposure or foreign exposure exists, no new entry");
      return;
     }
   string why;
   if(!PrepareOrder(why))
     {
      string detail = QuoteText();
      if(g_risk > 0)
         detail += StringFormat(" risk=%s sl=%s tp=%s",
                                DoubleToString(g_risk, 2),
                                DoubleToString(g_sl, _Digits),
                                DoubleToString(g_tp, _Digits));
      g_st.consumedBar = bar;
      ClearSetup();
      g_st.setupState = ST_IDLE;
      SaveState();
      LogBoth("跳过：" + why, "skip: " + why, detail);
      return;
     }
   SendEntry();
  }

//+------------------------------------------------------------------+
bool ChartStillThere(const long chartId)
  {
   if(chartId <= 0)
      return false;
   return ChartPeriod(chartId) != 0;
  }

//+------------------------------------------------------------------+
bool ResolveStartup()
  {
   if(g_st.chartId != 0 && g_st.chartId != ChartID() && ChartStillThere(g_st.chartId))
     {
      LogBoth("另一个图表正在使用这个状态，拒绝启动",
              "another chart owns this state, refuse start",
              "");
      return false;
     }
   g_st.chartId = ChartID();
   int foreign, verifiedPos, freshPos, verifiedOrd, freshOrd;
   ulong freshPosTicket, freshOrdTicket;
   string freshPosId;
   ScanStartup(foreign, verifiedPos, freshPos, verifiedOrd, freshOrd,
               freshPosTicket, freshPosId, freshOrdTicket);
   int ownUnits = verifiedPos + freshPos + verifiedOrd + freshOrd;
   if(foreign > 0 || ownUnits > 1)
     {
      LogBoth("拒绝启动：模拟账户不是空的，或者有无法唯一确认的持仓/挂单。不会修改、也不会平掉它们",
              "refuse start: demo account is not empty, or exposure is ambiguous. Nothing will be modified or closed",
              StringFormat("foreign=%d verifiedPos=%d freshPos=%d verifiedOrd=%d freshOrd=%d",
                           foreign, verifiedPos, freshPos, verifiedOrd, freshOrd));
      return false;
     }
   if(verifiedPos == 1)
     {
      ulong ticket;
      if(FindPositionById(g_st.ownPosId, ticket) && PositionSelectByTicket(ticket))
        {
         double sl = PositionGetDouble(POSITION_SL);
         double tp = PositionGetDouble(POSITION_TP);
         if(sl <= 0 || tp <= 0)
           {
            g_st.protHalt = 1;
            LogBoth("已记录的本策略持仓缺少止损或止盈。停止开新仓，但不会代为平掉它",
                    "recorded own position has no SL or TP. New entries halted, position is not closed by the EA",
                    "id=" + g_st.ownPosId);
           }
        }
      g_st.freshCheck = 0;
      g_st.inflight = 0;
      LogBoth("重新挂上：只认已记录的那一笔本策略持仓，不改它的止损止盈",
              "reattach: adopt the recorded own position, do not change its SL/TP",
              "id=" + g_st.ownPosId);
      return SaveState();
     }
   if(freshPos == 1 || freshOrd == 1)
     {
      LogBoth("发现上次未完成的本策略下单，先核对，不另开新单",
              "found an unfinished own order from last run, reconcile it, do not send another",
              "");
      Reconcile();
      return true;
     }
   if(g_st.inflight == 1)
     {
      g_st.protHalt = 1;
      g_st.inflight = 0;
      g_st.freshCheck = 0;
      SaveState();
      LogBoth("状态显示有在途下单，但账户里没有对应持仓或挂单。已永久停止开新仓，没有补发",
              "state says an order was in flight, but nothing is on the account. New entries halted, no resend",
              "");
      return true;
     }
   if(ownUnits == 0 && foreign == 0)
      return true;
   LogBoth("拒绝启动：账户状态无法安全判断", "refuse start: account state is not safe to judge", "");
   return false;
  }

//+------------------------------------------------------------------+
void ReleaseIndicators()
  {
   if(g_fast != INVALID_HANDLE)
     {
      IndicatorRelease(g_fast);
      g_fast = INVALID_HANDLE;
     }
   if(g_slow != INVALID_HANDLE)
     {
      IndicatorRelease(g_slow);
      g_slow = INVALID_HANDLE;
     }
   if(g_atr != INVALID_HANDLE)
     {
      IndicatorRelease(g_atr);
      g_atr = INVALID_HANDLE;
     }
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   g_ready = false;
   g_fast = INVALID_HANDLE;
   g_slow = INVALID_HANDLE;
   g_atr = INVALID_HANDLE;
   if(!MQLInfoInteger(MQL_TESTER))
     {
      LogBoth("拒绝启动：R300D500L3Lot010 只能在策略测试器运行。真实图表和模拟图表都不允许，没有开关可以放开",
              "refuse start: R300D500L3Lot010 runs only in the strategy tester. Real and demo charts are blocked, no override",
              "variant=R300D500L3Lot010 riskCap=300 dailyCap=500 streakCap=3 lot=0.10");
      return INIT_FAILED;
     }
   if(MQLInfoInteger(MQL_FRAME_MODE))
     {
      Print("优化结果帧，不下单 | optimization frame, no orders");
      return INIT_SUCCEEDED;
     }
   if(InpMagic < 1 || InpMagic > 99999999)
     {
      LogBoth("魔法号必须是 1 到 99999999", "magic must be from 1 to 99999999", "");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpMaxSpreadPrice <= 0 || InpMaxSpreadPrice > 5)
     {
      LogBoth("最大点差必须大于 0 且不超过 5 美元价格", "max spread must be within (0, 5]", "");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpCommissionBuffer < 0 || InpCommissionBuffer > 10)
     {
      LogBoth("手续费缓冲必须在 0 到 10 美元之间", "commission buffer must be from 0 to 10 USD", "");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpSlippagePoints < 0 || InpSlippagePoints > 500)
     {
      LogBoth("滑点点数必须在 0 到 500 之间", "slippage points must be from 0 to 500", "");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpExpiryBars < 1 || InpExpiryBars > 48)
     {
      LogBoth("形态有效根数必须在 1 到 48 之间", "setup expiry must be from 1 to 48 bars", "");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(!IsGoldSymbol(_Symbol))
     {
      LogBoth("这个图表不是 XAUUSD。允许经纪商后缀，例如 XAUUSD.m，不能用在其他品种",
              "chart symbol is not XAUUSD. Broker suffixes such as XAUUSD.m are allowed",
              _Symbol);
      return INIT_FAILED;
     }
   if(Bars(_Symbol, PERIOD_H1) < 60 || iTime(_Symbol, PERIOD_H1, 0) <= 0)
     {
      LogBoth("H1 历史不够，拒绝启动", "not enough H1 history, refuse start", "");
      return INIT_FAILED;
     }
   if(!AccountAllowed())
      return INIT_FAILED;
   if(!SymbolSelect(_Symbol, true))
     {
      LogBoth("无法选择当前品种", "symbol cannot be selected", _Symbol);
      return INIT_FAILED;
     }
   g_fast = iMA(_Symbol, PERIOD_H1, 20, 0, MODE_EMA, PRICE_CLOSE);
   g_slow = iMA(_Symbol, PERIOD_H1, 50, 0, MODE_EMA, PRICE_CLOSE);
   g_atr = iATR(_Symbol, PERIOD_H1, 14);
   if(g_fast == INVALID_HANDLE || g_slow == INVALID_HANDLE || g_atr == INVALID_HANDLE)
     {
      LogBoth("EMA 或 ATR 创建失败", "EMA or ATR handle failed", "");
      ReleaseIndicators();
      return INIT_FAILED;
     }
   g_file = StateFileName();
   bool missing = !FileIsExist(g_file);
   if(!LoadState())
     {
      if(ExposureTotal() > 0)
        {
         LogBoth("状态不可用且账户里已有持仓或挂单，拒绝启动，不会动这些单",
                 "state is unusable and the account already has exposure, refuse start, nothing is touched",
                 "");
         ReleaseIndicators();
         return INIT_FAILED;
        }
      LogBoth("旧状态不可用，账户是空的，从当前这根 H1 重新开始，不回放更早的信号",
              "old state is unusable and the account is empty, start from the current H1 bar, no historical replay",
              "");
      FreshIdentity();
     }
   else if(missing)
      LogBoth("第一次挂上：忽略挂上之前已经收盘的 K 线",
              "first attach: bars that closed before attachment are ignored",
              g_file);
   if(!ResolveStartup())
     {
      ReleaseIndicators();
      return INIT_FAILED;
     }
   if(!SaveState())
     {
      ReleaseIndicators();
      return INIT_FAILED;
     }
   g_ready = true;
   LogBoth("初始化完成。variant=R300D500L3Lot010。固定 0.10 手，H1 EMA20/50，止损 1.5 ATR，止盈 2 倍止损距离，没有移动止损。单笔计划风险上限是 300 美元。当日不利盈亏 500 美元只暂停新仓。当天连亏 3 笔暂停，下一服务器日解除。这不是收益承诺",
           "init ok. variant=R300D500L3Lot010. Fixed 0.10 lot, H1 EMA20/50, SL 1.5 ATR, TP 2R, no trailing. Trade cap is 300 USD. Daily adverse 500 USD only pauses new entries. Three same-day losses pause until the next server day. No performance claim",
           StringFormat("variant=R300D500L3Lot010 riskCap=300 dailyCap=500 streakCap=3 lot=0.10 state=%s tester=%d spreadCap=%s commission=%s slippagePts=%d expiry=%d",
                        g_file, IsTester() ? 1 : 0,
                        DoubleToString(InpMaxSpreadPrice, 2),
                        DoubleToString(InpCommissionBuffer, 2),
                        InpSlippagePoints, InpExpiryBars));
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   ReleaseIndicators();
   g_ready = false;
   LogBoth("EA 移除。不会因为移除而平仓，已有止损止盈留在服务器上",
           "EA removed. Removal does not close positions; existing SL/TP stay on the server",
           IntegerToString(reason));
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   if(!g_ready)
      return;
   if(ForeignPresent())
      LogSkip("foreign", "账户里有本策略之外的持仓或挂单，不开新仓，也不修改它们",
              "foreign exposure is present, no new entry and no modifications",
              "");
   Reconcile();
   ObserveClose();
   RefreshDay();
   CatchUp();
   TrySend();
  }
//+------------------------------------------------------------------+
