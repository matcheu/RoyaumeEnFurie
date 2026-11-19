extends Node
## Démarre le serveur en ligne (aucun joueur ici : il fait seulement suivre les messages, salon par salon).


func _ready() -> void:
	if Reseau.demarrer_serveur() != OK:
		push_error("Le serveur n'a pas pu démarrer.")
		get_tree().quit(1)
