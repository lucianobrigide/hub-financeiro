#!/bin/zsh
# Sobe o Hub Financeiro localmente com dados REAIS (Supabase).
# Usado pelo LaunchAgent com.brigide.hubfinanceiro (serviço permanente do macOS).

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" >/dev/null 2>&1
# Garante o Node na PATH mesmo sem shell interativo (launchd tem env mínimo).
export PATH="/Users/lucianobrigide/.nvm/versions/node/v24.18.0/bin:$PATH"

export DATA_SOURCE=supabase
export PORT=3000

cd /Users/lucianobrigide/Developer/hub-financeiro || exit 1
exec npm run dev
