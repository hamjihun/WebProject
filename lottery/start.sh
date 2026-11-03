#!/bin/sh
cd "$(dirname "$0")"
if [ -x ./node/bin/node ]; then NODE=./node/bin/node
elif command -v node >/dev/null 2>&1; then NODE=node
else echo "Node.js 18 이상이 필요합니다: https://nodejs.org"; exit 1; fi
exec "$NODE" server.js
