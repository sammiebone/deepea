//+------------------------------------------------------------------+
//|                                               XAU_Quantum_EA.mq5 |
//|                           Copyright 2025, Quantum Dynamics Labs  |
//|                                    https://www.quantumdynamics.ai|
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, Quantum Dynamics Labs"
#property link      "https://www.quantumdynamics.ai"
#property version   "2.00" // New, incremental build
#property description "A multi-strategy, volatility-aware EA for Gold (XAU)."

//--- Include libraries
#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>
#include <Trade\AccountInfo.mqh>

//--- Global variables & objects
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
input int    S1_ConsolidationBars   = 4;      // Number of bars for consolidation
input double S1_BreakoutPips        = 2.0;    // Pips beyond level for breakout
input double S1_RR_Ratio            = 1.5;    // Risk:Reward Ratio for TP
input double S1_VolumeMultiplier    = 1.5;    // Breakout volume must be X times average
input int    S1_AvgVolumePeriod     = 20;     // Period for average volume calculation

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
input int    S3_BandWidth_MAPeriod  = 50;      // Period to determine historical low BBW
input int    S3_CCI_Period          = 14;      // CCI period for confirmation
input double S3_CCI_Threshold       = 100;     // CCI threshold for entry
input int    S3_ATR_Period          = 14;      // ATR period for trailing stop
input double S3_ATR_Multiplier      = 2.5;     // ATR multiplier for trailing stop

//--- Magic Numbers for each strategy
#define MAGIC_S1 1001
#define MAGIC_S2 1002
#define MAGIC_S3 1003

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   if(!symbolInfo.Name(_Symbol)) return(INIT_FAILED);
   trade.SetExpertMagicNumber(0);
   trade.SetMarginMode();
   trade.SetTypeFillingBySymbol(_Symbol);

   printf("XAU_Quantum_EA Initialized.");

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
   printf("XAU_Quantum_EA Deinitialized. Reason: %d", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   if(g_trading_halted) return;

   //--- New Bar/Tick Logic ---
   // S1 needs to check every tick for breakouts. Other strategies are new-bar only.
   static datetime lastBarTime = 0;
   datetime currentBarTime = (datetime)SeriesInfoInteger(_Symbol, _Period, SERIES_LASTBAR_DATE);
   bool isNewBar = (currentBarTime != lastBarTime);
   if(isNewBar)
   {
       lastBarTime = currentBarTime;
   }

   //--- FRAMEWORK CHECKS (Run on every tick) ---
   ManageEquityTrail();
   if(g_trading_halted) return;
   CheckTimeStop();

   //--- STRATEGY EXECUTION ---
   if(EnableStrategy1) CheckStrategy1(); // Runs on every tick

   if(isNewBar) // These strategies only run on new bars
   {
      if(!IsTimeAllowed()) return;
      if(!IsVolatilityAllowed()) return;

      if(EnableStrategy2) CheckStrategy2();
      if(EnableStrategy3)
      {
         ManageStrategy3_TSL();
         CheckStrategy3();
      }
   }
}

//+------------------------------------------------------------------+
//| Risk Management & Filter Functions                               |
//+------------------------------------------------------------------+
void ManageEquityTrail()
{
    if(!EnableEquityTrail || g_trading_halted) return;
    accountInfo.Refresh();
    double current_equity = accountInfo.Equity();
    if(current_equity > g_peak_equity) g_peak_equity = current_equity;

    if (g_peak_equity > 0)
    {
        double drawdown_percent = ((g_peak_equity - current_equity) / g_peak_equity) * 100.0;
        if(drawdown_percent >= EquityTrailPercent)
        {
            g_trading_halted = true;
            string message = StringFormat("EQUITY TRAIL TRIGGERED! Trading has been halted. Peak: %.2f, Current: %.2f, DD: %.2f%%",
                                          g_peak_equity, current_equity, drawdown_percent);
            printf(message);
            Alert(message);
            for(int i = PositionsTotal() - 1; i >= 0; i--)
            {
                if(positionInfo.SelectByIndex(i) && (positionInfo.Magic() == MAGIC_S1 || positionInfo.Magic() == MAGIC_S2 || positionInfo.Magic() == MAGIC_S3))
                {
                    trade.PositionClose(positionInfo.Ticket());
                }
            }
        }
    }
}
//+------------------------------------------------------------------+
double CalculateLotSize(double stop_loss_price)
{
    if(!EnableDynamicLots) return 0.01;
    accountInfo.Refresh();
    symbolInfo.Refresh();
    double account_balance = accountInfo.Balance();
    double risk_amount = account_balance * (RiskPercent / 100.0);

    symbolInfo.RefreshRates();
    double entry_price = stop_loss_price > symbolInfo.Ask() ? symbolInfo.Bid() : symbolInfo.Ask();
    double sl_distance = MathAbs(entry_price - stop_loss_price);

    if(sl_distance <= 0) return 0.0;

    double tick_value = symbolInfo.TickValue();
    double tick_size = symbolInfo.TickSize();
    if(tick_value <= 0 || tick_size <= 0) return 0.0;

    double sl_value_per_lot = (sl_distance / tick_size) * tick_value;
    if(sl_value_per_lot <= 0) return 0.0;

    double lot_size = risk_amount / sl_value_per_lot;

    lot_size = NormalizeDouble(lot_size, 2);
    double min_lot = symbolInfo.LotsMin();
    double max_lot = symbolInfo.LotsMax();
    double lot_step = symbolInfo.LotsStep();

    if(lot_size < min_lot) lot_size = min_lot;
    if(lot_size > max_lot) lot_size = max_lot;

    lot_size = MathFloor(lot_size / lot_step) * lot_step;
    return lot_size;
}
//+------------------------------------------------------------------+
void CheckTimeStop()
{
    if(!EnableTimeStop) return;
    MqlDateTime time_struct;
    TimeCurrent(time_struct);

    if(time_struct.hour > TimeStopHour || (time_struct.hour == TimeStopHour && time_struct.min >= TimeStopMinute))
    {
        for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
            if(positionInfo.SelectByIndex(i) && (positionInfo.Magic() == MAGIC_S1 || positionInfo.Magic() == MAGIC_S2 || positionInfo.Magic() == MAGIC_S3))
            {
                trade.PositionClose(positionInfo.Ticket());
            }
        }
    }
}
//+------------------------------------------------------------------+
bool IsTimeAllowed()
{
    if(!EnableTimeFilter) return true;
    MqlDateTime time_struct;
    TimeCurrent(time_struct);
    int current_hour = time_struct.hour;

    if(StartTime < EndTime) return (current_hour >= StartTime && current_hour < EndTime);
    else return (current_hour >= StartTime || current_hour < EndTime);
}
//+------------------------------------------------------------------+
bool IsVolatilityAllowed()
{
    if(!EnableAtrFilter) return true;
    int atr_handle = iATR(_Symbol, PERIOD_D1, AtrFilterPeriod);
    double atr_buffer[];
    if(CopyBuffer(atr_handle, 0, 0, 1, atr_buffer) < 1) return true;

    symbolInfo.Refresh();
    double atr_in_pips = atr_buffer[0] / symbolInfo.Pip();

    if(atr_in_pips < MinAtrPips || atr_in_pips > MaxAtrPips) return false;

    return true;
}

//+------------------------------------------------------------------+
//|              S T R A T E G Y   F U N C T I O N S                 |
//+------------------------------------------------------------------+
void CheckStrategy1()
{
    // This strategy runs on every tick to catch breakouts in real-time.
    if(PositionSelectByMagic(_Symbol, MAGIC_S1)) return; // Position already open for this strategy

    // --- 1. Get Key Levels ---
    static double pdh = 0, pdl = 0;
    static datetime last_levels_update = 0;
    datetime current_day = (datetime)SeriesInfoInteger(_Symbol, PERIOD_D1, SERIES_LASTBAR_DATE);

    // Update levels once per day
    if(current_day != last_levels_update)
    {
        pdh = iHigh(_Symbol, PERIOD_D1, 1);
        pdl = iLow(_Symbol, PERIOD_D1, 1);
        last_levels_update = current_day;
        if(pdh == 0 || pdl == 0) return; // Not enough history yet
    }

    if(pdh == 0 || pdl == 0) return; // Levels not initialized

    // --- 2. Check for Breakout ---
    symbolInfo.RefreshRates();
    double ask = symbolInfo.Ask();
    double bid = symbolInfo.Bid();

    static double prev_ask = 0;
    static double prev_bid = 0;

    // Ensure we have previous tick prices to detect a cross
    if(prev_ask == 0 || prev_bid == 0)
    {
        prev_ask = ask;
        prev_bid = bid;
        return;
    }

    // --- 3. Long Breakout Logic ---
    if(ask > pdh && prev_ask <= pdh) // Price just crossed above PDH
    {
        // --- 4. Volume Confirmation ---
        long volume_hist[];
        if(CopyRealVolume(_Symbol, _Period, 0, S1_AvgVolumePeriod + 1, volume_hist) > S1_AvgVolumePeriod)
        {
            long current_volume = volume_hist[S1_AvgVolumePeriod];
            long avg_volume = 0;
            for(int i=0; i<S1_AvgVolumePeriod; i++) avg_volume += volume_hist[i];
            avg_volume /= S1_AvgVolumePeriod;

            if(current_volume > avg_volume * S1_VolumeMultiplier)
            {
                // --- 5. Execute Trade ---
                double stop_loss = pdl;
                double take_profit = ask + (ask - stop_loss) * S1_RR_Ratio;
                double lots = CalculateLotSize(stop_loss);

                if(lots > 0)
                {
                    trade.SetExpertMagicNumber(MAGIC_S1);
                    trade.Buy(lots, _Symbol, ask, stop_loss, take_profit, "S1 Buy");
                }
            }
        }
    }

    // --- 3. Short Breakout Logic ---
    if(bid < pdl && prev_bid >= pdl) // Price just crossed below PDL
    {
        // --- 4. Volume Confirmation ---
        long volume_hist[];
        if(CopyRealVolume(_Symbol, _Period, 0, S1_AvgVolumePeriod + 1, volume_hist) > S1_AvgVolumePeriod)
        {
            long current_volume = volume_hist[S1_AvgVolumePeriod];
            long avg_volume = 0;
            for(int i=0; i<S1_AvgVolumePeriod; i++) avg_volume += volume_hist[i];
            avg_volume /= S1_AvgVolumePeriod;

            if(current_volume > avg_volume * S1_VolumeMultiplier)
            {
                // --- 5. Execute Trade ---
                double stop_loss = pdh;
                double take_profit = bid - (stop_loss - bid) * S1_RR_Ratio;
                double lots = CalculateLotSize(stop_loss);

                if(lots > 0)
                {
                    trade.SetExpertMagicNumber(MAGIC_S1);
                    trade.Sell(lots, _Symbol, bid, stop_loss, take_profit, "S1 Sell");
                }
            }
        }
    }

    // Update previous prices for the next tick
    prev_ask = ask;
    prev_bid = bid;
}
//+------------------------------------------------------------------+
void CheckStrategy2()
{
    if(PositionSelectByMagic(_Symbol, MAGIC_S2)) return;

    int divergence_pivot_shift = findDivergence(1); // Check from the last closed bar
    if(divergence_pivot_shift == 0) return;

    if(!CheckDXYFilter(divergence_pivot_shift)) return;

    if(divergence_pivot_shift > 0) // Bullish
    {
        double stop_loss = iLow(_Symbol, _Period, divergence_pivot_shift) - S2_SL_Pips_Buffer * symbolInfo.Pip();
        double lots = CalculateLotSize(stop_loss);
        if(lots > 0)
        {
            trade.SetExpertMagicNumber(MAGIC_S2);
            trade.Buy(lots, _Symbol, 0, stop_loss, 0, "S2 Buy");
        }
    }
    else // Bearish
    {
        double stop_loss = iHigh(_Symbol, _Period, MathAbs(divergence_pivot_shift)) + S2_SL_Pips_Buffer * symbolInfo.Pip();
        double lots = CalculateLotSize(stop_loss);
        if(lots > 0)
        {
            trade.SetExpertMagicNumber(MAGIC_S2);
            trade.Sell(lots, _Symbol, 0, stop_loss, 0, "S2 Sell");
        }
    }
}
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
        double lots = CalculateLotSize(stop_loss);
        if(lots > 0)
        {
            trade.SetExpertMagicNumber(MAGIC_S3);
            trade.Buy(lots, _Symbol, 0, stop_loss, 0, "S3 Buy");
        }
        return;
    }

    // --- Short Trigger ---
    if(close_price < hist_lower[0] && cci_val[0] < -S3_CCI_Threshold)
    {
        double stop_loss = hist_upper[0];
        double lots = CalculateLotSize(stop_loss);
        if(lots > 0)
        {
            trade.SetExpertMagicNumber(MAGIC_S3);
            trade.Sell(lots, _Symbol, 0, stop_loss, 0, "S3 Sell");
        }
        return;
    }
}
//+------------------------------------------------------------------+
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
//|                  H E L P E R   F U N C T I O N S                 |
//+------------------------------------------------------------------+
int findDivergence(int start_shift)
{
    // Note on Logic: This is a simplified divergence detection function.
    double rsi_buffer[];
    int rsi_handle = iRSI(_Symbol, _Period, S2_RSI_Period, PRICE_CLOSE);
    if(CopyBuffer(rsi_handle, 0, start_shift, S2_DivergenceLookback, rsi_buffer) < S2_DivergenceLookback) return 0;

    int p2_lookback = S2_DivergenceLookback / 3;
    int p2_shift = iLowest(_Symbol, _Period, MODE_LOW, p2_lookback, start_shift);
    int p1_lookback = S2_DivergenceLookback - (p2_shift - start_shift);
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
//+------------------------------------------------------------------+
bool CheckDXYFilter(int divergence_type)
{
    if(S2_DXY_Symbol == "") return true;
    if(!SymbolSelect(S2_DXY_Symbol, true)) return true;

    double dxy_ma_buffer[];
    int dxy_ma_handle = iMA(S2_DXY_Symbol, S2_DXY_Timeframe, S2_DXY_MA_Period, 0, MODE_SMA, PRICE_CLOSE);
    if(CopyBuffer(dxy_ma_handle, 0, 0, 1, dxy_ma_buffer) < 1) return true;

    double dxy_close = iClose(S2_DXY_Symbol, S2_DXY_Timeframe, 0);
    if(dxy_close == 0) return true;

    bool dxy_trending_up = dxy_close > dxy_ma_buffer[0];
    bool dxy_trending_down = dxy_close < dxy_ma_buffer[0];

    if(divergence_type > 0) return dxy_trending_down;
    else return dxy_trending_up;
}
//+------------------------------------------------------------------+
