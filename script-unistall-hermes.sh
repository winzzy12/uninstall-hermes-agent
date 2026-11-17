#!/usr/bin/env bash
#
# script-unistall-hermes.sh
# Uninstall Hermes Agent from a root-based Ubuntu/Debian VPS.
#
# Targets the paths observed in this installation:
#   /root/.hermes
#   /root/.local/bin/hermes
#   /root/.local/bin/hermes-agent
#   /root/.local/bin/hermes-acp
#   /usr/local/bin/hermes
#   hermes-upgrade-guard.service
#
# Does NOT remove unrelated services such as tat_agent.service or lxd-agent.service.

set -Eeuo pipefail

HERMES_HOME="/root/.hermes"
UNIT_NAME="hermes-upgrade-guard.service"
UNIT_FILE="/etc/systemd/system/${UNIT_NAME}"

BINARIES=(
  "/root/.local/bin/hermes"
  "/root/.local/bin/hermes-agent"
  "/root/.local/bin/hermes-acp"
  "/usr/local/bin/hermes"
)

log()  { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || die "Jalankan script sebagai root: sudo bash $0"

printf '\n========================================\n'
printf '       HERMES AGENT UNINSTALLER\n'
printf '========================================\n'
printf 'Direktori : %s\n' "$HERMES_HOME"
printf 'Service   : %s\n' "$UNIT_NAME"
printf 'Executable:\n'
printf '  - %s\n' "${BINARIES[@]}"
printf '\nScript ini akan menghentikan proses yang command line-nya merujuk ke %s,\n' "$HERMES_HOME"
printf 'menonaktifkan service upgrade guard, lalu menghapus path di atas.\n'
printf 'Service lain dan package Python/Node global tidak akan dihapus.\n\n'

read -r -p "Lanjutkan uninstall Hermes? [y/N] " answer
case "$answer" in
  y|Y|yes|YES) ;;
  *) log "Dibatalkan. Tidak ada perubahan."; exit 0 ;;
esac

# Stop and remove only the known Hermes upgrade guard unit.
if systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1}' | grep -Fxq "$UNIT_NAME"; then
  log "Menonaktifkan dan menghentikan ${UNIT_NAME}..."
  systemctl disable --now "$UNIT_NAME" 2>/dev/null || warn "Service tidak aktif atau gagal dihentikan; lanjutkan pembersihan."
fi

if [[ -f "$UNIT_FILE" || -L "$UNIT_FILE" ]]; then
  log "Menghapus unit file ${UNIT_FILE}..."
  rm -f -- "$UNIT_FILE"
fi

# Remove only processes whose command line explicitly references this Hermes
# installation directory. Do not use broad pkill patterns such as 'hermes'.
mapfile -t hermes_pids < <(
  ps -eo pid=,args= |
    awk -v root="$HERMES_HOME/" 'index($0, root) { print $1 }' |
    sort -u
)

if ((${#hermes_pids[@]})); then
  log "Menghentikan proses yang merujuk ke ${HERMES_HOME}..."
  printf '  PID: %s\n' "${hermes_pids[*]}"
  kill -TERM "${hermes_pids[@]}" 2>/dev/null || true

  # Give processes a short grace period to exit.
  for _ in {1..5}; do
    still_running=()
    for pid in "${hermes_pids[@]}"; do
      kill -0 "$pid" 2>/dev/null && still_running+=("$pid")
    done
    ((${#still_running[@]} == 0)) && break
    sleep 1
  done

  for pid in "${hermes_pids[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      warn "PID ${pid} belum berhenti; mengirim SIGKILL."
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done
else
  log "Tidak ditemukan proses dengan command line yang merujuk ke ${HERMES_HOME}."
fi

log "Menghapus direktori Hermes dan executable yang diketahui..."
rm -rf -- "$HERMES_HOME"
for binary in "${BINARIES[@]}"; do
  rm -f -- "$binary"
done

log "Memuat ulang konfigurasi systemd..."
systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true

printf '\n========================================\n'
printf '             VERIFIKASI\n'
printf '========================================\n'

if [[ -e "$HERMES_HOME" ]]; then
  warn "Direktori masih ada: $HERMES_HOME"
else
  log "Direktori Hermes sudah tidak ditemukan."
fi

for binary in "${BINARIES[@]}"; do
  if [[ -e "$binary" || -L "$binary" ]]; then
    warn "Executable masih ada: $binary"
  fi
done

if command -v hermes >/dev/null 2>&1; then
  warn "Masih ada command 'hermes' di PATH: $(command -v hermes)"
else
  log "Command 'hermes' tidak ditemukan di PATH."
fi

remaining_pids="$(
  ps -eo pid=,args= |
    awk -v root="$HERMES_HOME/" 'index($0, root) { print }' || true
)"
if [[ -n "$remaining_pids" ]]; then
  warn "Masih ada proses yang merujuk ke direktori Hermes:"
  printf '%s\n' "$remaining_pids"
else
  log "Tidak ditemukan proses yang merujuk ke direktori Hermes."
fi

if systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1}' | grep -Fxq "$UNIT_NAME"; then
  warn "Unit ${UNIT_NAME} masih terdaftar; periksa secara manual."
else
  log "Unit ${UNIT_NAME} tidak lagi terdaftar."
fi

printf '\nSelesai. Jika command hermes masih ditemukan, periksa lokasi tersebut sebelum menghapusnya.\n'
printf 'Script ini tidak menghapus package global Python/Node atau service lain.\n'
