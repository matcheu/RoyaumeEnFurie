#!/bin/sh
# Démarrage sur Render : le portier nginx écoute sur le port public donné par Render ($PORT),
# et le serveur du jeu écoute en interne sur le port 7777.
set -e
PORT_PUBLIC="${PORT:-10000}"
sed "s/__PORT__/${PORT_PUBLIC}/" /app/nginx.conf.modele > /etc/nginx/conf.d/royaume.conf
rm -f /etc/nginx/sites-enabled/default
echo "Portier nginx sur le port ${PORT_PUBLIC}, serveur du jeu sur le port 7777"
nginx
# Si le serveur du jeu s'arrête, le conteneur s'arrête aussi : Render le redémarre tout seul.
PORT=7777 ADRESSE_ECOUTE=127.0.0.1 exec godot --headless --path /app
