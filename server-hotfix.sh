#!/usr/bin/env bash
set -Eeuo pipefail

APP="/var/www/quant-dashboard"
EXE_URL="https://github.com/pengjie666/pojet-temp-deploy-20260524-3-4-0/releases/download/v3.4.0/receiver-3.4.0.exe"
PY_URL="https://github.com/pengjie666/pojet-temp-deploy-20260524-3-4-0/releases/download/v3.4.0/receiver-3.4.0.py"
EXE_SHA="5552be9369f405ef289665a7de7e404580d8587b7fda274aad358dd90a132ffe"
PY_SHA="a21b71bbdadc7e5ddffb93c3609b5bcc24ca7540d914d254f27b7c5526d302da"
EXE_NAME="朴捷资本APEX_QUANT接收端.exe"
PY_NAME="朴捷资本APEX_QUANT接收端.py"

cd "$APP"

echo "=== install receiver 3.4.0 assets ==="
mkdir -p public/downloads public/downloads/receiver/latest dist/downloads dist/downloads/receiver/latest
curl -L --fail --show-error -o "/tmp/receiver-3.4.0.exe" "$EXE_URL"
curl -L --fail --show-error -o "/tmp/receiver-3.4.0.py" "$PY_URL"
echo "$EXE_SHA  /tmp/receiver-3.4.0.exe" | sha256sum -c -
echo "$PY_SHA  /tmp/receiver-3.4.0.py" | sha256sum -c -
cp /tmp/receiver-3.4.0.exe "public/downloads/$EXE_NAME"
cp /tmp/receiver-3.4.0.py "public/downloads/$PY_NAME"
cp /tmp/receiver-3.4.0.exe "public/downloads/receiver/latest/$EXE_NAME"
cp /tmp/receiver-3.4.0.exe "dist/downloads/$EXE_NAME" 2>/dev/null || true
cp /tmp/receiver-3.4.0.py "dist/downloads/$PY_NAME" 2>/dev/null || true
cp /tmp/receiver-3.4.0.exe "dist/downloads/receiver/latest/$EXE_NAME" 2>/dev/null || true

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

echo "=== patch receiver auto-update endpoints ==="
python3 - <<'PY'
from pathlib import Path
import re
p = Path('server.ts')
s = p.read_text()

public_manifest_route = '''
  // Public receiver update manifest: the desktop receiver must be able to check updates
  // even when the web dashboard login session has expired.
  app.get("/api/signal-relay/receiver-manifest", strictRateLimit, async (_req: any, res) => {
    try {
      const manifest = await buildReceiverManifest();
      if (!manifest) {
        return res.status(404).json({
          error: "receiver_package_not_found",
          message: "Receiver package has not been generated.",
        });
      }
      res.setHeader("Cache-Control", "no-store");
      res.json(manifest);
    } catch (err) {
      res.status(500).json({
        error: "receiver_manifest_error",
        message: "receiver manifest failed",
      });
    }
  });

'''

if 'Public receiver update manifest' not in s:
    marker = '  const receiverManifestAuthMiddleware = (req: any, res: any, next: any) =>'
    if marker in s:
        s = s.replace(marker, public_manifest_route + marker, 1)
    else:
        marker = '  app.get("/api/signal-relay/receiver-manifest"'
        idx = s.find(marker)
        if idx == -1:
            raise SystemExit('receiver manifest route marker not found')
        s = s[:idx] + public_manifest_route + s[idx:]

start = s.find('const sendReceiverClientPackage')
if start != -1:
    end = s.find('      const fileName', start)
    if end != -1:
        segment = s[start:end]
        segment = segment.replace(
            'if (!(await hasSignalPackageAccess(req.user))) {',
            'if (!req.path.startsWith("/api/signal-relay/receiver-package") && !(await hasSignalPackageAccess(req.user))) {'
        )
        s = s[:start] + segment + s[end:]

s = s.replace(
    'app.get("/api/signal-relay/receiver-package", receiverDownloadAuthMiddleware, sendReceiverClientPackage);',
    'app.get("/api/signal-relay/receiver-package", strictRateLimit, sendReceiverClientPackage);'
)

p.write_text(s)
PY

echo "=== receiver asset state before build ==="
python3 - <<'PY'
from pathlib import Path
import hashlib, re
for path in [Path('public/downloads/朴捷资本APEX_QUANT接收端.exe'), Path('public/downloads/朴捷资本APEX_QUANT接收端.py')]:
    if path.exists():
        h = hashlib.sha256(path.read_bytes()).hexdigest()
        print(path, path.stat().st_size, h)
        if path.suffix == '.py':
            m = re.search(r'APP_VERSION\s*=\s*["\']([^"\']+)', path.read_text(errors='ignore'))
            print('APP_VERSION', m.group(1) if m else 'not found')
PY

echo "=== docker build ==="
sudo docker compose build quant-dashboard apex-api

echo "=== docker restart ==="
sudo docker compose up -d --no-deps quant-dashboard apex-api

echo "=== wait health ==="
sleep 20

echo "=== container status ==="
sudo docker compose ps

echo "=== local receiver manifest check ==="
curl -sS -i http://127.0.0.1/api/signal-relay/receiver-manifest | head -120 || true

echo "=== local receiver package head ==="
curl -sS -I http://127.0.0.1/api/signal-relay/receiver-package | head -50 || true

echo "=== public receiver manifest check ==="
curl -sS -i https://www.pojetcapital.com/api/signal-relay/receiver-manifest | head -120 || true

echo "=== deploy hotfix done ==="