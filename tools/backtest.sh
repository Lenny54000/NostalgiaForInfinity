#!/usr/bin/env bash
# Lance un backtest NFI avec Docker.
# Usage : bash backtest.sh
set -euo pipefail

# ----------------------------------------------------------------------------
# Réglages (modifiables)
# ----------------------------------------------------------------------------
EXCHANGE="binance"
DEFAULT_STRATEGY="NostalgiaForInfinityX8"

# ----------------------------------------------------------------------------
# Fonctions utilitaires
# ----------------------------------------------------------------------------
die() { echo "Erreur : $*" >&2; exit 1; }

# Accepte AAAAMMJJ, AAAA-MM-JJ ou AAAA/MM/JJ et renvoie AAAAMMJJ
ask_date() {
  local prompt="$1" optional="${2:-no}" value
  while true; do
    read -r -p "$prompt : " value
    value="${value//-/}"; value="${value//\//}"
    if [[ -z "$value" && "$optional" == "yes" ]]; then printf ''; return; fi
    if [[ "$value" =~ ^[0-9]{8}$ ]] && date -d "${value:0:4}-${value:4:2}-${value:6:2}" >/dev/null 2>&1; then
      printf '%s' "$value"; return
    fi
    echo "  -> Date invalide. Format attendu : AAAAMMJJ (ex : 20250101)." >&2
  done
}

ask_mode() {
  local default="$1" value
  while true; do
    read -r -p "Mode de trading (spot/futures) [$default] : " value
    value="${value:-$default}"
    case "${value,,}" in
      spot|futures) printf '%s' "${value,,}"; return ;;
    esac
    echo "  -> Réponds par 'spot' ou 'futures'." >&2
  done
}

ask_strategy() {
  local value
  while true; do
    read -r -p "Stratégie [$DEFAULT_STRATEGY] : " value
    value="${value:-$DEFAULT_STRATEGY}"
    if [[ "$value" =~ ^[A-Za-z0-9_]+$ && -f "$value.py" ]]; then
      printf '%s' "$value"; return
    fi
    echo "  -> Fichier $value.py introuvable à la racine du projet." >&2
  done
}

ask_yes_no() {
  local prompt="$1" default="$2" value
  while true; do
    read -r -p "$prompt (oui/non) [$default] : " value
    value="${value:-$default}"
    case "${value,,}" in
      oui|o|yes|y) return 0 ;;
      non|n|no)    return 1 ;;
    esac
    echo "  -> Réponds par oui ou non." >&2
  done
}

# ----------------------------------------------------------------------------
# Se placer dans le dossier NFI
# ----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f docker-compose.tests.yml ]]; then
  :
elif [[ -f "$SCRIPT_DIR/docker-compose.tests.yml" ]]; then
  cd "$SCRIPT_DIR"
elif [[ -f "$SCRIPT_DIR/NostalgiaForInfinity/docker-compose.tests.yml" ]]; then
  cd "$SCRIPT_DIR/NostalgiaForInfinity"
else
  die "dossier NFI introuvable. Lance ce script depuis le dossier NostalgiaForInfinity (ou à côté)."
fi

command -v docker >/dev/null 2>&1 || die "docker n'est pas installé."
docker compose version >/dev/null 2>&1 || die "'docker compose' (v2) est introuvable."

# ----------------------------------------------------------------------------
# Questions
# ----------------------------------------------------------------------------
default_mode="$(grep -E '^FREQTRADE__TRADING_MODE=' .env 2>/dev/null | cut -d= -f2 || true)"
default_mode="${default_mode:-spot}"
[[ "$default_mode" == "spot" || "$default_mode" == "futures" ]] || default_mode="spot"

echo "=== Backtest NFI ($EXCHANGE) ==="
TRADING_MODE="$(ask_mode "$default_mode")"
STRATEGY_NAME="$(ask_strategy)"

while true; do
  START_DATE="$(ask_date "Date de début (AAAAMMJJ)")"
  END_DATE="$(ask_date "Date de fin (AAAAMMJJ, vide = jusqu'à aujourd'hui)" yes)"
  if [[ -n "$END_DATE" && "$END_DATE" < "$START_DATE" ]]; then
    echo "  -> La date de fin doit être après la date de début." >&2
    continue
  fi
  break
done
TIMERANGE="${START_DATE}-${END_DATE}"

# ----------------------------------------------------------------------------
# Vérifications avant de lancer
# ----------------------------------------------------------------------------
PAIRLIST="configs/pairlist-backtest-static-${EXCHANGE}-${TRADING_MODE}-usdt.json"
[[ -f "$PAIRLIST" ]] || die "liste de paires introuvable : $PAIRLIST"

DATA_DIR="user_data/data/${EXCHANGE}"
[[ "$TRADING_MODE" == "futures" ]] && DATA_DIR="${DATA_DIR}/futures"

if [[ -z "$(find "$DATA_DIR" -maxdepth 1 -name '*.feather' -print -quit 2>/dev/null)" ]]; then
  echo "Aucune donnée (.feather) trouvée dans $DATA_DIR." >&2
  echo "Lance d'abord : bash download-data.sh (mode $TRADING_MODE)." >&2
  exit 1
fi

if [[ -z "$(find "$DATA_DIR" -maxdepth 1 -name '*-1m*.feather' -print -quit 2>/dev/null)" ]]; then
  echo "Attention : aucune donnée 1m dans $DATA_DIR."
  echo "Le backtest utilise --timeframe-detail 1m, il risque d'échouer sans ces données."
  ask_yes_no "Continuer quand même" non || { echo "Annulé."; exit 0; }
fi

echo
echo "Récapitulatif :"
echo "  Exchange   : $EXCHANGE ($TRADING_MODE)"
echo "  Stratégie  : $STRATEGY_NAME"
echo "  Période    : $TIMERANGE"
echo "  Paires     : $PAIRLIST"
echo "  Note       : le backtest utilise le détail 1m, il peut durer longtemps (plusieurs paires, longue période)."
echo
ask_yes_no "Lancer le backtest" oui || { echo "Annulé."; exit 0; }

# ----------------------------------------------------------------------------
# Backtest
# ----------------------------------------------------------------------------
export EXCHANGE TRADING_MODE TIMERANGE STRATEGY_NAME

docker compose -f docker-compose.tests.yml run --rm backtesting

echo
echo "Backtest terminé."
echo "  Résultats : user_data/backtest_results/"
echo "  Logs      : user_data/logs/"
