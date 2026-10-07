#!/usr/bin/env node
// scripts/convert.js -- run a USD <-> USDC convert BY HAND.
//
//   node scripts/convert.js usd-to-usdc 5.00            quote only (moves nothing)
//   node scripts/convert.js usdc-to-usd 5.00            quote only (moves nothing)
//   node scripts/convert.js usd-to-usdc 5.00 --commit   actually converts
//   node scripts/convert.js accounts                    show the USD / USDC account uuids
//
// Without --commit this only asks Coinbase for a quote and prints it. A
// quote does not move money; it just expires if nobody commits it. With
// --commit the quote is sanity-checked (rate ~1:1, no fee, receive >= 99.5%
// of what is sent), committed, and polled until Coinbase reports it
// COMPLETED or CANCELED.
//
// Not wired into index.js or any cron: it only runs when you type it.
// Heads-up: the bot only counts USD as spendable cash (vw_balance name =
// 'USD' in thee_procedure), so USD converted to USDC is invisible to the
// buy logic until it is converted back.

const path = require('path')
const convert = require(path.join(__dirname, '..', 'modules', 'convert.js'))

const DIRECTIONS = {
    'usd-to-usdc': ['USD', 'USDC'],
    'usdc-to-usd': ['USDC', 'USD']
}

function usage (msg) {
    if (msg) console.error(`Error: ${msg}\n`)
    console.error('Usage: node scripts/convert.js <usd-to-usdc|usdc-to-usd> <amount> [--commit]')
    console.error('       node scripts/convert.js accounts')
    process.exit(1)
}

function printTrade (label, t) {
    console.log(`${label}`)
    console.log(`  trade id       ${t.tradeId}`)
    console.log(`  status         ${t.status}`)
    console.log(`  direction      ${t.from} -> ${t.to}`)
    console.log(`  you entered    ${t.entered}`)
    console.log(`  leaves ${String(t.from).padEnd(7)} ${t.sent}`)
    console.log(`  lands in ${String(t.to).padEnd(5)} ${t.received}`)
    console.log(`  fee            ${t.totalFee}${t.fees.length ? `  (${t.fees.join('; ')})` : ''}`)
    console.log(`  exchange rate  ${t.exchangeRate}`)
    console.log(`  effective rate ${t.effectiveRate !== null ? t.effectiveRate.toFixed(6) : 'n/a'}`)
    if (t.cancellationReason) console.log(`  canceled       ${t.cancellationReason}`)
}

async function main () {
    const args = process.argv.slice(2)
    const commit = args.includes('--commit')
    const pos = args.filter(a => !a.startsWith('--'))

    if (pos[0] === 'accounts') {
        console.log(`USD  account uuid: ${await convert.getAccountUuid('USD')}`)
        console.log(`USDC account uuid: ${await convert.getAccountUuid('USDC')}`)
        return
    }

    const dir = DIRECTIONS[(pos[0] || '').toLowerCase()]
    if (!dir) usage('first argument must be usd-to-usdc, usdc-to-usd or accounts')
    const amount = Number(pos[1])
    if (!Number.isFinite(amount) || amount <= 0) usage(`amount must be a positive number, got "${pos[1]}"`)
    const [from, to] = dir

    console.log(`${commit ? 'CONVERTING' : 'Quote only (no --commit, nothing will move)'}: ${amount.toFixed(2)} ${from} -> ${to}\n`)
    const result = await convert.convert(from, to, amount, { commit })

    printTrade('Quote:', result.quote)
    console.log(`  from wallet    ${result.quote.fromAccount} (${result.quote.fromUuid})`)
    console.log(`  to wallet      ${result.quote.toAccount} (${result.quote.toUuid})`)

    if (result.problems.length) {
        console.log('\nREFUSED, quote failed the sanity check (nothing committed):')
        for (const p of result.problems) console.log(`  - ${p}`)
        process.exitCode = 2
        return
    }
    console.log('\nSanity check: OK (rate ~1:1, no fee)')

    if (!result.committed) {
        console.log('Not committed. Re-run with --commit to actually convert. This quote will simply expire.')
        return
    }

    console.log('')
    printTrade('Result:', result.final)
    if (result.final.status === 'TRADE_STATUS_COMPLETED') {
        console.log('\nDONE: convert completed.')
    } else if (result.final.status === 'TRADE_STATUS_CANCELED') {
        console.log('\nCANCELED by Coinbase, no money moved.')
        process.exitCode = 3
    } else {
        console.log(`\nStill ${result.final.status} after ~60 s. Check it later with the trade id above.`)
        process.exitCode = 4
    }
}

main().catch(err => {
    console.error(`\nFAILED: ${err.message}`)
    process.exit(1)
})
