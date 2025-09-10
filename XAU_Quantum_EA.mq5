//+------------------------------------------------------------------+
//|                                               XAU_Quantum_EA.mq5 |
//|                           Copyright 2025, Quantum Dynamics Labs  |
//|                                    https://www.quantumdynamics.ai|
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, Quantum Dynamics Labs"
#property link      "https://www.quantumdynamics.ai"
#property version   "1.00"
#property description "A multi-strategy, volatility-aware EA for Gold (XAU)."

//+------------------------------------------------------------------+
//| EA Logic Overview                                                |
//+------------------------------------------------------------------+
/*
This Expert Advisor is a sophisticated, multi-strategy trading robot designed
specifically for Gold (XAU). It integrates three distinct trading models with
a robust framework of global filters and advanced risk management.

Core Framework Features:
- Multi-Strategy Engine: Runs three independent trading models concurrently,
  each identified by a unique magic number.
- Global Time Filter: Restricts all trading activity to specific hours to
  focus on high-liquidity sessions.
- Global Volatility Filter: Avoids trading in market conditions that are
  either too quiet or too chaotic, based on the daily Average True Range (ATR).
- Dynamic Position Sizing: Calculates lot size for every trade based on a
  fixed percentage of account equity and the specific stop-loss distance,
  ensuring consistent risk exposure.
- Time-Based Stop: Automatically closes all open positions at a set time
  daily to mitigate overnight and weekend gap risk.
- Equity Trail Protection: A master circuit-breaker that halts all trading
  and closes positions if a specified equity drawdown percentage from the
  peak is reached, protecting the account from severe losses.

Trading Strategy Modules:
- Strategy 1: Market Structure & Breakout Trading
- Strategy 2: Momentum Divergence with Macro-Filter
- Strategy 3: Volatility Squeeze Explosion
*/

//--- Include libraries
#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>
#include <Trade\AccountInfo.mqh>

//--- Global variables
CTrade          trade;
CSymbolInfo     symbolInfo;
CPositionInfo   positionInfo;
COrderInfo      orderInfo;
CAccountInfo    accountInfo;
double          g_peak_equity = 0.0;
bool            g_trading_halted = false;

//--- Input Parameters for Global Filters
input group "Global Trading Filters"
input bool   EnableTimeFilter    = true;     // Enable Time Filter
input int    StartTime           = 7;        // Trading start hour (Broker Server Time)
input int    EndTime             = 16;       // Trading end hour (Broker Server Time)
input bool   EnableAtrFilter     = true;     // Enable Volatility (ATR) Filter
input double MinAtrPips          = 20.0;     // Minimum Daily ATR in pips
input double MaxAtrPips          = 200.0;    // Maximum Daily ATR in pips
input int    AtrFilterPeriod     = 14;       // Period for ATR calculation

//--- Input Parameters for Risk Management
input group "Risk Management"
input bool   EnableDynamicLots   = true;     // Enable dynamic lot sizing
input double RiskPercent         = 1.0;      // Risk % of account balance per trade
input bool   EnableTimeStop      = true;     // Enable Time-Based Stop
input int    TimeStopHour        = 17;       // Hour to close all trades (Broker Time)
input int    TimeStopMinute      = 0;        // Minute to close all trades
input bool   EnableEquityTrail   = true;     // Enable Equity Trail Stop
input double EquityTrailPercent  = 5.0;      // Max equity drawdown % to halt trading

//--- Input Parameters for enabling/disabling strategies
input group "Strategy Selection"
input bool EnableStrategy1 = true; // Enable Market Structure & Breakout Trading
input bool EnableStrategy2 = true; // Enable Momentum Divergence with Macro-Filter
input bool EnableStrategy3 = true; // Enable Volatility Squeeze Explosion

//--- Input Parameters for Strategy 1: Market Structure & Breakout
input group "S1: Market Structure"
input int    S1_ConsolidationBars = 4;      // Number of bars for consolidation
input double S1_BuyStopPips       = 2.0;    // Pips above PDH for Buy Stop
input double S1_SellStopPips      = 2.0;    // Pips below PDL for Sell Stop
input double S1_RR_Ratio          = 1.5;    // Risk:Reward Ratio for TP

//--- Input Parameters for Strategy 2: Momentum Divergence
input group "S2: Momentum Divergence"
input int    S2_RSI_Period         = 21;      // RSI period for divergence
input string S2_DXY_Symbol         = "DXY";   // Symbol for DXY index (if available)
input ENUM_TIMEFRAMES S2_DXY_Timeframe = PERIOD_D1; // Timeframe for DXY trend
input int    S2_DXY_MA_Period      = 50;      // MA period for DXY trend
input int    S2_DivergenceLookback = 60;      // Bars to look back for divergence pivot points
input double S2_SL_Pips_Buffer     = 10;      // Pips to add to SL for buffer

//--- Input Parameters for Strategy 3: Volatility Squeeze
input group "S3: Volatility Squeeze"
input int    S3_BB_Period           = 20;      // Bollinger Bands period
input double S3_BB_Deviations       = 2.0;     // Bollinger Bands deviations
input int    S3_BandWidth_MAPeriod  = 50;      // MA period for BandWidth
input double S3_Squeeze_Threshold   = 0.2;     // Squeeze threshold (e.g., 0.2 for 20%)
input int    S3_CCI_Period          = 14;      // CCI period for confirmation
input double S3_CCI_Threshold       = 100;     // CCI threshold for entry
input int    S3_ATR_Period          = 14;      // ATR period for trailing stop
input double S3_ATR_Multiplier      = 2.5;     // ATR multiplier for trailing stop

//--- Magic Numbers for each strategy
#define MAGIC_S1 1001 // Magic Number for Strategy 1
#define MAGIC_S2 1002 // Magic Number for Strategy 2
#define MAGIC_S3 1003 // Magic Number for Strategy 3

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Initialization
   if(!symbolInfo.Name(_Symbol)) return(INIT_FAILED);
   trade.SetExpertMagicNumber(0);
   trade.SetMarginMode();
   trade.SetTypeFillingBySymbol(_Symbol);

   printf("XAU_Quantum_EA Initialized. Strategies Enabled: S1=%s, S2=%s, S3=%s",
          (string)EnableStrategy1, (string)EnableStrategy2, (string)EnableStrategy3);

   //--- Initialize Equity Trail
   if(EnableEquityTrail)
     {
      accountInfo.Refresh();
      g_peak_equity = accountInfo.Equity();
      printf("Equity Trail Initialized. Starting Peak Equity: %.2f", g_peak_equity);
     }

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   //--- Deinitialization
   printf("XAU_Quantum_EA Deinitialized. Reason: %d", reason);
   //--- Clean up pending orders on deinit
   CancelPendingOrders(MAGIC_S1);
   CancelPendingOrders(MAGIC_S2);
   CancelPendingOrders(MAGIC_S3);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- HALT CHECK ---
   if(g_trading_halted) return;

   //--- Check for new bar
   static datetime lastBarTime = 0;
   datetime currentBarTime = (datetime)SeriesInfoInteger(_Symbol, _Period, SERIES_LASTBAR_DATE);
   if(currentBarTime == lastBarTime)
     {
      return; // Not a new bar, exit
     }
   lastBarTime = currentBarTime;

   //--- EQUITY TRAIL MANAGEMENT ---
   ManageEquityTrail();
   if(g_trading_halted) return; // Re-check in case it was just triggered

   //--- TIME-BASED STOP ---
   CheckTimeStop();

   //--- GLOBAL FILTERS ---
   if(!IsTimeAllowed()) return;
   if(!IsVolatilityAllowed()) return;

   //--- Run enabled strategies
   if(EnableStrategy1)
     {
      CheckStrategy1();
     }
   if(EnableStrategy2)
     {
      CheckStrategy2();
     }
   if(EnableStrategy3)
     {
      ManageStrategy3_TSL();
      CheckStrategy3();
     }
}

//+------------------------------------------------------------------+
//| Risk Management Functions                                        |
//+------------------------------------------------------------------+
void ManageEquityTrail()
{
    if(!EnableEquityTrail || g_trading_halted) return;

    accountInfo.Refresh();
    double current_equity = accountInfo.Equity();

    if(current_equity > g_peak_equity)
    {
        g_peak_equity = current_equity;
    }

    if (g_peak_equity > 0) // Avoid division by zero
    {
        double drawdown_percent = ((g_peak_equity - current_equity) / g_peak_equity) * 100.0;

        if(drawdown_percent >= EquityTrailPercent)
        {
            g_trading_halted = true;

            string message = StringFormat("EQUITY TRAIL TRIGGERED! Trading has been halted. Peak Equity: %.2f, Current Equity: %.2f, Drawdown: %.2f%%",
                                          g_peak_equity, current_equity, drawdown_percent);
            printf(message);
            Alert(message);

            for(int i = PositionsTotal() - 1; i >= 0; i--)
            {
                if(positionInfo.SelectByIndex(i))
                {
                    int magic = (int)positionInfo.Magic();
                    if(magic == MAGIC_S1 || magic == MAGIC_S2 || magic == MAGIC_S3)
                    {
                        trade.PositionClose(positionInfo.Ticket());
                    }
                }
            }
        }
    }
}
double CalculateLotSize(double entry_price, double stop_loss_price)
{
    if(!EnableDynamicLots) return 0.01;

    accountInfo.Refresh();
    double account_balance = accountInfo.Balance();
    double risk_amount = account_balance * (RiskPercent / 100.0);
    double sl_distance = MathAbs(entry_price - stop_loss_price);

    if(sl_distance <= 0) return 0.0;

    double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    if(tick_value <= 0 || tick_size <= 0)
    {
        printf("Risk Management: Invalid tick value or size for %s.", _Symbol);
        return 0.0;
    }

    double sl_value_per_lot = (sl_distance / tick_size) * tick_value;

    if(sl_value_per_lot <= 0) return 0.0;

    double lot_size = risk_amount / sl_value_per_lot;

    lot_size = NormalizeDouble(lot_size, 2);
    double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double max_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

    if(lot_size < min_lot) lot_size = min_lot;
    if(lot_size > max_lot) lot_size = max_lot;

    lot_size = MathFloor(lot_size / lot_step) * lot_step;

    return lot_size;
}

void CheckTimeStop()
{
    if(!EnableTimeStop) return;

    MqlDateTime time_struct;
    TimeCurrent(time_struct);

    if(time_struct.hour > TimeStopHour || (time_struct.hour == TimeStopHour && time_struct.min >= TimeStopMinute))
    {
        for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
            if(positionInfo.SelectByIndex(i))
            {
                int magic = (int)positionInfo.Magic();
                if(magic == MAGIC_S1 || magic == MAGIC_S2 || magic == MAGIC_S3)
                {
                    trade.PositionClose(positionInfo.Ticket());
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Global Filter Functions                                          |
//+------------------------------------------------------------------+
bool IsTimeAllowed()
{
    if(!EnableTimeFilter) return true;

    MqlDateTime time_struct;
    TimeCurrent(time_struct);
    int current_hour = time_struct.hour;

    if(StartTime < EndTime) // Normal case, e.g., 7 to 16
    {
        return (current_hour >= StartTime && current_hour < EndTime);
    }
    else // Overnight case, e.g., 22 to 5
    {
        return (current_hour >= StartTime || current_hour < EndTime);
    }
}

bool IsVolatilityAllowed()
{
    if(!EnableAtrFilter) return true;

    int atr_handle = iATR(_Symbol, PERIOD_D1, AtrFilterPeriod);
    double atr_buffer[];
    if(CopyBuffer(atr_handle, 0, 0, 1, atr_buffer) < 1)
    {
        printf("ATR Filter: Could not get ATR value. Filter bypassed.");
        return true;
    }
    double current_atr = atr_buffer[0];
    symbolInfo.Refresh();
    double atr_in_pips = current_atr / symbolInfo.Pip();

    if(atr_in_pips < MinAtrPips)
    {
        //printf("ATR Filter: Volatility too low (%f pips). Trading paused.", atr_in_pips);
        return false;
    }
    if(atr_in_pips > MaxAtrPips)
    {
        //printf("ATR Filter: Volatility too high (%f pips). Trading paused.", atr_in_pips);
        return false;
    }

    return true;
}

//+------------------------------------------------------------------+
//| Strategy 1: Market Structure & Breakout Trading                  |
//+------------------------------------------------------------------+
void CheckStrategy1()
{
    // This function checks for breakout opportunities from the previous day's range.
    // It first checks for a long setup (breakout above PDH). If a trade is placed, it returns.
    // If no long trade is placed, it then proceeds to check for a short setup (breakout below PDL).
    // This sequential check is the intended logic.

    if(PositionSelectByMagic(_Symbol, MAGIC_S1) || OrderSelectByMagic(_Symbol, MAGIC_S1)) return;

    double pdh_arr[], pdl_arr[];
    if(CopyHigh(_Symbol, PERIOD_D1, 1, 1, pdh_arr) < 1 || CopyLow(_Symbol, PERIOD_D1, 1, 1, pdl_arr) < 1) return;
    double pdh = pdh_arr[0];
    double pdl = pdl_arr[0];

    MqlRates rates[];
    if(CopyRates(_Symbol, _Period, 1, S1_ConsolidationBars, rates) < S1_ConsolidationBars) return;

    symbolInfo.Refresh();
    double pip_size = symbolInfo.Pip();

    bool long_consolidation = true;
    for(int i = 0; i < S1_ConsolidationBars; i++)
    {
        if(rates[i].high >= pdh) { long_consolidation = false; break; }
    }

    if(long_consolidation)
    {
        double entry_price = pdh + S1_BuyStopPips * pip_size;
        entry_price = NormalizeDouble(entry_price, (int)symbolInfo.Digits());
        double stop_loss = pdl;
        double take_profit = entry_price + (entry_price - stop_loss) * S1_RR_Ratio;
        take_profit = NormalizeDouble(take_profit, (int)symbolInfo.Digits());

        double lots = CalculateLotSize(entry_price, stop_loss);
        if(lots > 0)
        {
            trade.SetExpertMagicNumber(MAGIC_S1);
            trade.BuyStop(lots, entry_price, _Symbol, stop_loss, take_profit, ORDER_TIME_GTC, 0, "S1 BuyStop");
        }
        return;
    }

    bool short_consolidation = true;
    for(int i = 0; i < S1_ConsolidationBars; i++)
    {
        if(rates[i].low <= pdl) { short_consolidation = false; break; }
    }

    if(short_consolidation)
    {
        double entry_price = pdl - S1_SellStopPips * pip_size;
        entry_price = NormalizeDouble(entry_price, (int)symbolInfo.Digits());
        double stop_loss = pdh;
        double take_profit = entry_price - (stop_loss - entry_price) * S1_RR_Ratio;
        take_profit = NormalizeDouble(take_profit, (int)symbolInfo.Digits());

        double lots = CalculateLotSize(entry_price, stop_loss);
        if(lots > 0)
        {
            trade.SetExpertMagicNumber(MAGIC_S1);
            trade.SellStop(lots, entry_price, _Symbol, stop_loss, take_profit, ORDER_TIME_GTC, 0, "S1 SellStop");
        }
        return;
    }
}


//+------------------------------------------------------------------+
//| Strategy 2: Momentum Divergence with Macro-Filter                |
//+------------------------------------------------------------------+
void CheckStrategy2()
{
    if(PositionSelectByMagic(_Symbol, MAGIC_S2)) return;

    int divergence_pivot_shift = findDivergence(S2_DivergenceLookback, 1);
    if(divergence_pivot_shift == 0) return;

    if(!CheckDXYFilter(divergence_pivot_shift)) return;

    if(divergence_pivot_shift > 0)
    {
        double stop_loss = iLow(_Symbol, _Period, divergence_pivot_shift) - S2_SL_Pips_Buffer * symbolInfo.Pip();
        stop_loss = NormalizeDouble(stop_loss, (int)symbolInfo.Digits());
        symbolInfo.RefreshRates();
        double entry_price = symbolInfo.Ask();

        double lots = CalculateLotSize(entry_price, stop_loss);
        if(lots > 0)
        {
            trade.SetExpertMagicNumber(MAGIC_S2);
            trade.Buy(lots, _Symbol, entry_price, stop_loss, 0, "S2 Buy");
        }
    }
    else
    {
        double stop_loss = iHigh(_Symbol, _Period, MathAbs(divergence_pivot_shift)) + S2_SL_Pips_Buffer * symbolInfo.Pip();
        stop_loss = NormalizeDouble(stop_loss, (int)symbolInfo.Digits());
        symbolInfo.RefreshRates();
        double entry_price = symbolInfo.Bid();

        double lots = CalculateLotSize(entry_price, stop_loss);
        if(lots > 0)
        {
            trade.SetExpertMagicNumber(MAGIC_S2);
            trade.Sell(lots, _Symbol, entry_price, stop_loss, 0, "S2 Sell");
        }
    }
}

// Returns shift of the second pivot point (>0 for bullish, <0 for bearish, 0 for none)
int findDivergence(int lookback, int start_shift)
{
    // Note on Logic: This is a simplified divergence detection function. It uses iLowest/iHighest
    // to find basic price pivots and compares them with RSI values at the same bar.
    // A more advanced implementation could use more robust pivot detection (e.g., via the
    // ZigZag indicator) or more complex pattern validation. This version prioritizes a
    // non-repainting signal based on closed bars.

    double rsi_buffer[];
    int rsi_handle = iRSI(_Symbol, _Period, S2_RSI_Period, PRICE_CLOSE);
    if(CopyBuffer(rsi_handle, 0, start_shift, lookback, rsi_buffer) < lookback) return 0;

    int p2_lookback = lookback / 3;
    int p2_shift = iLowest(_Symbol, _Period, MODE_LOW, p2_lookback, start_shift);
    int p1_lookback = lookback - (p2_shift - start_shift);
    int p1_shift = iLowest(_Symbol, _Period, MODE_LOW, p1_lookback, p2_shift + 1);

    if(p1_shift > 0 && p2_shift > 0)
    {
        double price1 = iLow(_Symbol, _Period, p1_shift);
        double price2 = iLow(_Symbol, _Period, p2_shift);
        double rsi1 = rsi_buffer[(int)(p1_shift - start_shift)];
        double rsi2 = rsi_buffer[(int)(p2_shift - start_shift)];
        if(price2 < price1 && rsi2 > rsi1) return p2_shift;
    }

    p2_shift = iHighest(_Symbol, _Period, MODE_HIGH, p2_lookback, start_shift);
    p1_shift = iHighest(_Symbol, _Period, MODE_HIGH, p1_lookback, p2_shift + 1);

    if(p1_shift > 0 && p2_shift > 0)
    {
        double price1 = iHigh(_Symbol, _Period, p1_shift);
        double price2 = iHigh(_Symbol, _Period, p2_shift);
        double rsi1 = rsi_buffer[(int)(p1_shift - start_shift)];
        double rsi2 = rsi_buffer[(int)(p2_shift - start_shift)];
        if(price2 > price1 && rsi2 < rsi1) return -p2_shift;
    }
    return 0;
}

bool CheckDXYFilter(int divergence_type)
{
    if(S2_DXY_Symbol == "") return true;
    if(!SymbolSelect(S2_DXY_Symbol, true)) return true;

    double dxy_ma_handle = iMA(S2_DXY_Symbol, S2_DXY_Timeframe, S2_DXY_MA_Period, 0, MODE_SMA, PRICE_CLOSE);
    double dxy_ma_buffer[];
    if(CopyBuffer(dxy_ma_handle, 0, 0, 1, dxy_ma_buffer) < 1) return true;

    double dxy_close = iClose(S2_DXY_Symbol, S2_DXY_Timeframe, 0);
    if(dxy_close == 0) return true;

    bool dxy_trending_up = dxy_close > dxy_ma_buffer[0];
    bool dxy_trending_down = dxy_close < dxy_ma_buffer[0];

    if(divergence_type > 0) return dxy_trending_down;
    else return dxy_trending_up;
}

//+------------------------------------------------------------------+
//| Strategy 3: Volatility Squeeze Explosion                         |
//+------------------------------------------------------------------+
void CheckStrategy3()
{
    // Note on Logic: All signals are based on the most recently CLOSED bar (shift 1)
    // to ensure signals are stable and do not repaint.

    if(PositionSelectByMagic(_Symbol, MAGIC_S3)) return;

    // 1. Get Indicator Handles
    int bb_handle = iBands(_Symbol, _Period, S3_BB_Period, 0, S3_BB_Deviations, PRICE_CLOSE);
    int cci_handle = iCCI(_Symbol, _Period, S3_CCI_Period, PRICE_TYPICAL);

    // 2. Calculate Historical BandWidth array to find the "multi-day low"
    double hist_upper[], hist_lower[], hist_middle[];
    int history_to_copy = S3_BandWidth_MAPeriod + 1; // +1 to get current bar's values for comparison
    if(CopyBuffer(bb_handle, 1, 1, history_to_copy, hist_upper) < history_to_copy ||
       CopyBuffer(bb_handle, 2, 1, history_to_copy, hist_lower) < history_to_copy ||
       CopyBuffer(bb_handle, 0, 1, history_to_copy, hist_middle) < history_to_copy) return;

    double bandwidth_history[];
    ArrayResize(bandwidth_history, S3_BandWidth_MAPeriod);

    for(int i = 0; i < S3_BandWidth_MAPeriod; i++)
    {
        // We look at the history from index 1 to 50 of the copied BB arrays
        if(hist_middle[i+1] != 0)
        {
            bandwidth_history[i] = (hist_upper[i+1] - hist_lower[i+1]) / hist_middle[i+1];
        }
        else
        {
            bandwidth_history[i] = 0;
        }
    }

    // 3. Find the historical low and get the current bandwidth
    double historical_low_bw = ArrayMinimum(bandwidth_history);
    double current_bw = (hist_middle[0] != 0) ? (hist_upper[0] - hist_lower[0]) / hist_middle[0] : -1;

    // 4. Detect the Squeeze: The core requirement is that bandwidth "falls to a multi-day low".
    // This is interpreted as the current bandwidth being at or very near the lowest point in the lookback period.
    // We use a small tolerance (1.05x) to avoid issues with floating point precision and to catch near-lows.
    if(current_bw < 0 || current_bw > (historical_low_bw * 1.05))
    {
        return; // Not in a squeeze, exit.
    }

    // 5. The Trigger and Confirmation
    double cci_val[];
    if(CopyBuffer(cci_handle, 0, 1, 1, cci_val) < 1) return;

    MqlRates rates[];
    if(CopyRates(_Symbol, _Period, 1, 1, rates) < 1) return;
    double close_price = rates[0].close;

    // --- Long Trigger ---
    if(close_price > hist_upper[0] && cci_val[0] > S3_CCI_Threshold)
    {
        double stop_loss = hist_lower[0];
        symbolInfo.RefreshRates();
        double entry_price = symbolInfo.Ask();
        double lots = CalculateLotSize(entry_price, stop_loss);
        if(lots > 0)
        {
            trade.SetExpertMagicNumber(MAGIC_S3);
            trade.Buy(lots, _Symbol, entry_price, stop_loss, 0, "S3 Buy");
        }
        return;
    }

    // --- Short Trigger ---
    if(close_price < hist_lower[0] && cci_val[0] < -S3_CCI_Threshold)
    {
        double stop_loss = hist_upper[0];
        symbolInfo.RefreshRates();
        double entry_price = symbolInfo.Bid();
        double lots = CalculateLotSize(entry_price, stop_loss);
        if(lots > 0)
        {
            trade.SetExpertMagicNumber(MAGIC_S3);
            trade.Sell(lots, _Symbol, entry_price, stop_loss, 0, "S3 Sell");
        }
        return;
    }
}

void ManageStrategy3_TSL()
{
    if(!PositionSelectByMagic(_Symbol, MAGIC_S3)) return;

    ulong pos_ticket = positionInfo.Ticket();
    long pos_type = positionInfo.PositionType();
    double current_sl = positionInfo.StopLoss();

    int atr_handle = iATR(_Symbol, _Period, S3_ATR_Period);
    double atr_buffer[];
    if(CopyBuffer(atr_handle, 0, 0, 1, atr_buffer) < 1) return;
    double atr_value = atr_buffer[0];

    double new_sl = 0;

    symbolInfo.RefreshRates();
    if(pos_type == POSITION_TYPE_BUY)
    {
        new_sl = symbolInfo.Bid() - S3_ATR_Multiplier * atr_value;
        new_sl = NormalizeDouble(new_sl, (int)symbolInfo.Digits());
        if(current_sl == 0 || new_sl > current_sl)
        {
            if(new_sl < symbolInfo.Bid())
            {
                trade.PositionModify(pos_ticket, new_sl, positionInfo.TakeProfit());
            }
        }
    }
    else if(pos_type == POSITION_TYPE_SELL)
    {
        new_sl = symbolInfo.Ask() + S3_ATR_Multiplier * atr_value;
        new_sl = NormalizeDouble(new_sl, (int)symbolInfo.Digits());
        if(current_sl == 0 || new_sl < current_sl)
        {
            if(new_sl > symbolInfo.Ask())
            {
                trade.PositionModify(pos_ticket, new_sl, positionInfo.TakeProfit());
            }
        }
    }
}
//+------------------------------------------------------------------+
//| Helper Functions                                                 |
//+------------------------------------------------------------------+
void CancelPendingOrders(int magic)
{
    for(int i = OrdersTotal() - 1; i >= 0; i--)
    {
        ulong ticket = OrderGetTicket(i);
        if(orderInfo.Select(ticket))
        {
            if(orderInfo.Symbol() == _Symbol && orderInfo.Magic() == magic)
            {
                trade.OrderDelete(ticket);
            }
        }
    }
}

bool OrderSelectByMagic(string symbol, int magic)
{
    for(int i = OrdersTotal() - 1; i >= 0; i--)
    {
        if(orderInfo.Select(OrderGetTicket(i)))
        {
            if(orderInfo.Symbol() == symbol && orderInfo.Magic() == magic)
            {
                return true;
            }
        }
    }
    return false;
}

bool PositionSelectByMagic(string symbol, int magic)
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(positionInfo.SelectByIndex(i))
        {
            if(positionInfo.Symbol() == symbol && positionInfo.Magic() == magic)
            {
                return true;
            }
        }
    }
    return false;
}
//+------------------------------------------------------------------+
