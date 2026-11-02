#ifndef ALX_MTP_H
#define ALX_MTP_H

#include <stdint.h>
#include <stddef.h>

/// Pont minimal vers libmtp, chargée à l'exécution (dlopen).
/// Toutes les fonctions renvoient une valeur négative en cas d'erreur.

/// 1 si libmtp a pu être chargée, 0 sinon.
int alx_mtp_available(void);

/// Nombre de Kindle (vendeur Lab126) détectées en MTP.
int alx_mtp_detect_kindles(void);

typedef struct alx_mtp_session alx_mtp_session;

/// Ouvre la première Kindle MTP. NULL si aucune ou si l'accès USB est refusé.
alx_mtp_session *alx_mtp_open(void);
void alx_mtp_close(alx_mtp_session *session);

/// Nom convivial de l'appareil (copié dans buffer).
void alx_mtp_name(alx_mtp_session *session, char *buffer, size_t length);

/// Numéro de série de l'appareil (chaîne vide si inconnu).
void alx_mtp_serial(alx_mtp_session *session, char *buffer, size_t length);

/// Espace libre du premier stockage, en octets (-1 si inconnu).
int64_t alx_mtp_free_space(alx_mtp_session *session);

/// `path` est relatif au dossier « documents » (ex. « Downloads/Items01/livre.kfx »).
typedef void (*alx_mtp_list_callback)(void *context, uint32_t item_id, const char *path, uint64_t size);

/// Liste récursivement les fichiers de « documents » (hors dossiers .sdr). Renvoie leur nombre.
int alx_mtp_list_documents(alx_mtp_session *session, alx_mtp_list_callback callback, void *context);

/// Copie un fichier de l'appareil vers un chemin local. 0 si succès.
int alx_mtp_download(alx_mtp_session *session, uint32_t item_id, const char *local_path);

/// Envoie un fichier local dans « documents » sous le nom donné. 0 si succès.
int alx_mtp_send(alx_mtp_session *session, const char *local_path, const char *filename, uint64_t size);

/// Envoie un fichier dans system/thumbnails (miniatures de couverture). 0 si succès.
int alx_mtp_send_thumbnail(alx_mtp_session *session, const char *local_path, const char *filename, uint64_t size);

/// Remplace le contenu d'un fichier existant (même dossier, même nom).
/// L'original n'est supprimé qu'une fois la nouvelle version envoyée. 0 si succès.
int alx_mtp_replace(alx_mtp_session *session, uint32_t item_id, const char *local_path, uint64_t size);

/// Supprime un objet par identifiant. 0 si succès.
int alx_mtp_delete(alx_mtp_session *session, uint32_t item_id);

#endif
