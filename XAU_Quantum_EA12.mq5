#property copyright "XAU_Quantum_EA"
#property version   "1.2"
#property strict

// ========================= Inputs =========================
input bool   InpUseStrategy1_Breakout     = true;
input bool   InpUseStrategy2_Divergence   = true;
input bool   InpUseStrategy3_Squeeze      = true;

input ENUM_TIMEFRAMES InpSignalTF         = PERIOD_M15;
input ENUM_TIMEFRAMES InpATR_TF           = PERIOD_D1;

input string InpTradeSessionStart         = "07:00";   // GMT
input string InpTradeSessionEnd           = "16:00";   // GMT
input string InpForceFlatTime             = "17:00";   // GMT, close all

input double InpATR_Min                   = 10.0;      // D1 ATR points (broker-scale)
input double InpATR_Max                   = 60.0;

input double InpRiskPerTradePercent       = 1.0;       // % of balance
input double InpEquityMaxDDPercent        = 5.0;       // stop trading if equity drawdown exceeds this from peak
input double InpSlippagePoints            = 20;        // slippage in points

// Strategy 1: Breakout
input int    InpConsolidationBars         = 14;        // stricter (was 8)
input double InpBreakoutBufferPoints      = 50;        // above PDH / below PDL
input int    InpVolumeMA_Period           = 20;
input double InpVolumeBoostFactor         = 2.0;       // stricter (was 1.5)

// Strategy 2: Divergence + Macro
input int    InpRSIPeriod                 = 21;
input bool   InpUseMacroFilter            = false;     // enable macro filter
input string InpMacroUrl_TIPS             = "";        // e.g., http://your-vps:8080/macro/tips
input string InpMacroUrl_DXY              = "";        // optional fallback
input int    InpMacroTimeoutMs            = 1500;
input int    InpEMA_Period                = 50;        // pullback MA

// Strategy 3: Squeeze Explosion
input int    InpBB_Period                 = 20;
input double InpBB_Dev                    = 2.0;
input int    InpBBW_MA_Period             = 50;        // bandwidth average
input double InpBBW_RatioThreshold        = 0.2;       // current BW < threshold * MA(BW)
input int    InpCCI_Period                = 14;
input int    InpCCI_Confirm               = 100;       // +100/-100

// Trailing (Chandelier Exit)
input bool   InpUseChandelierExit         = true;
input ENUM_TIMEFRAMES InpTrailTF          = PERIOD_M15; // timeframe for trail calc
input int    InpChandLookback             = 22;         // highest/lowest lookback
input int    InpChandATRPeriod            = 22;         // ATR period
input double InpChandATRMult              = 3.0;        // ATR multiple
input double InpTrailActivatePts          = 0.0;        // start trailing after this profit (points). 0=immediate

// Multi-TP + Breakeven
input bool   InpUseMultiTP                = true;
input double InpTP1_RR                    = 1.0;       // TP1 at 1R
input double InpTP2_RR                    = 2.0;       // TP2 at 2R
input double InpTP1_VolumeRatio           = 0.5;       // 50% volume to TP1
input double InpTP2_VolumeRatio           = 0.5;       // 50% volume to TP2
input double InpBreakevenOffsetPts        = 0.0;       // move SL to entry + offset after TP1
input bool   InpEnforceBreakeven          = true;      // keep SL >= entry+offset (buy) or <= entry-offset (sell) once TP1 is hit

// Safety
input int    InpMaxOpenTrades             = 2;

// ========================= Globals =========================
datetime g_lastSignalBarTime = 0;
double   g_equityPeak        = 0.0;
bool     g_tradingHalted     = false;

// ========================= Helpers =========================
bool ParseTimeHMGMT(const string hhmm, int &hour, int &minute)
{
	int h = StringToInteger(StringSubstr(hhmm, 0, 2));
	int m = StringToInteger(StringSubstr(hhmm, 3, 2));
	if(h < 0 || h > 23 || m < 0 || m > 59) return false;
	hour = h; minute = m; return true;
}

datetime ToGMT(datetime server_time)
{
	return server_time; // adjust if broker != UTC
}

bool IsWithinSessionGMT(datetime now_gmt)
{
	int sh, sm, eh, em;
	if(!ParseTimeHMGMT(InpTradeSessionStart, sh, sm)) return false;
	if(!ParseTimeHMGMT(InpTradeSessionEnd,   eh, em)) return false;
	MqlDateTime t; TimeToStruct(now_gmt, t);
	int cur = t.hour*60+t.min;
	int start = sh*60+sm, end = eh*60+em;
	return (cur >= start && cur <= end);
}

bool IsForceFlatTimeGMT(datetime now_gmt)
{
	int fh, fm;
	if(!ParseTimeHMGMT(InpForceFlatTime, fh, fm)) return false;
	MqlDateTime t; TimeToStruct(now_gmt, t);
	return (t.hour == fh && t.min >= fm && t.min < fm+5);
}

double GetATR(ENUM_TIMEFRAMES tf, int period)
{
	double atr[];
	if(!iATR(Symbol(), tf, period, 0, atr)) return -1.0;
	return atr[0];
}

bool NewBar(ENUM_TIMEFRAMES tf)
{
	static datetime lastTime = 0;
	datetime t0 = iTime(Symbol(), tf, 0);
	if(t0 != lastTime){ lastTime = t0; return true; }
	return false;
}

double NormalizeSLTPPrice(double price)
{
	return NormalizeDouble(price, (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS));
}

int CountOpenTradesForSymbol()
{
	int total = PositionsTotal();
	int count = 0;
	for(int i=0;i<total;i++)
	{
		ulong ticket = PositionGetTicket(i);
		if(PositionSelectByTicket(ticket))
		{
			if(PositionGetString(POSITION_SYMBOL) == Symbol())
				count++;
		}
	}
	return count;
}

bool GetPrevDayHLC(double &pdh, double &pdl, double &pdc)
{
	int shift = iBarShift(Symbol(), PERIOD_D1, iTime(Symbol(), PERIOD_D1, 0)) + 1;
	if(shift < 0) return false;
	double high = iHigh(Symbol(), PERIOD_D1, shift);
	double low  = iLow(Symbol(),  PERIOD_D1, shift);
	double close= iClose(Symbol(),PERIOD_D1, shift);
	if(high == 0 || low == 0 || close == 0) return false;
	pdh = high; pdl = low; pdc = close; return true;
}

bool VolumeBreakoutConfirmed(int vol_ma_period, double factor)
{
	long volume = iVolume(Symbol(), InpSignalTF, 0);
	double ma[];
	if(!iMAOnArrayVolume(vol_ma_period, ma)) return false;
	double avg = ma[0];
	return (avg > 0 && (double)volume >= factor * avg);
}

// SMA of tick volumes (helper)
bool iMAOnArrayVolume(int period, double &out[])
{
	ArraySetAsSeries(out, true);
	double buffer[];
	ArrayResize(buffer, period);
	double sum = 0;
	for(int i=0;i<period;i++)
	{
		long v = iVolume(Symbol(), InpSignalTF, i);
		sum += (double)v;
	}
	double avg = sum / MathMax(1, period);
	ArrayResize(out, 1);
	out[0] = avg;
	return true;
}

double PointsFromPrice(double price_diff)
{
	double pt = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
	return price_diff / pt;
}

double CalcPositionSizeByRisk(double stop_points, double risk_percent)
{
	if(stop_points <= 0) return 0.0;
	double balance = AccountInfoDouble(ACCOUNT_BALANCE);
	double riskAmt = balance * (risk_percent/100.0);

	double tick_value = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
	double tick_size  = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
	double point      = SymbolInfoDouble(Symbol(), SYMBOL_POINT);

	double money_per_point_per_lot = (tick_value / tick_size) * point;
	if(money_per_point_per_lot <= 0) return 0.0;

	double lot = riskAmt / (stop_points * money_per_point_per_lot);
	double min_lot = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
	double max_lot = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX);
	double lot_step= SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);

	lot = MathMax(min_lot, MathMin(max_lot, lot));
	lot = MathFloor(lot/lot_step)*lot_step;
	return lot;
}

bool SendOrder(int type, double entry, double sl, double tp, double lots, string comment)
{
	MqlTradeRequest req;
	MqlTradeResult  res;
	ZeroMemory(req); ZeroMemory(res);

	req.action   = TRADE_ACTION_DEAL;
	req.symbol   = Symbol();
	req.type     = (ENUM_ORDER_TYPE)type;
	req.volume   = lots;
	req.deviation= (int)InpSlippagePoints;
	req.price    = entry;
	req.sl       = sl;
	req.tp       = tp;
	req.type_filling = ORDER_FILLING_FOK;
	req.type_time    = ORDER_TIME_GTC;
	req.comment      = comment;

	bool ok = OrderSend(req, res);
	if(!ok)
	{
		Print("OrderSend failed: ", GetLastError(), " retcode=", res.retcode);
		return false;
	}
	return true;
}

// ========================= Macro Filter =========================
enum MacroTrend { MACRO_UNKNOWN=0, MACRO_UP=1, MACRO_DOWN=2 };

// Very lightweight stub; expects a simple payload like {"trend":"up"} or {"trend":"down"}
MacroTrend FetchMacroTrend(const string url)
{
	if(url == "") return MACRO_UNKNOWN;

	char data[];
	string headers;
	int status = WebRequest("GET", url, "", InpMacroTimeoutMs, data, headers);
	if(status != 200)
	{
		Print("WebRequest status=", status, " url=", url);
		return MACRO_UNKNOWN;
	}
	string body = CharArrayToString(data, 0, ArraySize(data));
	body = StringToLower(body);
	if(StringFind(body, "up") >= 0)   return MACRO_UP;
	if(StringFind(body, "down") >= 0) return MACRO_DOWN;
	return MACRO_UNKNOWN;
}

MacroTrend GetMacroContext()
{
	if(!InpUseMacroFilter) return MACRO_UNKNOWN;

	MacroTrend tips = FetchMacroTrend(InpMacroUrl_TIPS);
	if(tips != MACRO_UNKNOWN) return tips;

	MacroTrend dxy = FetchMacroTrend(InpMacroUrl_DXY);
	return dxy;
}

// ========================= Strategy 1: Breakout =========================
struct BreakoutSignal { bool buy; bool sell; double entry; double sl; double tp; string tag; };

bool ConsolidationBelow(double level, int bars, double tolerancePoints)
{
	double pt = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
	double tol = tolerancePoints*pt;
	for(int i=1;i<=bars;i++)
	{
		double high = iHigh(Symbol(), InpSignalTF, i);
		if(high >= level - tol) continue; // allow nudges
		if(high >= level + tol) return false;
	}
	return true;
}

bool ConsolidationAbove(double level, int bars, double tolerancePoints)
{
	double pt = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
	double tol = tolerancePoints*pt;
	for(int i=1;i<=bars;i++)
	{
		double low = iLow(Symbol(), InpSignalTF, i);
		if(low <= level + tol) continue;
		if(low <= level - tol) return false;
	}
	return true;
}

int ArrayMaximumLowIdx(int window)
{
	int idx = 1;
	double minv = 1e100;
	for(int i=1;i<=window;i++){ double v=iLow(Symbol(), InpSignalTF, i); if(v<minv){minv=v; idx=i;} }
	return idx;
}
int ArrayMaximumHighIdx(int window)
{
	int idx = 1;
	double maxv = -1e100;
	for(int i=1;i<=window;i++){ double v=iHigh(Symbol(), InpSignalTF, i); if(v>maxv){maxv=v; idx=i;} }
	return idx;
}

BreakoutSignal Strategy1_Breakout(double rr = 1.5)
{
	BreakoutSignal s; s.buy=false; s.sell=false; s.entry=0; s.sl=0; s.tp=0; s.tag="S1";
	double pdh, pdl, pdc;
	if(!GetPrevDayHLC(pdh, pdl, pdc)) return s;

	double pt = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
	double buffer = InpBreakoutBufferPoints*pt;

	// Buy setup
	if(ConsolidationBelow(pdh, InpConsolidationBars, InpBreakoutBufferPoints)
		&& VolumeBreakoutConfirmed(InpVolumeMA_Period, InpVolumeBoostFactor))
	{
		double entry = pdh + buffer;
		double recent_low = iLow(Symbol(), InpSignalTF, ArrayMaximumLowIdx(InpConsolidationBars+1));
		if(recent_low<=0) recent_low = pdc;
		double sl = MathMin(recent_low, pdl) - 2*pt*InpBreakoutBufferPoints;
		double risk_points = PointsFromPrice(entry - sl);
		double tp = entry + rr * risk_points * pt;
		s.buy=true; s.entry=NormalizeSLTPPrice(entry); s.sl=NormalizeSLTPPrice(sl); s.tp=NormalizeSLTPPrice(tp);
		return s;
	}

	// Sell setup
	if(ConsolidationAbove(pdl, InpConsolidationBars, InpBreakoutBufferPoints)
		&& VolumeBreakoutConfirmed(InpVolumeMA_Period, InpVolumeBoostFactor))
	{
		double entry = pdl - buffer;
		double recent_high = iHigh(Symbol(), InpSignalTF, ArrayMaximumHighIdx(InpConsolidationBars+1));
		if(recent_high<=0) recent_high = pdc;
		double sl = MathMax(recent_high, pdh) + 2*pt*InpBreakoutBufferPoints;
		double risk_points = PointsFromPrice(sl - entry);
		double tp = entry - rr * risk_points * pt;
		s.sell=true; s.entry=NormalizeSLTPPrice(entry); s.sl=NormalizeSLTPPrice(sl); s.tp=NormalizeSLTPPrice(tp);
		return s;
	}
	return s;
}

// ========================= Strategy 2: ZigZag Divergence + Macro =========================
struct DivSignal { bool buy; bool sell; double entry; double sl; double tp; string tag; };
struct Pivot { int shift; double price; };

int GetLastZigZagPivots(ENUM_TIMEFRAMES tf, int depth, int deviation, int backstep, int max_bars, Pivot &high1, Pivot &high2, Pivot &low1, Pivot &low2)
{
	int handle = iCustom(Symbol(), tf, "ZigZag", depth, deviation, backstep);
	if(handle == INVALID_HANDLE) { Print("ZigZag handle invalid"); return 0; }

	double zz[]; ArraySetAsSeries(zz, true);
	if(CopyBuffer(handle, 0, 0, max_bars, zz) <= 0) { Print("ZigZag copy failed"); return 0; }

	bool haveH1=false, haveH2=false, haveL1=false, haveL2=false;
	for(int i=1; i<max_bars && (!haveH2 || !haveL2); i++)
	{
		double v = zz[i];
		if(v == 0.0) continue;

		double hi_prev = iHigh(Symbol(), tf, i+1);
		double hi_next = iHigh(Symbol(), tf, i-1);
		double lo_prev = iLow(Symbol(),  tf, i+1);
		double lo_next = iLow(Symbol(),  tf, i-1);

		bool isHigh = (v >= hi_prev && v >= hi_next);
		bool isLow  = (v <= lo_prev && v <= lo_next);

		if(isHigh)
		{
			if(!haveH1) { high1.shift = i; high1.price = v; haveH1 = true; }
			else if(!haveH2 && i != high1.shift) { high2.shift = i; high2.price = v; haveH2 = true; }
		}
		else if(isLow)
		{
			if(!haveL1) { low1.shift = i; low1.price = v; haveL1 = true; }
			else if(!haveL2 && i != low1.shift) { low2.shift = i; low2.price = v; haveL2 = true; }
		}
	}
	return (haveH1 && haveH2 && haveL1 && haveL2) ? 1 : 0;
}

double GetRSIAtShift(int shift) { return iRSI(Symbol(), InpSignalTF, InpRSIPeriod, PRICE_CLOSE, shift); }
double GetEMAAtShift(int period, int shift) { return iMA(Symbol(), InpSignalTF, period, 0, MODE_EMA, PRICE_CLOSE, shift); }

DivSignal Strategy2_Divergence_ZZ()
{
	DivSignal s; s.buy=false; s.sell=false; s.entry=0; s.sl=0; s.tp=0; s.tag="S2";
	const int ZZ_Depth = 12;
	const int ZZ_Deviation = 5;
	const int ZZ_Backstep = 3;
	const int ZZ_MaxBars = 500;

	Pivot h1, h2, l1, l2;
	if(GetLastZigZagPivots(InpSignalTF, ZZ_Depth, ZZ_Deviation, ZZ_Backstep, ZZ_MaxBars, h1, h2, l1, l2) == 0)
		return s;

	double rsi_h1 = GetRSIAtShift(h1.shift);
	double rsi_h2 = GetRSIAtShift(h2.shift);
	double rsi_l1 = GetRSIAtShift(l1.shift);
	double rsi_l2 = GetRSIAtShift(l2.shift);

	MacroTrend macro = GetMacroContext();

	bool bearishDiv = (h1.price > h2.price) && (rsi_h1 < rsi_h2);
	bool bullishDiv = (l1.price < l2.price) && (rsi_l1 > rsi_l2);

	double pt = SymbolInfoDouble(Symbol(), SYMBOL_POINT);

	if(bearishDiv && (!InpUseMacroFilter || macro == MACRO_UP))
	{
		double ema0 = GetEMAAtShift(InpEMA_Period, 0);
		double price = SymbolInfoDouble(Symbol(), SYMBOL_BID);
		if(price > ema0)
		{
			double sl = h1.price + 2*pt*InpBreakoutBufferPoints;
			double risk_points = PointsFromPrice(sl - price);
			if(risk_points > 0)
			{
				double tp = price - 2*risk_points*pt;
				s.sell=true; s.entry=NormalizeSLTPPrice(price); s.sl=NormalizeSLTPPrice(sl); s.tp=NormalizeSLTPPrice(tp);
				return s;
			}
		}
	}

	if(bullishDiv && (!InpUseMacroFilter || macro == MACRO_DOWN))
	{
		double ema0 = GetEMAAtShift(InpEMA_Period, 0);
		double price = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
		if(price < ema0)
		{
			double sl = l1.price - 2*pt*InpBreakoutBufferPoints;
			double risk_points = PointsFromPrice(price - sl);
			if(risk_points > 0)
			{
				double tp = price + 2*risk_points*pt;
				s.buy=true; s.entry=NormalizeSLTPPrice(price); s.sl=NormalizeSLTPPrice(sl); s.tp=NormalizeSLTPPrice(tp);
				return s;
			}
		}
	}
	return s;
}

// ========================= Strategy 3: Squeeze =========================
struct SqueezeSignal { bool buy; bool sell; double entry; double sl; double tp; string tag; };

double BollingerBandwidth(int period, double dev, int shift)
{
	double upper = iBands(Symbol(), InpSignalTF, period, dev, 0, PRICE_CLOSE, MODE_UPPER, shift);
	double lower = iBands(Symbol(), InpSignalTF, period, dev, 0, PRICE_CLOSE, MODE_LOWER, shift);
	double mid   = iBands(Symbol(), InpSignalTF, period, dev, 0, PRICE_CLOSE, MODE_MAIN,  shift);
	if(mid == 0) return 0;
	return (upper - lower) / mid;
}

double SMAOnArray(const double &arr[], int len)
{
	double s=0; for(int i=0;i<len;i++) s+=arr[i];
	return s/MathMax(1,len);
}

int CCIValue(int shift) { return (int)iCCI(Symbol(), InpSignalTF, InpCCI_Period, PRICE_TYPICAL, shift); }

SqueezeSignal Strategy3_Squeeze()
{
	SqueezeSignal s; s.buy=false; s.sell=false; s.entry=0; s.sl=0; s.tp=0; s.tag="S3";

	double bw_now = BollingerBandwidth(InpBB_Period, InpBB_Dev, 0);
	if(bw_now <= 0) return s;

	double bw_hist[];
	ArrayResize(bw_hist, InpBBW_MA_Period);
	for(int i=0;i<InpBBW_MA_Period;i++){ bw_hist[i]=BollingerBandwidth(InpBB_Period, InpBB_Dev, i+1); }
	double bw_ma = SMAOnArray(bw_hist, InpBBW_MA_Period);

	bool in_squeeze = (bw_ma>0 && bw_now < InpBBW_RatioThreshold*bw_ma);
	if(!in_squeeze) return s;

	double close0 = iClose(Symbol(), InpSignalTF, 0);
	double upper0 = iBands(Symbol(), InpSignalTF, InpBB_Period, InpBB_Dev, 0, PRICE_CLOSE, MODE_UPPER, 0);
	double lower0 = iBands(Symbol(), InpSignalTF, InpBB_Period, InpBB_Dev, 0, PRICE_CLOSE, MODE_LOWER, 0);
	int cci0 = CCIValue(0);

	double pt = SymbolInfoDouble(Symbol(), SYMBOL_POINT);

	if(close0 > upper0 && cci0 >= InpCCI_Confirm)
	{
		double sl = lower0 - 2*pt*InpBreakoutBufferPoints;
		double risk_points = PointsFromPrice(close0 - sl);
		double tp = close0 + 2*risk_points*pt;
		s.buy=true; s.entry=NormalizeSLTPPrice(SymbolInfoDouble(Symbol(), SYMBOL_ASK)); s.sl=NormalizeSLTPPrice(sl); s.tp=NormalizeSLTPPrice(tp);
		return s;
	}
	if(close0 < lower0 && cci0 <= -InpCCI_Confirm)
	{
		double sl = upper0 + 2*pt*InpBreakoutBufferPoints;
		double risk_points = PointsFromPrice(sl - close0);
		double tp = close0 - 2*risk_points*pt;
		s.sell=true; s.entry=NormalizeSLTPPrice(SymbolInfoDouble(Symbol(), SYMBOL_BID)); s.sl=NormalizeSLTPPrice(sl); s.tp=NormalizeSLTPPrice(tp);
		return s;
	}
	return s;
}

// ========================= Multi-TP & Breakeven helpers =========================
string GenerateTradeId(const string strategyTag)
{
	long ms = GetMicrosecondCount();
	return strategyTag + "#" + IntegerToString((int)TimeCurrent()) + "-" + IntegerToString((int)(ms%1000000));
}

bool ModifySLForTicket(ulong ticket, double newSL)
{
	if(!PositionSelectByTicket(ticket)) return false;
	MqlTradeRequest req; MqlTradeResult res;
	ZeroMemory(req); ZeroMemory(res);
	req.action      = TRADE_ACTION_SLTP;
	req.symbol      = PositionGetString(POSITION_SYMBOL);
	req.volume      = PositionGetDouble(POSITION_VOLUME);
	req.sl          = NormalizeDouble(newSL, (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS));
	req.tp          = PositionGetDouble(POSITION_TP);
	req.type_time   = ORDER_TIME_GTC;
	req.type_filling= ORDER_FILLING_FOK;
	return OrderSend(req, res);
}

// Split order into TP1 and TP2 legs; TP2 can be trailing-only if Chandelier is enabled
bool SendOrderMultiTP(bool isBuy, double entry, double sl, double risk_points, double lotsBase, string strategyTag)
{
	if(!InpUseMultiTP)
	{
		int type = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
		double tp_stub = 0.0; // Keep 0 here; strategies' fixed TP not used in multi-TP mode
		return SendOrder(type, entry, sl, tp_stub, lotsBase, strategyTag);
	}

	double lot1 = lotsBase * InpTP1_VolumeRatio;
	double lot2 = lotsBase * InpTP2_VolumeRatio;
	double min_lot  = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
	double lot_step = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);

	lot1 = MathFloor(MathMax(lot1, min_lot)/lot_step)*lot_step;
	lot2 = MathFloor(MathMax(lot2, min_lot)/lot_step)*lot_step;
	if(lot1 + lot2 < min_lot) return false;

	double pt = SymbolInfoDouble(Symbol(), SYMBOL_POINT);

	double tp1 = 0.0, tp2 = 0.0;
	if(isBuy)
	{
		tp1 = entry + InpTP1_RR * risk_points * pt;
		tp2 = entry + InpTP2_RR * risk_points * pt;
	}
	else
	{
		tp1 = entry - InpTP1_RR * risk_points * pt;
		tp2 = entry - InpTP2_RR * risk_points * pt;
	}

	string baseId = GenerateTradeId(strategyTag);

	// TP1 leg (fixed TP at RR1)
	if(lot1 >= min_lot)
	{
		int type = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
		string cmt = strategyTag + "-TP1:" + baseId;
		SendOrder(type, entry, sl, NormalizeSLTPPrice(tp1), lot1, cmt);
	}

	// TP2 leg (fixed TP at RR2 or trailing if Chandelier)
	if(lot2 >= min_lot)
	{
		int type = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
		string cmt = strategyTag + "-TP2:" + baseId;
		double tp2_to_use = InpUseChandelierExit ? 0.0 : NormalizeSLTPPrice(tp2);
		SendOrder(type, entry, sl, tp2_to_use, lot2, cmt);
	}

	return true;
}

// Determine if BE+offset must be enforced for a TP2 leg, and output required SL
bool GetBreakevenRequirementForPosition(ulong posTicket, double &requiredSLOut)
{
	requiredSLOut = 0.0;
	if(!InpUseMultiTP || !InpEnforceBreakeven) return false;
	if(!PositionSelectByTicket(posTicket)) return false;
	if(PositionGetString(POSITION_SYMBOL) != Symbol()) return false;

	string cmt = PositionGetString(POSITION_COMMENT);
	int pos = StringFind(cmt, "-TP2:");
	if(pos < 0) return false; // only enforce on TP2 legs

	string baseId = StringSubstr(cmt, pos + 5);
	if(baseId == "") return false;

	// Is the matching TP1 leg closed?
	datetime t0 = TimeCurrent() - 2*24*60*60;
	HistorySelect(t0, TimeCurrent());
	bool tp1Closed = false;
	uint deals = HistoryDealsTotal();
	for(uint d=0; d<deals; ++d)
	{
		ulong deal_ticket = HistoryDealGetTicket(d);
		if(deal_ticket == 0) continue;
		string d_symbol = (string)HistoryDealGetString(deal_ticket, DEAL_SYMBOL);
		if(d_symbol != Symbol()) continue;
		string d_comment = (string)HistoryDealGetString(deal_ticket, DEAL_COMMENT);
		if(StringFind(d_comment, "-TP1:"+baseId) >= 0)
		{
			long entryKind = HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
			if(entryKind == DEAL_ENTRY_OUT) { tp1Closed = true; break; }
		}
	}
	if(!tp1Closed) return false;

	long   type       = PositionGetInteger(POSITION_TYPE);
	double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
	double pt         = SymbolInfoDouble(Symbol(), SYMBOL_POINT);

	if(type == POSITION_TYPE_BUY)
		requiredSLOut = entryPrice + MathMax(0.0, InpBreakevenOffsetPts) * pt;
	else
		requiredSLOut = entryPrice - MathMax(0.0, InpBreakevenOffsetPts) * pt;

	return true;
}

// Continuously enforce BE+offset for TP2 after TP1 is closed
void ApplyBreakevenIfTP1Closed()
{
	if(!InpUseMultiTP || !InpEnforceBreakeven) return;

	int totalPositions = PositionsTotal();
	for(int i=0; i<totalPositions; ++i)
	{
		ulong ticket = PositionGetTicket(i);
		if(!PositionSelectByTicket(ticket)) continue;
		if(PositionGetString(POSITION_SYMBOL) != Symbol()) continue;

		double requiredSL;
		if(!GetBreakevenRequirementForPosition(ticket, requiredSL)) continue;

		long   type = PositionGetInteger(POSITION_TYPE);
		double curSL = PositionGetDouble(POSITION_SL);

		bool needsUpdate = false;
		double newSL = curSL;

		if(type == POSITION_TYPE_BUY)
		{
			if(curSL <= 0 || curSL < requiredSL) { newSL = requiredSL; needsUpdate = true; }
		}
		else // sell
		{
			if(curSL <= 0 || curSL > requiredSL) { newSL = requiredSL; needsUpdate = true; }
		}

		if(needsUpdate)
			ModifySLForTicket(ticket, NormalizeSLTPPrice(newSL));
	}
}

// ========================= Chandelier Exit Trailing =========================
void UpdateChandelierTrailForSymbol()
{
	int total = PositionsTotal();
	if(total <= 0) return;

	double pt = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
	double atr = iATR(Symbol(), InpTrailTF, InpChandATRPeriod, 0);
	if(atr <= 0) return;

	double highest = iHigh(Symbol(), InpTrailTF, iHighest(Symbol(), InpTrailTF, MODE_HIGH, InpChandLookback, 1));
	double lowest  = iLow(Symbol(),  InpTrailTF, iLowest(Symbol(), InpTrailTF, MODE_LOW,  InpChandLookback, 1));
	if(highest == 0 || lowest == 0) return;

	for(int i=total-1; i>=0; --i)
	{
		ulong ticket = PositionGetTicket(i);
		if(!PositionSelectByTicket(ticket)) continue;
		if(PositionGetString(POSITION_SYMBOL) != Symbol()) continue;

		long type     = PositionGetInteger(POSITION_TYPE);
		double volume = PositionGetDouble(POSITION_VOLUME);
		double sl     = PositionGetDouble(POSITION_SL);
		double tp     = PositionGetDouble(POSITION_TP);
		double price_open = PositionGetDouble(POSITION_PRICE_OPEN);
		double bid    = SymbolInfoDouble(Symbol(), SYMBOL_BID);
		double ask    = SymbolInfoDouble(Symbol(), SYMBOL_ASK);

		if(InpTrailActivatePts > 0.0)
		{
			if(type == POSITION_TYPE_BUY && (bid - price_open)/pt < InpTrailActivatePts) continue;
			if(type == POSITION_TYPE_SELL && (price_open - ask)/pt < InpTrailActivatePts) continue;
		}

		double new_sl = sl;

		if(type == POSITION_TYPE_BUY)
		{
			double chand = highest - InpChandATRMult * atr;
			new_sl = (sl <= 0) ? chand : MathMax(sl, chand);
			if(tp > 0) tp = 0.0;
		}
		else if(type == POSITION_TYPE_SELL)
		{
			double chand = lowest + InpChandATRMult * atr;
			new_sl = (sl <= 0) ? chand : MathMin(sl, chand);
			if(tp > 0) tp = 0.0;
		}

		// Enforce breakeven floor/ceiling for TP2 legs once TP1 is closed
		double beRequired;
		if(GetBreakevenRequirementForPosition(ticket, beRequired))
		{
			if(type == POSITION_TYPE_BUY)
				new_sl = (new_sl <= 0) ? beRequired : MathMax(new_sl, beRequired);
			else
				new_sl = (new_sl <= 0) ? beRequired : MathMin(new_sl, beRequired);
		}

		if(new_sl <= 0 || MathAbs(new_sl - sl) < 0.5*pt) continue;

		MqlTradeRequest req; MqlTradeResult res;
		ZeroMemory(req); ZeroMemory(res);
		req.action      = TRADE_ACTION_SLTP;
		req.symbol      = Symbol();
		req.volume      = volume;
		req.sl          = NormalizeDouble(new_sl, (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS));
		req.tp          = tp;
		req.type_time   = ORDER_TIME_GTC;
		req.type_filling= ORDER_FILLING_FOK;

		if(!OrderSend(req, res))
			Print("Chandelier trail modify failed. ticket=", ticket, " err=", GetLastError(), " ret=", res.retcode);
	}
}

// ========================= Risk/Equity Management =========================
void UpdateEquityPeakAndHalt()
{
	double eq = AccountInfoDouble(ACCOUNT_EQUITY);
	if(g_equityPeak <= 0.0) g_equityPeak = eq;
	if(eq > g_equityPeak) g_equityPeak = eq;

	double dd = 100.0 * (g_equityPeak - eq) / g_equityPeak;
	g_tradingHalted = (dd >= InpEquityMaxDDPercent);
}

void CloseAllPositionsForSymbol()
{
	int total = PositionsTotal();
	for(int i=total-1;i>=0;i--)
	{
		ulong ticket = PositionGetTicket(i);
		if(!PositionSelectByTicket(ticket)) continue;
		if(PositionGetString(POSITION_SYMBOL) != Symbol()) continue;

		long type = PositionGetInteger(POSITION_TYPE);
		double vol = PositionGetDouble(POSITION_VOLUME);
		double price = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(Symbol(), SYMBOL_BID) : SymbolInfoDouble(Symbol(), SYMBOL_ASK);

		MqlTradeRequest req; MqlTradeResult res;
		ZeroMemory(req); ZeroMemory(res);
		req.action = TRADE_ACTION_DEAL;
		req.symbol = Symbol();
		req.volume = vol;
		req.type   = (type == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
		req.price  = price;
		req.deviation = (int)InpSlippagePoints;
		OrderSend(req, res);
	}
}

// ========================= Lifecycle =========================
int OnInit()
{
	Print("XAU_Quantum_EA v1.2 initialized on ", Symbol());
	g_equityPeak = AccountInfoDouble(ACCOUNT_EQUITY);
	return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
	Print("XAU_Quantum_EA deinit, reason=", reason);
}

void OnTick()
{
	if(Symbol() == "") return;

	// Force-flat time
	datetime now_server = TimeCurrent();
	datetime now_gmt    = ToGMT(now_server);
	if(IsForceFlatTimeGMT(now_gmt)) CloseAllPositionsForSymbol();

	// Equity trail halt
	UpdateEquityPeakAndHalt();
	if(g_tradingHalted) return;

	// Apply Chandelier trailing to existing positions
	if(InpUseChandelierExit)
		UpdateChandelierTrailForSymbol();

	// Breakeven promotion/enforcement for TP2 legs whose TP1 closed
	ApplyBreakevenIfTP1Closed();

	// Time filter
	if(!IsWithinSessionGMT(now_gmt)) return;

	// Volatility (ATR) filter on D1
	double atr_d1 = GetATR(InpATR_TF, 14);
	if(atr_d1 <= 0) return;
	double atr_points = PointsFromPrice(atr_d1);
	if(atr_points < InpATR_Min || atr_points > InpATR_Max) return;

	// Avoid duplicate actions per bar
	if(!NewBar(InpSignalTF)) return;

	// Limit concurrent trades
	if(CountOpenTradesForSymbol() >= InpMaxOpenTrades) return;

	// ===== Run Strategies =====
	bool triedTrade = false;

	// Strategy 1: Breakout
	if(InpUseStrategy1_Breakout)
	{
		BreakoutSignal b = Strategy1_Breakout(1.5);
		if(b.buy || b.sell)
		{
			bool isBuy = b.buy;
			double risk_points = isBuy ? PointsFromPrice(b.entry - b.sl) : PointsFromPrice(b.sl - b.entry);
			if(risk_points > 0)
			{
				double lots = CalcPositionSizeByRisk(risk_points, InpRiskPerTradePercent);
				if(lots > 0)
				{
					if(SendOrderMultiTP(isBuy, b.entry, b.sl, risk_points, lots, b.tag)) triedTrade = true;
				}
			}
		}
	}

	// Strategy 2: Divergence + Macro (ZigZag-based)
	if(InpUseStrategy2_Divergence && !triedTrade)
	{
		DivSignal d = Strategy2_Divergence_ZZ();
		if(d.buy || d.sell)
		{
			bool isBuy = d.buy;
			double risk_points = isBuy ? PointsFromPrice(d.entry - d.sl) : PointsFromPrice(d.sl - d.entry);
			if(risk_points > 0)
			{
				double lots = CalcPositionSizeByRisk(risk_points, InpRiskPerTradePercent);
				if(lots > 0)
				{
					if(SendOrderMultiTP(isBuy, d.entry, d.sl, risk_points, lots, d.tag)) triedTrade = true;
				}
			}
		}
	}

	// Strategy 3: Squeeze Explosion
	if(InpUseStrategy3_Squeeze && !triedTrade)
	{
		SqueezeSignal z = Strategy3_Squeeze();
		if(z.buy || z.sell)
		{
			bool isBuy = z.buy;
			double risk_points = isBuy ? PointsFromPrice(z.entry - z.sl) : PointsFromPrice(z.sl - z.entry);
			if(risk_points > 0)
			{
				double lots = CalcPositionSizeByRisk(risk_points, InpRiskPerTradePercent);
				if(lots > 0)
				{
					SendOrderMultiTP(isBuy, z.entry, z.sl, risk_points, lots, z.tag);
				}
			}
		}
	}
}
