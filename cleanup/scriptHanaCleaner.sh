#!/bin/bash
# ./scripthanacleaner.sh $RETENTION_DAY
# ./scripthanacleaner.sh 32
# le nom des alias CTM à utilisé est reporté dans un fichier "<SID>.conf" déposé en meme temps
# aide sur le script python
# -bd   nombre minimum de jours de sauvegarde dans le catalogue
# -be   nombre minimum d'entrées de sauvegarde conservées dans le catalogue
# -br   si cette option est réglée sur "true", les entrées de sauvegarde sont imprimées après le nettoyage
#python /logiciels/hanacleaner.py -es true -os true -bo true -br true -be 1 -bb true  -k HANACLEANERT

TAG="Hana-Backup"
RUN_BY=`whoami`
SCRIPTNAME=$0
BASENAME=`basename $SCRIPTNAME .sh`
DIR_LOG='/Backup/trace'
DIR_TARGET='/logiciels/hana-cleaner'
OWNER_USER='root'
OWNER_GROUP='sapsys'
PERM_CONF=754
CONF_EXTENTION='conf'
INSTALL_DEFAULT_FILE='default.conf'

########################################
function usage(){
cat <<EO_USAGE
le script supporte 3 mode d'invocation:

1/pour la configuration interactive via l'user root
	root# $SCRIPTNAME INSTALL
	l'instalation peut s'appuyer sur un script ${DIR_TARGET}/${INSTALL_DEFAULT_FILE}
	qui supporte 3 subtitutions
	<LOGDIR> remplacé par $DIR_LOG
	<SID> remplacé par le SID de l'instance
	<ALIAS> pour le parametre -k exclusivement
2/pour une execution en <sid>adm, avec la rétention configurée par le parametrage
	<sid>adm> $SCRIPTNAME

3/pour une execution en <sid>adm, avec une retention catalog personnalisée, ex à 4 jour
	<sid>adm> $SCRIPTNAME 4

EO_USAGE

}

########################################
function install_interactif(){
	local MYSID
	local MYUSER
	echo "regle les permissions d'exection du script"
	chmod $PERM_CONF $SCRIPTNAME
	chown $OWNER_USER':'$OWNER_GROUP $SCRIPTNAME
	echo "extrait du /etc/passwd à toute fin utile"
	grep 'adm' '/etc/passwd'
	echo "Nom de l'instance (SID) ?"
	read tmpread
	##netoyer la saisie
	MYSID=`echo ${tmpread^^} | tr -cd '[:alnum:]'`
	MYUSER="${MYSID,,}adm"

	echo "valeur acceptée:$MYSID -> $MYUSER"
	echo "chemin des logs:$DIR_LOG"
	echo "chemin des conf:$DIR_TARGET"
	echo
	install_composant "$MYUSER" "$MYSID" "systemdb"
	install_composant "$MYUSER" "$MYSID" "tenant"
	install_composant "$MYUSER" "$MYSID" "xsa"
	echo "fichiers de configuration installes "
	ls -la ${DIR_TARGET}/${MYSID}-*

	echo "fini, merci de relancer pour les autres instances"
}

########################################
function install_composant(){
	local MYUSER=$1
	local MYSID=$2
	local COMPOSANT=$3
	local myalias
	local target
	local tmpread
	local currentalias=""
	echo "lecture du hdbuserstore de l'utilisateur $MYUSER "
	su - "$MYUSER" -c "hdbuserstore LIST"
	echo
	target="${DIR_TARGET}/${MYSID}-${COMPOSANT}.${CONF_EXTENTION}"
	if [ -f $target ]; then
		currentalias=`read_conf_alias "$target"`
		echo "l'alias actuel pour '$COMPOSANT' est: ${currentalias}"
	else
		echo "pas encore de fichier de conf: '${target}'"
	fi
	echo "Alias/key hdbuserstore pour '$COMPOSANT' (vide pour passer)?"
	read tmpread
	myalias=`echo $tmpread| tr -cd '[:alnum:]-_'`
	if [ -z $myalias ];then
		echo "pas de configuration pour $COMPOSANT"
	else
		echo "valeur acceptée:$MYSID -> $MYUSER -> $myalias"
		su - "$MYUSER" -c "hdbuserstore LIST $myalias "
		if [ -f $target ]; then
			tmpread=`date +%Y%m%d-%H%M%S`
			mv $target "${DIR_TARGET}/${MYSID}-${COMPOSANT}.${CONF_EXTENTION}.${tmpread}.old"
		fi
		echo "Configuration : $target "
		install_content "$DIR_LOG" "$MYSID" $myalias | tee $target
		chmod $PERM_CONF $target
		chown $MYUSER':'$OWNER_GROUP $target
		echo
	fi
	echo
}

########################################
function install_content(){
local TMP=$DIR_TARGET/$INSTALL_DEFAULT_FILE
if [ -r $TMP ]; then
	echo "##créé à partir de $TMP"
	cat $TMP | sed -e "s/<LOGDIR>/${1//\//\\/}/"  -e "s/<SID>/${2//\//\\/}/"   -e "s/<ALIAS>/${3//\//\\/}/"
else
	cat <<EO_CONFIGURATION
##créé via le parametrage par défaut.
##hanacleaner.py configuration file
#output configuration
 -op $1
 -of hanacleaner_$2
 -or 7
#execute sql [true/false], execute all crucial housekeeping tasks
 -es true
#output catalog [true/false], displays backup catalog before and after the cleanup
 -bo false
#output removed catalog entries [true/false], displays backup catalog entries that were removed
 -br true
#nombre d'entree minimale
 -be 1
#nombre de jour minimal
 -bd 30
# user
 -k $3
EO_CONFIGURATION
fi
}

########################################
function read_conf_alias(){
	local CONFIG="$1"
	grep -o -m 1 -e '^[[:space:]]*-k[[:space:]]*[[:alnum:]_-]\+' "$CONFIG" | sed -n -r "s/-k\s+([a-zA-Z0-9_-]+)/\1/p"| tr -d "[:blank:]"
}

########################################
function hanacleanup(){
	local MYSID=$1
	local CONF=$2
	local COMPOSANT=$3
	local RC
	local EXTRA=$4
	local MYALIAS
	if [ ! -f $CONF ]; then
		echo "Le fichier de configuration n'existe pas"
		return 1
	elif [ ! -r $CONF ]; then
		echo "Le fichier de configuration n'est pas lisible"
		return 1
	fi
	##on lance le hanacleaner
	echo "Contenu du fichier de configuration:"
	cat $CONF
	echo
	MYALIAS=`read_conf_alias "$CONF"`
	if [ -z $MYALIAS ];then
		echo "Ne peut pas déterminer l'alias/key hdbuserstore"
	else
		echo "Tentative de connexion avec la clé $MYALIAS"
		hdbsql -U "$MYALIAS" "SELECT * from DUMMY"
	fi


	if [ -z $EXTRA ]; then
		python /logiciels/hana-cleaner/hanacleaner.py -ff "$CONF"
		RC=$?
	else
		python /logiciels/hana-cleaner/hanacleaner.py -ff "$CONF" -bd "$EXTRA"
		RC=$?
	fi
	echo "execution hanacleaner.py terminée Status=${RC}"
	##gestion du code retours
	if [ $RC -ne 0 ]; then
		logger -p user.err -t "$TAG" "Hanacleaner failed for $COMPOSANT ($RUN_BY) "
		return 2
	else
		logger -p user.info -t "$TAG" "Hanacleaner successfull for $COMPOSANT ($RUN_BY) "
		return 0
	fi
}

########################################

if [[ "root" = "$RUN_BY" ]]; then
	if [[ "INSTALL" = "$1" ]]; then
		echo "mode installation des fichiers de conf"
		install_interactif
		exit 0
	else
		echo "root n'est supporté que pour l'installation."
		usage
		exit 1
	fi
fi

## si passé en parametre, obéir au parametrage plutot qu'à la valeur du fichier de conf.
if [ ! -z $1 ]; then
	echo "utilisation de la rétention $1 "
	CLEANER_RETENTION_DAY=$1
else
	CLEANER_RETENTION_DAY=''
fi


## extraire le SID depuis le nom de l'utilisateur qui execute le script
TMP=`echo $RUN_BY|tr '[:lower:]' '[:upper:]'`
BCKSID=${TMP//ADM/}
RC=0
ITEM=0

##verification de l'utilisateur
echo "inventaires des secrets de $RUN_BY"
hdbuserstore LIST

##on lance le cleanup

for file in `find $DIR_TARGET -name "${BCKSID}-*.${CONF_EXTENTION}" -type f `
do
	echo "Le fichier de configuration: $file"
	COMPOSANT=`basename "$file" | sed -E -n "s/[0-9a-zA-Z]+-(.+)\.${CONF_EXTENTION}/\1/p"`
	if [ -z $COMPOSANT ];then
		echo "Le fichier de configuration n'est pas utilisable '$COMPOSANT'"
		RC=1
	else
		hanacleanup "$BCKSID" "$file" "$COMPOSANT" $CLEANER_RETENTION_DAY
		RC1=$?
		RC=$(($RC1+$RC))
		ITEM=$(($ITEM+1))
	fi
	#un peut d'espace pour simplifier la lecture.
	echo
	echo
done

if [ $ITEM -eq 0 ];then
	echo "pas de fichier de configuration trouvé"
	exit 1
fi
## envoyer un code de retours à notre amis controlm
exit $RC