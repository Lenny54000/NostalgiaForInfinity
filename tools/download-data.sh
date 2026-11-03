#!/usr/bin/env bash
# Télécharge les données de marché nécessaires au backtest NFI (Binance).
# Usage : bash download-data.sh
set -euo pipefail

# ----------------------------------------------------------------------------
# Réglages (modifiables)
# ----------------------------------------------------------------------------
EXCHANGE="binance"
DEFAULT_TIMEFRAMES="5m 15m 1h 4h 1d 1m"   # ceux recommandés par NFI

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

ask_timeframes() {
  local value tf ok
  while true; do
    read -r -p "Timeframes [$DEFAULT_TIMEFRAMES] : " value
    value="${value:-$DEFAULT_TIMEFRAMES}"
    ok=1
    for tf in $value; do
      [[ "$tf" =~ ^[0-9]+[mhdwM]$ ]] || { echo "  -> Timeframe invalide : $tf" >&2; ok=0; }
    done
    if [[ "$ok" -eq 1 ]]; then printf '%s' "$value"; return; fi
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

echo "=== Téléchargement des données $EXCHANGE ==="
TRADING_MODE="$(ask_mode "$default_mode")"

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

TIMEFRAMES="$(ask_timeframes)"

PAIRLIST="configs/pairlist-backtest-static-${EXCHANGE}-${TRADING_MODE}-usdt.json"
[[ -f "$PAIRLIST" ]] || die "liste de paires introuvable : $PAIRLIST"

echo
echo "Récapitulatif :"
echo "  Exchange    : $EXCHANGE ($TRADING_MODE)"
echo "  Période     : $TIMERANGE"
echo "  Timeframes  : $TIMEFRAMES"
echo "  Paires      : $PAIRLIST"
if [[ " $TIMEFRAMES " == *" 1m "* ]]; then
  echo "  Note        : le 1m est le plus long et le plus lourd à télécharger."
fi
if [[ "$TRADING_MODE" == "futures" ]]; then
  echo "  Note        : en futures, les données mark et funding rate sont aussi téléchargées."
fi
echo
ask_yes_no "Lancer le téléchargement" oui || { echo "Annulé."; exit 0; }

# ----------------------------------------------------------------------------
# Téléchargement
# ----------------------------------------------------------------------------
# On passe par le service 'backtesting' de docker-compose.tests.yml : il ne lit
# pas le fichier .env, donc ton mode de trading et ton API ne perturbent pas
# le téléchargement. Les données arrivent dans user_data/data/$EXCHANGE.
export EXCHANGE TRADING_MODE TIMERANGE

args=(
  download-data
  --config "configs/trading_mode-${TRADING_MODE}.json"
  --config "$PAIRLIST"
  --exchange "$EXCHANGE"
  --datadir "/freqtrade/user_data/data/${EXCHANGE}"
  --timeframes $TIMEFRAMES
  --timerange "$TIMERANGE"
)
if [[ "$TRADING_MODE" == "futures" ]]; then
  args+=(--trading-mode futures)
fi

docker compose -f docker-compose.tests.yml run --rm backtesting "${args[@]}"

echo
echo "Téléchargement terminé."
if [[ "$TRADING_MODE" == "futures" ]]; then
  echo "  Données : user_data/data/${EXCHANGE}/futures/"
else
  echo "  Données : user_data/data/${EXCHANGE}/"
fi
echo "  Étape suivante : bash backtest.sh"
