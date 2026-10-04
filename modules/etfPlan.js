// Dip rules for equity ETF buys. This is the Alpaca watchlist shape
// (specials vs regulars, red P&L, then a deeper dip) but the Chicago
// calendar date comes from America/Chicago. Alpaca's hasBoughtToday()
// uses toISOString(), which is UTC, and that is intentionally not copied:
// a buy after 7 PM Chicago would otherwise count as the next day.
//
// quote_usd is the notional of each attempt (currently $1). It is not a
// share count. is_special is what keeps XDTE off the special repeat-buy
// and end-of-session catch-up rules.

// Minutes since midnight in America/Chicago, including DST.
function chicagoMinutes(date = new Date()) {
    const parts = new Intl.DateTimeFormat('en-US', {
        timeZone: 'America/Chicago',
        hour: '2-digit',
        minute: '2-digit',
        hourCycle: 'h23',
    }).formatToParts(date)
    const pick = (type) => Number(parts.find((p) => p.type === type)?.value)
    return pick('hour') * 60 + pick('minute')
}

// 2:45 PM through 3:00 PM Chicago. 3:00:00 is included; 3:01 is not.
// The caller still requires equity_session_open, so this does not
// hardcode the 9:30-4:00 session. A closed session never catch-up buys.
function inCatchUpWindow(date = new Date()) {
    const minutes = chicagoMinutes(date)
    return minutes >= (14 * 60 + 45) && minutes <= (15 * 60)
}

// One ticker, one decision. catchUp is only passed for a special that
// has not already been chosen by the dip pass.
function decideEtfAttempt(input) {
    const {
        isSpecial,
        boughtToday,
        pending,
        sharesKnown,
        shares,
        price,
        averageEntry,
        unrealizedPnl,
        lastFillPrice,
        catchUp,
    } = input

    if (pending) {
        return {
            attempt: false,
            reason: 'an earlier buy is still open and might fill',
            dipPrice: null,
        }
    }
    if (!sharesKnown) {
        return {
            attempt: false,
            reason: 'share count unreadable, not assuming a flat position',
            dipPrice: null,
        }
    }
    if (catchUp) {
        if (!isSpecial) {
            return {
                attempt: false,
                reason: 'regulars do not get the session-end catch-up',
                dipPrice: null,
            }
        }
        if (boughtToday) {
            return { attempt: false, reason: 'already filled today', dipPrice: null }
        }
        return {
            attempt: true,
            reason: 'special catch-up in the last 15 Chicago minutes; red/dip ignored',
            dipPrice: null,
        }
    }

    // First attempt of the Chicago day.
    if (!boughtToday) {
        if (!(Number(shares) > 0)) {
            return {
                attempt: true,
                reason: 'no shares held; first $1 of the Chicago day needs no red P&L',
                dipPrice: null,
            }
        }
        // Prefer Coinbase unrealized_pnl when the equity position has it.
        // Otherwise compare the live product price with average entry.
        // Never invent either number.
        if (unrealizedPnl != null && Number.isFinite(Number(unrealizedPnl))) {
            if (!(Number(unrealizedPnl) < 0)) {
                return {
                    attempt: false,
                    reason: `unrealized P&L is not negative (${unrealizedPnl})`,
                    dipPrice: price || null,
                }
            }
            return {
                attempt: true,
                reason: 'first buy today and unrealized P&L is negative',
                dipPrice: price || null,
            }
        }
        if (!(Number(price) > 0) || !(Number(averageEntry) > 0)) {
            return {
                attempt: false,
                reason: 'shares are held but there is no unrealized P&L and no price to compare with average cost',
                dipPrice: null,
            }
        }
        if (!(Number(price) < Number(averageEntry))) {
            return {
                attempt: false,
                reason: `price ${price} is not below average cost ${averageEntry}`,
                dipPrice: price,
            }
        }
        return {
            attempt: true,
            reason: 'first buy today and price is below average cost',
            dipPrice: price,
        }
    }

    // Later attempt the same Chicago day. Bought-today is a filled
    // etf_buy row for that Chicago date, not a UTC timestamp.
    if (!(Number(price) > 0) || !(Number(lastFillPrice) > 0)) {
        return {
            attempt: false,
            reason: 'later buy needs a live price and a last filled buy price; neither was invented',
            dipPrice: null,
        }
    }
    if (isSpecial) {
        if (!(Number(price) < Number(lastFillPrice))) {
            return {
                attempt: false,
                reason: `price ${price} is not below last fill ${lastFillPrice}`,
                dipPrice: price,
            }
        }
        return {
            attempt: true,
            reason: 'special later buy; price is below the last fill',
            dipPrice: price,
        }
    }
    const gate = Number(lastFillPrice) * 0.99
    if (!(Number(price) < gate)) {
        return {
            attempt: false,
            reason: `price ${price} is not below last fill ${lastFillPrice} * 0.99 (${gate})`,
            dipPrice: price,
        }
    }
    return {
        attempt: true,
        reason: 'regular later buy; price is more than 1% under the last fill',
        dipPrice: price,
    }
}

// Specials keep their ticker order and may all be chosen. Regulars stop
// at the first one that qualifies, so only one regular is attempted
// per minute. The catch-up pass adds specials the dip pass did not
// already choose. It does not add regulars.
function planAttempts(rows, infoByTicker, catchUp) {
    const notes = []
    const ordered = [...rows].sort((a, b) => String(a.ticker).localeCompare(String(b.ticker)))
    const specials = ordered.filter((r) => r.is_special === true)
    const regulars = ordered.filter((r) => r.is_special !== true)
    const chosen = []
    const chosenTickers = new Set()

    function consider(row, asCatchUp) {
        const info = infoByTicker[row.ticker] || {}
        const decision = decideEtfAttempt({
            isSpecial: row.is_special === true,
            boughtToday: info.boughtToday === true,
            pending: info.pending === true,
            sharesKnown: info.sharesKnown !== false,
            shares: info.shares,
            price: info.price,
            averageEntry: info.averageEntry,
            unrealizedPnl: info.unrealizedPnl,
            lastFillPrice: info.lastFillPrice,
            catchUp: asCatchUp,
        })
        if (!decision.attempt) {
            notes.push(`ETF skip ${row.ticker}: ${decision.reason}`)
            return false
        }
        chosen.push({
            ticker: row.ticker,
            product_id: row.product_id,
            quote_usd: Number(row.quote_usd),
            is_special: row.is_special === true,
            dipPrice: decision.dipPrice,
            reason: decision.reason,
        })
        chosenTickers.add(row.ticker)
        notes.push(`ETF plan ${row.ticker}: ${decision.reason}`)
        return true
    }

    for (const row of specials) consider(row, false)
    for (const row of regulars) {
        if (consider(row, false)) break
    }
    if (catchUp) {
        for (const row of specials) {
            if (chosenTickers.has(row.ticker)) continue
            consider(row, true)
        }
    }
    return { chosen, notes }
}

// Walk the plan in priority order and keep only the attempts Default
// USD can still cover. A ticker that does not fit is skipped for cash
// and is not part of the reserve, so crypto is not blocked by dollars
// this run will not spend. Already-filled tickers never enter `chosen`.
function fundAttempts(chosen, available) {
    let cash = Number(available)
    const attempts = []
    const notes = []
    if (!Number.isFinite(cash)) cash = 0
    for (const row of chosen) {
        const quote = Number(row.quote_usd)
        if (!(quote > 0) || !(cash >= quote)) {
            notes.push(`ETF skip ${row.ticker}: needs $${Number.isFinite(quote) ? quote.toFixed(2) : quote} Default USD, have $${cash.toFixed(2)} (not reserved)`)
            continue
        }
        attempts.push(row)
        cash -= quote
    }
    const reserve = attempts.reduce((sum, row) => sum + Number(row.quote_usd), 0)
    return { attempts, reserve, notes }
}

module.exports = {
    chicagoMinutes,
    inCatchUpWindow,
    decideEtfAttempt,
    planAttempts,
    fundAttempts,
}
