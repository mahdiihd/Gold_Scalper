# Gold_Scalper

This repo contains a MetaTrader 5 Expert Advisor.

## Files

- `BTC_Scalper.mq5`: hedge + step-add logic with ATR-based spacing and balance-based profit threshold exits.

## Notes

- The EA only manages positions for the **current chart symbol** and the configured **`Magic`** number.
- ATR is read from **M5** (`PERIOD_M5`) using an indicator handle (correct for MQL5).