# BitDjinn

BitDjinn is a real-time cryptocurrency and stock market tracker, trend visualizer, and multi-chain address balance monitor with desktop transaction alerts for Noctalia.

## Plugin

| Field | Value |
| --- | --- |
| ID | `nirvam/bitdjinn` |
| Entries | Bar widget: `bar`; panel: `panel`; service: `service`; desktop widget: `desktop`; shortcut: `toggle` |

## Usage

Access the BitDjinn interactive dashboard by clicking the bar widget or via IPC:

```sh
noctalia msg panel-toggle duchovs/bitdjinn:panel
```

- **Bar Widget (`bar`)**: Shows current price for your preferred coin (e.g. BTC) and a 24h change pill. Scroll vertically over the widget to cycle through watched assets. Click to open the dashboard panel.
- **Panel (`panel`)**: Interactive multi-tab dashboard featuring real-time market cards, 36-hour sparkline trend graphs, instant currency converter (`USD`, `CNY`, `EUR`, `BTC`, `ETH`), drag-to-reorder tickers (grab the grip handle on a row), add coins or stocks (`$AAPL`), and an on-chain address watcher with copy-to-clipboard actions.
- **Desktop Widget (`desktop`)**: HUD card pinned to the desktop displaying large price trend graphs and total portfolio valuation.
- **Control Center Shortcut (`toggle`)**: Quick toggle tile to mute or enable desktop transaction notifications.

## Stocks

Stocks and ETFs sit in the same watchlist as coins. Because tickers collide between the two
(`ETH`, `SOL`, `APT` are all both a coin and a listed security), the prefix decides:

| You type | Resolved as |
| --- | --- |
| `$AAPL` | Stock — goes straight to Yahoo Finance |
| `stock:AAPL` | Stock — same thing, longer form |
| `coin:eth` | Crypto — forces CoinGecko, never falls back |
| `AAPL` | Unforced — tries CoinGecko first, falls back to Yahoo if no coin matches |

Use `$` whenever the name is ambiguous. A bare ticker is a convenience, not a guarantee:
CoinGecko's search is fuzzy and will happily match an obscure altcoin before it gives up.

Tickers with dots or dashes work as-is (`$BRK-B`, `$BF.B`).

### How stock values are computed

The price is live in extended hours, but every other number describes the **regular session**
(09:30-16:00 ET):

| Field | Source |
| --- | --- |
| Price | `meta.fulldayPrice` — includes pre/post-market trades |
| 24h change % | `meta.regularMarketChangePercent` — the regular-session move only |
| Sparkline | Regular-session closes, resampled across the whole day |
| 24h high/low, volume | Regular-session values |

So after the close the price keeps ticking while the change pill stays pinned to the day's
official move. That is intentional: the two numbers deliberately describe different windows,
which is why the price can drift while the percentage sits still.

Caveats:

- **Extended hours are 04:00-09:30 and 16:00-20:00 ET.** Outside those windows nothing trades,
  so the price is the last print, frozen until the next session.
- **One request per stock per poll** — Yahoo has no batch endpoint. Raise `interval` if you
  watch a lot of tickers.
- **Non-US listings report in their local currency** and will be mislabeled by the currency
  selector, which assumes USD.

## When CoinGecko is unavailable

CoinGecko's keyless API answers heavy use with `429`s and, if it continues, a CDN-level `403`
block on its price endpoints. BitDjinn backs off instead of retrying through it: after each
failed poll CoinGecko is skipped for `interval × 2ⁿ` (60 s, 2 m, 4 m … capped at 30 min),
and the first success resets that. The backoff survives plugin reloads and shell restarts.

While CoinGecko is skipped or failing, crypto quotes come from Yahoo's `<SYM>-USD` listings
instead, one request per coin. Hourly bars keep the same meaning as CoinGecko's
numbers: the change, high/low and volume cover a rolling 24 h window, and the sparkline is
the last 37 hours. The BTC and ETH display currencies keep updating from those quotes;
CNY and EUR keep their last cached rate until CoinGecko is back.

`noctalia.log` records each switch between sources (`crypto quotes falling back to Yahoo` /
`back on CoinGecko`) and each backoff step.

## Settings

Configure BitDjinn under **Settings → Plugins → BitDjinn** or in `~/.config/noctalia/config.toml`:

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `currency` | `select` | `usd` | Display valuation currency (`usd`, `cny`, `eur`, `btc`, `eth`). |
| `interval` | `int` | `30` | Market prices and trend sparklines refresh cadence (10–600 seconds). |
| `wallet_interval` | `int` | `60` | On-chain address balance and transaction check cadence (15–1800 seconds). |
| `notify_tx` | `bool` | `true` | Send desktop notifications when a balance or transaction count change is detected. |
| `widget_coin` | `string` | `BTC` | Default cryptocurrency symbol displayed on the status bar widget. |

## IPC

Send commands to BitDjinn's background service from scripts or compositor bindings:

```sh
# Trigger immediate market prices and on-chain balance refresh
noctalia msg plugin duchovs/bitdjinn:service all refresh

# Add a wallet address to watch list (supports BTC, ETH 0x..., and SOL)
noctalia msg plugin duchovs/bitdjinn:service all add "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045 Vitalik-Cold"

# Remove a watched address from list
noctalia msg plugin duchovs/bitdjinn:service all remove "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"

# Add a ticker, with the same syntax as the panel's input ($AAPL, coin:eth, AAPL)
noctalia msg plugin duchovs/bitdjinn:service all add_coin '$AAPL'

# Remove a ticker by id or symbol (stocks' ids are stock:<symbol>)
noctalia msg plugin duchovs/bitdjinn:service all remove_coin stock:aapl

# Toggle transaction notification alerts
noctalia msg plugin duchovs/bitdjinn:service all toggle_notify

# Refresh status bar widget instance on focused output
noctalia msg plugin duchovs/bitdjinn:bar focused refresh
```

## Notes

- **Network Access**: BitDjinn queries public CoinGecko market endpoints for live exchange rates and sparkline trend history, Yahoo Finance chart endpoints for stock quotes (and crypto quotes while CoinGecko is unavailable), Mempool.space for Bitcoin addresses, and public JSON-RPC nodes for Ethereum and Solana balances.
- **Privacy & Security**: All address lookups and API requests are read-only. No private keys, seed phrases, or credentials are ever required or stored.
- **Local Persistence**: User watchlists, transaction notification states, and cached exchange rate matrices are saved in `$XDG_DATA_HOME/noctalia/bitdjinn_state.json`.
