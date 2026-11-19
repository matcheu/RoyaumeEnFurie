# Recette suivie par Render pour faire tourner le serveur de « Royaume en Furie ».
# 1) une petite machine Linux, 2) le moteur Godot (version sans fenêtre) et le portier nginx,
# 3) ce dossier, 4) on lance (voir demarrer.sh).
FROM debian:bookworm-slim

ARG GODOT_VERSION=4.7.2
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates wget unzip libfontconfig1 nginx \
 && rm -rf /var/lib/apt/lists/* \
 && wget -q "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip" -O /tmp/godot.zip \
 && unzip -q /tmp/godot.zip -d /tmp \
 && mv "/tmp/Godot_v${GODOT_VERSION}-stable_linux.x86_64" /usr/local/bin/godot \
 && chmod +x /usr/local/bin/godot \
 && rm /tmp/godot.zip

WORKDIR /app
COPY . .
# Prépare le projet une fois (Godot crée son dossier .godot)
RUN godot --headless --path /app --import || true
RUN chmod +x /app/demarrer.sh

# Render donne le port public dans la variable PORT : demarrer.sh s'en occupe.
CMD ["/app/demarrer.sh"]
