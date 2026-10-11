//+------------------------------------------------------------------+
//|                                     KalmanRegimeEstimator.mqh    |
//|                                  Copyright 2026, Quant Research  |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#ifndef _KALMAN_REGIME_ESTIMATOR_MQH_
#define _KALMAN_REGIME_ESTIMATOR_MQH_

#property copyright "Copyright 2026, Quant Research"
#property link      "https://www.mql5.com"
#property strict

//--- デフォルト配置パス定義
#ifndef DEFAULT_KALMAN_INDICATOR_PATH
#define DEFAULT_KALMAN_INDICATOR_PATH "Hybrid_DFA_EA\\KalmanRegimeEstimator"
#endif

//+------------------------------------------------------------------+
//| カルマンレジーム定数 (インジケーター出力値: double)              |
//+------------------------------------------------------------------+
#define KALMAN_REGIME_UP     1.0   // 上昇トレンド (+1.0)
#define KALMAN_REGIME_DOWN  -1.0   // 下降トレンド (-1.0)
#define KALMAN_REGIME_RANGE  0.0   // レンジ相場 (0.0)

//+------------------------------------------------------------------+
//| カラーバッファ用インデックス定数                                 |
//+------------------------------------------------------------------+
#define KALMAN_COLOR_UP      0     // clrDodgerBlue
#define KALMAN_COLOR_DOWN    1     // clrCrimson
#define KALMAN_COLOR_RANGE   2     // clrDarkGray

// 後方互換用エイリアス
#define COLOR_UP             KALMAN_COLOR_UP
#define COLOR_DOWN           KALMAN_COLOR_DOWN
#define COLOR_RANGE          KALMAN_COLOR_RANGE

//+------------------------------------------------------------------+
//| インジケーターバッファインデックス定義 (EA・外部プログラム共有) |
//+------------------------------------------------------------------+
#define KALMAN_BUFFER_ZSCORE 0     // プロット用: Zスコア (DRAW_COLOR_LINE)
#define KALMAN_BUFFER_COLOR  1     // プロット用: カラーインデックス (COLOR_INDEX)
#define KALMAN_BUFFER_SLOPE  2     // 計算用/EA取得用: 局所的な傾き beta (CALCULATIONS)
#define KALMAN_BUFFER_REGIME 3     // 計算用/EA取得用: レジーム判定値 (CALCULATIONS: +1.0/0.0/-1.0)

//--- 総バッファ数定義
#define KALMAN_TOTAL_BUFFERS 4

//+------------------------------------------------------------------+
//| カルマンレジーム種別定義 (EA内部状態・後方互換用)                |
//+------------------------------------------------------------------+
#ifndef _ENUM_REGIME_TYPE_DEFINED_
#define _ENUM_REGIME_TYPE_DEFINED_
enum ENUM_REGIME_TYPE
{
   REGIME_NONE       = 0, // 未判定
   REGIME_RANGE      = 1, // レンジ相場 (反発性 / 平均回帰)
   REGIME_TRANSITION = 2, // 遷移状態 / ランダムウォーク (不感帯・静観)
   REGIME_TREND      = 3, // トレンド相場 (持続性 / 追従 - 汎用)
   REGIME_UP_TREND   = 4, // 上昇トレンド (カルマン Z >= 2.0)
   REGIME_DOWN_TREND = 5, // 下降トレンド (カルマン Z <= -2.0)
   REGIME_ALL        = 6  // レジーム制限なし (無効時)
};
#endif

//+------------------------------------------------------------------+
//| 各バーの状態を隔離保持する構造体（未確定足の状態汚染防止）       |
//+------------------------------------------------------------------+
#ifndef _KALMAN_STATE_DEFINED_
#define _KALMAN_STATE_DEFINED_
struct KalmanState
{
   double mu;          // 平滑化対数価格水準 ln(P)
   double beta;        // 局所的な対数傾き (1足あたりの期待リターン速度)
   double p00;         // 共分散 P[0,0]
   double p01;         // 共分散 P[0,1]
   double p11;         // 共分散 P[1,1]
   double regime;      // 現在のレジーム状態
   bool   initialized; // 初期化フラグ
};
#endif

//+------------------------------------------------------------------+
//| カルマンZスコアに基づくレジーム判定ヘルパー                      |
//+------------------------------------------------------------------+
inline ENUM_REGIME_TYPE DetermineKalmanRegime(const double z, const double threshold = 2.0)
{
   if(!MathIsValidNumber(z) || z == EMPTY_VALUE) return REGIME_RANGE;
   if(z >= threshold) return REGIME_UP_TREND;
   if(z <= -threshold) return REGIME_DOWN_TREND;
   return REGIME_RANGE;
}

#endif // _KALMAN_REGIME_ESTIMATOR_MQH_
