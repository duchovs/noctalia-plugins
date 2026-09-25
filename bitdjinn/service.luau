--!nonstrict
-- BitDjinn Headless Service — Background Market & Blockchain Watcher.
-- Features instant 0ms multi-currency conversion cache and multi-chain tracker.

local format = require("./lib/format.luau")

noctalia.setUpdateInterval(1000)

-- ── Constant Definitions ───────────────────────────────────────────────────

local coinDefs = {
  { id = "bitcoin", symbol = "BTC", name = "Bitcoin", glyph = "currency-bitcoin", defaultPrice = 80000 },
  { id = "ethereum", symbol = "ETH", name = "Ethereum", glyph = "currency-ethereum", defaultPrice = 2800 },
  { id = "zcash", symbol = "ZEC", name = "Zcash", glyph = "currency-zcash", defaultPrice = 1100 },
  { id = "solana", symbol = "SOL", name = "Solana", glyph = "currency-solana", defaultPrice = 180 },
  { id = "binancecoin", symbol = "BNB", name = "BNB", glyph = "brand-binance", defaultPrice = 600 },
  { id = "ripple", symbol = "XRP", name = "XRP", glyph = "currency-ripple", defaultPrice = 1.8 },
  { id = "dogecoin", symbol = "DOGE", name = "Dogecoin", glyph = "currency-dogecoin", defaultPrice = 0.22 },
}

local MAX_HISTORY_POINTS = 36

-- Yahoo Finance chart endpoint. Deliberately queried WITHOUT `includePrePost`: the
-- sparkline, % change, day high/low and volume must all describe the *regular* session
-- (09:30-16:00 ET). The extended-hours price still arrives via meta.fulldayPrice, which
-- is populated regardless of that flag -- so one request serves both needs.
local STOCK_CHART_URL = "https://query1.finance.yahoo.com/v8/finance/chart/%s?range=1d&interval=5m"
local STOCK_UA = "Mozilla/5.0 (X11; Linux x86_64)"

-- A stock def is tagged kind == "stock"; crypto defs leave `kind` nil.
local function isStock(def: any): boolean
  return type(def) == "table" and def.kind == "stock"
end

local function urlEncode(s: string): string
  return (string.gsub(s, "([^%w%-%_%.%~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

-- Evenly resample `src` down to at most `target` points, always keeping the first and
-- last. A 1d/5m regular session is 79 points; the graph only draws MAX_HISTORY_POINTS,
-- and slicing the tail would show just the final ~3 hours -- resampling keeps the whole
-- trading day in frame instead.
local function downsample(src: { number }, target: number): { number }
  local n = #src
  if n <= target or target < 2 then
    return src
  end
  local out = {}
  for i = 1, target do
    local idx = math.floor((i - 1) * (n - 1) / (target - 1) + 0.5) + 1
    table.insert(out, src[idx])
  end
  return out
end

-- ── Internal State ─────────────────────────────────────────────────────────

local tickCount = 0
local marketPollInterval = 30
local walletPollInterval = 60
local notifyEnabled = true
local currentCurrency = "usd"
local widgetCoin = "BTC"

-- Live exchange rates against USD (USD = 1.0; BTC/ETH are seed defaults, refreshed from
-- CoinGecko on the first market fetch)
local exchangeRates = {
  usd = 1.0,
  cny = 7.25,
  eur = 0.92,
  btc = 1.0 / 80000.0,
  eth = 1.0 / 2800.0,
}

local priceHistory = {}   -- coin_id -> { number }
-- Last known 24h % change per ticker. Price already survives a failed poll via
-- priceHistory; without this the change pill would drop to 0.00% on any poll that
-- doesn't return an item, then snap back on the next good one.
local lastChange = {}     -- coin_id -> number
local marketData = {}     -- array of coin tables
local watchedWallets = {} -- array of wallet objects
local isUpdating = false
local lastMarketFetchTime = 0
local lastWalletFetchTime = 0

-- ── Persistence ────────────────────────────────────────────────────────────

local function dataFilePath(): string?
  local dir = noctalia.pluginDataDir()
  if dir == nil then
    return nil
  end
  return dir .. "/bitdjinn_state.json"
end

local function saveState()
  local path = dataFilePath()
  if path == nil then
    return
  end
  local payload = {
    currency = currentCurrency,
    notifyEnabled = notifyEnabled,
    exchangeRates = exchangeRates,
    wallets = watchedWallets,
    priceHistory = priceHistory,
    lastChange = lastChange,
    coins = coinDefs,
  }
  local raw = noctalia.json.encode(payload)
  if raw ~= nil then
    noctalia.writeFile(path, raw)
  end
end

local function loadState()
  local path = dataFilePath()
  if path ~= nil then
    local raw = noctalia.readFile(path)
    if raw ~= nil then
      local decoded = noctalia.json.decode(raw)
      if type(decoded) == "table" then
        if type(decoded.currency) == "string" then
          currentCurrency = decoded.currency
        end
        if type(decoded.notifyEnabled) == "boolean" then
          notifyEnabled = decoded.notifyEnabled
        end
        if type(decoded.exchangeRates) == "table" then
          for k, v in pairs(decoded.exchangeRates) do
            if type(v) == "number" and v > 0 then
              exchangeRates[k] = v
            end
          end
        end
        if type(decoded.wallets) == "table" then
          watchedWallets = decoded.wallets
        end
        if type(decoded.coins) == "table" and #decoded.coins > 0 then
          coinDefs = decoded.coins
        end
        if type(decoded.lastChange) == "table" then
          for coinId, ch in pairs(decoded.lastChange) do
            if type(ch) == "number" then
              lastChange[coinId] = ch
            end
          end
        end
        if type(decoded.priceHistory) == "table" then
          for coinId, hist in pairs(decoded.priceHistory) do
            if type(hist) == "table" and #hist > 0 then
              priceHistory[coinId] = hist
            end
          end
        end
      end
    end
  end

  -- Seed price history for any coin (default or loaded) that doesn't have any yet
  for _, c in ipairs(coinDefs) do
    if priceHistory[c.id] == nil then
      priceHistory[c.id] = { c.defaultPrice, c.defaultPrice }
    end
  end
end

-- ── Price & Market Engine ──────────────────────────────────────────────────

local function getRate(currency: string): number
  local c = string.lower(currency or "usd")
  return exchangeRates[c] or 1.0
end

local function getCoinPrice(coinSymbol: string): number
  local sym = string.upper(coinSymbol or "")
  for _, m in ipairs(marketData) do
    if m.symbol == sym then
      return m.price or 0
    end
  end
  for _, c in ipairs(coinDefs) do
    if c.symbol == sym then
      return c.defaultPrice * getRate(currentCurrency)
    end
  end
  return 0
end

local function recalculatePricesForCurrency()
  local rate = getRate(currentCurrency)
  for _, m in ipairs(marketData) do
    local baseUsd = m.baseUsdPrice or m.price or 0
    m.price = baseUsd * rate
  end
end

local function publishState()
  recalculatePricesForCurrency()

  local totalValuation = 0
  for _, w in ipairs(watchedWallets) do
    local coinPrice = getCoinPrice(w.chain)
    w.value = (w.balance or 0) * coinPrice
    totalValuation = totalValuation + w.value
  end

  local topCoinPrice = getCoinPrice(widgetCoin)
  local topCoinChange = 0
  for _, m in ipairs(marketData) do
    if m.symbol == widgetCoin then
      topCoinChange = m.change24h or 0
      break
    end
  end

  noctalia.state.set("bitdjinn.market", marketData)
  noctalia.state.set("bitdjinn.wallets", watchedWallets)
  noctalia.state.set("bitdjinn.summary", {
    currency = currentCurrency,
    currencySymbol = format.currencySymbol(currentCurrency),
    totalValuation = totalValuation,
    widgetCoin = widgetCoin,
    widgetPrice = topCoinPrice,
    widgetChange = topCoinChange,
    isUpdating = isUpdating,
    lastUpdated = os.date("%H:%M:%S"),
    notifyEnabled = notifyEnabled,
  })
end

local function updateExchangeRates(onDone: () -> ())
  local rateUrl = "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd,cny,eur,eth"
  noctalia.http({
    url = rateUrl,
    method = "GET",
    headers = { "Accept: application/json", "User-Agent: Mozilla/5.0 (Noctalia-BitDjinn)" },
  }, function(res)
    if res.ok and res.status == 200 then
      local data = noctalia.json.decode(res.body)
      if type(data) == "table" and type(data.bitcoin) == "table" then
        local bUsd = tonumber(data.bitcoin.usd) or 0
        local bCny = tonumber(data.bitcoin.cny) or 0
        local bEur = tonumber(data.bitcoin.eur) or 0
        -- CoinGecko returns this as BTC's price in ETH (ETH per BTC); dividing by bUsd
        -- (USD per BTC) yields ETH per USD, the same "target units per 1 USD" shape as
        -- every other rate here.
        local bEth = tonumber(data.bitcoin.eth) or 0
        if bUsd > 0 then
          if bCny > 0 then exchangeRates.cny = bCny / bUsd end
          if bEur > 0 then exchangeRates.eur = bEur / bUsd end
          if bEth > 0 then exchangeRates.eth = bEth / bUsd end
          -- BTC's own price is the base of this query, so its BTC-per-USD rate is just
          -- the reciprocal of bUsd -- no separate vs_currency needed (querying vs_currencies=btc
          -- for ids=bitcoin would trivially return 1).
          exchangeRates.btc = 1.0 / bUsd
          exchangeRates.usd = 1.0
        end
      end
    end
    onDone()
  end)
end

-- Rebuild the published market array from the current coin list. `coinMap` (id -> CoinGecko
-- market item) is used when a fresh fetch succeeded; pass nil to rebuild purely from cached
-- priceHistory/defaultPrice, so a coin list change (add/remove) is always reflected immediately
-- even when CoinGecko is unreachable or rate-limiting us.
local function buildMarketData(coinMap: { [string]: any }?): { any }
  local currentRate = getRate(currentCurrency)
  local updatedMarket = {}

  for _, def in ipairs(coinDefs) do
    local item = if coinMap ~= nil then coinMap[def.id] else nil
    local baseUsdPrice = def.defaultPrice
    local change = 0
    local vol = 0
    local high24 = 0
    local low24 = 0
    local sparkline = nil

    if item ~= nil then
      baseUsdPrice = tonumber(item.current_price) or def.defaultPrice
      change = tonumber(item.price_change_percentage_24h) or 0
      lastChange[def.id] = change
      vol = tonumber(item.total_volume) or 0
      high24 = (tonumber(item.high_24h) or 0) * currentRate
      low24 = (tonumber(item.low_24h) or 0) * currentRate

      if type(item.sparkline_in_7d) == "table" and type(item.sparkline_in_7d.price) == "table" then
        local rawPoints = item.sparkline_in_7d.price
        local totalRaw = #rawPoints
        if totalRaw >= 24 then
          local sliced = {}
          local startIdx = math.max(1, totalRaw - 36)
          for i = startIdx, totalRaw do
            table.insert(sliced, rawPoints[i])
          end
          sparkline = sliced
          priceHistory[def.id] = sliced
        end
      end
    else
      -- No fresh data for this coin (API failure, or just added): fall back to the last
      -- known price and 24h move. Checked outside the priceHistory guard so the change
      -- is restored even for a ticker that has no cached series yet.
      change = lastChange[def.id] or 0
      if priceHistory[def.id] ~= nil and #priceHistory[def.id] > 0 then
        baseUsdPrice = priceHistory[def.id][#priceHistory[def.id]]
      end
    end

    if sparkline == nil then
      if priceHistory[def.id] == nil then
        priceHistory[def.id] = {}
      end
      table.insert(priceHistory[def.id], baseUsdPrice)
      if #priceHistory[def.id] > MAX_HISTORY_POINTS then
        table.remove(priceHistory[def.id], 1)
      end
      sparkline = priceHistory[def.id]
    end

    table.insert(updatedMarket, {
      id = def.id,
      symbol = def.symbol,
      name = def.name,
      glyph = def.glyph,
      kind = def.kind,
      ticker = def.ticker,
      baseUsdPrice = baseUsdPrice,
      price = baseUsdPrice * currentRate,
      change24h = change,
      vol24h = vol * currentRate,
      high24h = high24,
      low24h = low24,
      graphValues = format.normalizeForGraph(sparkline),
    })
  end

  return updatedMarket
end

-- Fetch one stock quote and normalize it into the same item shape buildMarketData
-- already consumes for CoinGecko, so nothing downstream needs to know the difference.
--
--   current_price  <- meta.fulldayPrice   (live, includes extended-hours trading)
--   change / OHLC  <- regular-session meta fields only
--
-- meta.fulldayChangePercent is NOT used: on most symbols it is just a copy of
-- regularMarketChangePercent, and when it does diverge it disagrees with the value
-- computed from fulldayPrice -- so it can't be trusted for either reading.
local function fetchStockQuote(def: any, coinMap: { [string]: any }, onDone: (boolean) -> ())
  local url = string.format(STOCK_CHART_URL, urlEncode(def.ticker or def.symbol))
  noctalia.http({
    url = url,
    method = "GET",
    headers = { "Accept: application/json", "User-Agent: " .. STOCK_UA },
  }, function(res)
    if not res.ok or res.status ~= 200 then
      noctalia.log(string.format("BitDjinn: stock fetch error %s status %d", def.symbol, res.status))
      onDone(false)
      return
    end

    local data = noctalia.json.decode(res.body)
    local result = nil
    if type(data) == "table" and type(data.chart) == "table" and type(data.chart.result) == "table" then
      result = data.chart.result[1]
    end
    if type(result) ~= "table" or type(result.meta) ~= "table" then
      noctalia.log("BitDjinn: unexpected stock payload for " .. def.symbol)
      onDone(false)
      return
    end

    local meta = result.meta
    -- fulldayPrice tracks the extended session; fall back to the regular close when a
    -- symbol has had no pre/post trades (thin names report them as equal anyway).
    local price = tonumber(meta.fulldayPrice) or tonumber(meta.regularMarketPrice)
    if price == nil or price <= 0 then
      onDone(false)
      return
    end

    -- Regular-session closes only -- this is the series the flag-less request returns.
    -- Thin symbols can carry JSON nulls in `close`; if the decoder turns those into nil
    -- they become holes, and ipairs would stop at the first one. `timestamp` is a
    -- parallel array with no nulls, so its length is the safe bound to walk.
    local closes = {}
    if type(result.indicators) == "table" and type(result.indicators.quote) == "table" then
      local quote = result.indicators.quote[1]
      if type(quote) == "table" and type(quote.close) == "table" then
        local count = if type(result.timestamp) == "table" then #result.timestamp else #quote.close
        for i = 1, count do
          local n = tonumber(quote.close[i])
          if n ~= nil and n > 0 then
            table.insert(closes, n)
          end
        end
      end
    end

    local sparkline = nil
    if #closes >= 24 then
      sparkline = downsample(closes, MAX_HISTORY_POINTS)
    end

    coinMap[def.id] = {
      current_price = price,
      price_change_percentage_24h = tonumber(meta.regularMarketChangePercent) or 0,
      total_volume = tonumber(meta.regularMarketVolume) or 0,
      high_24h = tonumber(meta.regularMarketDayHigh) or 0,
      low_24h = tonumber(meta.regularMarketDayLow) or 0,
      sparkline_in_7d = if sparkline ~= nil then { price = sparkline } else nil,
    }
    onDone(true)
  end)
end

local function fetchMarketPrices()
  isUpdating = true
  publishState()

  -- Fetch fresh exchange rates and market data in parallel
  updateExchangeRates(function()
    local cryptoIds = {}
    local stockDefs = {}
    for _, def in ipairs(coinDefs) do
      if isStock(def) then
        table.insert(stockDefs, def)
      else
        table.insert(cryptoIds, def.id)
      end
    end

    -- Both sources write into one map, which is handed to buildMarketData once every
    -- request has reported in. Any id missing from it falls back to cached history, so a
    -- failure on one source never blanks out the other's tickers.
    local coinMap = {}
    local anyOk = false
    -- +1 pre-count so an early synchronous failure can't fire finish() before every
    -- request has been dispatched.
    local pending = 1

    local function finish()
      pending = pending - 1
      if pending > 0 then
        return
      end
      isUpdating = false
      marketData = buildMarketData(coinMap)
      if anyOk then
        lastMarketFetchTime = os.time()
      end
      saveState()
      publishState()
    end

    if #cryptoIds > 0 then
      pending = pending + 1
      local url = string.format(
        "https://api.coingecko.com/api/v3/coins/markets?vs_currency=usd&ids=%s&sparkline=true&price_change_percentage=24h",
        table.concat(cryptoIds, ",")
      )
      noctalia.http({
        url = url,
        method = "GET",
        headers = { "Accept: application/json", "User-Agent: Mozilla/5.0 (Noctalia-BitDjinn)" },
      }, function(res)
        if not res.ok or res.status ~= 200 then
          noctalia.log(string.format("BitDjinn: market fetch error status %d, using cached prices", res.status))
          finish()
          return
        end

        local data, err = noctalia.json.decode(res.body)
        if err ~= nil or type(data) ~= "table" then
          noctalia.log("BitDjinn: json decode error for market data")
          finish()
          return
        end

        for _, item in ipairs(data) do
          if type(item) == "table" and item.id ~= nil then
            coinMap[item.id] = item
            anyOk = true
          end
        end
        finish()
      end)
    end

    -- Yahoo has no batch endpoint, so this is one request per stock per poll. Keep the
    -- `interval` setting reasonably high if you watch a lot of tickers.
    for _, def in ipairs(stockDefs) do
      pending = pending + 1
      fetchStockQuote(def, coinMap, function(ok)
        if ok then
          anyOk = true
        end
        finish()
      end)
    end

    finish()
  end)
end


-- ── Blockchain Address Watcher ─────────────────────────────────────────────

local function parseHexNumber(hexStr: string?): number
  if hexStr == nil or hexStr == "" then
    return 0
  end
  local clean = string.gsub(hexStr, "^0x", "")
  local n = tonumber(clean, 16)
  return n or 0
end

local function triggerTxAlert(wallet: any, delta: number, isNewTx: boolean)
  if not notifyEnabled then
    return
  end
  local title = noctalia.tr("notify.tx_title")
  local label = wallet.label or format.shortAddress(wallet.address)
  local coin = wallet.chain

  if delta > 0.000001 then
    local body = string.format(noctalia.tr("notify.balance_increase"), string.format("%.4f", delta), coin, label)
    noctalia.notify(title, body)
  elseif delta < -0.000001 then
    local body = string.format(noctalia.tr("notify.balance_decrease"), string.format("%.4f", -delta), coin, label)
    noctalia.notify(title, body)
  elseif isNewTx then
    local body = string.format(noctalia.tr("notify.tx_detected"), label, coin)
    noctalia.notify(title, body)
  end
end

local function checkBtcAddress(wallet: any, onDone: () -> ())
  local url = "https://mempool.space/api/address/" .. wallet.address
  noctalia.http({ url = url, method = "GET" }, function(res)
    if res.ok and res.status == 200 then
      local data = noctalia.json.decode(res.body)
      if type(data) == "table" and type(data.chain_stats) == "table" then
        local funded = tonumber(data.chain_stats.funded_txo_sum) or 0
        local spent = tonumber(data.chain_stats.spent_txo_sum) or 0
        local txCount = (tonumber(data.chain_stats.tx_count) or 0)
        local mempoolTxs = 0
        if type(data.mempool_stats) == "table" then
          mempoolTxs = tonumber(data.mempool_stats.tx_count) or 0
        end
        local totalTx = txCount + mempoolTxs
        local newBalance = (funded - spent) / 100000000.0

        if wallet.initialized then
          local delta = newBalance - (wallet.balance or 0)
          local hasNewTx = totalTx > (wallet.txCount or 0)
          if math.abs(delta) > 0.00000001 or hasNewTx then
            triggerTxAlert(wallet, delta, hasNewTx)
          end
        end

        wallet.balance = newBalance
        wallet.txCount = totalTx
        wallet.initialized = true
        wallet.lastChecked = os.date("%H:%M:%S")
      end
    end
    onDone()
  end)
end

local function checkEthAddress(wallet: any, onDone: () -> ())
  local rpcUrl = "https://ethereum-rpc.publicnode.com"
  local balancePayload = noctalia.json.encode({
    jsonrpc = "2.0",
    method = "eth_getBalance",
    params = { wallet.address, "latest" },
    id = 1,
  })

  noctalia.http({
    url = rpcUrl,
    method = "POST",
    headers = { "Content-Type: application/json" },
    body = balancePayload,
  }, function(res)
    if res.ok and res.status == 200 then
      local data = noctalia.json.decode(res.body)
      if type(data) == "table" and data.result ~= nil then
        local wei = parseHexNumber(data.result)
        local newBalance = wei / 1000000000000000000.0

        local txCountPayload = noctalia.json.encode({
          jsonrpc = "2.0",
          method = "eth_getTransactionCount",
          params = { wallet.address, "latest" },
          id = 2,
        })
        noctalia.http({
          url = rpcUrl,
          method = "POST",
          headers = { "Content-Type: application/json" },
          body = txCountPayload,
        }, function(txRes)
          local txCount = wallet.txCount or 0
          if txRes.ok and txRes.status == 200 then
            local txData = noctalia.json.decode(txRes.body)
            if type(txData) == "table" and txData.result ~= nil then
              txCount = parseHexNumber(txData.result)
            end
          end

          if wallet.initialized then
            local delta = newBalance - (wallet.balance or 0)
            local hasNewTx = txCount > (wallet.txCount or 0)
            if math.abs(delta) > 0.00000001 or hasNewTx then
              triggerTxAlert(wallet, delta, hasNewTx)
            end
          end

          wallet.balance = newBalance
          wallet.txCount = txCount
          wallet.initialized = true
          wallet.lastChecked = os.date("%H:%M:%S")
          onDone()
        end)
        return
      end
    end
    onDone()
  end)
end

local function checkSolAddress(wallet: any, onDone: () -> ())
  local rpcUrl = "https://api.mainnet-beta.solana.com"
  local payload = noctalia.json.encode({
    jsonrpc = "2.0",
    method = "getBalance",
    params = { wallet.address },
    id = 1,
  })

  noctalia.http({
    url = rpcUrl,
    method = "POST",
    headers = { "Content-Type: application/json" },
    body = payload,
  }, function(res)
    if res.ok and res.status == 200 then
      local data = noctalia.json.decode(res.body)
      if type(data) == "table" and type(data.result) == "table" then
        local lamports = tonumber(data.result.value) or 0
        local newBalance = lamports / 1000000000.0

        if wallet.initialized then
          local delta = newBalance - (wallet.balance or 0)
          if math.abs(delta) > 0.00000001 then
            triggerTxAlert(wallet, delta, false)
          end
        end

        wallet.balance = newBalance
        wallet.initialized = true
        wallet.lastChecked = os.date("%H:%M:%S")
      end
    end
    onDone()
  end)
end

local function fetchWalletBalances()
  if #watchedWallets == 0 then
    publishState()
    return
  end

  local remaining = #watchedWallets
  local function onDoneOne()
    remaining = remaining - 1
    if remaining <= 0 then
      lastWalletFetchTime = os.time()
      saveState()
      publishState()
    end
  end

  for _, w in ipairs(watchedWallets) do
    if w.chain == "BTC" then
      checkBtcAddress(w, onDoneOne)
    elseif w.chain == "ETH" then
      checkEthAddress(w, onDoneOne)
    elseif w.chain == "SOL" then
      checkSolAddress(w, onDoneOne)
    else
      onDoneOne()
    end
  end
end

-- ── Wallet Management Actions ──────────────────────────────────────────────

local function addWallet(addr: string, label: string): (boolean, string?)
  local clean = noctalia.string.trim(addr or "")
  if clean == "" then
    return false, "invalid_address"
  end

  local chain = format.detectChain(clean)
  if chain == "unknown" then
    return false, "invalid_address"
  end

  for _, w in ipairs(watchedWallets) do
    if string.lower(w.address) == string.lower(clean) then
      return false, "duplicate_address"
    end
  end

  local cleanLabel = noctalia.string.trim(label or "")
  if cleanLabel == "" then
    cleanLabel = chain .. " (" .. format.shortAddress(clean) .. ")"
  end

  local newWallet = {
    id = "w_" .. tostring(os.time()) .. "_" .. tostring(#watchedWallets + 1),
    address = clean,
    chain = chain,
    label = cleanLabel,
    balance = 0,
    value = 0,
    txCount = 0,
    initialized = false,
    lastChecked = "--",
  }

  table.insert(watchedWallets, newWallet)
  saveState()
  publishState()

  if chain == "BTC" then
    checkBtcAddress(newWallet, function() saveState() publishState() end)
  elseif chain == "ETH" then
    checkEthAddress(newWallet, function() saveState() publishState() end)
  elseif chain == "SOL" then
    checkSolAddress(newWallet, function() saveState() publishState() end)
  end

  return true, nil
end

local function removeWallet(addrOrId: string): boolean
  local target = noctalia.string.trim(addrOrId or "")
  local idx = nil
  for i, w in ipairs(watchedWallets) do
    if w.id == target or string.lower(w.address) == string.lower(target) then
      idx = i
      break
    end
  end
  if idx ~= nil then
    table.remove(watchedWallets, idx)
    saveState()
    publishState()
    return true
  end
  return false
end

-- ── Coin List Management Actions ───────────────────────────────────────────

local function findCoinIndex(idOrSymbol: string): number?
  local target = string.lower(noctalia.string.trim(idOrSymbol or ""))
  if target == "" then
    return nil
  end
  for i, def in ipairs(coinDefs) do
    if string.lower(def.id) == target or string.lower(def.symbol) == target then
      return i
    end
  end
  return nil
end

-- Splits an add query into (kind, bareSymbol). Stocks and coins share plenty of tickers
-- (ETH, SOL, APT...), so an explicit prefix is the only reliable disambiguator:
--   "$AAPL" / "stock:AAPL" -> forced stock
--   "coin:eth"             -> forced crypto
--   "AAPL"                 -> unforced; caller tries CoinGecko, then falls back to Yahoo
local function parseAddQuery(query: string): (string?, string)
  local clean = noctalia.string.trim(query or "")
  local rest = string.match(clean, "^%$(.+)$")
  if rest ~= nil then
    return "stock", noctalia.string.trim(rest)
  end
  rest = string.match(clean, "^[Ss][Tt][Oo][Cc][Kk]:(.+)$")
  if rest ~= nil then
    return "stock", noctalia.string.trim(rest)
  end
  rest = string.match(clean, "^[Cc][Oo][Ii][Nn]:(.+)$")
  if rest ~= nil then
    return "crypto", noctalia.string.trim(rest)
  end
  return nil, clean
end

local function removeCoin(idOrSymbol: string): boolean
  local idx = findCoinIndex(idOrSymbol)
  if idx == nil then
    return false
  end
  local removedDef = table.remove(coinDefs, idx)
  priceHistory[removedDef.id] = nil
  lastChange[removedDef.id] = nil

  local filteredMarket = {}
  for _, m in ipairs(marketData) do
    if m.id ~= removedDef.id then
      table.insert(filteredMarket, m)
    end
  end
  marketData = filteredMarket

  saveState()
  publishState()
  return true
end

-- Reorders coinDefs (and the published marketData) to match `order`, an array of coin ids.
-- Any id in `order` that no longer exists is skipped; any coin missing from `order` is kept,
-- appended at the end, so a stale/partial order can never drop a ticker from the list.
local function reorderCoins(order: { string }): boolean
  local defById = {}
  for _, def in ipairs(coinDefs) do
    defById[def.id] = def
  end
  local marketById = {}
  for _, m in ipairs(marketData) do
    marketById[m.id] = m
  end

  local newDefs = {}
  local seen = {}
  for _, id in ipairs(order) do
    local def = defById[id]
    if def ~= nil and not seen[id] then
      table.insert(newDefs, def)
      seen[id] = true
    end
  end
  for _, def in ipairs(coinDefs) do
    if not seen[def.id] then
      table.insert(newDefs, def)
      seen[def.id] = true
    end
  end
  coinDefs = newDefs

  local newMarket = {}
  for _, def in ipairs(coinDefs) do
    local m = marketById[def.id]
    if m ~= nil then
      table.insert(newMarket, m)
    end
  end
  marketData = newMarket

  saveState()
  publishState()
  return true
end

-- Resolve a bare ticker against Yahoo and append it as a stock def. Validation is just
-- the quote request itself: if meta comes back with a price, the symbol is real.
local function addStock(symbol: string, onDone: (boolean, string?) -> ())
  local sym = string.upper(noctalia.string.trim(symbol or ""))
  if sym == "" then
    onDone(false, "invalid_ticker")
    return
  end

  local id = "stock:" .. string.lower(sym)
  if findCoinIndex(id) ~= nil or findCoinIndex(sym) ~= nil then
    onDone(false, "duplicate_ticker")
    return
  end

  local url = string.format(STOCK_CHART_URL, urlEncode(sym))
  noctalia.http({
    url = url,
    method = "GET",
    headers = { "Accept: application/json", "User-Agent: " .. STOCK_UA },
  }, function(res)
    if not res.ok or res.status ~= 200 then
      -- Yahoo answers an unknown symbol with 404, so this doubles as "no such ticker".
      onDone(false, if res.status == 404 then "not_found" else "network_error")
      return
    end

    local data = noctalia.json.decode(res.body)
    local result = nil
    if type(data) == "table" and type(data.chart) == "table" and type(data.chart.result) == "table" then
      result = data.chart.result[1]
    end
    if type(result) ~= "table" or type(result.meta) ~= "table" then
      onDone(false, "not_found")
      return
    end

    local meta = result.meta
    local resolvedSymbol = string.upper(meta.symbol or sym)
    local price = tonumber(meta.fulldayPrice) or tonumber(meta.regularMarketPrice) or 1

    table.insert(coinDefs, {
      id = id,
      symbol = resolvedSymbol,
      name = meta.shortName or meta.longName or resolvedSymbol,
      glyph = "chart-candle",
      kind = "stock",
      ticker = resolvedSymbol,
      defaultPrice = price,
    })
    priceHistory[id] = { price, price }

    saveState()
    fetchMarketPrices()
    onDone(true, resolvedSymbol)
  end)
end

local function addCrypto(query: string, allowStockFallback: boolean, onDone: (boolean, string?) -> ())
  local searchUrl = "https://api.coingecko.com/api/v3/search?query=" .. urlEncode(query)
  noctalia.http({
    url = searchUrl,
    method = "GET",
    headers = { "Accept: application/json", "User-Agent: Mozilla/5.0 (Noctalia-BitDjinn)" },
  }, function(res)
    -- An unprefixed query that CoinGecko can't resolve is very likely an equity, so
    -- retry it against Yahoo before giving up.
    local function missed(reason: string)
      if allowStockFallback then
        addStock(query, onDone)
      else
        onDone(false, reason)
      end
    end

    if not res.ok or res.status ~= 200 then
      missed("network_error")
      return
    end

    local data = noctalia.json.decode(res.body)
    if type(data) ~= "table" or type(data.coins) ~= "table" or #data.coins == 0 then
      missed("not_found")
      return
    end

    local top = data.coins[1]
    if type(top) ~= "table" or top.id == nil then
      missed("not_found")
      return
    end

    local resolvedId = string.lower(top.id)
    local resolvedSymbol = string.upper(top.symbol or query)

    if findCoinIndex(resolvedId) ~= nil or findCoinIndex(resolvedSymbol) ~= nil then
      onDone(false, "duplicate_ticker")
      return
    end

    table.insert(coinDefs, {
      id = resolvedId,
      symbol = resolvedSymbol,
      name = top.name or resolvedSymbol,
      glyph = format.coinGlyph(resolvedSymbol),
      kind = "crypto",
      defaultPrice = 1,
    })
    priceHistory[resolvedId] = { 1, 1 }

    saveState()
    fetchMarketPrices()
    onDone(true, resolvedSymbol)
  end)
end

local function addCoin(query: string, onDone: (boolean, string?) -> ())
  local kind, clean = parseAddQuery(query)
  if clean == "" then
    onDone(false, "invalid_ticker")
    return
  end

  if findCoinIndex(clean) ~= nil then
    onDone(false, "duplicate_ticker")
    return
  end

  if kind == "stock" then
    addStock(clean, onDone)
  else
    addCrypto(clean, kind == nil, onDone)
  end
end


-- ── Command & State Watching ───────────────────────────────────────────────

noctalia.state.watch("bitdjinn.cmd", function(cmd)
  if type(cmd) ~= "table" then
    return
  end
  local op = cmd.op
  if op == "add_wallet" then
    local ok, reason = addWallet(cmd.address, cmd.label)
    if not ok and reason ~= nil then
      noctalia.notify(noctalia.tr("title"), noctalia.tr("wallet." .. reason))
    end
  elseif op == "remove_wallet" then
    removeWallet(cmd.address or cmd.id)
  elseif op == "add_coin" then
    addCoin(cmd.query, function(ok, reasonOrSymbol)
      if ok then
        noctalia.notify(noctalia.tr("title"), string.format(noctalia.tr("market.add_success"), reasonOrSymbol))
      else
        noctalia.notify(noctalia.tr("title"), noctalia.tr("market." .. (reasonOrSymbol or "not_found")))
      end
    end)
  elseif op == "remove_coin" then
    if removeCoin(cmd.id) then
      noctalia.notify(noctalia.tr("title"), string.format(noctalia.tr("market.remove_success"), cmd.symbol or cmd.id))
    end
  elseif op == "reorder_coins" then
    if type(cmd.order) == "table" then
      reorderCoins(cmd.order)
    end
  elseif op == "refresh" then
    fetchMarketPrices()
    fetchWalletBalances()
  elseif op == "set_currency" then
    if type(cmd.currency) == "string" then
      currentCurrency = string.lower(cmd.currency)
      saveState()
      -- Instantaneous local currency conversion (0ms)
      publishState()
    end
  elseif op == "toggle_notify" then
    notifyEnabled = not notifyEnabled
    saveState()
    publishState()
  end
  noctalia.state.set("bitdjinn.cmd", nil)
end)

function onConfigChanged()
  local confCur = noctalia.getConfig("currency")
  if confCur ~= nil and confCur ~= "" then
    currentCurrency = string.lower(confCur)
  end
  local confInt = tonumber(noctalia.getConfig("interval"))
  if confInt ~= nil and confInt >= 10 then
    marketPollInterval = confInt
  end
  local confWallInt = tonumber(noctalia.getConfig("wallet_interval"))
  if confWallInt ~= nil and confWallInt >= 15 then
    walletPollInterval = confWallInt
  end
  local confNotify = noctalia.getConfig("notify_tx")
  if type(confNotify) == "boolean" then
    notifyEnabled = confNotify
  end
  local confCoin = noctalia.getConfig("widget_coin")
  if confCoin ~= nil and confCoin ~= "" then
    widgetCoin = string.upper(confCoin)
  end

  publishState()
  fetchMarketPrices()
  fetchWalletBalances()
end

function onIpc(event, payload)
  if event == "refresh" then
    fetchMarketPrices()
    fetchWalletBalances()
    noctalia.notify(noctalia.tr("title"), noctalia.tr("ui.refresh"))
  elseif event == "add" then
    local addr, label = string.match(payload or "", "^(%S+)%s*(.*)$")
    if addr ~= nil then
      local ok, reason = addWallet(addr, label)
      if ok then
        noctalia.notify(noctalia.tr("title"), "Wallet added: " .. addr)
      else
        noctalia.notify(noctalia.tr("title"), "Failed: " .. (reason or "invalid"))
      end
    end
  elseif event == "remove" then
    if removeWallet(payload or "") then
      noctalia.notify(noctalia.tr("title"), "Wallet removed: " .. (payload or ""))
    end
  elseif event == "toggle_notify" then
    notifyEnabled = not notifyEnabled
    saveState()
    publishState()
    noctalia.notify(noctalia.tr("title"), if notifyEnabled then noctalia.tr("shortcut.label_on") else noctalia.tr("shortcut.label_off"))
  end
end

-- ── Main Loop ──────────────────────────────────────────────────────────────

function update()
  tickCount = tickCount + 1

  if tickCount % marketPollInterval == 0 or os.time() - lastMarketFetchTime > marketPollInterval then
    fetchMarketPrices()
  end

  if tickCount % walletPollInterval == 0 or os.time() - lastWalletFetchTime > walletPollInterval then
    fetchWalletBalances()
  end
end

-- ── Boot Initialization ────────────────────────────────────────────────────

loadState()
onConfigChanged()
fetchMarketPrices()
fetchWalletBalances()
