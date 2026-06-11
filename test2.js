// Sample price data (timestamp in ISO format, price in USD)
const priceData = [
    { timestamp: "2025-04-28T20:37:00-05:00", price: 95079.00 }, // TradingView
    { timestamp: "2025-04-28T22:00:00-05:00", price: 94648.45 }, // X post
    { timestamp: "2025-04-29T00:00:00-05:00", price: 94391.06 }, // X post
    { timestamp: "2025-04-29T00:06:00-05:00", price: 94333.02 }, // CoinGecko
    { timestamp: "2025-04-29T02:00:00-05:00", price: 94816.83 }, // X post
    { timestamp: "2025-04-29T06:43:00-05:00", price: 95103.47 }, // CoinDesk
    { timestamp: "2025-04-29T07:00:00-05:00", price: 94753.05 }, // Coinbase
];

// Function to calculate average price and percentage movements
function analyzePriceMovements(data) {
    if (!data || data.length < 2) {
        throw new Error("Insufficient data points");
    }

    // Sort data by timestamp to ensure chronological order
    data.sort((a, b) => new Date(a.timestamp) - new Date(b.timestamp));

    // Calculate average price
    const totalPrice = data.reduce((sum, point) => sum + point.price, 0);
    const averagePrice = totalPrice / data.length;

    // Calculate percentage upward and downward movements
    let upwardPercentages = [];
    let downwardPercentages = [];

    for (let i = 1; i < data.length; i++) {
        const prevPrice = data[i - 1].price;
        const currPrice = data[i].price;
        const percentChange = ((currPrice - prevPrice) / prevPrice) * 100;

        if (percentChange > 0) {
            upwardPercentages.push(percentChange);
        } else if (percentChange < 0) {
            downwardPercentages.push(-percentChange); // Store as positive
        }
    }

    // Calculate average upward and downward percentage movements
    const avgUpwardPercent = upwardPercentages.length
        ? upwardPercentages.reduce((sum, percent) => sum + percent, 0) / upwardPercentages.length
        : 0;
    const avgDownwardPercent = downwardPercentages.length
        ? downwardPercentages.reduce((sum, percent) => sum + percent, 0) / downwardPercentages.length
        : 0;

    return {
        averagePrice: averagePrice.toFixed(2),
        avgUpwardPercent: avgUpwardPercent.toFixed(4),
        avgDownwardPercent: avgDownwardPercent.toFixed(4),
        upwardCount: upwardPercentages.length,
        downwardCount: downwardPercentages.length,
    };
}

// Run analysis
try {
    const result = analyzePriceMovements(priceData);
    console.log("BTC Price Analysis (Past 24 Hours):");
    console.log(`Average Price: $${result.averagePrice}`);
    console.log(`Average Upward Movement: ${result.avgUpwardPercent}% (${result.upwardCount} occurrences)`);
    console.log(`Average Downward Movement: ${result.avgDownwardPercent}% (${result.downwardCount} occurrences)`);
} catch (error) {
    console.error("Error:", error.message);
}