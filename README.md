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
├── Include/
│   └── Hybrid_DFA_EA/
│       └── DFA_Common.mqh        # 共通定義・資金管理・注文執行補助・レジーム状態遷移機械
├── Indicators/
│   └── Hybrid_DFA_EA/
│       ├── DFA.mq5               # 双方向DFAレジーム判別インディケータ (静的バッファ最適化済み)
│       ├── SmoothedRSI.mq5       # 2-Pole Super Smoother 平滑化RSI
│       └── DualALMA.mq5          # デュアル・アーナウドレグー移動平均線
└── docs/
    ├── 20260822_2_DFA-Smoother ハイブリッド高堅牢化取引システム 仕様書（改訂版）.md
    └── 20260901_MQL5 EA Implementation Review.md
```

---

## 3. 主要コンポーネント詳細

### 3.1 DFA（Detrended Fluctuation Analysis）インディケータ (`DFA.mq5`)

時系列の対数リターン系列 $\Delta \ln P_t$ に対して DFA-1 解析を行い、ハースト指数 $H$ に相当するスケーリング指数 $\alpha$ を算出します。

- **ドリフト結合型ハイブリッド補正 (Drift-Coupled Hybrid DFA)**:
  - **カウフマン効率比（$ER$）によるトレンド復元**: 純粋なDFA-1が消去してしまう大局的ドリフト（一本調子の強いトレンド成分）を、ウィンドウ内の対数リターンから効率比 $ER \in [0.0, 1.0]$ として高速抽出。
  - **ジリ高・低ボラ上昇相場（$ER \ge 0.20$）の完全救済**: 為替の微細構造ノイズによる平均回帰誤認（$\alpha < 0.45$ 赤線）を排除し、真のトレンド（$\alpha \ge 0.55$ 青線）へ自動昇格。
  - **天井圏・乱高下もみ合い相場の偽トレンド抑制**: 方向感のない往復ビンタ相場（$ER < 0.20$ かつ $\alpha \ge 0.50$）を中立・不感帯（$0.50 \sim 0.55$ グレー線）へ減衰させ、ダマシ損失を防止。
  - `InpUseDriftFilter`（有効/無効切り替え）および `InpDriftThreshold`（閾値設定）パラメータにより完全カスタマイズ可能。
- **高速化アルゴリズム・1パス解析的SSR (v1.4.0)**:
  - **1パス解析的残差平方和（SSR）**: 中間配列へのデータコピーと線形回帰関数呼び出し・残差積算の多重パスを完全排除し、単一走査ループで残差平方和を解析的に導出（局所回帰処理を約67%削減）。
  - **スケール定数・対数回帰定数の事前構造体キャッシュ**: 全16スケールの定数および $\ln(s)$ 回帰の分母等を `OnInit` で事前計算し、毎バー反復評価されていた超越関数（`MathExp`, `MathLog`）呼び出し（10万バーで約160万回）を100%排除。
  - **初回計算バー数のクリッピング制御 (`InpMaxBarsToCalc = 1500`)**: 初回起動時の計算範囲を実用範囲に厳格制限し、UIフリーズ（約30秒）をミリ秒単位（約1,000倍高速化）へ解消。
  - **学術推奨最小ボックスサイズ ($s_{\min} \ge 10$)**: 有限長標本効果による上方バイアス（Bryce & Sprague, 2012）を防止するため最小ボックスサイズを 10 に設定。
- **静的バッファによるメモリ最適化 (v1.3.0)**:
  - 毎バーの動的配列生成（`ArrayResize`）を完全に排除し、グローバル領域に事前割り当てした静的ワーク配列を再利用。
- **マルチタイムフレーム (MTF) ネイティブ対応**:
  - `InpTimeframe` パラメータにより、インジケータ単体またはEA経由で上位足（例: M5チャート上でM15やH1）のDFA値を直接算出し、現在足チャート上にステップ状の波形として美しく同時描画。
- **双方向ボックス分割（Bidirectional DFA）**:
  - 原著論文（Kantelhardt et al.）に準拠し、順方向（$N_s$ 個）＋ 逆方向（$N_s$ 個）の計 $2N_s$ ブロックで分割。端数データの切り捨てをなくし、サンプル数が少ない金融データでも極めて高精度なスケーリング解析を実現。
- **マルチスケール回帰**:
  - 最小ボックスサイズ $s_{\min} = 10$ から 最大 $s_{\max} = N/4$ まで、対数等間隔で 16 スケールを抽出。
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

### 3.4 ハイブリッド取引 EA (`Hybrid_DFA_EA.mq5` & `DFA_Common.mqh`)

- **ヒステリシス付きレジーム状態遷移機械 (v1.3.0)**:
  - シュミットトリガー方式による状態保持を導入。一度確定したレジーム（RANGE / TREND）を覆すには反対側の閾値を超える必要があり、閾値境界付近での微小振動によるチャタリング決済（往復ビンタ）を完全抑制。
- **堅牢な実弾注文執行レイヤー (v1.3.0)**:
  - **充填モード自動判定 (`DetectFillType`)**: `SYMBOL_FILLING_MODE` ビットマスクを解析し、ブローカー許容モード（FOK/IOC/RETURN）を安全に自動割り当て。
  - **ストップレベル/スプレッドガード (`AdjustStopDistance`)**: ブローカーの最小ストップレベルおよび拡大スプレッドを加味し、`INVALID_STOPS` エラーを事前回避。
  - **動的ロット正規化 (`NormalizeLot`)**: 銘柄ごとの `SYMBOL_VOLUME_STEP` 精度に自動追従して正規化し、`INVALID_VOLUME` エラーを防止。
  - **有効証拠金基準の資金管理**: 含み損時の過剰レバレッジを防ぐため、許容リスク算出基準を `ACCOUNT_BALANCE` から `ACCOUNT_EQUITY` へ最適化。
- **厳密な上位足タイムスタンプ同期 (v1.3.0)**:
  - DFA および ATR のデータ取得において、上位足の確定足オープン時刻（`iTime(_Symbol, htf, 1)`）を個別に厳密指定。上位足の形成中未確定バーの巻き込み（リペイント）を構造的に完全排除。
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
| **`InpRiskPercent`** | `1.0` | 1トレードあたりの許容リスク (%) (有効証拠金基準) |
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

### [v1.4.0] - 2026-09-12
- **レジーム判定アーキテクチャの刷新（新規売買停止と0.50基準線決済）(`DFA_Common.mqh`, `Hybrid_DFA_EA.mq5`)**:
  - **新規売買判定の完全一致化**: 従来のヒステリシスによる不要な状態固着を解消し、$\alpha$ が $0.45 \sim 0.55$（不感帯）にある間は確実に `REGIME_TRANSITION`（完全静観・新規発注なし）として判定。
  - **ポジション保有中の0.50基準線決済 (`ShouldCloseRegimePosition`)**: 一度保有したポジションは、高周波ノイズによる早期クローズを防ぐため、トレンドポジションは $\alpha < 0.50$、レンジポジションは $\alpha > 0.50$ を跨ぐまで粘り強くホールドし、基準線を跨いだ時点で安全に手仕舞い。
  - **未計算領域・異常値ガード**: `EMPTY_VALUE` や NaN 検出時の安全フォールバック（`0.50 / REGIME_TRANSITION`）を追加。
- **ドリフト結合型ハイブリッドDFA（Drift-Coupled Hybrid DFA）の導入 (`DFA.mq5`, `Hybrid_DFA_EA.mq5`)**:
  - **トレンド除去パラドックスの解消**: 一定ペースで綺麗に上昇・下降する相場において、DFA-1のトレンド消去と為替の微細構造ノイズ（Bid-Askバウンス）により $\alpha < 0.45$（レンジ誤認）となる致命的欠点を解消。
  - **カウフマン効率比（$ER$）による複合判定**: 既存のリターン計算ループから $ER$ を追加コストゼロで同時算出し、$ER \ge \text{InpDriftThreshold}$（デフォルト: 0.20）の相場を確実に TREND（$\alpha \ge 0.55$ 青線）へ昇格。
  - **乱高下・天井もみ合いの偽トレンド抑制**: 方向感のない荒れ相場（$ER < 0.20$ かつ $\alpha \ge 0.50$）を中立・不感帯（$0.50 \sim 0.55$ グレー線）へ減衰させ、ダマシ損失を防止。
  - **EA・インディケータ完全同期**: `InpUseDriftFilter` および `InpDriftThreshold` をパラメータ化し、EA側からも柔軟に制御可能。
- **DFAインディケータの超高速化リファクタリング (`DFA.mq5`, `Hybrid_DFA_EA.mq5`)**:
  - **初回計算バー数のクリッピング制御**: 入力パラメータ `InpMaxBarsToCalc`（デフォルト: 1500本）を新設。初回描画時の走査対象を過去全バー（5〜10万本）から直近実用範囲に限定し、起動時のUIフリーズ（約30秒）をミリ秒単位へ解消（約1,000倍高速化）。
  - **1パス解析的残差平方和（SSR）の導入**: 局所回帰処理における中間配列コピー、OLS回帰関数呼び出し、残差再計算の3重パスを完全排除し、単一ループ内で閉形式数式に基づき直接残差平方和を導出。局所回帰演算を約67%削減。
  - **スケール定数・対数回帰定数の事前構造体キャッシュ (`DfaScaleInfo`)**: 全16スケールのボックスサイズ、正規方程式分母逆数、対数値等を `OnInit` で一括事前計算。バーごとの反復超越関数評価（`MathExp`, `MathLog`）を100%排除。
  - **学術推奨最小ボックスサイズの適用**: 有限長標本効果と自由度喪失による上方バイアス（Bryce & Sprague, 2012）を排除するため、`InpMinBoxSize` の下限・推奨値を 8 $\to$ 10 に更新。
  - **平滑化処理の堅牢化**: 初回クリッピングに伴う未計算領域（`EMPTY_VALUE`）への参照時における Super Smoother 平滑化ガード処理を追加。
  - **EA `iCustom` 呼び出し同期**: `Hybrid_DFA_EA.mq5` における DFA ハンドル取得パラメータ順序・デフォルト値を新パラメータ体系に適合。

### [v1.3.0] - 2026-09-02
- **DFA内部メモリの静的バッファ化 (`DFA.mq5`)**:
  - `CalculateDfaAlphaAtBar` 内の動的 `ArrayResize` を全廃し、事前確保した静的ワーク配列を再利用。ヒープ断片化とキャッシュミスを解消し大幅に高速化。
  - `blockX[]` 静的整数列の初期化を `OnInit` に集約。
- **実弾運用向け注文執行レイヤーの強化 (`DFA_Common.mqh`, `Hybrid_DFA_EA.mq5`)**:
  - `SYMBOL_FILLING_MODE` ビットマスクによる充填モード自動判定（`DetectFillType`）を実装。
  - `SYMBOL_TRADE_STOPS_LEVEL` および現在スプレッドを考慮した動的 SL/TP 距離ガード補正（`AdjustStopDistance`）を追加。
  - `SYMBOL_VOLUME_STEP` の小数桁数に応じた動的ロット正規化（`NormalizeLot`）を実装。
  - 許容リスク額の算出基準を `ACCOUNT_BALANCE` から `ACCOUNT_EQUITY`（有効証拠金）に変更。
- **シュミットトリガー方式レジーム状態遷移機械の導入 (`DFA_Common.mqh`, `Hybrid_DFA_EA.mq5`)**:
  - レジーム判定にヒステリシス（粘り）を持たせ、境界値付近でのチャタリング（往復ビンタ）と不要な強制決済コストを防止。
- **上位足確定足タイムスタンプ同期の厳密化 (`Hybrid_DFA_EA.mq5`)**:
  - 上位足 DFA / ATR のデータ参照時に `iTime(_Symbol, htf, 1)` を指定し、未確定バー巻き込み（リペイント）を完全排除。

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

