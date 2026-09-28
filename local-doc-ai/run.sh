#!/usr/bin/env sh
# macOS / Linux 실행 (개발용)
cd "$(dirname "$0")"
[ -x .venv/bin/python ] || { python3 -m venv .venv && .venv/bin/pip install -q -r requirements.txt; }
exec .venv/bin/python -m app
