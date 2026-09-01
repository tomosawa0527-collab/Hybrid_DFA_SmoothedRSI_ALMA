# Hybrid DFA & Smoothed RSI / Dual ALMA Trading System

MetaTrader 5 (MQL5) 向けに開発された、物理学・時系列解析の理論に基づく**DFA（トレンド除去変動解析）**による相場レジーム判別と、**Super Smoother RSI** および **Dual ALMA** を組み合わせた高堅牢ハイブリッド自動売買システム（EA）です。

---

## 1. システム概要

相場のランダムウォーク性（フラクタル構造）をリアルタイムに解析し、**「レンジ相場」「トレンド相場」「遷移相場（中立）」**を厳密に分離した上で、それぞれの環境に特化した最適戦略を自動で切り替えて執行します。

```mermaid
graph TD
    Market[MT5 市場データ] --> DFA[DFA.mq5<br/>相場レジーム判別]
    
    DFA -->|Alpha < Low (赤)| RangeMode[レンジ相場モード]
    DFA -->|Low <= Alpha <= High (グレー)| WaitMode[中立・遷移モード<br/>(エントリー静観)]
    DFA -->|Alpha > High (青)| TrendMode[トレンド相場モード]
    
    RangeMode --> SmoothedRSI[SmoothedRSI.mq5<br/>Super Smoother + RSI<br/>ゾーン脱出逆張りエントリー]
    TrendMode --> DualALMA[DualALMA.mq5<br/>Fast/Slow ALMA Cross<br/>ゴールデン/デッドクロス順張り]
    
    SmoothedRSI --> EA[Hybrid_DFA_EA.mq5<br/>ポジション管理 & ATR動的決済]
    DualALMA --> EA
```

---

## 2. ディレクトリ構成

```text
├── Experts/
│   └── Hybrid_DFA_EA.mq5         # メイン自動売買EA (ポジション管理・発注制御)
├── Indicators/
│   └── Hybrid_DFA_EA/
│       ├── DFA.mq5               # 双方向DFAレジーム判別インディケータ
│       ├── SmoothedRSI.mq5       # 2-Pole Super Smoother 平滑化RSI
│       └── DualALMA.mq5          # デュアル・アーナウドレグー移動平均線
└── docs/
    └── 20260822_2_DFA-Smoother ハイブリッド高堅牢化取引システム 仕様書（改訂版）.md
```

---

## 3. 主要コンポーネント詳細

### 3.1 DFA（Detrended Fluctuation Analysis）インディケータ (`DFA.mq5`)

時系列の対数リターン系列 $\Delta \ln P_t$ に対して DFA-1 解析を行い、ハースト指数 $H$ に相当するスケーリング指数 $\alpha$ を算出します。

- **マルチタイムフレーム (MTF) ネイティブ対応**:
  - `InpTimeframe` パラメータにより、インジケータ単体またはEA経由で上位足（例: M5チャート上でM15やH1）のDFA値を直接算出し、現在足チャート上にステップ状の波形として美しく同時描画。
- **双方向ボックス分割（Bidirectional DFA）**:
  - 原著論文（Kantelhardt et al.）に準拠し、順方向（$N_s$ 個）＋ 逆方向（$N_s$ 個）の計 $2N_s$ ブロックで分割。端数データの切り捨てをなくし、サンプル数が少ない金融データでも極めて高精度なスケーリング解析を実現。
- **マルチスケール回帰**:
  - 最小ボックスサイズ $s_{\min} = 8$ から 最大 $s_{\max} = N/4$ まで、対数等間隔で 16 スケールを抽出。
- **Super Smoother 平滑化フィルター**:
  - ジョン・エラーズの 2 次低遅延フィルター（`InpSmoothPeriod = 5`）を搭載し、高周波ジッターを除去。
- **マルチカラーライン描画 (`DRAW_COLOR_LINE`)**:
  - 🔴 **赤色 (Crimson)**: レンジレジーム ($\alpha < \text{InpDfaThresholdLow}$)
  - ⚪ **グレー (Gray)**: 中立・遷移レジーム ($\text{Low} \le \alpha \le \text{High}$)
  - 🔵 **青色 (DodgerBlue)**: トレンドレジーム ($\alpha > \text{InpDfaThresholdHigh}$)
- **動的スケール固定**:
  - レベルライン（Low / 0.50 / High）と連動し、波形がサブウィンドウいっぱいに美しく表示されるよう固定マージンで自動スケーリング。

---

### 3.2 Smoothed RSI インディケータ (`SmoothedRSI.mq5`)

高周波ノイズを排除した低遅延オシレーターです。

- **正しい平滑化パイプライン（RSI $\rightarrow$ Super Smoother）**:
  - 生の価格から高速 RSI(7) を計算した後、2-Pole Super Smoother フィルター（周期14）を通過。
  - トレンド相場でも 0 や 100 に飽和・張り付くことなく、30〜70 を中心とする滑らかなサイン波を描きます。
- **レンジ戦略シグナル（ゾーン復帰・脱出クロス方式）**:
  - **BUY**: 前々足が売られすぎ水準以下で、直前足が 35 を上抜け（$\text{RSI}_{t-1} \le 35 \text{ かつ } \text{RSI}_t > 35$）
  - **SELL**: 前々足が買われすぎ水準以上で、直前足が 65 を下抜け（$\text{RSI}_{t-1} \ge 65 \text{ かつ } \text{RSI}_t < 65$）

---

### 3.3 Dual ALMA インディケータ (`DualALMA.mq5`)

アーナウド・レグー移動平均（ALMA）による超低遅延トレンドフォローフィルターです。

- **ガウシアン加重移動平均**:
  - オフセットパラメータ（$0.85$）により最新バーに最大ウェイトを集中配置し、位相遅延を最小化。
- **トレンド戦略シグナル**:
  - **BUY（ゴールデンクロス）**: 短期 ALMA(9) が 長期 ALMA(21) を上抜け
  - **SELL（デッドクロス）**: 短期 ALMA(9) が 長期 ALMA(21) を下抜け

---

### 3.4 ハイブリッド取引 EA (`Hybrid_DFA_EA.mq5`)

- **レジーム駆動型マルチ戦略**:
  - DFA の相場判定に応じて、Smoothed RSI（レンジ）と Dual ALMA（トレンド）のシグナル受付を動的にスイッチング。
- **両建て防止 & ドテン決済**:
  - 同一戦略内での買い・売りの同時保有を禁止。反対シグナル発生時は既存ポジションを即時クローズしてドテンエントリー。
- **動的 ATR エグジット**:
  - 利確（Take Profit）: $\text{ATR}(14) \times 3.0$
  - 損切（Stop Loss）: $\text{ATR}(14) \times 1.5$
- **レジーム急変フェイルセーフ**:
  - レンジ保有中に DFA がトレンドに急変した場合は即時決済。

---

## 4. パラメータ一覧

### EA パラメータ (`Hybrid_DFA_EA.mq5`)

| パラメータ名 | デフォルト値 | 説明 |
| :--- | :--- | :--- |
| **`InpRiskPercent`** | `1.0` | 1トレードあたりの許容リスク (%) |
| **`InpFixedLot`** | `0.1` | 固定ロット数 (RiskPercent=0時に適用) |
| **`InpUseDfa`** | `true` | DFAレジーム判定フィルターの有効化 |
| **`InpDfaTimeframeMode`** | `HTF_MODE_AUTO_NEXT` | DFA 計算時間軸 (デフォルト: 自動1段階上位足) |
| **`InpDfaWindowSize`** | `300` | DFA 計算対象バー数 ($N$) |
| **`InpDfaSmoothPeriod`** | `5` | DFA 平滑化期間 (Super Smoother) |
| **`InpDfaThresholdLow`** | `0.45` | レンジ相場判定閾値 ($\alpha < \text{Low}$) |
| **`InpDfaThresholdHigh`** | `0.55` | トレンド相場判定閾値 ($\alpha > \text{High}$) |
| **`InpUseRangeStrategy`** | `true` | レンジ戦略 (Smoothed RSI) の有効化 |
| **`InpSSPeriod`** | `14` | Super Smoother 遮断周期 |
| **`InpRsiPeriod`** | `7` | RSI 計算期間 |
| **`InpRsiOverbought`** | `65.0` | 買われすぎ境界値 |
| **`InpRsiOversold`** | `35.0` | 売られすぎ境界値 |
| **`InpUseTrendStrategy`** | `true` | トレンド戦略 (Dual ALMA) の有効化 |
| **`InpAlmaFastWindow`** | `9` | 短期 ALMA 期間 |
| **`InpAlmaSlowWindow`** | `21` | 長期 ALMA 期間 |
| **`InpUseAtrExit`** | `true` | ATR ベース動的 TP/SL の有効化 |
| **`InpAtrTimeframeMode`** | `HTF_MODE_AUTO_NEXT` | ATR 計算時間軸 (デフォルト: 自動1段階上位足) |
| **`InpAtrPeriod`** | `14` | ATR 計算期間 |
| **`InpAtrTpFactor`** | `3.0` | ATR 利確乗数 ($\text{ATR} \times 3.0$) |
| **`InpAtrSlFactor`** | `1.5` | ATR 損切乗数 ($\text{ATR} \times 1.5$) |

---

## 5. セットアップ & コンパイル手順

1. **ファイルの配置**:
   - `Experts/Hybrid_DFA_EA.mq5` を MT5 の `MQL5/Experts/` 配下に配置
   - `Indicators/Hybrid_DFA_EA/` フォルダを MT5 の `MQL5/Indicators/` 配下に配置
   - `Include/Hybrid_DFA_EA/` フォルダを MT5 の `MQL5/Include/` 配下に配置
2. **コンパイル**:
   - MetaEditor で以下のファイルを順次開き、**F7** キーでコンパイルします：
     1. `Indicators/Hybrid_DFA_EA/DFA.mq5`
     2. `Indicators/Hybrid_DFA_EA/SmoothedRSI.mq5`
     3. `Indicators/Hybrid_DFA_EA/DualALMA.mq5`
     4. `Experts/Hybrid_DFA_EA.mq5`
3. **バックテスト実行**:
   - MT5 のストラテジーテスターを開き、`Hybrid_DFA_EA` を選択してバックテストを実行します。
   - 推奨時間軸: **1時間足 (H1)** (DFA/ATRは自動でH4上位足を適用)
   - 推奨通貨ペア: **USDJPY, EURUSD**

---

## 6. 改訂履歴 (Changelog)

### [v1.2.0] - 2026-08-30
- **マルチタイムフレーム (MTF) & チャート同時描画サポート (`Hybrid_DFA_EA.mq5`, `DFA.mq5`, `DFA_Common.mqh`)**:
  - **DFA MTF ネイティブ描画**: `DFA.mq5` に `InpTimeframe` パラメータを追加し、上位足の計算結果を現在足チャート上にステップ状の波形として美しく同時描画するMT5ネイティブカスケード機構を実装。
  - **自動上位足マッピング (`HTF_MODE_AUTO_NEXT`)**: DFA（環境認識）および ATR（リスク管理・決済）において、取引足より1段階上の上位足（M1→M5, M5→M15, M15→M30, M30→H1, H1→H4, H4→D1, D1→W1, W1→MN）を自動適用。
  - **3インジケータ完全同時表示**: EAの描画ハンドルを現在足（`_Period`）に統合し、バックテスト完了後のチャート上に「メイン: Dual ALMA」「サブ1: 上位足DFA」「サブ2: Smoothed RSI」の3つがすべて確実に同時描画されるよう最適化。
  - 下位足の微細ノイズやダマシ損切りを排除し、大局的なレジームと十分なボラティリティバッファを確保。
  - 直近確定足時刻（`bar1_time`）を基準としたリペイント・ルックアヘッドフリーな安全データ取得ロジックを採用。

### [v1.1.0] - 2026-08-30
- **DFA (`DFA.mq5`)**:
  - 原著論文（Kantelhardt et al.）準拠の「双方向ボックス分割（Bidirectional DFA）」を実装し、端数データ切り捨てを完全解消。
  - Super Smoother 2次低遅延平滑化フィルターを追加し、DFA Alpha の微細ジッターを除去。
  - `DRAW_COLOR_LINE` による相場レジーム色分け（赤: レンジ / グレー: 中立 / 青: トレンド）を実装。
  - レベルライン（Low / 0.50 / High）連動の動的サブウィンドウ縮尺固定を実装。
  - MQL5 公式推奨の 0=最古 インデックス設計（`ArraySetAsSeries(false)`）に全面刷新。
- **Smoothed RSI (`SmoothedRSI.mq5`)**:
  - 計算パイプラインを「生の価格からRSI算出 $\rightarrow$ Super Smoother平滑化」に修正し、トレンド時の 0/100 張り付き（飽和）バグを解消。
  - MQL5 標準インデックス設計に刷新。
- **Dual ALMA (`DualALMA.mq5`)**:
  - 過去データ参照（`GetPrice(i - k)`）および最新バー最大加重の整合化により、過去価格が描画されるバグを完全解消。
  - MQL5 標準インデックス設計に刷新。
- **Hybrid DFA EA (`Hybrid_DFA_EA.mq5`)**:
  - 同一戦略内での両建て（買い・売り同時保有）を禁止し、反対シグナル発生時のドテン決済を実装。
  - レンジ戦略のエントリー判定を「ゾーン復帰・脱出クロス方式（明確な反転確定エントリー）」に最適化。
  - シグナル検知時の詳細ログ出力（Alpha値、レジーム、オシレーター値）を追加。
  - バックテスト完了後のチャート上インディケータ表示維持（`OnDeinit` 調整）。

### [v1.0.0] - 2026-08-23
- 初回リリース
  - DFA-Smoother ハイブリッド取引システムの基本アーキテクチャ実装
  - `DFA.mq5`, `SmoothedRSI.mq5`, `DualALMA.mq5`, `Hybrid_DFA_EA.mq5` の初期バージョン実装

