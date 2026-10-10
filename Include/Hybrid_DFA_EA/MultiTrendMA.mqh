//+------------------------------------------------------------------+
//|                                                 MultiTrendMA.mqh |
//|                                  Copyright 2026, Hybrid DFA Quant |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#ifndef _MULTI_TREND_MA_MQH_
#define _MULTI_TREND_MA_MQH_

//+------------------------------------------------------------------+
//| トレンド戦略 移動平均種別定義                                    |
//+------------------------------------------------------------------+
#ifndef _ENUM_TREND_MA_TYPE_DEFINED_
#define _ENUM_TREND_MA_TYPE_DEFINED_
enum ENUM_TREND_MA_TYPE {
 TREND_MA_SMA  = 0, // SMA (単純移動平均)
 TREND_MA_EMA  = 1, // EMA (指数平滑移動平均)
 TREND_MA_SMMA = 2, // SMMA (平滑移動平均)
 TREND_MA_LWMA = 3, // LWMA (線形加重移動平均: 仕様書標準)
 TREND_MA_ALMA = 4  // ALMA (Arnaud Legoux 移動平均)
};
#endif

//--- MultiTrendMA バッファインデックス定義 (EA・外部プログラム共有)
#define MULTI_TREND_MA_BUFFER_FAST       0  // Fast MA バッファ (DRAW_LINE: オレンジ赤)
#define MULTI_TREND_MA_BUFFER_MID        1  // Mid MA バッファ  (DRAW_LINE: スカイブルー)
#define MULTI_TREND_MA_BUFFER_SLOW       2  // Slow MA バッファ (DRAW_LINE: マゼンタ)
#define MULTI_TREND_MA_BUFFER_PREFILTER  3  // 前処理・先行補正適用済み価格 (CALCULATIONS)
#define MULTI_TREND_MA_BUFFER_SIGNAL     4  // シグナル状態   (CALCULATIONS: +1.0/0.0/-1.0)
#define MULTI_TREND_MA_BUFFER_ATR        5  // ATRバッファ    (CALCULATIONS)
#define MULTI_TREND_MA_BUFFER_SS         6  // SuperSmoother 純粋出力バッファ (CALCULATIONS)

//--- 総バッファ数定義
#define MULTI_TREND_MA_TOTAL_BUFFERS     7

//--- デフォルトインジケーターパス
#define DEFAULT_MULTI_TREND_MA_PATH      "Hybrid_DFA_EA\\MultiTrendMA"

#endif // _MULTI_TREND_MA_MQH_