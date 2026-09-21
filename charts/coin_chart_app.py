"""
Interactive Coinage price + fill chart.

Pick a coin, see hourly close with buy/sell markers (zoom/pan).
Data comes from charts/fetch_chart_data.js (same Coinbase auth as the bot).
"""
from __future__ import annotations

import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

import pandas as pd
import plotly.graph_objects as go
import streamlit as st

CT = ZoneInfo("America/Chicago")
ROOT = Path(__file__).resolve().parent.parent
HELPER = ROOT / "charts" / "fetch_chart_data.js"


def _node_bin() -> str:
    # Streamlit launched via nohup/ssh often has a bare PATH without Homebrew.
    for candidate in ("/opt/homebrew/bin/node", "/usr/local/bin/node"):
        if Path(candidate).exists():
            return candidate
    return "node"


def run_helper(args: list[str]) -> dict:
    """Run the Node Coinbase helper and parse JSON stdout."""
    import os
    env = os.environ.copy()
    homebrew = "/opt/homebrew/bin"
    path = env.get("PATH", "")
    if homebrew not in path.split(":"):
        env["PATH"] = f"{homebrew}:{path}"
    proc = subprocess.run(
        [_node_bin(), str(HELPER), *args],
        cwd=str(ROOT),
        capture_output=True,
        text=True,
        timeout=120,
        env=env,
    )
    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout or "unknown error").strip()
        raise RuntimeError(err)
    return json.loads(proc.stdout)


@st.cache_data(ttl=300, show_spinner=False)
def load_products() -> list[str]:
    data = run_helper(["list"])
    return data.get("products") or []


@st.cache_data(ttl=120, show_spinner="Loading candles and fills…")
def load_chart(product_id: str, days: int) -> dict:
    return run_helper(["data", product_id, str(days)])


def to_ct(ts) -> datetime:
    if isinstance(ts, (int, float)):
        dt = datetime.fromtimestamp(ts, tz=timezone.utc)
    else:
        dt = pd.to_datetime(ts, utc=True).to_pydatetime()
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(CT)


st.set_page_config(page_title="Coinage chart", layout="wide")
st.title("Coinage — price vs fills")
st.caption("Hourly close from Coinbase · buy/sell markers from your fills · times in CT")

try:
    products = load_products()
except Exception as e:
    st.error(f"Could not list products: {e}")
    st.stop()

if not products:
    st.warning("No fill products found yet.")
    st.stop()

col1, col2, col3 = st.columns([2, 1, 1])
with col1:
    # Prefer ALGO if present (recent context), else first product
    default_ix = products.index("ALGO-USD") if "ALGO-USD" in products else 0
    product = st.selectbox("Coin", products, index=default_ix)
with col2:
    days = st.selectbox("Lookback (days)", [14, 30, 45, 60, 90], index=2)
with col3:
    if st.button("Refresh"):
        load_products.clear()
        load_chart.clear()
        st.rerun()

try:
    payload = load_chart(product, int(days))
except Exception as e:
    st.error(f"Could not load {product}: {e}")
    st.stop()

candles = payload.get("candles") or []
fills = payload.get("fills") or []

if not candles and not fills:
    st.info("No candle or fill data in this window.")
    st.stop()

fig = go.Figure()

if candles:
    xs = [to_ct(c["start"]) for c in candles]
    ys = [c["close"] for c in candles]
    fig.add_trace(
        go.Scatter(
            x=xs,
            y=ys,
            mode="lines",
            name="Hourly close",
            line=dict(color="#5b7c99", width=1.5),
            hovertemplate="%{x}<br>$%{y:.6g}<extra>Close</extra>",
        )
    )

buys = [f for f in fills if f.get("side") == "BUY"]
sells = [f for f in fills if f.get("side") == "SELL"]

if buys:
    fig.add_trace(
        go.Scatter(
            x=[to_ct(f["trade_time"]) for f in buys],
            y=[f["price"] for f in buys],
            mode="markers",
            name=f"Buys ({len(buys)})",
            marker=dict(symbol="triangle-up", size=11, color="#27ae60", line=dict(width=0.5, color="white")),
            customdata=[[f.get("size"), f.get("fee")] for f in buys],
            hovertemplate="BUY %{y:.6g}<br>size %{customdata[0]}<br>%{x}<extra></extra>",
        )
    )

if sells:
    fig.add_trace(
        go.Scatter(
            x=[to_ct(f["trade_time"]) for f in sells],
            y=[f["price"] for f in sells],
            mode="markers",
            name=f"Sells ({len(sells)})",
            marker=dict(symbol="triangle-down", size=11, color="#c0392b", line=dict(width=0.5, color="white")),
            customdata=[[f.get("size"), f.get("fee")] for f in sells],
            hovertemplate="SELL %{y:.6g}<br>size %{customdata[0]}<br>%{x}<extra></extra>",
        )
    )

fig.update_layout(
    height=620,
    margin=dict(l=40, r=20, t=40, b=40),
    title=f"{product} · last {days} days",
    xaxis_title="Time (CT)",
    yaxis_title="Price (USD)",
    hovermode="x unified",
    legend=dict(orientation="h", yanchor="bottom", y=1.02, x=0),
    template="plotly_white",
)
fig.update_xaxes(rangeslider_visible=True)

st.plotly_chart(fig, use_container_width=True)

c1, c2, c3 = st.columns(3)
c1.metric("Candles", len(candles))
c2.metric("Buys", len(buys))
c3.metric("Sells", len(sells))

with st.expander("Recent fills"):
    if fills:
        rows = []
        for f in reversed(fills[-40:]):
            rows.append(
                {
                    "time_ct": to_ct(f["trade_time"]).strftime("%Y-%m-%d %H:%M"),
                    "side": f["side"],
                    "price": f["price"],
                    "size": f["size"],
                    "fee": f.get("fee"),
                }
            )
        st.dataframe(pd.DataFrame(rows), use_container_width=True, hide_index=True)
    else:
        st.write("No fills in this window.")
