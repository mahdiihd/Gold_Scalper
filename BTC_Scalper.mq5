#property strict
#property version "1.10"

#include <Trade/Trade.mqh>
CTrade trade;

//================ INPUTS =================
input double BaseLot        = 0.01;  // first order volume per side
input double LotStep        = 0.01;  // used in FIXED_STEP mode
input double MaxLot         = 0.20;

input int    ATR_Period     = 14;
input double ATR_Mult       = 0.6;
input int    MinDistPoints  = 500;

input double BalancePctTP   = 0.4;
input double MinTPUSD       = 5.0;

input ulong  Magic          = 202512;

// Volume leveling
enum VOLUME_MODE
{
   VOLUME_FIXED_STEP = 0,     // next = last + LotStep
   VOLUME_MULTIPLIER = 1,     // next = last * LotMult
   VOLUME_RISK_PER_STEP = 2   // next = lot sized so 1 step adverse move ~= RiskPctPerStep% equity
};
input VOLUME_MODE VolumeMode = VOLUME_FIXED_STEP;
input double      LotMult    = 1.25; // used in MULTIPLIER mode
input double      RiskPctPerStep = 0.10; // used in RISK_PER_STEP mode (percent)

// Smart/safety filters
input int    MaxSpreadPoints = 200;   // 0 = disabled
input int    MaxPositionsSide = 20;   // 0 = unlimited

//================ GLOBAL =================
double lastBuyLot=0,lastSellLot=0;
double lastBuyPrice=0,lastSellPrice=0;
double firstBuyProfit=0,lastBuyProfit=0;
double firstSellProfit=0,lastSellProfit=0;
int    buyCount=0, sellCount=0;
double buyProfitTotal=0, sellProfitTotal=0;

int g_atrHandle = INVALID_HANDLE;

//================ UTIL =================
bool IsMyPosition()
{
   return (PositionGetInteger(POSITION_MAGIC)==(long)Magic &&
           PositionGetString(POSITION_SYMBOL)==_Symbol);
}

double NormalizeVolume(double vol)
{
   const double vmin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double vmax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   const double vstep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(vstep<=0.0)
      return MathMax(vmin, MathMin(vmax, vol));

   vol = MathMax(vmin, MathMin(vmax, vol));
   vol = MathFloor(vol / vstep) * vstep;
   return NormalizeDouble(vol, (int)SymbolInfoInteger(_Symbol, SYMBOL_VOLUME_DIGITS));
}

double GetATR()
{
   if(g_atrHandle==INVALID_HANDLE)
      return 0.0;

   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(g_atrHandle, 0, 0, 1, buf) != 1)
      return 0.0;

   return buf[0];
}

double StepDistance()
{
   return MathMax(GetATR()*ATR_Mult, MinDistPoints*_Point);
}

double PointValuePerLot()
{
   // Value of 1 point (=_Point) move per 1.0 lot, in account currency.
   const double tick_val  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   const double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick_val<=0.0 || tick_size<=0.0) return 0.0;
   return (tick_val / tick_size) * _Point;
}

double RiskLotForStepDistance(const double distPrice)
{
   const double pv = PointValuePerLot();
   if(pv<=0.0) return 0.0;

   const double distPoints = distPrice / _Point;
   if(distPoints<=0.0) return 0.0;

   const double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   const double riskUsd = equity * (RiskPctPerStep/100.0);
   if(riskUsd<=0.0) return 0.0;

   // loss ~= distPoints * pv * lot  =>  lot ~= riskUsd / (distPoints * pv)
   return (riskUsd / (distPoints * pv));
}

bool SpreadOK()
{
   if(MaxSpreadPoints<=0) return true;
   const double spreadPts = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
   return (spreadPts <= (double)MaxSpreadPoints);
}

bool PositionsSideOK(const int count)
{
   if(MaxPositionsSide<=0) return true;
   return (count < MaxPositionsSide);
}

double NextLotForSide(const ENUM_POSITION_TYPE side, const bool isInitial)
{
   const double lastLot = (side==POSITION_TYPE_BUY) ? lastBuyLot : lastSellLot;

   if(isInitial || lastLot<=0.0)
      return BaseLot;

   if(VolumeMode==VOLUME_MULTIPLIER)
      return lastLot * LotMult;

   if(VolumeMode==VOLUME_RISK_PER_STEP)
   {
      const double riskLot = RiskLotForStepDistance(StepDistance());
      // keep it practical: never go below BaseLot when stepping
      return MathMax(BaseLot, riskLot);
   }

   // default: fixed step
   return lastLot + LotStep;
}

double Threshold()
{
   return MathMax(
      AccountInfoDouble(ACCOUNT_BALANCE)*BalancePctTP/100.0,
      MinTPUSD
   );
}

ENUM_ORDER_TYPE_FILLING GetFilling()
{
   int mode = (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);

   switch(mode)
   {
      case SYMBOL_FILLING_FOK:
         return ORDER_FILLING_FOK;
      case SYMBOL_FILLING_IOC:
         return ORDER_FILLING_IOC;
      default:
         return ORDER_FILLING_RETURN;
   }
}

bool SendOrder(ENUM_ORDER_TYPE type, double lot)
{
   lot = NormalizeVolume(lot);
   if(lot<=0.0)
   {
      Print("Order rejected: volume<=0 after normalize");
      return false;
   }

   bool ok=false;
   if(type==ORDER_TYPE_BUY)
      ok = trade.Buy(lot, _Symbol);
   else if(type==ORDER_TYPE_SELL)
      ok = trade.Sell(lot, _Symbol);

   if(!ok)
      Print("Order FAILED | retcode=", trade.ResultRetcode(), " desc=", trade.ResultRetcodeDescription());
   else
      Print("Order OK | order=", trade.ResultOrder(), " retcode=", trade.ResultRetcode());

   return ok;
}

//================ POSITION SCAN =================
void ScanPositions()
{
   lastBuyLot=lastSellLot=0;
   lastBuyPrice=lastSellPrice=0;
   firstBuyProfit=lastBuyProfit=0;
   firstSellProfit=lastSellProfit=0;
   buyCount=0;
   sellCount=0;
   buyProfitTotal=0;
   sellProfitTotal=0;

   datetime buyEarliest=0, buyLatest=0;
   datetime sellEarliest=0, sellLatest=0;

   for(int i=0;i<PositionsTotal();i++)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(!IsMyPosition()) continue;

      const long type = PositionGetInteger(POSITION_TYPE);
      const double profit = PositionGetDouble(POSITION_PROFIT);
      const double lot    = PositionGetDouble(POSITION_VOLUME);
      const double price  = PositionGetDouble(POSITION_PRICE_OPEN);
      const datetime t    = (datetime)PositionGetInteger(POSITION_TIME);

      if(type==POSITION_TYPE_BUY)
      {
         buyCount++;
         buyProfitTotal += profit;

         if(buyEarliest==0 || t<buyEarliest)
         {
            buyEarliest=t;
            firstBuyProfit=profit;
         }

         if(buyLatest==0 || t>buyLatest)
         {
            buyLatest=t;
            lastBuyProfit=profit;
            lastBuyLot=lot;
            lastBuyPrice=price;
         }
      }
      else if(type==POSITION_TYPE_SELL)
      {
         sellCount++;
         sellProfitTotal += profit;

         if(sellEarliest==0 || t<sellEarliest)
         {
            sellEarliest=t;
            firstSellProfit=profit;
         }

         if(sellLatest==0 || t>sellLatest)
         {
            sellLatest=t;
            lastSellProfit=profit;
            lastSellLot=lot;
            lastSellPrice=price;
         }
      }
   }
}

//================ OPEN =================
void OpenBuy(double lot)
{
   if(lot>MaxLot) lot=MaxLot;
   SendOrder(ORDER_TYPE_BUY, lot);
}

void OpenSell(double lot)
{
   if(lot>MaxLot) lot=MaxLot;
   SendOrder(ORDER_TYPE_SELL, lot);
}

//================ STEP LOGIC =================
void CheckSteps()
{
   const double dist = StepDistance();
   const double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // BUY side (only add if latest buy is in drawdown)
   if(lastBuyLot>0 && lastBuyProfit<0)
   {
      // add only if price moved AGAINST buys (down) by dist
      if(PositionsSideOK(buyCount) && bid <= (lastBuyPrice - dist))
         OpenBuy(NextLotForSide(POSITION_TYPE_BUY, false));
   }

   // SELL side (only add if latest sell is in drawdown)
   if(lastSellLot>0 && lastSellProfit<0)
   {
      // add only if price moved AGAINST sells (up) by dist
      if(PositionsSideOK(sellCount) && ask >= (lastSellPrice + dist))
         OpenSell(NextLotForSide(POSITION_TYPE_SELL, false));
   }
}

//================ EXIT =================
void CloseSide(ENUM_POSITION_TYPE type)
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(!IsMyPosition()) continue;

      if(PositionGetInteger(POSITION_TYPE)==type)
         trade.PositionClose(ticket);
   }
}

void CheckExit()
{
   const double th = Threshold();

   // smarter: exit based on TOTAL profit per side
   if(buyCount>0 && buyProfitTotal >= th)
      CloseSide(POSITION_TYPE_BUY);

   if(sellCount>0 && sellProfitTotal >= th)
      CloseSide(POSITION_TYPE_SELL);
}

//================ INFO =================
void DrawInfo()
{
   const double nextBuyLot  = NormalizeVolume(MathMin(MaxLot, NextLotForSide(POSITION_TYPE_BUY, (buyCount==0))));
   const double nextSellLot = NormalizeVolume(MathMin(MaxLot, NextLotForSide(POSITION_TYPE_SELL, (sellCount==0))));

   Comment(
      "BUY (", buyCount, "):\n",
      "  Last Lot: ",DoubleToString(lastBuyLot,2),
      "\n  Next Lot: ",DoubleToString(nextBuyLot,2),
      "\n  First Profit: ",DoubleToString(firstBuyProfit,2),
      "\n  Last Profit: ",DoubleToString(lastBuyProfit,2),
      "\n  Profit Total: ",DoubleToString(buyProfitTotal,2),
      "\n\nSELL (", sellCount, "):\n",
      "  Last Lot: ",DoubleToString(lastSellLot,2),
      "\n  Next Lot: ",DoubleToString(nextSellLot,2),
      "\n  First Profit: ",DoubleToString(firstSellProfit,2),
      "\n  Last Profit: ",DoubleToString(lastSellProfit,2),
      "\n  Profit Total: ",DoubleToString(sellProfitTotal,2),
      "\n\nThreshold: ",DoubleToString(Threshold(),2),
      "\nSpreadOK: ", (SpreadOK() ? "yes" : "no"),
      "\nStepDist: ", DoubleToString(StepDistance(), _Digits),
      "\nPointValue/lot: ", DoubleToString(PointValuePerLot(), 4)
   );
}

//================ LIFECYCLE =================
int OnInit()
{
   trade.SetExpertMagicNumber((long)Magic);
   trade.SetDeviationInPoints(100);
   trade.SetTypeFilling(GetFilling());

   g_atrHandle = iATR(_Symbol, PERIOD_M5, ATR_Period);
   if(g_atrHandle==INVALID_HANDLE)
   {
      Print("Failed to create ATR handle");
      return INIT_FAILED;
   }

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_atrHandle!=INVALID_HANDLE)
   {
      IndicatorRelease(g_atrHandle);
      g_atrHandle = INVALID_HANDLE;
   }
   Comment("");
}

//================ ON TICK =================
void OnTick()
{
   ScanPositions();

   if(!SpreadOK())
   {
      DrawInfo();
      return;
   }

   // Keep hedge alive per-side (only for this EA/symbol)
   if(buyCount==0)
      OpenBuy(NextLotForSide(POSITION_TYPE_BUY, true));
   if(sellCount==0)
      OpenSell(NextLotForSide(POSITION_TYPE_SELL, true));

   CheckSteps();
   CheckExit();
   DrawInfo();
}

