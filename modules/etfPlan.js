// Limit-order math for equity ETF buys (2026-10-06 redesign).
//
// Retired 2026-10-06: the dip rules ("IEX mid < last fill" market re-buy
// every minute, regulars' 1% dip re-buy, 2:45 PM CT market catch-up). The
// IEX mid on thin ETFs (BLOX quoted 13.43 x 14.45) sat below every
// Coinbase fill, so specials re-bought $1 at market every minute.
// Kept: the once-per-Chicago-day $1 market buy (index.js placeEtfMarket).
//
// New: every enabled ticker keeps exactly ONE resting limit buy (index.js
// syncEtfLimitOrders / buildEtfPlan / placeEtfLimit). Its price is a step
// under a basis price (the latest real fill VWAP, else the best bid). This
// file only does the arithmetic so it can be checked without the API.

// Number of decimals in an increment string such as "0.01" or "0.00001".
function decimalsOf(increment) {
    const text = String(increment || '')
    const dot = text.indexOf('.')
    if (dot < 0) return 0
    return text.slice(dot + 1).replace(/0+$/, '').length || 0
}

// Snap value DOWN (floor) or UP (ceil) to a multiple of increment, using
// integer ticks so 13.96 does not become 13.959999999. Returns a string
// with exactly the increment's decimals (what Coinbase expects).
function snap(value, increment, mode) {
    const inc = Number(increment)
    if (!(inc > 0) || !Number.isFinite(Number(value))) return null
    const ticks = Number(value) / inc
    // 1e-9 tolerance: 13.96 / 0.01 can come out as 1395.9999999998.
    const whole = mode === 'up' ? Math.ceil(ticks - 1e-9) : Math.floor(ticks + 1e-9)
    return (whole * inc).toFixed(decimalsOf(increment))
}

// Limit price = basis * (1 - stepPct/100), floored to the product's
// price_increment. stepPct is a percent (0.10 means 0.10%, from
// config.etf_limit_step_pct). Flooring keeps the limit at or under the
// exact step (for a $14 ETF 0.10% is 1.4 cents, so it rounds to 1 cent
// lower than a plain round would). Never returns a price >= basis.
function limitPriceFrom(basis, stepPct, priceIncrement) {
    const b = Number(basis)
    const step = Number(stepPct)
    if (!(b > 0) || !(step >= 0)) return null
    let price = snap(b * (1 - step / 100), priceIncrement, 'down')
    if (price == null) return null
    // A tiny basis or a coarse tick could floor back to the basis itself;
    // force at least one tick under it so the order really is below.
    if (!(Number(price) < b)) price = snap(b - Number(priceIncrement), priceIncrement, 'down')
    return Number(price) > 0 ? price : null
}

// Shares for a notional at the limit: notional / limit, rounded UP to
// base_increment so the order is never under the $1 fractional minimum
// (rounding down would give $0.99997 and Coinbase rejects < $1).
function baseSizeFor(notional, limitPrice, baseIncrement) {
    const n = Number(notional)
    const p = Number(limitPrice)
    if (!(n > 0) || !(p > 0)) return null
    const size = snap(n / p, baseIncrement, 'up')
    return Number(size) > 0 ? size : null
}

// Walk the planned placements in ticker order and keep only the ones
// Default USD can cover. Skipped tickers are not reserved, so crypto is
// not blocked by dollars this run will not spend.
function fundAttempts(chosen, available) {
    let cash = Number(available)
    const attempts = []
    const notes = []
    if (!Number.isFinite(cash)) cash = 0
    for (const row of chosen) {
        const cost = Number(row.notional)
        if (!(cost > 0) || !(cash >= cost)) {
            notes.push(`ETF skip ${row.ticker}: limit needs $${Number.isFinite(cost) ? cost.toFixed(2) : cost} Default USD, have $${cash.toFixed(2)} (not reserved)`)
            continue
        }
        attempts.push(row)
        cash -= cost
    }
    const reserve = attempts.reduce((sum, row) => sum + Number(row.notional), 0)
    return { attempts, reserve, notes }
}

// 2026-10-07 (Theodore): ETFs Coinbase also lists in USDC buy with USDC,
// the rest with USD. Same walk as fundAttempts, but with two separate pots:
//   - row.usdcProductId set (etf.usdc_product_id) -> pay from the USDC pot
//     and send the order to the USDC product id.
//   - USDC pot too small -> if fallbackUsd (config.etf_usdc_fallback_usd,
//     default true) pay from the USD pot on the USD product id instead, so
//     ETF buying does not stall while USDC is near $0; else skip this minute.
//   - row.usdcProductId NULL (TOPW) -> USD pot, USD product id, as before.
// Each funded row gets quoteCurrency ('USD' | 'USDC') and orderProductId.
// reserve is USD ONLY: it becomes config.etf_usd_reserve, which
// thee_procedure subtracts from free USD for crypto. USDC-funded rows must
// not hold back USD. usdcPlanned is the USDC total, for the log only.
function fundAttemptsByCurrency(chosen, pots, fallbackUsd) {
    let usd = Number(pots?.usd)
    let usdc = Number(pots?.usdc)
    if (!Number.isFinite(usd)) usd = 0
    if (!Number.isFinite(usdc)) usdc = 0
    const attempts = []
    const notes = []
    for (const row of chosen) {
        const cost = Number(row.notional)
        const costText = Number.isFinite(cost) ? cost.toFixed(2) : String(cost)
        if (!(cost > 0)) {
            notes.push(`ETF skip ${row.ticker}: bad notional ${costText} (not reserved)`)
            continue
        }
        if (row.usdcProductId) {
            if (usdc >= cost) {
                attempts.push({ ...row, quoteCurrency: 'USDC', orderProductId: row.usdcProductId })
                usdc -= cost
                continue
            }
            if (!fallbackUsd) {
                notes.push(`ETF skip ${row.ticker}: needs ${costText} USDC, have ${usdc.toFixed(2)} USDC (USD fallback off, not reserved)`)
                continue
            }
            if (usd >= cost) {
                notes.push(`ETF ${row.ticker}: USDC short (${usdc.toFixed(2)} < ${costText}), falling back to USD`)
                attempts.push({ ...row, quoteCurrency: 'USD', orderProductId: row.product_id })
                usd -= cost
                continue
            }
            notes.push(`ETF skip ${row.ticker}: needs $${costText}, have ${usdc.toFixed(2)} USDC and $${usd.toFixed(2)} Default USD (not reserved)`)
            continue
        }
        if (usd >= cost) {
            attempts.push({ ...row, quoteCurrency: 'USD', orderProductId: row.product_id })
            usd -= cost
            continue
        }
        notes.push(`ETF skip ${row.ticker}: limit needs $${costText} Default USD, have $${usd.toFixed(2)} (not reserved)`)
    }
    const sum = (cur) => attempts
        .filter((row) => row.quoteCurrency === cur)
        .reduce((total, row) => total + Number(row.notional), 0)
    return { attempts, reserve: sum('USD'), usdcPlanned: sum('USDC'), notes }
}

module.exports = {
    decimalsOf,
    snap,
    limitPriceFrom,
    baseSizeFor,
    fundAttempts,
    fundAttemptsByCurrency,
}
