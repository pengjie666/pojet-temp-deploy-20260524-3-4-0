#!/usr/bin/env bash
set -Eeuo pipefail

APP="/var/www/quant-dashboard"
cd "$APP"

echo "=== patch tsconfig: exclude scripts from production lint ==="
python3 - <<'PY'
import json
from pathlib import Path
p = Path('tsconfig.json')
data = json.loads(p.read_text())
exclude = data.setdefault('exclude', [])
for item in ['backups', 'dist', 'node_modules', 'scripts']:
    if item not in exclude:
        exclude.append(item)
p.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
PY

echo "=== patch Dockerfile: ensure manuals directory exists ==="
python3 - <<'PY'
from pathlib import Path
p = Path('Dockerfile')
s = p.read_text()
if 'RUN mkdir -p manuals' not in s:
    if 'COPY . .\n' in s:
        s = s.replace('COPY . .\n', 'COPY . .\nRUN mkdir -p manuals\n', 1)
    else:
        s = s.replace('RUN npm run build', 'RUN mkdir -p manuals\nRUN npm run build', 1)
p.write_text(s)
Path('manuals').mkdir(exist_ok=True)
PY

echo "=== docker build ==="
sudo docker compose build quant-dashboard apex-api

echo "=== docker restart ==="
sudo docker compose up -d --no-deps quant-dashboard apex-api

echo "=== wait health ==="
sleep 20

echo "=== container status ==="
sudo docker compose ps

echo "=== recent logs if any ==="
sudo docker compose logs --tail=80 quant-dashboard apex-api || true

echo "=== local receiver manifest check ==="
curl -sS -i http://127.0.0.1/api/signal-relay/receiver-manifest | head -80 || true

echo "=== public home check ==="
curl -sS -I http://127.0.0.1/ | head -20 || true

echo "=== deploy hotfix done ==="