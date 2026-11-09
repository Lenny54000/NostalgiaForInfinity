#!/usr/bin/env bash
# Installation guidée de NostalgiaForInfinity (NFI) avec Docker.
# Usage : bash setup.sh

# Setup pour une nouvelle machine :
sudo apt update
sudo apt upgrade -y
sudo apt install git
# copié collé de la doc docker :
# Add Docker's official GPG key:
sudo apt update
sudo apt install ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to Apt sources:
sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt update
sudo apt install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo apt-get update
sudo apt-get install docker-compose-plugin
sudo groupadd docker
sudo usermod -aG docker $USER
newgrp docker
docker run hello-world




set -euo pipefail

# ----------------------------------------------------------------------------
# Réglages (modifiables)
# ----------------------------------------------------------------------------
REPO_URL="https://github.com/Lenny54000/NostalgiaForInfinity" #ma fork qui va rester compatible avec le setup.sh
DIR_NAME="NostalgiaForInfinity"
TRADING_MODE="futures"      # futures ou spot
MARGIN_MODE="isolated"      # utilisé seulement en futures
STRATEGY="NostalgiaForInfinityX8"
API_PORT="8080"
TIMEZONE="Europe/Paris"

# ----------------------------------------------------------------------------
# Fonctions utilitaires
# ----------------------------------------------------------------------------
die() { echo "Erreur : $*" >&2; exit 1; }

# Les valeurs ne doivent contenir ni espace ni '$' (casserait le fichier .env).
check_value() {
  [[ "$1" != *[[:space:]]* && "$1" != *'$'* ]]
}

# ask "Question" [valeur_par_defaut]  -> valeur obligatoire
ask() {
  local prompt="$1" default="${2:-}" value
  while true; do
    if [[ -n "$default" ]]; then
      read -r -p "$prompt [$default] : " value
      value="${value:-$default}"
    else
      read -r -p "$prompt : " value
    fi
    if [[ -z "$value" ]]; then
      echo "  -> Valeur obligatoire." >&2; continue
    fi
    if ! check_value "$value"; then
      echo "  -> Pas d'espace ni de '\$' dans cette valeur." >&2; continue
    fi
    printf '%s' "$value"
    return
  done
}

# ask_optional "Question" -> peut rester vide
ask_optional() {
  local prompt="$1" value
  while true; do
    read -r -p "$prompt : " value
    if [[ -n "$value" ]] && ! check_value "$value"; then
      echo "  -> Pas d'espace ni de '\$' dans cette valeur." >&2; continue
    fi
    printf '%s' "$value"
    return
  done
}

# ask_secret "Question" longueur_min mode
#   mode : strict   = refuse si trop court
#          warn     = avertit mais accepte
#          optional = vide accepté ; sinon longueur_min obligatoire
ask_secret() {
  local prompt="$1" min="${2:-0}" mode="${3:-strict}" value
  while true; do
    read -r -s -p "$prompt : " value
    echo >&2
    if [[ -z "$value" ]]; then
      if [[ "$mode" == "optional" ]]; then printf ''; return; fi
      echo "  -> Valeur obligatoire." >&2; continue
    fi
    if ! check_value "$value"; then
      echo "  -> Pas d'espace ni de '\$' dans cette valeur." >&2; continue
    fi
    if (( ${#value} < min )); then
      if [[ "$mode" == "warn" ]]; then
        echo "  -> Attention : moins de $min caractères, c'est déconseillé." >&2
      else
        echo "  -> Minimum $min caractères (${#value} saisis)." >&2; continue
      fi
    fi
    printf '%s' "$value"
    return
  done
}

# ask_bool "Question" defaut(true|false) -> affiche true ou false
ask_bool() {
  local prompt="$1" default="$2" value
  while true; do
    read -r -p "$prompt (oui/non) [$default] : " value
    value="${value:-$default}"
    case "${value,,}" in
      true|t|oui|o|yes|y) printf 'true'; return ;;
      false|f|non|n|no)   printf 'false'; return ;;
    esac
    echo "  -> Réponds par oui ou non." >&2
  done
}

random_string() {
  LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$1" || true
}

# ----------------------------------------------------------------------------
# Vérifications
# ----------------------------------------------------------------------------
command -v git >/dev/null 2>&1    || die "git n'est pas installé."
command -v docker >/dev/null 2>&1 || die "docker n'est pas installé."
docker compose version >/dev/null 2>&1 || die "'docker compose' (v2) est introuvable."

# ----------------------------------------------------------------------------
# 1. Dépôt et configuration
# ----------------------------------------------------------------------------
if [[ -d "$DIR_NAME/.git" ]]; then
  echo "Le dossier $DIR_NAME existe déjà, clonage ignoré."
else
  git clone "$REPO_URL" "$DIR_NAME"
fi
cd "$DIR_NAME"

mkdir -p user_data
if [[ -f user_data/config.json ]]; then
  echo "user_data/config.json existe déjà, il est conservé."
else
  cp configs/recommended_config.json user_data/config.json
fi

# ----------------------------------------------------------------------------
# 2. Fichier .env
# ----------------------------------------------------------------------------
if [[ -f .env ]]; then
  overwrite="$(ask_bool "Un fichier .env existe déjà. Le remplacer (sauvegarde en .env.bak)" false)"
  if [[ "$overwrite" == "false" ]]; then
    echo "Conservation du .env existant."
    SKIP_ENV=1
  else
    cp .env .env.bak
    SKIP_ENV=0
  fi
else
  SKIP_ENV=0
fi

if [[ "$SKIP_ENV" -eq 0 ]]; then
  echo
  echo "=== Configuration du bot ($TRADING_MODE, dry-run activé par défaut) ==="
  BOT_NAME="$(ask "Nom du bot")"

  echo
  echo "--- Mode de trading ---"
  echo "Dry-run = simulation avec de l'argent fictif (aucune clé Binance requise)."
  DRY_RUN="$(ask_bool "Activer le dry-run (recommandé pour commencer)" true)"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "Dry-run activé : les clés Binance ne sont pas demandées."
    EX_KEY="Put_Your_Exchange_Key_Here"
    EX_SECRET="Put_Your_Exchange_Keys_Secret_Here"
  else
    echo
    echo "--- Exchange : $TRADING_MODE sur Binance (TRADING RÉEL) ---"
    EX_KEY="$(ask "Clé API Binance")"
    EX_SECRET="$(ask_secret "Secret API Binance (masqué)" 1 strict)"
  fi

  echo
  echo "--- Telegram ---"
  TG_ENABLED="$(ask_bool "Activer Telegram" false)"
  if [[ "$TG_ENABLED" == "true" ]]; then
    TG_TOKEN="$(ask "Token du bot Telegram")"
    TG_CHAT_ID="$(ask "Chat ID Telegram")"
  else
    TG_TOKEN="123456789:123456789YourTelegramTokenConfiguration"
    TG_CHAT_ID="123456789"
  fi

  echo
  echo "--- Interface web (API) ---"
  API_ENABLED="$(ask_bool "Activer l'API / interface web" true)"
  if [[ "$API_ENABLED" == "true" ]]; then
    API_USER="$(ask "Nom d'utilisateur")"
    API_PASS="$(ask_secret "Mot de passe (6 caractères minimum recommandés, masqué)" 6 warn)"
    echo "JWT secret : 35 caractères minimum. Laisse vide pour en générer un automatiquement."
    JWT_SECRET="$(ask_secret "JWT secret (masqué)" 35 optional)"
    if [[ -z "$JWT_SECRET" ]]; then
      JWT_SECRET="$(random_string 48)"
      echo "  -> JWT secret généré automatiquement."
    fi
    WS_TOKEN="$(random_string 40)"
  fi

  umask 077
  {
    echo "# Fichier généré par setup.sh"
    echo
    echo "FREQTRADE__BOT_NAME=$BOT_NAME"
    echo "# FREQTRADE__MAX_OPEN_TRADES=12"
    echo "# FREQTRADE__FUTURES_MAX_OPEN_TRADES_LONG=8"
    echo "# FREQTRADE__FUTURES_MAX_OPEN_TRADES_SHORT=4"
    echo
    echo "# FREQTRADE__LOGFILE=user_data/logs/$BOT_NAME.log"
    echo
    echo "FREQTRADE__TRADING_MODE=$TRADING_MODE"
    if [[ "$TRADING_MODE" == "futures" ]]; then
      echo "FREQTRADE__MARGIN_MODE=$MARGIN_MODE"
    fi
    echo
    echo "FREQTRADE__EXCHANGE__NAME=binance"
    echo "FREQTRADE__EXCHANGE__KEY=$EX_KEY"
    echo "# FREQTRADE__EXCHANGE__PASSWORD="
    echo "FREQTRADE__EXCHANGE__SECRET=$EX_SECRET"
    echo "# hyperliquid"
    echo "# FREQTRADE__EXCHANGE__WALLET_ADDRESS="
    echo "# FREQTRADE__EXCHANGE__PRIVATE_KEY="
    echo
    echo "FREQTRADE__TELEGRAM__ENABLED=$TG_ENABLED"
    echo "FREQTRADE__TELEGRAM__TOKEN=$TG_TOKEN"
    echo "FREQTRADE__TELEGRAM__CHAT_ID=$TG_CHAT_ID"
    echo
    echo "FREQTRADE__API_SERVER__ENABLED=$API_ENABLED"
    echo "FREQTRADE__API_SERVER__LISTEN_IP_ADDRESS=0.0.0.0"
    echo "FREQTRADE__API_SERVER__LISTEN_PORT=$API_PORT"
    if [[ "$API_ENABLED" == "true" ]]; then
      echo "FREQTRADE__API_SERVER__USERNAME=$API_USER"
      echo "FREQTRADE__API_SERVER__PASSWORD=$API_PASS"
      echo "FREQTRADE__API_SERVER__JWT_SECRET_KEY=$JWT_SECRET"
      echo "FREQTRADE__API_SERVER__WS_TOKEN=$WS_TOKEN"
    fi
    echo
    echo "# Time Zone"
    echo "TZ=$TIMEZONE"
    echo "FREQTRADE__DRY_RUN=$DRY_RUN"
    echo "FREQTRADE__STRATEGY=$STRATEGY"
  } > .env
  chmod 600 .env
  echo
  echo ".env créé."
fi

# ----------------------------------------------------------------------------
# 3. Démarrage
# ----------------------------------------------------------------------------
echo
echo "Démarrage du bot..."
docker compose up -d

echo
echo "Terminé."
echo "  Logs            : cd $DIR_NAME && docker compose logs -f"
if grep -q '^FREQTRADE__API_SERVER__ENABLED=true' .env 2>/dev/null; then
  echo "  Interface web   : http://localhost:$API_PORT"
fi
if grep -q '^FREQTRADE__DRY_RUN=true' .env 2>/dev/null; then
  echo "  Passer en réel  : mets tes clés Binance et FREQTRADE__DRY_RUN=false dans .env, puis 'docker compose up -d'"
else
  echo "  ATTENTION       : le bot est en mode RÉEL (dry-run désactivé)."
fi
