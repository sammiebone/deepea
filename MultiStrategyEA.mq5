//+------------------------------------------------------------------+
//|                                               MultiStrategyEA.mq5|
//|                        Copyright 2025, Your Name & Co. |
//|                           https://www.yourwebsite.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, Your Name & Co."
#property link      "https://www.yourwebsite.com"
#property version   "1.00"
#property description "A multi-strategy Expert Advisor."

//+------------------------------------------------------------------+
//| EA Logic Overview                                                |
//+------------------------------------------------------------------+
/*
This Expert Advisor is designed to trade multiple strategies concurrently.
Each strategy operates independently, identified by a unique "Magic Number".

The main logic runs inside the OnTick() event handler, but only on the
formation of a new bar to conserve resources.

- Strategy 1: Market Structure & Breakout Trading
  - Identifies consolidation below the previous day's high (PDH) or above the
    previous day's low (PDL).
  - Places pending stop orders (Buy Stop/Sell Stop) to catch breakouts.
  - Risk management is a fixed Stop Loss (at the opposite side of the range)
    and a Risk:Reward based Take Profit.

- Strategy 2: Momentum Divergence with Macro-Filter
  - Detects regular bullish and bearish divergence between price and the RSI.
  - Confirms signals with a macro filter based on the DXY (US Dollar Index) trend.
  - Enters with a market order upon confirmation.
  - Stop Loss is placed at the recent swing point that formed the divergence.

- Strategy 3: Volatility Squeeze Explosion
  - Uses Bollinger Bands BandWidth to identify periods of very low volatility (a "squeeze").
  - Triggers a market order when the price breaks out of the bands during a squeeze,
    confirmed by the CCI indicator.
  - Manages open positions with a dynamic ATR-based Trailing Stop Loss to ride trends.

Each strategy can be enabled or disabled via the input parameters.
*/

//--- Include libraries
#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//--- Global variables
CTrade trade;
CSymbolInfo symbolInfo;
CPositionInfo positionInfo;
COrderInfo orderInfo;

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
input double S1_Lots              = 0.01;   // Lot size for Strategy 1

//--- Input Parameters for Strategy 2: Momentum Divergence
input group "S2: Momentum Divergence"
input int    S2_RSI_Period         = 21;      // RSI period for divergence
input string S2_DXY_Symbol         = "DXY";   // Symbol for DXY index (if available)
input ENUM_TIMEFRAMES S2_DXY_Timeframe = PERIOD_D1; // Timeframe for DXY trend
input int    S2_DXY_MA_Period      = 50;      // MA period for DXY trend
input double S2_Lots               = 0.01;    // Lot size for Strategy 2
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
input double S3_Lots                = 0.01;    // Lot size for Strategy 3
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

   printf("MultiStrategyEA Initialized. Strategies Enabled: S1=%s, S2=%s, S3=%s",
          (string)EnableStrategy1, (string)EnableStrategy2, (string)EnableStrategy3);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   //--- Deinitialization
   printf("MultiStrategyEA Deinitialized. Reason: %d", reason);
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
   //--- Check for new bar
   static datetime lastBarTime = 0;
   datetime currentBarTime = (datetime)SeriesInfoInteger(_Symbol, _Period, SERIES_LAST_BAR_TIME);
   if(currentBarTime == lastBarTime)
     {
      return; // Not a new bar, exit
     }
   lastBarTime = currentBarTime;

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
//| Strategy 1: Market Structure & Breakout Trading                  |
//+------------------------------------------------------------------+
void CheckStrategy1()
{
    //--- Only check for new trades if no position or order for this strategy exists
    if(PositionSelectByMagic(_Symbol, MAGIC_S1) || OrderSelectByMagic(_Symbol, MAGIC_S1))
    {
        return;
    }

    // 1. Identify Key Levels: PDH, PDL
    double pdh_arr[], pdl_arr[];
    if(CopyHigh(_Symbol, PERIOD_D1, 1, 1, pdh_arr) < 1 || CopyLow(_Symbol, PERIOD_D1, 1, 1, pdl_arr) < 1)
    {
        printf("S1: Could not retrieve previous day's H/L. Waiting for more data.");
        return;
    }
    double pdh = pdh_arr[0];
    double pdl = pdl_arr[0];

    // 2. Get recent bars for consolidation check (we check the bars *before* the current one)
    MqlRates rates[];
    if(CopyRates(_Symbol, _Period, 1, S1_ConsolidationBars, rates) < S1_ConsolidationBars)
    {
        printf("S1: Not enough bars for consolidation analysis.");
        return;
    }

    // 3. The Setup
    double pip_size = symbolInfo.Pip();

    //--- Long Signal: Price consolidates below the PDH
    bool long_consolidation = true;
    for(int i = 0; i < S1_ConsolidationBars; i++)
    {
        if(rates[i].high >= pdh)
        {
            long_consolidation = false;
            break;
        }
    }

    if(long_consolidation)
    {
        // Place Buy Stop Order
        double entry_price = pdh + S1_BuyStopPips * pip_size;
        entry_price = NormalizeDouble(entry_price, (int)symbolInfo.Digits());
        double stop_loss = pdl;
        double take_profit = entry_price + (entry_price - stop_loss) * S1_RR_Ratio;
        take_profit = NormalizeDouble(take_profit, (int)symbolInfo.Digits());

        trade.SetExpertMagicNumber(MAGIC_S1);
        trade.BuyStop(S1_Lots, entry_price, _Symbol, stop_loss, take_profit, ORDER_TIME_GTC, 0, "S1 BuyStop");
        // Note: The volume confirmation on the breakout bar is not possible with a pending order.
        // This EA places the pending order based on consolidation and lets the broker handle the trigger.
        return;
    }

    //--- Short Signal: Price consolidates above the PDL
    bool short_consolidation = true;
    for(int i = 0; i < S1_ConsolidationBars; i++)
    {
        if(rates[i].low <= pdl)
        {
            short_consolidation = false;
            break;
        }
    }

    if(short_consolidation)
    {
        // Place Sell Stop Order
        double entry_price = pdl - S1_SellStopPips * pip_size;
        entry_price = NormalizeDouble(entry_price, (int)symbolInfo.Digits());
        double stop_loss = pdh;
        double take_profit = entry_price - (stop_loss - entry_price) * S1_RR_Ratio;
        take_profit = NormalizeDouble(take_profit, (int)symbolInfo.Digits());

        trade.SetExpertMagicNumber(MAGIC_S1);
        trade.SellStop(S1_Lots, entry_price, _Symbol, stop_loss, take_profit, ORDER_TIME_GTC, 0, "S1 SellStop");
        return;
    }
}


//+------------------------------------------------------------------+
//| Strategy 2: Momentum Divergence with Macro-Filter                |
//+------------------------------------------------------------------+
void CheckStrategy2()
{
    //--- Only check for new trades if no position for this strategy exists
    if(PositionSelectByMagic(_Symbol, MAGIC_S2)) return;

    // 1. Detect Divergence on the bars that just closed (starting from bar 1)
    int divergence_pivot_shift = findDivergence(S2_DivergenceLookback, 1);

    if(divergence_pivot_shift == 0) return; // No divergence found

    // 2. The Macro Filter (DXY)
    if(!CheckDXYFilter(divergence_pivot_shift)) return;

    // 3. Entry
    // Bullish divergence was found
    if(divergence_pivot_shift > 0)
    {
        double stop_loss = iLow(_Symbol, _Period, divergence_pivot_shift) - S2_SL_Pips_Buffer * symbolInfo.Pip();
        stop_loss = NormalizeDouble(stop_loss, (int)symbolInfo.Digits());

        trade.SetExpertMagicNumber(MAGIC_S2);
        trade.Buy(S2_Lots, _Symbol, 0, stop_loss, 0, "S2 Buy");
    }
    // Bearish divergence was found
    else
    {
        double stop_loss = iHigh(_Symbol, _Period, MathAbs(divergence_pivot_shift)) + S2_SL_Pips_Buffer * symbolInfo.Pip();
        stop_loss = NormalizeDouble(stop_loss, (int)symbolInfo.Digits());

        trade.SetExpertMagicNumber(MAGIC_S2);
        trade.Sell(S2_Lots, _Symbol, 0, stop_loss, 0, "S2 Sell");
    }
}

// Returns shift of the second pivot point (>0 for bullish, <0 for bearish, 0 for none)
int findDivergence(int lookback, int start_shift)
{
    double rsi_buffer[];
    int rsi_handle = iRSI(_Symbol, _Period, S2_RSI_Period, PRICE_CLOSE);
    if(CopyBuffer(rsi_handle, start_shift, lookback, rsi_buffer) < lookback)
    {
        printf("S2: Could not copy RSI buffer.");
        return 0;
    }

    // --- Bullish Divergence Check ---
    int p2_lookback = lookback / 3;
    int p2_shift = iLowest(_Symbol, _Period, p2_lookback, start_shift);

    int p1_lookback = lookback - (p2_shift - start_shift);
    int p1_shift = iLowest(_Symbol, _Period, p1_lookback, p2_shift + 1);

    if(p1_shift > 0 && p2_shift > 0)
    {
        double price1 = iLow(_Symbol, _Period, p1_shift);
        double price2 = iLow(_Symbol, _Period, p2_shift);
        double rsi1 = rsi_buffer[p1_shift - start_shift];
        double rsi2 = rsi_buffer[p2_shift - start_shift];

        if(price2 < price1 && rsi2 > rsi1)
        {
            printf("S2: Bullish Divergence found. P1 at bar %d, P2 at bar %d", p1_shift, p2_shift);
            return p2_shift;
        }
    }

    // --- Bearish Divergence Check ---
    p2_shift = iHighest(_Symbol, _Period, p2_lookback, start_shift);
    p1_shift = iHighest(_Symbol, _Period, p1_lookback, p2_shift + 1);

    if(p1_shift > 0 && p2_shift > 0)
    {
        double price1 = iHigh(_Symbol, _Period, p1_shift);
        double price2 = iHigh(_Symbol, _Period, p2_shift);
        double rsi1 = rsi_buffer[p1_shift - start_shift];
        double rsi2 = rsi_buffer[p2_shift - start_shift];

        if(price2 > price1 && rsi2 < rsi1)
        {
            printf("S2: Bearish Divergence found. P1 at bar %d, P2 at bar %d", p1_shift, p2_shift);
            return -p2_shift; // Negative for bearish
        }
    }

    return 0;
}

bool CheckDXYFilter(int divergence_type)
{
    if(S2_DXY_Symbol == "") return true; // No filter if symbol is not set

    if(!SymbolSelect(S2_DXY_Symbol, true))
    {
        printf("S2: DXY Symbol '%s' not found or not visible in Market Watch. Filter inactive.", S2_DXY_Symbol);
        return true; // Return true to not block trades if DXY is unavailable
    }

    double dxy_ma_handle = iMA(S2_DXY_Symbol, S2_DXY_Timeframe, S2_DXY_MA_Period, 0, MODE_SMA, PRICE_CLOSE);
    double dxy_ma_buffer[];
    if(CopyBuffer(dxy_ma_handle, 0, 1, dxy_ma_buffer) < 1)
    {
        printf("S2: Could not get DXY MA value. Filter inactive.");
        return true; // Return true to not block trades if data is unavailable
    }
    double dxy_close = iClose(S2_DXY_Symbol, S2_DXY_Timeframe, 0);
    if(dxy_close == 0)
    {
        printf("S2: Could not get DXY Close price. Filter inactive.");
        return true;
    }

    bool dxy_trending_up = dxy_close > dxy_ma_buffer[0];
    bool dxy_trending_down = dxy_close < dxy_ma_buffer[0];

    // Bullish divergence (we want to buy)
    if(divergence_type > 0)
    {
        // Filter: Only take signal if DXY is moving DOWN
        return dxy_trending_down;
    }
    // Bearish divergence (we want to sell)
    else
    {
        // Filter: Only take signal if DXY is moving UP
        return dxy_trending_up;
    }

    return false;
}

//+------------------------------------------------------------------+
//| Strategy 3: Volatility Squeeze Explosion                         |
//+------------------------------------------------------------------+
void CheckStrategy3()
{
    //--- Only check for new trades if no position for this strategy exists
    if(PositionSelectByMagic(_Symbol, MAGIC_S3)) return;

    // 1. Get Indicator Handles
    int bb_handle = iBands(_Symbol, _Period, S3_BB_Period, 0, S3_BB_Deviations, PRICE_CLOSE);
    int cci_handle = iCCI(_Symbol, _Period, S3_CCI_Period, PRICE_TYPICAL);

    // 2. Get Indicator Values for the most recently closed bar (shift 1)
    double upper_bb[], lower_bb[], middle_bb[];
    if(CopyBuffer(bb_handle, 1, 1, 1, upper_bb) < 1 ||
       CopyBuffer(bb_handle, 2, 1, 1, lower_bb) < 1 ||
       CopyBuffer(bb_handle, 0, 1, 1, middle_bb) < 1) return;

    double cci_val[];
    if(CopyBuffer(cci_handle, 0, 1, 1, cci_val) < 1) return;

    // 3. Calculate BandWidth and its MA
    double hist_upper[], hist_lower[], hist_middle[];
    if(CopyBuffer(bb_handle, 1, 1, S3_BandWidth_MAPeriod, hist_upper) < S3_BandWidth_MAPeriod ||
       CopyBuffer(bb_handle, 2, 1, S3_BandWidth_MAPeriod, hist_lower) < S3_BandWidth_MAPeriod ||
       CopyBuffer(bb_handle, 0, 1, S3_BandWidth_MAPeriod, hist_middle) < S3_BandWidth_MAPeriod) return;

    double bandwidth_sum = 0;
    int valid_bars = 0;
    for(int i=0; i < S3_BandWidth_MAPeriod; i++)
    {
        if(hist_middle[i] != 0)
        {
            bandwidth_sum += (hist_upper[i] - hist_lower[i]) / hist_middle[i];
            valid_bars++;
        }
    }
    if(valid_bars == 0) return;
    double avg_bandwidth = bandwidth_sum / valid_bars;
    double current_bandwidth = (middle_bb[0] != 0) ? (upper_bb[0] - lower_bb[0]) / middle_bb[0] : 0;

    // 4. Detect the Squeeze on the last closed bar
    if(current_bandwidth == 0 || current_bandwidth > avg_bandwidth * S3_Squeeze_Threshold) return;

    // 5. The Trigger and Confirmation
    MqlRates rates[];
    if(CopyRates(_Symbol, _Period, 1, 1, rates) < 1) return;
    double close_price = rates[0].close;

    // --- Long Trigger ---
    if(close_price > upper_bb[0] && cci_val[0] > S3_CCI_Threshold)
    {
        double stop_loss = lower_bb[0];
        trade.SetExpertMagicNumber(MAGIC_S3);
        trade.Buy(S3_Lots, _Symbol, 0, stop_loss, 0, "S3 Buy");
        return;
    }

    // --- Short Trigger ---
    if(close_price < lower_bb[0] && cci_val[0] < -S3_CCI_Threshold)
    {
        double stop_loss = upper_bb[0];
        trade.SetExpertMagicNumber(MAGIC_S3);
        trade.Sell(S3_Lots, _Symbol, 0, stop_loss, 0, "S3 Sell");
        return;
    }
}

void ManageStrategy3_TSL()
{
    if(!PositionSelectByMagic(_Symbol, MAGIC_S3)) return;

    long pos_ticket = positionInfo.TicketNumber();
    long pos_type = positionInfo.PositionType();
    double current_sl = positionInfo.StopLoss();

    int atr_handle = iATR(_Symbol, _Period, S3_ATR_Period);
    double atr_buffer[];
    if(CopyBuffer(atr_handle, 0, 1, 1, atr_buffer) < 1) return;
    double atr_value = atr_buffer[0];

    double new_sl = 0;

    if(pos_type == POSITION_TYPE_BUY)
    {
        new_sl = _Symbol.Bid() - S3_ATR_Multiplier * atr_value;
        new_sl = NormalizeDouble(new_sl, (int)symbolInfo.Digits());
        if(current_sl == 0 || new_sl > current_sl)
        {
            if(new_sl < _Symbol.Bid())
            {
                trade.PositionModify(pos_ticket, new_sl, positionInfo.TakeProfit());
            }
        }
    }
    else if(pos_type == POSITION_TYPE_SELL)
    {
        new_sl = _Symbol.Ask() + S3_ATR_Multiplier * atr_value;
        new_sl = NormalizeDouble(new_sl, (int)symbolInfo.Digits());
        if(current_sl == 0 || new_sl < current_sl)
        {
            if(new_sl > _Symbol.Ask())
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
