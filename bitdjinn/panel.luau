--!nonstrict
-- BitDjinn Interactive Dashboard Panel — Declarative UI.
-- Tab 1: Real-time crypto market cards & sparkline trend graphs.
-- Tab 2: Blockchain address watcher, balances, valuation & transaction monitor.

local format = require("./lib/format.luau")

-- ── UI State ───────────────────────────────────────────────────────────────

local activeTab = "market" -- "market" or "wallets"
local addCoinInput = ""
local addCoinDraftCounter = 0
local inputAddress = ""
local inputLabel = ""
local draftCounter = 0

local market = {}
local wallets = {}
local summary = {}

-- ── Tab Renderers ──────────────────────────────────────────────────────────

-- Crypto lives at /symbols/<SYM>USD/ on TradingView; equities are just /symbols/<SYM>/.
local function openTradingView(c: any)
  local symbol = c.symbol or ""
  local path = if c.kind == "stock" then symbol else symbol .. "USD"
  noctalia.runAsync({ "xdg-open", "https://www.tradingview.com/symbols/" .. path .. "/" })
end

-- Thin insertion drop zone between (or after) coin rows, for drag-to-reorder.
local function coinGapZone(anchor: string)
  return ui.dropZone({
    key = "coin-gap-" .. anchor,
    accepts = { "coin" },
    value = anchor,
    onDrop = "onReorderCoin",
    height = 3,
    expandOnDrag = true,
    hitSlop = 24,
  })
end

local function renderMarketTab()
  local rows = {}

  for _, c in ipairs(market) do
    local changeCol = format.changeColor(c.change24h)
    local changeBg = format.changeBgColor(c.change24h)
    local isPos = (c.change24h or 0) >= 0

    table.insert(rows, coinGapZone("before:" .. c.id))

    table.insert(rows, ui.row({
      key = "coin-" .. c.id,
      gap = 8,
      align = "center",
      padding = 8,
      radius = 8,
      fill = "surface_variant/0.2",
      border = "outline/0.15",
    }, {
      -- Drag handle: press-and-drag to reorder this ticker
      ui.dragSource({
        key = "coin-grip-" .. c.id,
        dragType = "coin",
        payload = c.id,
        previewAncestor = 1,
        liftFromLayout = true,
        width = 20,
        height = 20,
        tooltip = noctalia.tr("market.drag_tooltip"),
      }, {
        ui.glyph({ name = "grip-vertical", size = 16, color = "on_surface_variant" }),
      }),

      -- Clickable area: opens TradingView for this coin
      ui.row({
        flexGrow = 1,
        gap = 10,
        align = "center",
        onClick = function() openTradingView(c) end,
      }, {
        -- Coin Icon & Name
        ui.row({ gap = 8, align = "center", width = 110 }, {
          ui.glyph({
            name = c.glyph or format.coinGlyph(c.symbol, c.kind),
            size = 20,
            color = changeCol,
          }),
          ui.column({ gap = 1 }, {
            ui.label({ text = c.symbol, fontWeight = "bold", fontSize = 13 }),
            ui.label({ text = c.name, fontSize = 10, color = "on_surface_variant" }),
          }),
        }),

        -- Sparkline Trend Graph Container
        ui.row({
          width = 86,
          height = 30,
          radius = 6,
          fill = changeBg,
          align = "center",
          justify = "center",
          padding = 2,
        }, {
          ui.graph({
            values = c.graphValues or { 0.5, 0.5, 0.5, 0.5 },
            color = changeCol,
            lineWidth = 2,
            fillOpacity = 0.35,
            width = 82,
            height = 26,
          }),
        }),

        -- Price and Change Pill
        ui.column({ flexGrow = 1, align = "end", gap = 2 }, {
          ui.label({
            text = format.formatPrice(c.price, summary.currency),
            fontWeight = "bold",
            fontSize = 13,
          }),
          ui.row({
            gap = 2,
            align = "center",
            paddingH = 5,
            paddingV = 2,
            radius = 4,
            fill = changeBg,
          }, {
            ui.glyph({
              name = if isPos then "arrow-up-right" else "arrow-down-right",
              size = 11,
              color = changeCol,
            }),
            ui.label({
              text = format.formatChange(c.change24h),
              fontSize = 10,
              fontWeight = "bold",
              color = changeCol,
            }),
          }),
        }),
      }),

      -- Delete button (outside the TradingView click zone)
      ui.button({
        glyph = "trash",
        variant = "ghost",
        controlSize = "sm",
        tooltip = noctalia.tr("market.remove_confirm"),
        onClick = function()
          noctalia.state.set("bitdjinn.cmd", { op = "remove_coin", id = c.id, symbol = c.symbol })
        end,
      }),
    }))
  end

  if #market > 0 then
    table.insert(rows, coinGapZone("end"))
  end

  if #rows == 0 then
    table.insert(rows, ui.column({ align = "center", gap = 8, paddingV = 24 }, {
      ui.glyph({ name = "mood-empty", size = 28, color = "on_surface_variant" }),
      ui.label({ text = noctalia.tr("ui.loading"), color = "on_surface_variant", fontSize = 12 }),
    }))
  end

  return ui.column({ flexGrow = 1, gap = 8 }, {
    -- Add Coin Input
    ui.row({ gap = 6, align = "center" }, {
      ui.input({
        key = "input-addcoin-" .. addCoinDraftCounter,
        value = addCoinInput,
        placeholder = noctalia.tr("market.add_placeholder"),
        flexGrow = 1,
        controlSize = "sm",
        onChange = function(val)
          addCoinInput = val
        end,
        onSubmit = "onAddCoin",
      }),
      ui.button({
        glyph = "plus",
        variant = "primary",
        controlSize = "sm",
        onClick = "onAddCoin",
      }),
    }),
    -- Scrollable coin list
    ui.scroll({ flexGrow = 1, gap = 6 }, rows),
  })
end

local function renderWalletsTab()
  local items = {}

  -- Total valuation banner
  local totalValStr = format.formatPrice(summary.totalValuation or 0, summary.currency)
  local banner = ui.row({
    align = "center",
    justify = "space_between",
    padding = 10,
    radius = 8,
    fill = "primary/0.12",
    border = "primary/0.3",
  }, {
    ui.column({ gap = 2 }, {
      ui.label({ text = noctalia.tr("wallet.total_valuation"), fontSize = 11, color = "on_surface_variant" }),
      ui.label({ text = totalValStr, fontSize = 18, fontWeight = "bold", color = "primary" }),
    }),
    ui.glyph({ name = "wallet", size = 26, color = "primary" }),
  })

  -- Address Add Form
  local addForm = ui.column({
    gap = 6,
    padding = 8,
    radius = 8,
    fill = "surface_variant/0.25",
    border = "outline/0.2",
  }, {
    ui.label({ text = noctalia.tr("wallet.add_title"), fontWeight = "bold", fontSize = 12 }),
    ui.input({
      key = "input-addr-" .. draftCounter,
      value = inputAddress,
      placeholder = noctalia.tr("wallet.input_placeholder"),
      controlSize = "sm",
      onChange = function(val)
        inputAddress = val
      end,
      onSubmit = "onAddWallet",
    }),
    ui.row({ gap = 6, align = "center" }, {
      ui.input({
        key = "input-lbl-" .. draftCounter,
        value = inputLabel,
        placeholder = noctalia.tr("wallet.label_placeholder"),
        flexGrow = 1,
        controlSize = "sm",
        onChange = function(val)
          inputLabel = val
        end,
        onSubmit = "onAddWallet",
      }),
      ui.button({
        text = noctalia.tr("wallet.btn_add"),
        glyph = "plus",
        variant = "primary",
        controlSize = "sm",
        onClick = "onAddWallet",
      }),
    }),
  })

  -- Watched Wallets List
  for _, w in ipairs(wallets) do
    local chainCol = if w.chain == "BTC" then "#f59e0b" elseif w.chain == "ETH" then "#6366f1" else "#14f195"
    local chainBg = if w.chain == "BTC" then "#f59e0b24" elseif w.chain == "ETH" then "#6366f124" else "#14f19524"
    local valStr = format.formatPrice(w.value or 0, summary.currency)
    local balStr = string.format("%.4f %s", w.balance or 0, w.chain or "")

    table.insert(items, ui.row({
      key = "wallet-" .. (w.id or w.address),
      gap = 8,
      align = "center",
      padding = 8,
      radius = 8,
      fill = "surface_variant/0.2",
      border = "outline/0.15",
    }, {
      -- Chain Badge
      ui.row({
        width = 32,
        height = 32,
        radius = 6,
        fill = chainBg,
        align = "center",
        justify = "center",
      }, {
        ui.glyph({ name = format.coinGlyph(w.chain), size = 16, color = chainCol }),
      }),

      -- Address Details & Copy
      ui.column({ flexGrow = 1, gap = 2 }, {
        ui.row({ gap = 6, align = "center" }, {
          ui.label({ text = w.label or w.chain, fontWeight = "bold", fontSize = 12 }),
          ui.label({ text = string.format(noctalia.tr("wallet.tx_count"), w.txCount or 0), fontSize = 10, color = "on_surface_variant" }),
        }),
        ui.row({ gap = 4, align = "center" }, {
          ui.label({ text = format.shortAddress(w.address), fontSize = 11, color = "on_surface_variant" }),
          ui.button({
            glyph = "copy",
            variant = "ghost",
            controlSize = "sm",
            tooltip = "Copy address",
            onClick = function()
              noctalia.copyToClipboard(w.address, "text/plain")
              noctalia.notify(noctalia.tr("title"), noctalia.tr("wallet.copy_success"))
            end,
          }),
        }),
      }),

      -- Balance & Value
      ui.column({ align = "end", gap = 2 }, {
        ui.label({ text = balStr, fontWeight = "bold", fontSize = 12 }),
        ui.label({ text = valStr, fontSize = 11, color = "primary" }),
      }),

      -- Remove button
      ui.button({
        glyph = "trash",
        variant = "ghost",
        controlSize = "sm",
        tooltip = noctalia.tr("wallet.delete_confirm"),
        onClick = function()
          noctalia.state.set("bitdjinn.cmd", { op = "remove_wallet", address = w.address, id = w.id })
        end,
      }),
    }))
  end

  if #items == 0 then
    table.insert(items, ui.column({ align = "center", gap = 8, paddingV = 18 }, {
      ui.glyph({ name = "wallet-off", size = 26, color = "on_surface_variant" }),
      ui.label({ text = noctalia.tr("wallet.empty"), color = "on_surface_variant", fontSize = 11 }),
    }))
  end

  return ui.column({ flexGrow = 1, gap = 8 }, {
    banner,
    addForm,
    ui.scroll({ flexGrow = 1, gap = 6 }, items),
  })
end

-- ── Main Render ────────────────────────────────────────────────────────────

function render()
  -- Header: Title, Tab Navigation Switcher, and Actions (Refresh & Close)
  local header = ui.row({ align = "center", justify = "space_between" }, {
    ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = "currency-bitcoin", size = 20, color = "primary" }),
      ui.label({ text = noctalia.tr("title"), fontSize = 15, fontWeight = "bold" }),
    }),

    -- Tab Switcher Buttons (Market Trends / Wallets & Alerts)
    ui.row({ gap = 4, padding = 2, radius = 6, fill = "surface_variant/0.3" }, {
      ui.button({
        text = noctalia.tr("tab.market"),
        glyph = "chart-line",
        variant = if activeTab == "market" then "primary" else "ghost",
        controlSize = "sm",
        onClick = function()
          activeTab = "market"
          render()
        end,
      }),
      ui.button({
        text = noctalia.tr("tab.wallets"),
        glyph = "wallet",
        variant = if activeTab == "wallets" then "primary" else "ghost",
        controlSize = "sm",
        onClick = function()
          activeTab = "wallets"
          render()
        end,
      }),
    }),

    -- Action Controls
    ui.row({ gap = 2, align = "center" }, {
      ui.button({
        glyph = "refresh",
        variant = "ghost",
        tooltip = noctalia.tr("ui.refresh"),
        onClick = "onRefresh",
      }),
      ui.button({
        glyph = "close",
        variant = "ghost",
        onClick = function() panel.close() end,
      }),
    }),
  })

  -- Currency Selector Bar (USD / CNY / EUR / BTC / ETH)
  local currencyBar = ui.row({
    align = "center",
    justify = "space_between",
    paddingV = 2,
  }, {
    ui.label({
      text = noctalia.tr("settings.currency.label"),
      fontSize = 11,
      color = "on_surface_variant",
    }),
    ui.row({ gap = 2, padding = 2, radius = 6, fill = "surface_variant/0.3" }, {
      ui.button({
        text = "USD",
        variant = if summary.currency == "usd" then "primary" else "ghost",
        controlSize = "sm",
        onClick = function() setCurrency("usd") end,
      }),
      ui.button({
        text = "CNY",
        variant = if summary.currency == "cny" then "primary" else "ghost",
        controlSize = "sm",
        onClick = function() setCurrency("cny") end,
      }),
      ui.button({
        text = "EUR",
        variant = if summary.currency == "eur" then "primary" else "ghost",
        controlSize = "sm",
        onClick = function() setCurrency("eur") end,
      }),
      ui.button({
        text = "BTC",
        variant = if summary.currency == "btc" then "primary" else "ghost",
        controlSize = "sm",
        onClick = function() setCurrency("btc") end,
      }),
      ui.button({
        text = "ETH",
        variant = if summary.currency == "eth" then "primary" else "ghost",
        controlSize = "sm",
        onClick = function() setCurrency("eth") end,
      }),
    }),
  })

  local body = if activeTab == "market" then renderMarketTab() else renderWalletsTab()

  -- Footer with timestamp and Right-side controls (Alert toggle & Settings gear button)
  local footer = ui.row({ align = "center", justify = "space_between", paddingV = 2 }, {
    ui.label({
      text = string.format(noctalia.tr("market.last_updated"), summary.lastUpdated or "--"),
      fontSize = 10,
      color = "on_surface_variant",
    }),
    ui.row({ gap = 4, align = "center" }, {
      ui.button({
        text = if summary.notifyEnabled ~= false then noctalia.tr("shortcut.label_on") else noctalia.tr("shortcut.label_off"),
        glyph = if summary.notifyEnabled ~= false then "bell" else "bell-off",
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          noctalia.state.set("bitdjinn.cmd", { op = "toggle_notify" })
        end,
      }),
      ui.button({
        glyph = "settings",
        variant = "ghost",
        controlSize = "sm",
        tooltip = noctalia.tr("ui.settings"),
        onClick = function()
          noctalia.openSettings()
        end,
      }),
    }),
  })

  panel.render(ui.column({
    flexGrow = 1,
    gap = 8,
    padding = 10,
  }, {
    header,
    currencyBar,
    body,
    ui.separator({ thickness = 1, color = "outline/0.2" }),
    footer,
  }))
end

-- ── Callbacks ──────────────────────────────────────────────────────────────

function setCurrency(cur: string)
  noctalia.state.set("bitdjinn.cmd", { op = "set_currency", currency = cur })
end

function onRefresh()
  noctalia.state.set("bitdjinn.cmd", { op = "refresh" })
end

function onAddCoin()
  local q = noctalia.string.trim(addCoinInput)
  if q ~= "" then
    noctalia.state.set("bitdjinn.cmd", { op = "add_coin", query = q })
    addCoinInput = ""
    addCoinDraftCounter = addCoinDraftCounter + 1
    render()
  end
end

function onReorderCoin(id: string, target: string)
  local order = {}
  for _, c in ipairs(market) do
    if c.id ~= id then
      table.insert(order, c.id)
    end
  end

  if target == "end" then
    table.insert(order, id)
  else
    local beforeId = string.match(target, "^before:(.+)$")
    local insertIdx = #order + 1
    for i, oid in ipairs(order) do
      if oid == beforeId then
        insertIdx = i
        break
      end
    end
    table.insert(order, insertIdx, id)
  end

  -- Optimistic local reorder so the drop lands instantly, without a flash
  local byId = {}
  for _, c in ipairs(market) do
    byId[c.id] = c
  end
  local reordered = {}
  for _, oid in ipairs(order) do
    if byId[oid] ~= nil then
      table.insert(reordered, byId[oid])
    end
  end
  market = reordered
  render()

  noctalia.state.set("bitdjinn.cmd", { op = "reorder_coins", order = order })
end

function onAddWallet()
  local addr = noctalia.string.trim(inputAddress)
  local lbl = noctalia.string.trim(inputLabel)
  if addr ~= "" then
    noctalia.state.set("bitdjinn.cmd", { op = "add_wallet", address = addr, label = lbl })
    inputAddress = ""
    inputLabel = ""
    draftCounter = draftCounter + 1
    render()
  end
end

function onOpen(_context)
  market = noctalia.state.get("bitdjinn.market") or {}
  wallets = noctalia.state.get("bitdjinn.wallets") or {}
  summary = noctalia.state.get("bitdjinn.summary") or {}
  render()
end

noctalia.state.watch("bitdjinn.market", function(val)
  if type(val) == "table" then market = val else market = {} end
  render()
end)

noctalia.state.watch("bitdjinn.wallets", function(val)
  if type(val) == "table" then wallets = val else wallets = {} end
  render()
end)

noctalia.state.watch("bitdjinn.summary", function(val)
  if type(val) == "table" then summary = val else summary = {} end
  render()
end)

-- Initial render
market = noctalia.state.get("bitdjinn.market") or {}
wallets = noctalia.state.get("bitdjinn.wallets") or {}
summary = noctalia.state.get("bitdjinn.summary") or {}
render()
