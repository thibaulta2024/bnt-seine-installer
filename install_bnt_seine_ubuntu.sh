#!/usr/bin/env bash
# Seine / Blocknet BNT - conservative CPU-only Ubuntu installer
# Official downloads only: https://github.com/zpalmtree/seine
set -Eeuo pipefail

say() { printf '\n[%s] %s\n' 'BNT' "$*"; }
fail() { printf '\n[錯誤] %s\n' "$*" >&2; exit 1; }

if [[ ! -r /etc/os-release ]]; then
  fail '無法識別作業系統。此腳本只支援 Ubuntu。'
fi
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == 'ubuntu' ]] || fail '此腳本只支援 Ubuntu。'
command -v systemctl >/dev/null 2>&1 || fail '此系統沒有 systemd。'

case "$(uname -m)" in
  x86_64) ARCH=x86_64 ;;
  aarch64|arm64) ARCH=aarch64 ;;
  *) fail "不支援的 CPU 架構：$(uname -m)" ;;
esac

CPUS=$(nproc)
TOTAL_MB=$(awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo)
AVAILABLE_MB=$(awk '/^MemAvailable:/ {printf "%d", $2/1024}' /proc/meminfo)
[[ "$CPUS" =~ ^[0-9]+$ && "$TOTAL_MB" =~ ^[0-9]+$ && "$AVAILABLE_MB" =~ ^[0-9]+$ ]] || fail 'CPU 或記憶體偵測失敗。'

# No more than 75% of the reported logical CPUs (except one-vCPU hosts).
CPU_LIMIT=$(( CPUS * 3 / 4 ))
(( CPU_LIMIT >= 1 )) || CPU_LIMIT=1

# Leave RAM for Ubuntu and other services: 20% of RAM, min 1 GiB, max 4 GiB.
RESERVE_MB=$(( TOTAL_MB / 5 ))
(( RESERVE_MB >= 1024 )) || RESERVE_MB=1024
(( RESERVE_MB <= 4096 )) || RESERVE_MB=4096

# Allow 2.25 GiB per lane rather than the bare 2 GiB requirement.
RAM_LIMIT=$(( (AVAILABLE_MB - RESERVE_MB) / 2304 ))
(( RAM_LIMIT >= 0 )) || RAM_LIMIT=0
THREADS=$CPU_LIMIT
if (( RAM_LIMIT < THREADS )); then THREADS=$RAM_LIMIT; fi

say "檢測：Ubuntu ${VERSION_ID:-?} / ${ARCH}，CPU ${CPUS} vCPU"
say "記憶體：總量 ${TOTAL_MB} MiB、目前可用 ${AVAILABLE_MB} MiB；至少保留 ${RESERVE_MB} MiB"
say "保守線程：CPU 上限 ${CPU_LIMIT}、記憶體上限 ${RAM_LIMIT} ⇒ 使用 ${THREADS} 線程"

if [[ "${1:-}" == '--check' ]]; then
  exit 0
fi

(( EUID == 0 )) || fail '請用 root 或 sudo 執行：sudo bash install_bnt_seine_ubuntu.sh'
# Avoid disrupting an already-running Seine systemd deployment.
if systemctl cat seine.service >/dev/null 2>&1; then
  say '已發現 seine.service。為保護現有錢包、礦池與挖礦任務，不覆蓋現有服務。'
  systemctl status seine --no-pager -l || true
  say '如需調整既有服務線程，請先單獨確認其設定，而不是重複安裝。'
  exit 0
fi
if pgrep -x seine >/dev/null 2>&1; then
  fail '目前已偵測到 Seine 程序在執行。請先正常退出現有挖礦程序，避免同一台機器重複運行。'
fi
(( THREADS >= 1 )) || fail '目前可用記憶體不夠安全啟動 1 個線程（至少約 2.25 GiB，另加系統保留量）。未作任何安裝變更。'

# Reuse a legacy installation's existing data path, if present.
EXISTING=0
if [[ -f /root/seine/seine-data/seine.config.json && -f /root/seine/seine ]]; then
  EXISTING=1
  INSTALL_DIR=/root/seine
  DATA_DIR=/root/seine/seine-data
  RUN_USER=root
  say '找到舊的 /root/seine/seine-data 設定，將沿用原始資料，不重新輸入地址。'
elif [[ -f /var/lib/seine/seine.config.json ]]; then
  EXISTING=2
  INSTALL_DIR=/opt/seine
  DATA_DIR=/var/lib/seine
  RUN_USER=seine
  id seine >/dev/null 2>&1 || fail '已存在 /var/lib/seine 設定，但 seine 專用帳號不存在，為保護資料已停止。'
  say '找到現有的 /var/lib/seine 設定，將沿用原始資料，不重新輸入地址。'
else
  INSTALL_DIR=/opt/seine
  DATA_DIR=/var/lib/seine
  RUN_USER=seine
  BNT_ADDRESS="${BNT_ADDRESS:-}"
  if [[ -z "$BNT_ADDRESS" ]]; then
    [[ -r /dev/tty ]] || fail '沒有互動終端。請使用 BNT_ADDRESS=你的完整BNT地址 sudo -E bash ... 傳入地址。'
    printf '請輸入你的 BNT 收款地址（或 @BlocknetID）: ' >/dev/tty
    IFS= read -r BNT_ADDRESS </dev/tty || fail '未能讀取錢包地址。'
  fi
  [[ "$BNT_ADDRESS" =~ ^[A-Za-z0-9@._:-]+$ ]] || fail '收款地址格式有問題，或包含空白/特殊字元。未安裝。'
fi

say '安裝 curl、ca-certificates、tar（不執行 Ubuntu 系統大版本升級）。'
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates tar

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ASSET="seine-linux-${ARCH}.tar.gz"
BASE='https://github.com/zpalmtree/seine/releases/latest/download'
say "下載官方最新發行版：${ASSET}"
curl --fail --location --show-error --silent --retry 3 -o "$TMP/$ASSET" "$BASE/$ASSET"
curl --fail --location --show-error --silent --retry 3 -o "$TMP/SHA256SUMS.txt" "$BASE/SHA256SUMS.txt"
awk -v f="$ASSET" '$2 == f || $2 == "*" f || $2 == "./" f {print}' "$TMP/SHA256SUMS.txt" > "$TMP/verify.txt"
[[ -s "$TMP/verify.txt" ]] || fail '官方校驗清單中找不到對應的安裝包，已停止安裝。'
(cd "$TMP" && sha256sum --check verify.txt) || fail '下載檔案校驗失敗，已停止安裝。'
mkdir -p "$TMP/extract"
tar -xzf "$TMP/$ASSET" -C "$TMP/extract"
[[ -f "$TMP/extract/seine" ]] || fail '壓縮包缺少 seine 執行檔。'

if [[ "$EXISTING" == 0 ]]; then
  if ! id seine >/dev/null 2>&1; then
    useradd --system --user-group --home-dir /var/lib/seine --shell /usr/sbin/nologin seine
  fi
  install -d -m 0755 "$INSTALL_DIR"
  install -d -o seine -g seine -m 0750 "$DATA_DIR"
else
  if [[ -f "$INSTALL_DIR/seine" ]]; then
    cp -p "$INSTALL_DIR/seine" "$INSTALL_DIR/seine.backup.$(date +%Y%m%d%H%M%S)"
  fi
fi

install -d -m 0755 "$INSTALL_DIR"
install -m 0755 "$TMP/extract/seine" "$INSTALL_DIR/seine"
"$INSTALL_DIR/seine" --version

HOST_LABEL=$(hostname -s | sed 's/[^A-Za-z0-9_-]/-/g' | cut -c 1-20)
NODE_SUFFIX=$(head -c 6 /etc/machine-id 2>/dev/null || printf 'node01')
WORKER="${HOST_LABEL:-vps}-${NODE_SUFFIX}"
CPU_QUOTA=$(( THREADS * 90 ))
if (( CPUS == 1 )); then CPU_QUOTA=80; fi

# The address appears only on a fresh installation; legacy settings are read
# directly from the existing data directory (wallet and pool unchanged).
EXTRA_ARGS=''
if (( EXISTING == 0 )); then
  EXTRA_ARGS="--address ${BNT_ADDRESS} --pool-url stratum+tcp://bntpool.com:3333 --pool-worker ${WORKER}"
fi

cat > /etc/systemd/system/seine.service <<EOF
[Unit]
Description=Seine Blocknet BNT CPU Miner
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=${RUN_USER}
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/seine --backend cpu --threads ${THREADS} --ui plain --data-dir ${DATA_DIR} --no-auto-update ${EXTRA_ARGS}
Restart=always
RestartSec=15
Nice=10
CPUQuota=${CPU_QUOTA}%
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now seine.service
sleep 3
if ! systemctl is-active --quiet seine.service; then
  journalctl -u seine.service -n 40 --no-pager -l || true
  fail '服務沒有成功啟動，請檢查上方日誌。'
fi
say "安裝成功！已啟動 ${THREADS} 線程，CPU 限額約 ${CPU_QUOTA}%（以單個 CPU 為 100%）。"
say "資料目錄：${DATA_DIR}（不會自動清除）"
printf '\n常用命令：\n'
printf '  systemctl status seine --no-pager\n'
printf '  journalctl -u seine -f\n'
printf '  systemctl restart seine\n'
printf '  systemctl stop seine\n'
printf '\n關閉 SSH 不會停止挖礦；真正關機則會停止。\n'
