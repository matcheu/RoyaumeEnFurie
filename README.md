# Royaume en Furie — serveur en ligne

Le « central » du multijoueur : il ne joue pas, il fait seulement suivre les messages entre les joueurs
d'un même salon (codes de 4 lettres, 8 joueurs par salon, 10 salons au maximum).

- `reseau.gd` est **copié depuis le jeu** (`scripts/network/reseau.gd`) par `outils/preparer_serveur.py`.
  Ne pas le modifier ici : modifier celui du jeu, puis relancer le script.
- `Dockerfile` : la recette utilisée par Render (Linux + Godot sans fenêtre + ce dossier).
- Le port est donné par Render dans la variable `PORT` (7777 sinon).

Essai sur le PC : `godot --headless --path serveur_en_ligne`, puis lancer le jeu avec
`-- --serveur-adresse ws://127.0.0.1:7777` et choisir « Jouer en ligne ».
