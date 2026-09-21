#!/bin/bash
# Open from MacBook: http://Theodores-Mac-mini.local:8501
# Start the interactive Coinage price/fill chart (Streamlit on localhost:8501).
# Uses the project venv under charts/.venv so we don't touch system Python.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENV="$ROOT/charts/.venv"
cd "$ROOT"
if [[ ! -x "$VENV/bin/streamlit" ]]; then
  echo "Creating charts/.venv and installing streamlit/plotly/pandas…"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --upgrade pip
  "$VENV/bin/pip" install streamlit plotly pandas
fi
exec "$VENV/bin/streamlit" run charts/coin_chart_app.py --server.headless true --server.port 8501 --server.address 0.0.0.0
