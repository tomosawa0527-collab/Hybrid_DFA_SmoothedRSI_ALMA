//+------------------------------------------------------------------+
//|                                                 MultiTrendMA.mqh |
//|                                  Copyright 2026, Quant Research  |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#ifndef _MULTI_TREND_MA_MQH_
#define _MULTI_TREND_MA_MQH_

#property copyright "Copyright 2026, Quant Research"
#property link      "https://www.mql5.com"
#property strict

//+------------------------------------------------------------------+
//| 移動平均種別定義 (Enum)                                          |
//+------------------------------------------------------------------+
#ifndef _ENUM_TREND_MA_TYPE_DEFINED_
#define _ENUM_TREND_MA_TYPE_DEFINED_
enum ENUM_TREND_MA_TYPE
{
   TREND_MA_SMA  = 0, // SMA (単純移動平均)
   TREND_MA_EMA  = 1, // EMA (指数平滑移動平均)
   TREND_MA_SMMA = 2, // SMMA (平滑移動平均)
   TREND_MA_LWMA = 3, // LWMA (線形加重移動平均: 仕様書標準)
   TREND_MA_ALMA = 4  // ALMA (Arnaud Legoux 移動平均)
};
#endif

//+------------------------------------------------------------------+
//| 移動平均 期間定義 (Enum: カーブフィッティング防止)                |
//+------------------------------------------------------------------+
#ifndef _ENUM_MA_PERIOD_DEFINED_
#define _ENUM_MA_PERIOD_DEFINED_
enum ENUM_MA_PERIOD
{
   MA_PERIOD_DISABLED =   0, // 0 (無効)
   MA_PERIOD_5        =   5, // 5
   MA_PERIOD_8        =   8, // 8
   MA_PERIOD_10       =  10, // 10
   MA_PERIOD_13       =  13, // 13
   MA_PERIOD_15       =  15, // 15
   MA_PERIOD_20       =  20, // 20
   MA_PERIOD_21       =  21, // 21
   MA_PERIOD_25       =  25, // 25
   MA_PERIOD_26       =  26, // 26
   MA_PERIOD_30       =  30, // 30
   MA_PERIOD_34       =  34, // 34
   MA_PERIOD_40       =  40, // 40
   MA_PERIOD_50       =  50, // 50
   MA_PERIOD_52       =  52, // 52
   MA_PERIOD_55       =  55, // 55
   MA_PERIOD_60       =  60, // 60
   MA_PERIOD_75       =  75, // 75
   MA_PERIOD_89       =  89, // 89
   MA_PERIOD_100      = 100, // 100
   MA_PERIOD_120      = 120, // 120
   MA_PERIOD_150      = 150, // 150
   MA_PERIOD_200      = 200  // 200
};
#define ENUM_PERIOD ENUM_MA_PERIOD
#endif

//+------------------------------------------------------------------+
//| シグナル状態定義定数 (インジケーター出力値: double)              |
//+------------------------------------------------------------------+
#define MULTI_TREND_MA_SIGNAL_BULLISH     1.0   // 強気 / 上昇シグナル (+1.0)
#define MULTI_TREND_MA_SIGNAL_BEARISH    -1.0   // 弱気 / 下降シグナル (-1.0)
#define MULTI_TREND_MA_SIGNAL_NEUTRAL     0.0   // 中立 / レンジシグナル (0.0)

//+------------------------------------------------------------------+
//| インジケーターバッファインデックス定義 (EA・外部プログラム共有) |
//+------------------------------------------------------------------+
#define MULTI_TREND_MA_BUFFER_FAST        0     // Fast MA バッファ (DRAW_LINE: オレンジ赤)
#define MULTI_TREND_MA_BUFFER_MID         1     // Mid MA バッファ  (DRAW_LINE: スカイブルー)
#define MULTI_TREND_MA_BUFFER_SLOW        2     // Slow MA バッファ (DRAW_LINE: マゼンタ)
#define MULTI_TREND_MA_BUFFER_PREFILTER   3     // 前処理・先行補正適用済み価格 (CALCULATIONS)
#define MULTI_TREND_MA_BUFFER_SIGNAL      4     // シグナル状態 (CALCULATIONS: +1.0/0.0/-1.0)
#define MULTI_TREND_MA_BUFFER_ATR         5     // ATRバッファ (CALCULATIONS)
#define MULTI_TREND_MA_BUFFER_SS          6     // SuperSmoother 純粋出力バッファ (CALCULATIONS)

//--- 総バッファ数定義
#define MULTI_TREND_MA_TOTAL_BUFFERS      7

//+------------------------------------------------------------------+
//| デフォルト配置パス定義                                           |
//+------------------------------------------------------------------+
#ifndef DEFAULT_MULTI_TREND_MA_PATH
#define DEFAULT_MULTI_TREND_MA_PATH       "Hybrid_DFA_EA\\MultiTrendMA"
#endif

#endif // _MULTI_TREND_MA_MQH_