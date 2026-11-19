extends Node
## Multijoueur. Tous les messages passent par un « central » (le serveur), qui les fait suivre
## uniquement aux joueurs du même SALON. Deux façons de jouer :
## - Réseau local : un joueur héberge (il est à la fois joueur et central, un seul salon « LOCAL »),
##   les autres tapent son adresse IP.
## - En ligne : un serveur dédié (le jeu lancé avec --serveur, sans fenêtre, par ex. sur Render)
##   gère plusieurs salons avec un code de 4 lettres. Le créateur du salon est le « chef » :
##   c'est son PC qui fait tourner la partie (départ, ennemis de l'arène coop…), comme l'hôte en local.
## La connexion passe par WebSocket (comme une page web) : c'est le seul type accepté par Render.
##
## Ce qui est partagé dans une partie : la carte (même graine), la position et les tirs de chaque joueur,
## les dégâts entre joueurs, le départ et la fin. En course, chaque joueur garde ses propres ennemis.

signal joueurs_change
signal partie_lancee
signal depart_course
signal etat_recu(id: int, pos: Vector3, rot_y: float, tete_x: float, vivant: bool)
signal tir_recu(id: int, type: String, depart: Vector3, vitesse: Vector3)
signal degats_recus(source_id: int, degats: int, effet: String)
signal elimination(victime_id: int, auteur_id: int)
signal fin_course(vainqueur_id: int)
signal joueur_parti(id: int)
signal connexion_perdue
signal erreur(texte: String)
signal arene_evt(id: int, evt: String, donnees: Array)
signal arene_rapide(id: int, donnees: Array)
signal connecte_en_ligne               # le serveur en ligne a accepté ce joueur
signal salons_recus(liste: Array)      # [{code, chef, joueurs, en_partie}]

const PORT := 7777
const MAX_JOUEURS := 8         # par salon
const MAX_SALONS := 10         # sur le serveur en ligne
## Même valeur que DonneesMonde.NB_VILLAGES (recopiée ici pour que le serveur en ligne n'ait besoin que de ce fichier).
const NB_VILLAGES := 8
const SALON_LOCAL := "LOCAL"
## Version du multijoueur : deux jeux de versions différentes ne peuvent pas jouer ensemble.
const VERSION := 3
const LETTRES := "ABCDEFGHJKLMNPQRSTUVWXYZ"
## Adresse du serveur en ligne (sera remplie quand le serveur sera installé sur Render).
## Pour les essais : lancer le jeu avec « -- --serveur-adresse ws://127.0.0.1 ».
const ADRESSE_EN_LIGNE := ""

var actif := false            # une partie en réseau est en cours (ou en préparation)
var en_ligne := false         # connecté à un serveur dédié
var serveur_dedie := false    # CE programme est le serveur en ligne (aucun joueur ici)
var joueurs := {}             # joueurs de MON salon : id -> {nom, couleur, village, niveau, cristaux}
var hote_id := 1              # chef de mon salon
var salon := ""               # code de mon salon
var graine := 0
var mode := "course"          # "course", "coop" (arène contre les vagues) ou "duel"
var mon_nom := "Tuyo"
var en_partie := false
var _prets := {}
var adresse_en_ligne := ADRESSE_EN_LIGNE

# Côté central (serveur dédié, ou hôte en réseau local)
var _salons := {}             # code -> {chef, prive, en_partie, joueurs: {id: {...}}}
var _salon_de := {}           # id -> code
var _accueillis := {}         # id -> nom (connectés au serveur en ligne, pas forcément dans un salon)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var args := OS.get_cmdline_user_args()
	var i := args.find("--serveur-adresse")
	if i >= 0 and i + 1 < args.size():
		adresse_en_ligne = args[i + 1]
	multiplayer.peer_disconnected.connect(_sur_deconnexion)
	multiplayer.connected_to_server.connect(func() -> void:
		_presenter.rpc_id(1, mon_nom, VERSION, "" if en_ligne else SALON_LOCAL))
	multiplayer.connection_failed.connect(func() -> void:
		var etait_en_ligne := en_ligne
		quitter()
		erreur.emit("Impossible de joindre le serveur en ligne. Réessaie dans une minute." if etait_en_ligne
			else "Impossible de rejoindre la partie (adresse incorrecte, ou l'hôte n'a pas encore créé la partie)."))
	multiplayer.server_disconnected.connect(func() -> void:
		quitter()
		connexion_perdue.emit())


func mon_id() -> int:
	return multiplayer.get_unique_id() if actif else 1


## Le chef du salon : c'est son PC qui fait tourner la partie.
func est_hote() -> bool:
	return actif and mon_id() == hote_id


## Adresses de ce PC sur le réseau local, à donner aux autres joueurs.
static func adresses_locales() -> PackedStringArray:
	var liste := PackedStringArray()
	for a in IP.get_local_addresses():
		if a.count(".") == 3 and not a.begins_with("127.") and not a.begins_with("169.254."):
			liste.append(a)
	return liste


## « 192.168.1.20 » → « ws://192.168.1.20:7777 ». Une adresse complète (ws:// ou wss://) est gardée telle quelle.
static func adresse_websocket(adresse: String) -> String:
	var a := adresse.strip_edges()
	if a.begins_with("ws://") or a.begins_with("wss://"):
		return a
	return "ws://%s:%d" % [a, PORT]


func _ouvrir_serveur(port: int) -> Error:
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_server(port)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	(multiplayer as SceneMultiplayer).server_relay = false   # c'est nous qui faisons suivre, salon par salon
	actif = true
	_salons = {}
	_salon_de = {}
	_accueillis = {}
	return OK


# ---------------------------------------------------------------- Réseau local

func heberger(nom: String) -> Error:
	mon_nom = nom
	en_ligne = false
	serveur_dedie = false
	if _ouvrir_serveur(PORT) != OK:
		erreur.emit("Impossible d'héberger (le port 7777 est peut-être déjà utilisé).")
		return ERR_CANT_CREATE
	_salons[SALON_LOCAL] = {"chef": 1, "prive": true, "en_partie": false, "joueurs": {}}
	_ajouter_au_salon(1, nom, SALON_LOCAL)
	return OK


func rejoindre(adresse: String, nom: String) -> Error:
	mon_nom = nom
	en_ligne = false
	return _connecter(adresse)


func _connecter(adresse: String) -> Error:
	var peer := WebSocketMultiplayerPeer.new()
	if en_ligne:
		peer.handshake_timeout = 75.0   # un serveur Render endormi met jusqu'à une minute à se réveiller
	var err := peer.create_client(adresse_websocket(adresse))
	if err != OK:
		erreur.emit("Adresse invalide.")
		return err
	multiplayer.multiplayer_peer = peer
	actif = true
	return OK


func quitter() -> void:
	if multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	actif = false
	en_ligne = false
	en_partie = false
	joueurs = {}
	hote_id = 1
	salon = ""
	_prets = {}
	_salons = {}
	_salon_de = {}
	_accueillis = {}


# ---------------------------------------------------------------- En ligne (côté joueur)

func connecter_en_ligne(adresse: String, nom: String) -> Error:
	mon_nom = nom
	en_ligne = true
	return _connecter(adresse)


func demander_salons() -> void:
	_demande.rpc_id(1, "liste", "", false)


func creer_salon(prive := false) -> void:
	_demande.rpc_id(1, "creer", "", prive)


func rejoindre_salon(code: String) -> void:
	_demande.rpc_id(1, "rejoindre", code.strip_edges().to_upper(), false)


# ---------------------------------------------------------------- Serveur dédié

## Lance le serveur en ligne (sans fenêtre). Port : variable d'environnement PORT (Render) ou 7777.
func demarrer_serveur() -> Error:
	serveur_dedie = true
	en_ligne = true
	Engine.max_fps = 60                 # le serveur n'affiche rien : inutile de tourner plus vite
	OS.low_processor_usage_mode = true
	var port := PORT
	var env := OS.get_environment("PORT")
	if env.is_valid_int():
		port = int(env)
	var err := _ouvrir_serveur(port)
	print("SERVEUR Royaume en Furie v%d %s sur le port %d" % [VERSION, "démarré" if err == OK else "IMPOSSIBLE", port])
	return err


func _journal(texte: String) -> void:
	if serveur_dedie:
		print("SERVEUR %s  (%d connectés, %d salons)" % [texte, _accueillis.size(), _salons.size()])


@rpc("any_peer", "reliable")
func _presenter(nom: String, version := 0, code := "") -> void:
	if not multiplayer.is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	var refus := ""
	if version != VERSION:
		refus = "Ton jeu n'est pas la même version que celui %s.\nMettez le jeu à jour." % ("du serveur" if serveur_dedie else "de l'hôte")
	elif serveur_dedie and _accueillis.size() >= MAX_SALONS * MAX_JOUEURS:
		refus = "Le serveur est complet. Réessaie plus tard."
	elif not serveur_dedie:
		refus = _refus_salon(SALON_LOCAL)
	if refus != "":
		_refuser_et_deconnecter(id, refus)
		return
	_accueillis[id] = nom.substr(0, 16)
	if serveur_dedie:
		_bienvenue.rpc_id(id)
		_journal("%s s'est connecté" % nom)
	else:
		_ajouter_au_salon(id, nom, SALON_LOCAL)


func _refuser_et_deconnecter(id: int, raison: String) -> void:
	_refus.rpc_id(id, raison)
	get_tree().create_timer(1.0).timeout.connect(func() -> void:
		if multiplayer.multiplayer_peer and multiplayer.is_server():
			multiplayer.multiplayer_peer.disconnect_peer(id))


func _refus_salon(code: String) -> String:
	if not _salons.has(code):
		return "Ce salon n'existe pas (ou plus). Vérifie le code."
	var s: Dictionary = _salons[code]
	if s["en_partie"]:
		return "La partie a déjà commencé. Attends la prochaine !"
	if s["joueurs"].size() >= MAX_JOUEURS:
		return "La partie est pleine (%d joueurs maximum)." % MAX_JOUEURS
	return ""


@rpc("any_peer", "reliable")
func _demande(quoi: String, code: String, prive: bool) -> void:
	if not multiplayer.is_server() or not serveur_dedie:
		return
	var id := multiplayer.get_remote_sender_id()
	if not _accueillis.has(id):
		return
	match quoi:
		"liste":
			var liste: Array = []
			for c in _salons:
				var s: Dictionary = _salons[c]
				if not s["prive"]:
					liste.append({"code": c, "chef": _nom_dans(s, s["chef"]), "joueurs": s["joueurs"].size(), "en_partie": s["en_partie"]})
			_salons_liste.rpc_id(id, liste)
		"creer":
			if _salon_de.has(id):
				return
			if _salons.size() >= MAX_SALONS:
				_refus_doux.rpc_id(id, "Trop de salons ouverts sur le serveur. Réessaie plus tard ou rejoins un salon existant.")
				return
			var nouveau := _nouveau_code()
			_salons[nouveau] = {"chef": id, "prive": prive, "en_partie": false, "joueurs": {}}
			_ajouter_au_salon(id, _accueillis[id], nouveau)
			_journal("salon %s créé par %s" % [nouveau, _accueillis[id]])
		"rejoindre":
			if _salon_de.has(id):
				return
			var raison := _refus_salon(code)
			if raison != "":
				_refus_doux.rpc_id(id, raison)
				return
			_ajouter_au_salon(id, _accueillis[id], code)
			_journal("%s rejoint le salon %s" % [_accueillis[id], code])


func _nom_dans(s: Dictionary, id: int) -> String:
	return s["joueurs"][id]["nom"] if s["joueurs"].has(id) else "?"


func _nouveau_code() -> String:
	while true:
		var c := ""
		for k in 4:
			c += LETTRES[randi() % LETTRES.length()]
		if not _salons.has(c):
			return c
	return ""


func _ajouter_au_salon(id: int, nom: String, code: String) -> void:
	var s: Dictionary = _salons[code]
	var prises: Array = []
	for j in s["joueurs"].values():
		prises.append(j["couleur"])
	var couleur := 0
	while couleur in prises:
		couleur += 1
	s["joueurs"][id] = {"nom": nom.substr(0, 16), "couleur": couleur, "village": 0, "niveau": 1, "cristaux": 0}
	_salon_de[id] = code
	_envoyer_liste(code)


## Envoie à chaque joueur du salon la liste à jour (joueurs, chef, code).
func _envoyer_liste(code: String) -> void:
	var s: Dictionary = _salons[code]
	# D'abord les autres joueurs, et l'hôte local en dernier : s'il lance la partie aussitôt,
	# son ordre de départ arrive ainsi APRÈS la liste chez tout le monde.
	for m in s["joueurs"]:
		if m != mon_id() or serveur_dedie:
			_liste.rpc_id(m, s["joueurs"], s["chef"], code)
	if s["joueurs"].has(mon_id()) and not serveur_dedie:
		_liste(s["joueurs"].duplicate(true), s["chef"], code)


func _sur_deconnexion(id: int) -> void:
	if not multiplayer.is_server():
		return
	var nom: String = _accueillis.get(id, "?")
	_accueillis.erase(id)
	if not _salon_de.has(id):
		return
	var code: String = _salon_de[id]
	_salon_de.erase(id)
	var s: Dictionary = _salons[code]
	s["joueurs"].erase(id)
	if s["joueurs"].is_empty():
		_salons.erase(code)
		_journal("%s est parti, salon %s fermé" % [nom, code])
		return
	if s["chef"] == id:
		var ids: Array = s["joueurs"].keys()
		ids.sort()
		s["chef"] = ids[0]
	_relayer(id, "parti", [], 0)
	_envoyer_liste(code)
	_journal("%s est parti du salon %s" % [nom, code])


# ---------------------------------------------------------------- Réponses du central

@rpc("authority", "reliable")
func _bienvenue() -> void:
	connecte_en_ligne.emit()


@rpc("authority", "reliable")
func _salons_liste(liste: Array) -> void:
	salons_recus.emit(liste)


@rpc("authority", "reliable")
func _refus(raison: String) -> void:
	quitter()
	erreur.emit(raison)


## Refus sans déconnexion (en ligne : salon plein, code inconnu…).
@rpc("authority", "reliable")
func _refus_doux(raison: String) -> void:
	erreur.emit(raison)


@rpc("authority", "reliable")
func _liste(liste: Dictionary, chef: int, code: String) -> void:
	var ancien_chef := hote_id
	joueurs = liste
	hote_id = chef
	salon = code
	joueurs_change.emit()
	# En pleine partie d'arène, l'ancien chef faisait tourner les ennemis : la partie ne peut pas continuer
	if en_partie and ancien_chef != chef and mode != "course":
		connexion_perdue.emit()


# ---------------------------------------------------------------- Messages de jeu (relayés dans le salon)

## Envoie un message aux joueurs de mon salon (cible > 0 : à un seul joueur ; moi_aussi : je le traite aussi).
func _diffuser(nom: String, args: Array, cible := 0, moi_aussi := false) -> void:
	if not actif:
		return
	if moi_aussi or cible == mon_id():
		_traiter(mon_id(), nom, args)
	if cible == mon_id():
		return
	if multiplayer.is_server():
		_relayer(mon_id(), nom, args, cible)
	else:
		_vers_central.rpc_id(1, nom, args, cible)


func _diffuser_vite(nom: String, args: Array) -> void:
	if not actif:
		return
	if multiplayer.is_server():
		_relayer(mon_id(), nom, args, 0, true)
	else:
		_vers_central_vite.rpc_id(1, nom, args)


@rpc("any_peer", "reliable")
func _vers_central(nom: String, args: Array, cible: int) -> void:
	if multiplayer.is_server():
		_relayer(multiplayer.get_remote_sender_id(), nom, args, cible)


# WebSocket passe tout de façon fiable (comme une page web) : pas de mode « rapide mais peu sûr » ici.
@rpc("any_peer", "call_remote", "reliable", 1)
func _vers_central_vite(nom: String, args: Array) -> void:
	if multiplayer.is_server():
		_relayer(multiplayer.get_remote_sender_id(), nom, args, 0, true)


## (Central) Fait suivre un message aux autres joueurs du salon de « source ».
func _relayer(source: int, nom: String, args: Array, cible: int, vite := false) -> void:
	var code: String = _salon_de.get(source, "")
	if code == "" or not _salons.has(code):
		return
	var s: Dictionary = _salons[code]
	if nom == "lancer" and source == s["chef"]:
		s["en_partie"] = true
		_journal("salon %s : partie lancée (%s)" % [code, args[2]])
	for m in s["joueurs"]:
		if m == source or (cible > 0 and m != cible):
			continue
		if m == mon_id() and not serveur_dedie:
			_traiter(source, nom, args)   # l'hôte en réseau local est aussi un joueur du salon
		elif vite:
			_depuis_central_vite.rpc_id(m, source, nom, args)
		else:
			_depuis_central.rpc_id(m, source, nom, args)


@rpc("authority", "reliable")
func _depuis_central(source: int, nom: String, args: Array) -> void:
	_traiter(source, nom, args)


@rpc("authority", "call_remote", "reliable", 1)
func _depuis_central_vite(source: int, nom: String, args: Array) -> void:
	_traiter(source, nom, args)


func _traiter(source: int, nom: String, a: Array) -> void:
	match nom:
		"etat":
			etat_recu.emit(source, a[0], a[1], a[2], a[3])
		"tir":
			tir_recu.emit(source, a[0], a[1], a[2])
		"degats":
			degats_recus.emit(source, a[0], a[1])
		"elimination":
			elimination.emit(source, a[0])
		"progression":
			if joueurs.has(source):
				joueurs[source]["niveau"] = a[0]
				joueurs[source]["cristaux"] = a[1]
		"fin":
			fin_course.emit(a[0])
		"arene":
			arene_evt.emit(source, a[0], a[1])
		"arene_vite":
			arene_rapide.emit(source, a[0])
		"lancer":
			graine = a[0]
			mode = a[2]
			en_partie = true
			var attribution: Dictionary = a[1]
			for id in attribution:
				if joueurs.has(id):
					joueurs[id]["village"] = attribution[id]
			_prets = {}
			partie_lancee.emit()
		"pret":
			if est_hote():
				_prets[source] = true
				_verifier_prets()
		"depart":
			depart_course.emit()
		"parti":
			joueurs.erase(source)
			_prets.erase(source)
			joueur_parti.emit(source)
			if est_hote():
				_verifier_prets()


# ---------------------------------------------------------------- Lancement de la partie

## Le chef lance la partie : même carte pour tous, un village de départ différent par joueur.
func lancer(graine_choisie := -1, mode_choisi := "course") -> void:
	if not est_hote():
		return
	var g := graine_choisie if graine_choisie >= 0 else randi() % 1000000
	var villages := range(NB_VILLAGES)
	villages.shuffle()
	var ids := joueurs.keys()
	ids.sort()
	var attribution := {}
	var pas := maxi(1, NB_VILLAGES / maxi(1, ids.size()))
	var depart: int = villages[0]
	for k in ids.size():
		attribution[ids[k]] = (depart + k * pas) % NB_VILLAGES
	_diffuser("lancer", [g, attribution, mode_choisi], 0, true)


## Chaque joueur prévient le chef quand il est prêt ; le chef donne le départ quand tous le sont.
func signaler_pret() -> void:
	_diffuser("pret", [], hote_id)


func _verifier_prets() -> void:
	if not en_partie:
		return
	for id in joueurs:
		if not _prets.has(id):
			return
	if not joueurs.is_empty():
		_prets = {}
		_diffuser("depart", [], 0, true)


# ---------------------------------------------------------------- Pendant la partie

func envoyer_etat(pos: Vector3, rot_y: float, tete_x: float, vivant: bool) -> void:
	_diffuser_vite("etat", [pos, rot_y, tete_x, vivant])


func envoyer_tir(type: String, depart: Vector3, vitesse: Vector3) -> void:
	_diffuser("tir", [type, depart, vitesse])


## Le tireur décide s'il a touché ; la victime applique les dégâts chez elle.
func infliger(cible_id: int, degats: int, effet: String) -> void:
	_diffuser("degats", [degats, effet], cible_id)


## J'ai été éliminé par « auteur_id » (tout le monde est prévenu, moi compris).
func annoncer_elimination(auteur_id: int) -> void:
	_diffuser("elimination", [auteur_id], 0, true)


func envoyer_progression(niveau: int, cristaux: int) -> void:
	_diffuser("progression", [niveau, cristaux], 0, true)


## J'ai libéré la princesse : la course est finie pour tout le monde.
func gagner() -> void:
	_diffuser("fin", [mon_id()], 0, true)


## Arène : message fiable (à tous, moi compris ; ou à un seul joueur avec « cible »).
func envoyer_arene(evt: String, donnees: Array = [], cible := 0) -> void:
	_diffuser("arene", [evt, donnees], cible, cible == 0)


## Arène : message rapide, peut se perdre (positions des ennemis, score…).
func envoyer_arene_rapide(donnees: Array) -> void:
	_diffuser_vite("arene_vite", [donnees])


func nom_de(id: int) -> String:
	return joueurs[id]["nom"] if joueurs.has(id) else "Un joueur"
