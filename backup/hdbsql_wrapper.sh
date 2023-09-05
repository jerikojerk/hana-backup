#!/bin/bash
## Pierre-Emmanuel Périllon - AUDES OI APPS CLIFFS
## testé sur GNU bash, version 4.2.46(2)-release
## Script de lancement "manuel" de la sauvegarde pour base hana.
## le script requiere
##  hdbsql pour l'execution de la sauvegarde
##  logger pour l'insertion de notes dans le journal systeme.
##  hdbuserstore pour configurer les entrées dans le userstore de l'instance.


##un peu de reflexion sur soi-même.
RUN_BY=`whoami`
DATE_LONG=`date +%Y%m%d-%H%M%S`
DATE_SHORT=`date +%Y%m%d`
DATE_HUMAN=`date +"%a %d %b %R"`
SCRIPTNAME=`basename $0`
BASENAME=`basename $SCRIPTNAME .sh`
DIRNAME="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
HOSTNAME=`hostname -s`


## définition du backup operator pour chacun des bases a sauvegarder
# c'est le tableau le plus important, pas de compte, pas de connexion sur l'instance.
# on donne un alias/key hdbsql
declare -A BASE_BACKUP_OPERATOR
## activer ou désactiver le backup par défaut (0 désactive, 1 activé, non défini = active)
declare -A BASE_DO_ACTION

## nom du répertoire dans lequel enregistrer le backup (libre, non défini 'fixme')
declare -A BASE_BACKUP_SUBPATH

## jouer la purge des backup valeur possible (non défini = success)
# 'always'  toujours purger
# 'never'   jamais purger
# 'success' suite à un backup réussi
declare -A BASE_BACKUP_WITH_PURGE

## les différentes policy par base 3 valeurs attendues (non défini=standard)
# 'only full' => ne faire que des backup full
# 'if full' => faire un backup uniquement si on est en mode full
# 'standard' => backup full
declare -A BASE_BACKUP_POLICY


###############################################################################
########VARIABLES A REPRENDRE DANS LA CONFIG                            #######
###############################################################################

##log du script.
DIR_LOG_WRAPPER="/Backup/trace"
LOG_RETENTION="28"
LOGGER_TAG="Hana-Backup"


##stockage backup
## TEMPLATE_BACKUP_PATH modèle de chemin de backup
## MOUNT_BACKUP   remplace <MOUNT> dans le template
## LEVEL_BACKUP_* remplace <LEVEL> dans le template
## <SID> est remplacé par le SID de l'instance (déterminé en via l'arguments -i )
#TEMPLATE_BACKUP_PATH='<MOUNT>/<SID>/data/db_<SUBPATH>/<LEVEL>-<DATE>'
#TEMPLATE_BACKUP_PATH='<MOUNT>/<SID>/data/<SUBPATH>/<LEVEL>-<DATE>'
TEMPLATE_BACKUP_PATH='<MOUNT>/<SID>/data/<SUBPATH>/<LEVEL>'
MOUNT_BACKUP="/Backup"
LEVEL_BACKUP_INCR='incr'
LEVEL_BACKUP_FULL='full'
LEVEL_BACKUP_DIFF='diff'

## longueur en jours du résumé affiche à l'écran
SUMMARY_LENGTH=9

## activer la purge systematique post backup réussi (Never/Always/Success)
BACKUPS_WITH_PURGE='Success'

## age max en jour des purges de logs (commun tenant/system db)
FILE_LOG_BACKUP_MAXAGE=2
## pattern pour le basename du backup catalogue (pour durcir) désactivé par défaut
FILE_LOG_BACKUP_PATTERN='log_backup_[1-9]*'

## age max en jour des purges de catalogue (commun tenant/system db)
FILE_CATALOG_BACKUP_MAXAGE=7
## pattern pour le basename du backup catalogue (pour durcir) désactivé par défaut
FILE_CATALOG_BACKUP_PATTERN='log_backup_0*'

## age max en jour des purges des datas (commun tenant/system db)
FILE_DATA_BACKUP_FULL_MAXAGE=7
## age max en jour des purges des datas (commun tenant/system db)
FILE_DATA_BACKUP_INCR_MAXAGE=7
## age max en jour des purges des datas (commun tenant/system db)
FILE_DATA_BACKUP_DIFF_MAXAGE=7

##environnement hana
## TEMPLATE_HANA_ENV chemin type du script hdbenv
## BACKUP_OPERATOR_*  alias pour identifier des entrées dans le "hdbuserstore" pour les tenants et les systemes
TEMPLATE_HANA_ENV='/hana/shared/<SID>/HDB*/'
SCRIPT_HANA_ENV="hdbenv.sh"

## la valeur de BASE est neutre sur le fonctionnement du script
## elle utilisée dans le commentaire du backup et dans le chemin modele du nom.
## BASE_BACKUP_OPERATOR -> l'alias/key hdbuserstore
## BASE_DO_ACTION-> 1 pour activer, 0 pour désactiver.
## BASE_BACKUP_SUBPATH -> nom du sous répertoire qui servira à remplacer <SUBPAHT> dans la variable TEMPLATE_BACKUP_PATH (SYSTEMDB, TENANT, XSA ... DB_AP2 ... )
## BASE_BACKUP_POLICY -> 3 valeurs au choix
##    'standard' (recommande tenant) backup full/inc/diff possible
##    'only full' (recommande systemdb) backup full dans tous les cas
##    'if full' pour ne s'executer que si on demande un backup full
## BASE_BACKUP_WITH_PURGE -> 3 valeurs au choix
##    'always' toujours purger meme si backup ko
##    'success' ne purger qu'en cas de réussite du backup
##    'never'   ne pas utiliser l'effacemement du fichier via le catalogue
## à décommenter obligatoirement en fonction du besoin dans le fichier de conf

# BASE='systemdb'
# BASE_BACKUP_OPERATOR[$BASE]='BACKUPS'
# BASE_DO_ACTION[$BASE]=1
# BASE_BACKUP_SUBPATH[$BASE]='SYSTEMDB'
# BASE_BACKUP_POLICY[$BASE]='only full'
# BASE_BACKUP_WITH_PURGE[$BASE]='always'

# BASE='tenant'
# BASE_BACKUP_OPERATOR[$BASE]='BACKUPT'
# BASE_DO_ACTION[$BASE]=1
# BASE_BACKUP_SUBPATH[$BASE]='TENANT'
# BASE_BACKUP_POLICY[$BASE]='standard'
# BASE_BACKUP_WITH_PURGE[$BASE]='success'

# BASE='xsa'
# BASE_BACKUP_OPERATOR[$BASE]='BACKUPX'
# BASE_DO_ACTION[$BASE]=1
# BASE_BACKUP_SUBPATH[$BASE]='XSA'
# BASE_BACKUP_POLICY[$BASE]='if full'
# BASE_BACKUP_WITH_PURGE[$BASE]='success'

###############################################################################
######## FIN VARIABLES A REPRENDRE DANS LA CONFIG                       #######
###############################################################################

## pour modifier une valeur du script pour une instance spécifique
## merci de surcharger la valeur via le script désigné par TEMPLATE_CONFIG_FILE
## afin d'éviter de modifier le script commun.
TEMPLATE_CONFIG_FILE="<DIRNAME>/<SID>.config"


## quelques variable pour piloter des options de fonctionnement
## ces variables ne doivent pas être modifiée via le script de config.
BCKSID='sid'
ARG_MODE='No-mode-provided'
HAS_PARAM_MODE=0
HAS_PARAM_SID=0
RC=0
CONFIG_FILE=''
DRY_RUN=0
##un tableau
declare -A ARG_FORCE_BACKUP
declare -A ARG_FORCE_NOBACKUP
## nom du log par défaut.
LOG=$DIR_LOG_WRAPPER/"$BASENAME"_"$HOSTNAME"_"$DATE_LONG".log


##tester si le pipe nous cache des choses.
set -o pipefail
false | true
if [ $? -eq 0 ];then
	echo "Warning pipe error"
	RC=2
fi

#--------------------------
## dictionnaire de requetes
read -r -d '' SQL_BACKUP_SUMMARY <<QUERY_END
select year_bkp||'-'||month_bkp||'-'||day_bkp date_backup,count_bakup, size/1024/1024/1024 Size_Go, ENTRY_TYPE_NAME type_backup
from(
	select COUNT(b.BACKUP_ID) count_bakup, sum(BACKUP_SIZE) size, b.ENTRY_TYPE_NAME, YEAR(b.SYS_START_TIME) year_bkp, MONTH(b.SYS_START_TIME) month_bkp, DAYOFMONTH(b.SYS_START_TIME) day_bkp
	from SYS.M_BACKUP_CATALOG b INNER JOIN SYS.M_BACKUP_CATALOG_FILES f on b.BACKUP_ID=f.BACKUP_ID
	where b.SYS_START_TIME >= ADD_DAYS(CURRENT_TIMESTAMP, -<RETENTION> ) AND b.STATE_NAME ='successful'
	GROUP BY b.ENTRY_TYPE_NAME, YEAR(b.SYS_START_TIME),MONTH(b.SYS_START_TIME),DAYOFMONTH(b.SYS_START_TIME)
) ORDER BY year_bkp,month_bkp,day_bkp
QUERY_END

read -r -d '' SQL_FILES_IN_CATALOG <<QUERY_END
select count(BACKUP_ID)
from M_BACKUP_CATALOG_FILES
where DESTINATION_TYPE_NAME='file' AND DESTINATION_PATH='<FILENAME>'
QUERY_END

read -r -d '' SQL_FILE_DATA_BACKUP_PATH <<QUERY_END
select FILE_DATA_BACKUP_PATH from SYS.M_BACKUP_CONFIGURATION
QUERY_END

read -r -d '' SQL_FILE_LOG_BACKUP_PATH <<QUERY_END
select FILE_LOG_BACKUP_PATH from SYS.M_BACKUP_CONFIGURATION
QUERY_END

read -r -d '' SQL_FILE_CATALOG_BACKUP_PATH <<QUERY_END
select FILE_CATALOG_BACKUP_PATH from SYS.M_BACKUP_CONFIGURATION
QUERY_END

read -r -d '' SQL_ABOUT_DATABASE <<QUERY_END
select SYSTEM_ID,DATABASE_NAME,HOST,START_TIME,VERSION,USAGE
from SYS.M_DATABASE
QUERY_END

read -r -d '' SQL_ABOUT_HOSTS <<QUERY_END
select HOST,KEY,VALUE
from SYS.M_HOST_INFORMATION
where KEY like 'net%'
QUERY_END

#---------------------------
function build_backup_path(){
	local TMP
	TMP=${TEMPLATE_BACKUP_PATH//<MOUNT>/$1}
	TMP=${TMP//<SID>/$2}
	TMP=${TMP//<LEVEL>/$3}
	TMP=${TMP//<SUBPATH>/$4}
	echo $TMP
}

#--------------------------
function build_config_path(){
	local TMP
	TMP=${TEMPLATE_CONFIG_FILE//<DIRNAME>/$DIRNAME}
	TMP=${TMP//<SID>/$1}
	echo $TMP
}

#--------------------------
function compute_priority(){
	local ALLOW=$1
	local DENY=$2
	local CONF=$3
	if [ $ALLOW -ne 0 ];then
		return 1
	elif [ $DENY -ne 0 ];then
		return 0
	elif [ $CONF -ne 0 ];then
		return 1
	else
		return 0
	fi
}
#--------------------------
function kill_me(){
	logger -t "$LOGGER_TAG" -p user.warn "$1"
	exit $2
}

#--------------------------
function show_usage(){
cat <<FIN_EXPLICATIONS
Le script de backup doit s'executer depuis le compte <sid>adm ou root ().
Modes Possibles: INC, FULL, DIFF
	differentiel: $SCRIPTNAME -m DIFF -i <SID>
	cumulatif:    $SCRIPTNAME -m INCR -i <SID>
	cumulatif:    $SCRIPTNAME -m INC  -i <SID>
	complet:      $SCRIPTNAME -m FULL -i <SID>
Mode en lecture seule
	resume:       $SCRIPTNAME -m SUM -i <SID>
Mode en suppression de backup
	disque uniquement:  $SCRIPTNAME -m DELETE -i <SID>
Mode dry run (what if)
	complet:      $SCRIPTNAME -dry -m <MODE> -i <SID>

Fichier de parametrage
	$CONFIG_FILE
Options supplementaires pour forcer/desactiver la cible
	-force_${NAME_S:-'*'} -bypass_${NAME_S:-'*'}
	-force_${NAME_T:-'*'} -bypass_${NAME_T:-'*'}
	-force_${NAME_X:-'*'} -bypass_${NAME_X:-'*'}
Rappel, on ne peut pas cumuler 2 differentielles dans la meme restauration.
FIN_EXPLICATIONS
}

#--------------------------
function show_config(){
cat <<FIN_CONFIGURATION
Configuration du script
	Utilisateur:              $RUN_BY
	MODE:                     $ARG_MODE
	SID:                      $BCKSID
	Ficher config:            $CONFIG_FILE
	Execution a blanc:        $DRY_RUN

	Environnement Hana:                         $TEMPLATE_HANA_ENV
	Script de configuration d'environnement:    $SCRIPT_HANA_ENV
	Nombre jour dans le resume:                 $SUMMARY_LENGTH

	Conservation des backup DATA (full):        $FILE_DATA_BACKUP_FULL_MAXAGE
	Conservation des backup DATA (incr):        $FILE_DATA_BACKUP_INCR_MAXAGE
	Conservation des backup DATA (diff):        $FILE_DATA_BACKUP_DIFF_MAXAGE
	Conservation des catalogues                 $FILE_CATALOG_BACKUP_MAXAGE
	Conservation des log hana                   $FILE_LOG_BACKUP_MAXAGE

	Template chemin du backup                   $TEMPLATE_BACKUP_PATH
	 <DATE> :  $DATE_SHORT
	 <MOUNT>:  $MOUNT_BACKUP
	 <LEVEL> (full):  $LEVEL_BACKUP_FULL
	 <LEVEL> (incr):  $LEVEL_BACKUP_INCR
	 <LEVEL> (diff):  $LEVEL_BACKUP_DIFF

	Repertoire des logs du present script:      $DIR_LOG_WRAPPER
	Log du present script:                      $LOG
	Conservation des logs du present script:    $LOG_RETENTION

FIN_CONFIGURATION

for BASE in ${!BASE_BACKUP_OPERATOR[@]}
do
	cat <<FIN_CONFIGURATION
	Lecture configuration specifique instance $BASE
	 BASE_BACKUP_POLICY[$BASE]:     ${BASE_BACKUP_POLICY[$BASE]}
	 BASE_BACKUP_WITH_PURGE[$BASE]: ${BASE_BACKUP_WITH_PURGE[$BASE]}
	 BASE_BACKUP_OPERATOR[$BASE]:   ${BASE_BACKUP_OPERATOR[$BASE]}
	 BASE_DO_ACTION[$BASE]:         ${BASE_DO_ACTION[$BASE]}
	 BASE_BACKUP_SUBPATH[$BASE]:    ${BASE_BACKUP_SUBPATH[$BASE]}

FIN_CONFIGURATION
done

}

#---------------------------
function hanaabout(){
	local OPERATOR="$1"
	local TMP
	#lecture de l'alias du compte dans le hdbuserstore
	echo
	echo '-------------------------------------------------------------------'
	echo "Verification de l'entree '$OPERATOR' pour l'utilisateur OS $RUN_BY."
	hdbuserstore list "$OPERATOR"
	TMP=$?
	
	if [ $TMP -ne 0 ];then
		echo "hdbuserstore warning, alias non trouve"
		logger -p user.warning -t "$LOGGER_TAG" "$BCKSID: hdbuserstore failed, key $OPERATOR see ${LOG}"
		return 1
	fi

	echo "Identification de la base connectee"
	hdbsql -U "$OPERATOR" "$SQL_ABOUT_DATABASE"
	TMP=$?
	if [ $? -ne 0 ];then
		echo "connection failure on database"
		logger -p user.err -t "$LOGGER_TAG" "$BCKSID: connection failed, key $OPERATOR see ${LOG}"
		return 1
	fi

	echo "Identification de la topologie réseau"
	hdbsql -x -U "$OPERATOR" "$SQL_ABOUT_HOSTS"
	echo
	return 0
}


#---------------------------
function hanabackup_generic(){
	local TEXT
	local COMM
	local DIR_WORK
	local RETENTION
	local TMP
	local BACKUP_FOR
	local SUBPATH=$2
	local OPERATOR=$3
	local BACKUP_WITH_PURGE=$4
	local BASE="$5"
	local PREFIX

	PREFIX=`echo ${BASE,,}| tr -cd '[:alnum:]_.'`

	case $1 in
		FULL)
			echo "${BCKSID}: Sauvegarde mode complet de '$BASE'"
			#tenant
			TMP=$(build_backup_path $MOUNT_BACKUP $BCKSID $LEVEL_BACKUP_FULL $SUBPATH)
			DIR_WORK=${TMP//<DATE>/$DATE_SHORT}
			TEXT="backup data using FILE ('${DIR_WORK}/${BCKSID}_${PREFIX}_F_${DATE_LONG}_')"
			COMM="COMMENT '${BASENAME}: ${PREFIX}/full'"
			DIR_WORK=${TMP//<DATE>/*}
			RETENTION=$FILE_DATA_BACKUP_FULL_MAXAGE
		;;
		DIFF)
			echo "${BCKSID}: Sauvegarde mode differentiel de '$BASE'"
			#tenant
			TMP=$(build_backup_path	$MOUNT_BACKUP $BCKSID $LEVEL_BACKUP_DIFF $SUBPATH)
			DIR_WORK=${TMP//<DATE>/$DATE_SHORT}
			TEXT="backup data DIFFERENTIAL using FILE ('${DIR_WORK}/${BCKSID}_${PREFIX}_D_${DATE_LONG}_')"
			COMM="COMMENT '${BASENAME}: ${PREFIX}/diff'"
			DIR_WORK=${TMP//<DATE>/*}
			RETENTION=$FILE_DATA_BACKUP_DIFF_MAXAGE
		;;
		INCR)
			echo "${BCKSID}: Sauvegarde mode incrementiel de '$BASE'"
			#tenant
			TMP=$(build_backup_path	$MOUNT_BACKUP $BCKSID $LEVEL_BACKUP_INCR $SUBPATH)
			DIR_WORK=${TMP//<DATE>/$DATE_SHORT}
			TEXT="backup data INCREMENTAL using FILE ('${DIR_WORK}/${BCKSID}_${PREFIX}_I_${DATE_LONG}_')"
			COMM="COMMENT '${BASENAME}: ${PREFIX}/incr'"
			DIR_WORK=${TMP//<DATE>/*}

			RETENTION=$FILE_DATA_BACKUP_INCR_MAXAGE
		;;
		*)
			echo "Erreur: logique de programmation [$1]"
			return 1
		;;
	esac

	hanabackup_hdbsql "$OPERATOR" "$DIR_WORK" "$TEXT" "$COMM" "$RETENTION" "$BASE"
	RC=$?
	hanacleanup_controler "$OPERATOR" "$DIR_WORK" "$RETENTION" "$RC" "${BASE_BACKUP_WITH_PURGE[$BASE]}"
	return $RC

}

#---------------------------
# point d'entrée pour lancement de la procédure de backup
function hanabackup_main(){
	local RC_FINAL=0
	local RC=0
	local TMP
	local BASE
	local OPERATOR
	local MODE=$1

	for BASE in ${!BASE_BACKUP_OPERATOR[@]}
	do
		OPERATOR=${BASE_BACKUP_OPERATOR[$BASE]}
		#si l'utilisateur est défini
		if [ -z $OPERATOR ];then
			continue
		fi
		hanaabout "$OPERATOR"
		#si c'est en echec ici, c'est mal parti :(

		#si le backup est active
		if [ ${BASE_DO_ACTION[$BASE]} -eq 1 ];then
			if [ 'only full' = "${BASE_BACKUP_POLICY[$BASE]}" ];then
				# envoyer le backup en mode FULL
				hanabackup_generic 'FULL' "${BASE_BACKUP_SUBPATH[$BASE]}" "$OPERATOR" "${BASE_BACKUP_WITH_PURGE[$BASE]}" "$BASE"
				RC=$?
				RC_FINAL=$(($RC_FINAL+$RC))
			elif [ 'if full' = "${BASE_BACKUP_POLICY[$BASE]}" ];then
				if [ 'FULL' = $MODE ];then
					#envoyer le backup en mode FULL
					hanabackup_generic 'FULL' "${BASE_BACKUP_SUBPATH[$BASE]}" "$OPERATOR" "${BASE_BACKUP_WITH_PURGE[$BASE]}" "$BASE"
					RC=$?
					RC_FINAL=$(($RC_FINAL+$RC))
				else
					echo "${BCKSID}: Sauvegarde desactivee pour '$BASE' car le mode est '$MODE' au lieu de full."
				fi
			else
				#mode standard
				#envoyer le backup en mode standard
				hanabackup_generic "$MODE" "${BASE_BACKUP_SUBPATH[$BASE]}" "$OPERATOR" "${BASE_BACKUP_WITH_PURGE[$BASE]}" "$BASE"
				RC=$?
				RC_FINAL=$(($RC_FINAL+$RC))
			fi
		else
			echo "${BCKSID}: actions interdites pour '$BASE'"
		fi
	done
	#renvoyer 0 ou plus
	return $RC_FINAL
}

#---------------------------
# fonction principale de backup
function hanabackup_hdbsql(){
	local OPERATOR="$1"
	local WHERE="$2"
	local QUERY="$3 $4"
	local RETENTION="$5"
	local BASE="$6"
	local TMP
	local RC

	echo "SQL: $QUERY"

	if [ $DRY_RUN -eq 0 ];then
		hdbsql -U "$OPERATOR" "$QUERY"
		TMP=$?
	else
		echo hdbsql -U "$OPERATOR" "$QUERY"
		TMP=0
	fi

	if [ $TMP -eq 0 ];then
		logger  -p user.info -t "$LOGGER_TAG" "$BCKSID: backup success with $3"
		RC=0
	else
		echo "Erreur hdbsql, abandon purge backup"
		logger  -p user.err -t "$LOGGER_TAG" "$BCKSID: backup error see ${LOG}"
		RC=2
	fi

	#ajout d'un petit historique.
	hanasummary_hdbsql "$OPERATOR" "$SUMMARY_LENGTH"

	return $RC
}

#---------------------------
## recherche des fichiers agés de $AGE_DAYS
## qui ne sont pas dans le catalogue
function hanabackup_foreignfiles(){
	local OPERATOR=$1
	local WHERE="$2"
	local AGE_DAYS=$3
	local COUNT

	find $WHERE -type f -mtime "+$AGE_DAYS" -print0 2> /dev/null | while read -d $'\0' file
	do
		SQL=${SQL_FILES_IN_CATALOG//<FILENAME>/$file}
		COUNT=`hdbsql -U $OPERATOR -x -a "$SQL"`
		if [ $COUNT -eq 0 ];then
			echo "rm $file"
		fi
	done
}


#---------------------------
## point d'entrée pour le mode d'execution DELETE
function hanacleanup_main(){
	local RC
	local RC_FINAL
	local BASE
	local OPERATOR
	local SUBPATH

	for BASE in ${!BASE_BACKUP_OPERATOR[@]}
	do
		OPERATOR=${BASE_BACKUP_OPERATOR[$BASE]}
		#si l'utilisateur est défini
		if [ -z $OPERATOR ];then
			#pas d'utilisateur -> pas de connexion possible à la base pour s'informer des chemins
			continue
		fi
		hanaabout "$OPERATOR"

		#si le backup est activé
		if [ ${BASE_DO_ACTION[$BASE]} -eq 1 ];then
			echo "${BCKSID}: actions actives pour '$BASE'"
			SUBPATH=${BASE_BACKUP_SUBPATH[$BASE]}
			#full
			TMP=$(build_backup_path "$MOUNT_BACKUP" "$BCKSID" "$LEVEL_BACKUP_FULL" "$SUBPATH")
			DIR_WORK=${TMP//<DATE>/*}
			hanacleanup_controler "$OPERATOR" "$DIR_WORK" "$FILE_DATA_BACKUP_FULL_MAXAGE" 0 "always"
			#incr
			TMP=$(build_backup_path "$MOUNT_BACKUP" "$BCKSID" "$LEVEL_BACKUP_INCR" "$SUBPATH")
			DIR_WORK=${TMP//<DATE>/*}
			hanacleanup_controler "$OPERATOR" "$DIR_WORK" "$FILE_DATA_BACKUP_INCR_MAXAGE" 0 "always"
			#diff
			TMP=$(build_backup_path "$MOUNT_BACKUP" "$BCKSID" "$LEVEL_BACKUP_DIFF" "$SUBPATH")
			DIR_WORK=${TMP//<DATE>/*}
			hanacleanup_controler "$OPERATOR" "$DIR_WORK" "$FILE_DATA_BACKUP_DIFF_MAXAGE" 0 "always"
		else
			echo "${BCKSID}: actions interdites pour '$BASE'"
		fi
	done
	#renvoyer 0 ou plus
	return 0
}

#---------------------------
## permet de mutualiser la logique de declanchement du clean
## TODO ajouter le 5 parametre
function hanacleanup_controler(){
	local OPERATOR="$1"
	local DIR_WORK="$2"
	local RETENTION="$3"
	local STATUS="$4"
	local BACKUP_WITH_PURGE="$5"
	local DO_PURGE=0

	if [ "never" = $BACKUP_WITH_PURGE ]; then
		DO_PURGE=0
	elif [ "always" = $BACKUP_WITH_PURGE ]; then
		DO_PURGE=1
	#on successful backup
	elif [ $STATUS -eq 0 ]; then
		DO_PURGE=1
	else
		DO_PURGE=0
	fi
	if [ $DO_PURGE -ne 0 ]; then
#		echo "Effacement des fichiers sur disques"
		purge_by_age "$DIR_WORK" "$RETENTION" && purge_empty_dir "$DIR_WORK"
		hanacleanup_catalog "$OPERATOR"
		hanacleanup_logbackup "$OPERATOR"
	fi
}

#---------------------------
## fonction generique qui recupere un chemin via un ordre sql
## et qui envoie une purge de tout ce qui est trop vieux.
function hanacleanup_sql_folder(){
	local OPERATOR=$1
	local RETENTION=$2
	local SQL="$3"
	local PATTERN="$4"
	local FOLDER

	FOLDER=`hdbsql -x -a -U $OPERATOR "$SQL"`
	##supprimer la premiere & derniere lettre qui sont des '"'
	RC=$?
	if [ $RC -ne 0 ];then
		echo "Lecture impossible du dossier a purger depuis la base, abandon."
		return 1
	fi
	FOLDER=${FOLDER:1:$((${#FOLDER}-2))}

	if [ -z $FOLDER ]; then
		return 1
	fi

	## vérifier que le dossier existe
	if [[ -d "$FOLDER" ]];then
		purge_by_age "$FOLDER" "$RETENTION" "$PATTERN"
		return $?
	else
		return 1
	fi
}

#---------------------------
function hanacleanup_catalog(){
	echo "Effacement des backup de catalog ($FILE_CATALOG_BACKUP_PATTERN)"
	hanacleanup_sql_folder "$1" "$FILE_CATALOG_BACKUP_MAXAGE" "$SQL_FILE_CATALOG_BACKUP_PATH" "$FILE_CATALOG_BACKUP_PATTERN"
	return $?
}

#---------------------------
function hanacleanup_logbackup(){
	echo "Effacement des log hana ($FILE_LOG_BACKUP_PATTERN)"
	hanacleanup_sql_folder "$1" "$FILE_LOG_BACKUP_MAXAGE" "$SQL_FILE_LOG_BACKUP_PATH" "$FILE_LOG_BACKUP_PATTERN"
	return $?
}

#---------------------------
##on utilise le BACKUP CATALOG pour lister les backups en place.
function hanasummary_main(){
	local BASE
	local OPERATOR
	local SUBPATH
	#BASE est l'index du tableau.
	for BASE in ${!BASE_BACKUP_OPERATOR[@]}
	do
		OPERATOR=${BASE_BACKUP_OPERATOR[$BASE]}
		#si l'utilisateur est défini
		if [ -z $OPERATOR ];then
			#pas d'utilisateur -> pas de connexion possible à la base pour s'informer des chemins
			continue
		fi
		hanaabout "$OPERATOR"

		#si le backup est active
		if [ ${BASE_DO_ACTION[$BASE]} -eq 1 ];then
			SUBPATH=${BASE_BACKUP_SUBPATH[$BASE]}
			echo "Summary pour $BASE"
			hanasummary_hdbsql "$OPERATOR" "$SUMMARY_LENGTH"
			#full
			TMP=$(build_backup_path "$MOUNT_BACKUP" "$BCKSID" "$LEVEL_BACKUP_FULL" "$SUBPATH")
			DIR_WORK=${TMP//<DATE>/*}
			hanabackup_foreignfiles "$OPERATOR" "$DIR_WORK" "$FILE_DATA_BACKUP_FULL_MAXAGE"

			if [ "standard" = "${BASE_BACKUP_POLICY[$BASE]}" ];then
				#incr
				TMP=$(build_backup_path "$MOUNT_BACKUP" "$BCKSID" "$LEVEL_BACKUP_INCR" "$SUBPATH")
				DIR_WORK=${TMP//<DATE>/*}
				hanabackup_foreignfiles "$OPERATOR" "$DIR_WORK" "$FILE_DATA_BACKUP_INCR_MAXAGE"
				#diff
				TMP=$(build_backup_path "$MOUNT_BACKUP" "$BCKSID" "$LEVEL_BACKUP_DIFF" "$SUBPATH")
				DIR_WORK=${TMP//<DATE>/*}
				hanabackup_foreignfiles "$OPERATOR" "$DIR_WORK" "$FILE_DATA_BACKUP_DIFF_MAXAGE"
			else
				echo "$BASE n'a pas de backup INCR/DIFF par configuration"
			fi
		else
			echo "${BCKSID}: actions interdites pour '$BASE'"
		fi
	done
	return 0
}

#---------------------------
##affichage d'un resume des backup connus par le catalogue
function hanasummary_hdbsql(){
	local OPERATOR=$1
	local AGE_DAYS=$2

	echo "Recherche des backup sur $AGE_DAYS jours vu par $OPERATOR"
	SQL=${SQL_BACKUP_SUMMARY//<RETENTION>/$AGE_DAYS}
	hdbsql -U "$OPERATOR" "$SQL"
	return $?
}

#---------------------------
## attention le where contient une étoile si on utilise le masque de <DATE>
## c'est pas super fiable car la substitution de l'étoile se fera avant le
## lancement du find ce qui pourrait faire planter le shell bash mais logiquement
## on devrait jamais dépasser 1 mois sans purge = 30 chemins.
function purge_by_age(){
	local WHERE="$1"
	local AGE_MIN
	local PATTERN="$3"
	local TMP

	if [ 0 -ge $2 ]; then
		echo "Purge pour des fichier pour une duree negative, abandon"
		return 1
	fi

	#on abandonne si le WHERE n'existe pas.
	TMP=`ls -1f $WHERE 2>/dev/null |wc -l `
	if [ 0 -eq $TMP ];then
		echo "Le chemin $WHERE n'est pas trouvé, abandon."
		return 1
	fi

	AGE_MIN=`echo "1440*$2/1" | bc`
	echo -n 'Purge de '$WHERE', efface les fichiers ages de '$2' jours ('$AGE_MIN' minutes), proprietaire '$RUN_BY
	## pour offrir la possibilité de garder des demies journées, on fait la conversion en minutes
	## 1440 = 24*60
	## on a également une spécificité sur la gestion de la virgule flottante sur -ctime/-mtime du coup c'est moins
	## impactant de travailler en minutes

	#DRY_RUN est une variable globale.
	if [ 0 -eq $DRY_RUN ];then
		if [ -z "$PATTERN" ];then
			echo ' (sans motif de nom)'
			find $WHERE -type f -cmin "+$AGE_MIN" -user $RUN_BY  | xargs rm -vf
			RC=$?
		else
			echo ' avec pour nom '"$PATTERN"
			find $WHERE -type f -cmin "+$AGE_MIN" -user $RUN_BY -name "$PATTERN" | xargs rm -vf
			RC=$?
		fi
	else
		if [ -z "$PATTERN" ];then
			echo ' (sans motif de nom) Dry Run !'
			find $WHERE -type f -cmin "+$AGE_MIN" -user $RUN_BY  | sed 's/^/remove(dry run) /'
			RC=$?
		else
			echo " avec pour nom '$PATTERN' Dry run !"
			find $WHERE -type f -cmin "+$AGE_MIN"  -user $RUN_BY -name "$PATTERN" | sed 's/^/remove(dry run) /'
			RC=$?
		fi
	fi

	echo -n "Fichiers restants: "
	ls -1 -f $WHERE 2>/dev/null |wc -l
	echo -n "Volume donnees restantes:"
	## du +summary +human +1 fs
	du -shx  $WHERE
	return $RC
}

#---------------------------
function purge_empty_dir(){
	local WHERE="$1"
	##delete empty folders
	find $WHERE -type d -empty -delete
	return $?
}

#---------------------------
function verify_folder (){
	local FOLDER="$1"
	if [ -d "$FOLDER" ];then
		return 0
	else
		echo "Erreur: manque $FOLDER"
		return 1
	fi
}

#---------------------------
## demander aux DBA de reverser l'incident chez les sapiens.
echo "Demarrage du script de sauvegarde de base SAP HANA"

##Gestion de la ligne de commandes
ALL_ARGS=''
for arg in $*
do
	case "$1" in
		-m) # MODE
			shift 1
			case $1 in
				DIF*)
					ARG_MODE='DIFF'
					;;
				INC*)
					ARG_MODE='INCR'
					;;
				FUL*)
					ARG_MODE='FULL'
					;;
				SUM*)
					ARG_MODE='SUMMARY'
					;;
				DEL*)
					ARG_MODE='DELETE'
					;;
				*)
					ARG_MODE='ERROR'
				;;
			esac
			ALL_ARGS=$ALL_ARGS" -m $ARG_MODE"
			HAS_PARAM_MODE=1
			;;
		-i) # SID
			shift 1
			BCKSID=`echo $1| tr '[:lower:]' '[:upper:]'`
			HAS_PARAM_SID=1
			ALL_ARGS=$ALL_ARGS" -i $BCKSID"
			;;
		-force_*)
			ARG_FORCE_BACKUP[${1:7}]=1
			ALL_ARGS=$ALL_ARGS" $1"
			;;
		-bypass_*)
			ARG_FORCE_NOBACKUP[${1:8}]=1
			ALL_ARGS=$ALL_ARGS" $1"
			;;
		-dry)
			DRY_RUN=1
			ALL_ARGS=$ALL_ARGS" -dry"
			;;
		"" )
			;;
		*)
			echo "Erreur : option non reconnue $1"
			show_usage
		;;
	esac
	shift 1
done


## Vérification du user
EXPECTED_USER="${BCKSID,,}adm"
if [[ "$RUN_BY" == "root" ]]
then
	echo "Running as root, switch to $EXPECTED_USER:$DIRNAME/$SCRIPTNAME $ALL_ARGS"
	exec su - "$EXPECTED_USER" -c "$DIRNAME/$SCRIPTNAME $ALL_ARGS"
	# exec replace executing code.
elif [[ "$RUN_BY" != "$EXPECTED_USER" ]]
then
	echo "Erreur: Le programme doit etre lance sous \"$EXPECTED_USER\" et non $RUN_BY."
	#TODO remove
	kill_me "$BCKSID: Backup aborted: Wrong user" 1
else
	echo "Le script s'execute sous $RUN_BY comme attendu."
fi


## Véfication présence des arguments obligatoires
if [ $HAS_PARAM_MODE -lt 1 ] && [ $HAS_PARAM_SID -lt 1 ]
then
	echo "Erreur: Arguments obligatoires manquants"
	show_usage
	kill_me "$BCKSID: Backup aborted: Missing mandatory parameters" 1
fi


##rechercher le script SAP qui positionne l'env natif
CONFIG_FILE=$(build_config_path $BCKSID)
if [ -f $CONFIG_FILE ]; then
	echo "utilise $CONFIG_FILE"
	source $CONFIG_FILE
else
	echo "configuration specifique instance non trouve"
	CONFIG_FILE=''
fi

#configuration des logs
LOG=$DIR_LOG_WRAPPER/"$BASENAME"_"$BCKSID"_"$DATE_LONG"_"$ARG_MODE".log
verify_folder "$DIR_LOG_WRAPPER"
purge_by_age "$DIR_LOG_WRAPPER" "$LOG_RETENTION" "*.log" | tee -a  $LOG

if mountpoint -q $MOUNT_BACKUP
then
	echo "$MOUNT_BACKUP est un montage " | tee -a  $LOG
else
	echo "$MOUNT_BACKUP n'est pas un montage "| tee -a  $LOG
fi


##rechercher le script SAP qui positionne l'env natif
##substitution du motif dans le template.
DIR_HANA_ENV=${TEMPLATE_HANA_ENV/<SID>/$BCKSID}
SEARCH=`find $DIR_HANA_ENV -name $SCRIPT_HANA_ENV|wc -l`

if [ "$SEARCH" != "1" ]
then
	echo "fichier d'environnement ambigue/non trouve (find=$SEARCH)" | tee -a $LOG
	kill_me "$BCKSID: Backup aborted: environnement not setable" 1
fi
SEARCH=`find $DIR_HANA_ENV -name $SCRIPT_HANA_ENV`

## recharge l'environnement
echo "source du fichier '$SEARCH'" | tee -a $LOG
source $SEARCH

## maintenant on analyse la configuration reçue.
## histoire de faire un peu de sanitization.
for BASE in ${!BASE_BACKUP_OPERATOR[@]}
do
	##si l'opérateur n'existe pas
	if [ -z ${BASE_BACKUP_OPERATOR[$BASE]} ];then
		echo "erreur configuration pour la base $BASE, pas d'operateur"
		exit 1
	fi

	##dire s'il faut faire le backup
	compute_priority ${ARG_FORCE_BACKUP[$BASE]:-0} ${ARG_FORCE_NOBACKUP[$BASE]:-0} ${BASE_DO_ACTION[$BASE]:-1}
	BASE_DO_ACTION[$BASE]=$?
	##subpath - fournir une valeur par défaut.
	BASE_BACKUP_SUBPATH[$BASE]=`echo ${BASE_BACKUP_SUBPATH[$BASE]:-'fixme'}|tr -cd '[:alnum:]._-'`
	##backup with purge, fix case
	BASE_BACKUP_WITH_PURGE[$BASE]=${BASE_BACKUP_WITH_PURGE[$BASE],,}
	if [ "always" = "${BASE_BACKUP_WITH_PURGE[$BASE]}" ]; then
		#valeur acceptée
		:
	elif [ "never" = "${BASE_BACKUP_WITH_PURGE[$BASE]}" ]; then
		#valeur acceptée
		:
	else
		#valeur par défaut.
		BASE_BACKUP_WITH_PURGE[$BASE]='success'
	fi
	##backup policy, fix case
	BASE_BACKUP_POLICY[$BASE]=${BASE_BACKUP_POLICY[$BASE],,}
	if [ "only full" = "${BASE_BACKUP_POLICY[$BASE]}" ];then
		#valeur acceptée
		:
	elif [ "if full" = "${BASE_BACKUP_POLICY[$BASE]}" ];then
		#valeur acceptée
		:
	else
		BASE_BACKUP_POLICY[$BASE]='standard'
	fi
done
##on a tout, on peut envoyer un peu d'output
show_config | tee -a $LOG


case $ARG_MODE in
	DIFF)
		hanabackup_main DIFF 2>&1 | tee -a $LOG
		RC=$?
		;;
	INCR)
		hanabackup_main INCR  2>&1 | tee -a $LOG
		RC=$?
		;;
	FULL)
		hanabackup_main FULL  2>&1 | tee -a $LOG
		RC=$?
		;;
	SUMMARY)
		hanasummary_main  2>&1 | tee -a $LOG
		RC=0
		;;
	DELETE)
		hanacleanup_main  2>&1 | tee -a $LOG
		RC=0
		;;
	*)
		echo "Mode '$MODE' inconnu"  | tee -a $LOG
		show_usage
		kill_me "$BCKSID: Backup aborted: mode not supported" 1
		;;
esac
echo
echo "Fichier de log: $LOG" | tee -a $LOG
echo "Execution terminee. Status=$RC" | tee -a $LOG

exit $RC
