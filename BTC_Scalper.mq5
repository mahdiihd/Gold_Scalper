#property strict
#property version "1.10"

#include <Trade/Trade.mqh>
CTrade trade;

//================ INPUTS =================
input double LotStep        = 0.01;
input double MaxLot         = 0.20;

input int    ATR_Period     = 14;
input double ATR_Mult       = 0.6;
input int    MinDistPoints  = 500;

input double BalancePctTP   = 0.4;
input double MinTPUSD       = 5.0;

input ulong  Magic          = 202512;

//================ GLOBAL =================
double lastBuyLot=0,lastSellLot=0;
double lastBuyPrice=0,lastSellPrice=0;
double firstBuyProfit=0,lastBuyProfit=0;
double firstSellProfit=0,lastSellProfit=0;
int    buyCount=0, sellCount=0;

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
      if(MathAbs(bid - lastBuyPrice) >= dist)
         OpenBuy(lastBuyLot + LotStep);
   }

   // SELL side (only add if latest sell is in drawdown)
   if(lastSellLot>0 && lastSellProfit<0)
   {
      if(MathAbs(ask - lastSellPrice) >= dist)
         OpenSell(lastSellLot + LotStep);
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

double ExitProfitSumBuy()
{
   if(buyCount<=0) return 0.0;
   if(buyCount==1) return lastBuyProfit;
   return firstBuyProfit + lastBuyProfit;
}

double ExitProfitSumSell()
{
   if(sellCount<=0) return 0.0;
   if(sellCount==1) return lastSellProfit;
   return firstSellProfit + lastSellProfit;
}

void CheckExit()
{
   const double th = Threshold();

   if(ExitProfitSumBuy() >= th)
      CloseSide(POSITION_TYPE_BUY);

   if(ExitProfitSumSell() >= th)
      CloseSide(POSITION_TYPE_SELL);
}

//================ INFO =================
void DrawInfo()
{
   Comment(
      "BUY (", buyCount, "):\n",
      "  Last Lot: ",DoubleToString(lastBuyLot,2),
      "\n  First Profit: ",DoubleToString(firstBuyProfit,2),
      "\n  Last Profit: ",DoubleToString(lastBuyProfit,2),
      "\n  Exit Sum: ",DoubleToString(ExitProfitSumBuy(),2),
      "\n\nSELL (", sellCount, "):\n",
      "  Last Lot: ",DoubleToString(lastSellLot,2),
      "\n  First Profit: ",DoubleToString(firstSellProfit,2),
      "\n  Last Profit: ",DoubleToString(lastSellProfit,2),
      "\n  Exit Sum: ",DoubleToString(ExitProfitSumSell(),2),
      "\n\nThreshold: ",DoubleToString(Threshold(),2),
      "\nStepDist: ", DoubleToString(StepDistance(), _Digits)
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

   // Initial hedge (only for this EA/symbol)
   if(buyCount==0 && sellCount==0)
   {
      OpenBuy(LotStep);
      OpenSell(LotStep);
      return;
   }

   CheckSteps();
   CheckExit();
   DrawInfo();
}

