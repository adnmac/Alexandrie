#include "alx_mtp.h"

#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>

// Sous-ensemble des structures publiques de libmtp.h (1.1.x), dans le même ordre de champs.

typedef struct {
    char *vendor;
    uint16_t vendor_id;
    char *product;
    uint16_t product_id;
    uint32_t device_flags;
} LIBMTP_device_entry_t;

typedef struct {
    LIBMTP_device_entry_t device_entry;
    uint32_t bus_location;
    uint8_t devnum;
} LIBMTP_raw_device_t;

typedef struct LIBMTP_devicestorage_struct LIBMTP_devicestorage_t;
struct LIBMTP_devicestorage_struct {
    uint32_t id;
    uint16_t StorageType;
    uint16_t FilesystemType;
    uint16_t AccessCapability;
    uint64_t MaxCapacity;
    uint64_t FreeSpaceInBytes;
    uint64_t FreeSpaceInObjects;
    char *StorageDescription;
    char *VolumeIdentifier;
    LIBMTP_devicestorage_t *next;
    LIBMTP_devicestorage_t *prev;
};

typedef struct {
    uint8_t object_bitsize;
    void *params;
    void *usbinfo;
    LIBMTP_devicestorage_t *storage;
    // … champs suivants inutilisés
} LIBMTP_mtpdevice_t;

typedef struct LIBMTP_file_struct LIBMTP_file_t;
struct LIBMTP_file_struct {
    uint32_t item_id;
    uint32_t parent_id;
    uint32_t storage_id;
    char *filename;
    uint64_t filesize;
    time_t modificationdate;
    int filetype;
    LIBMTP_file_t *next;
};

enum { LIBMTP_FILETYPE_FOLDER = 0, LIBMTP_FILETYPE_JPEG = 14, LIBMTP_FILETYPE_UNKNOWN = 44 };
static const uint32_t ROOT_PARENT = 0xFFFFFFFFu;
static const uint16_t KINDLE_VENDOR = 0x1949;

static struct {
    int loaded;
    void (*Init)(void);
    int (*Detect_Raw_Devices)(LIBMTP_raw_device_t **, int *);
    LIBMTP_mtpdevice_t *(*Open_Raw_Device_Uncached)(LIBMTP_raw_device_t *);
    void (*Release_Device)(LIBMTP_mtpdevice_t *);
    char *(*Get_Friendlyname)(LIBMTP_mtpdevice_t *);
    char *(*Get_Modelname)(LIBMTP_mtpdevice_t *);
    char *(*Get_Serialnumber)(LIBMTP_mtpdevice_t *);
    int (*Get_Storage)(LIBMTP_mtpdevice_t *, int);
    LIBMTP_file_t *(*Get_Files_And_Folders)(LIBMTP_mtpdevice_t *, uint32_t, uint32_t);
    LIBMTP_file_t *(*new_file_t)(void);
    void (*destroy_file_t)(LIBMTP_file_t *);
    int (*Send_File_From_File)(LIBMTP_mtpdevice_t *, const char *, LIBMTP_file_t *, void *, const void *);
    int (*Delete_Object)(LIBMTP_mtpdevice_t *, uint32_t);
    uint32_t (*Create_Folder)(LIBMTP_mtpdevice_t *, char *, uint32_t, uint32_t);
    int (*Get_File_To_File)(LIBMTP_mtpdevice_t *, uint32_t, const char *, void *, const void *);
    LIBMTP_file_t *(*Get_Filemetadata)(LIBMTP_mtpdevice_t *, uint32_t);
    int (*Set_File_Name)(LIBMTP_mtpdevice_t *, LIBMTP_file_t *, const char *);
} lib;

static pthread_once_t load_once = PTHREAD_ONCE_INIT;

static void load_library(void) {
    const char *candidates[] = {
        "/opt/homebrew/opt/libmtp/lib/libmtp.9.dylib",
        "/opt/homebrew/lib/libmtp.9.dylib",
        "/usr/local/opt/libmtp/lib/libmtp.9.dylib",
        "/usr/local/lib/libmtp.9.dylib",
        "libmtp.9.dylib",
        NULL,
    };
    void *handle = NULL;
    for (int i = 0; candidates[i] && !handle; i++) handle = dlopen(candidates[i], RTLD_NOW | RTLD_LOCAL);
    if (!handle) return;

#define BIND(field, symbol) lib.field = dlsym(handle, symbol); if (!lib.field) return;
    BIND(Init, "LIBMTP_Init")
    BIND(Detect_Raw_Devices, "LIBMTP_Detect_Raw_Devices")
    BIND(Open_Raw_Device_Uncached, "LIBMTP_Open_Raw_Device_Uncached")
    BIND(Release_Device, "LIBMTP_Release_Device")
    BIND(Get_Friendlyname, "LIBMTP_Get_Friendlyname")
    BIND(Get_Modelname, "LIBMTP_Get_Modelname")
    // Facultatif : une libmtp qui ne l'expose pas reste utilisable.
    lib.Get_Serialnumber = dlsym(handle, "LIBMTP_Get_Serialnumber");
    BIND(Get_Storage, "LIBMTP_Get_Storage")
    BIND(Get_Files_And_Folders, "LIBMTP_Get_Files_And_Folders")
    BIND(new_file_t, "LIBMTP_new_file_t")
    BIND(destroy_file_t, "LIBMTP_destroy_file_t")
    BIND(Send_File_From_File, "LIBMTP_Send_File_From_File")
    BIND(Delete_Object, "LIBMTP_Delete_Object")
    BIND(Create_Folder, "LIBMTP_Create_Folder")
    BIND(Get_File_To_File, "LIBMTP_Get_File_To_File")
    BIND(Get_Filemetadata, "LIBMTP_Get_Filemetadata")
    BIND(Set_File_Name, "LIBMTP_Set_File_Name")
#undef BIND

    lib.Init();
    lib.loaded = 1;
}

int alx_mtp_available(void) {
    pthread_once(&load_once, load_library);
    return lib.loaded;
}

struct alx_mtp_session {
    LIBMTP_mtpdevice_t *device;
    uint32_t storage_id;
};

int alx_mtp_detect_kindles(void) {
    if (!alx_mtp_available()) return -1;
    LIBMTP_raw_device_t *raw = NULL;
    int count = 0;
    if (lib.Detect_Raw_Devices(&raw, &count) != 0 || !raw) return 0;
    int kindles = 0;
    for (int i = 0; i < count; i++)
        if (raw[i].device_entry.vendor_id == KINDLE_VENDOR) kindles++;
    free(raw);
    return kindles;
}

alx_mtp_session *alx_mtp_open(void) {
    if (!alx_mtp_available()) return NULL;
    LIBMTP_raw_device_t *raw = NULL;
    int count = 0;
    if (lib.Detect_Raw_Devices(&raw, &count) != 0 || !raw) return NULL;
    LIBMTP_mtpdevice_t *device = NULL;
    for (int i = 0; i < count && !device; i++)
        if (raw[i].device_entry.vendor_id == KINDLE_VENDOR) device = lib.Open_Raw_Device_Uncached(&raw[i]);
    free(raw);
    if (!device) return NULL;
    lib.Get_Storage(device, 0);
    alx_mtp_session *session = calloc(1, sizeof(alx_mtp_session));
    session->device = device;
    session->storage_id = device->storage ? device->storage->id : 0;
    return session;
}

void alx_mtp_close(alx_mtp_session *session) {
    if (!session) return;
    lib.Release_Device(session->device);
    free(session);
}

void alx_mtp_name(alx_mtp_session *session, char *buffer, size_t length) {
    if (!length) return;
    buffer[0] = 0;
    char *name = lib.Get_Friendlyname(session->device);
    if (!name || !*name) { free(name); name = lib.Get_Modelname(session->device); }
    if (name) { strncpy(buffer, name, length - 1); buffer[length - 1] = 0; free(name); }
}

void alx_mtp_serial(alx_mtp_session *session, char *buffer, size_t length) {
    if (!length) return;
    buffer[0] = 0;
    if (!lib.Get_Serialnumber) return;
    char *serial = lib.Get_Serialnumber(session->device);
    if (serial) { strncpy(buffer, serial, length - 1); buffer[length - 1] = 0; free(serial); }
}

int64_t alx_mtp_free_space(alx_mtp_session *session) {
    LIBMTP_devicestorage_t *storage = session->device->storage;
    return storage ? (int64_t)storage->FreeSpaceInBytes : -1;
}

static void free_list(LIBMTP_file_t *files) {
    while (files) {
        LIBMTP_file_t *next = files->next;
        lib.destroy_file_t(files);
        files = next;
    }
}

/// Identifiant d'un sous-dossier (insensible à la casse), créé au besoin si `create`.
static uint32_t find_folder(alx_mtp_session *s, uint32_t parent, const char *name, int create) {
    LIBMTP_file_t *files = lib.Get_Files_And_Folders(s->device, s->storage_id, parent);
    uint32_t found = 0;
    for (LIBMTP_file_t *f = files; f; f = f->next)
        if (f->filetype == LIBMTP_FILETYPE_FOLDER && f->filename && strcasecmp(f->filename, name) == 0) {
            found = f->item_id;
            break;
        }
    free_list(files);
    if (!found && create) {
        char *copy = strdup(name);
        found = lib.Create_Folder(s->device, copy, parent == ROOT_PARENT ? 0 : parent, s->storage_id);
        free(copy);
    }
    return found;
}

static size_t has_suffix(const char *s, const char *suffix) {
    size_t a = strlen(s), b = strlen(suffix);
    return a >= b && strcasecmp(s + a - b, suffix) == 0;
}

static int list_folder(alx_mtp_session *s, uint32_t folder, const char *prefix, int depth,
                       alx_mtp_list_callback callback, void *context) {
    LIBMTP_file_t *files = lib.Get_Files_And_Folders(s->device, s->storage_id, folder);
    int n = 0;
    char path[1024];
    for (LIBMTP_file_t *f = files; f; f = f->next) {
        const char *name = f->filename ? f->filename : "";
        snprintf(path, sizeof path, "%s%s%s", prefix, *prefix ? "/" : "", name);
        if (f->filetype == LIBMTP_FILETYPE_FOLDER) {
            // Les dossiers .sdr contiennent les positions de lecture, pas des livres.
            if (depth < 4 && !has_suffix(name, ".sdr"))
                n += list_folder(s, f->item_id, path, depth + 1, callback, context);
        } else {
            callback(context, f->item_id, path, f->filesize);
            n++;
        }
    }
    free_list(files);
    return n;
}

int alx_mtp_list_documents(alx_mtp_session *session, alx_mtp_list_callback callback, void *context) {
    uint32_t documents = find_folder(session, ROOT_PARENT, "documents", 0);
    if (!documents) return 0;
    return list_folder(session, documents, "", 0, callback, context);
}

int alx_mtp_download(alx_mtp_session *session, uint32_t item_id, const char *local_path) {
    return lib.Get_File_To_File(session->device, item_id, local_path, NULL, NULL);
}

static int send_to(alx_mtp_session *s, uint32_t parent, const char *path, const char *filename,
                   uint64_t size, int filetype) {
    LIBMTP_file_t *file = lib.new_file_t();
    file->filename = strdup(filename);
    file->filesize = size;
    file->filetype = filetype;
    file->parent_id = parent;
    file->storage_id = s->storage_id;
    int result = lib.Send_File_From_File(s->device, path, file, NULL, NULL);
    lib.destroy_file_t(file);
    return result;
}

int alx_mtp_send(alx_mtp_session *session, const char *local_path, const char *filename, uint64_t size) {
    uint32_t documents = find_folder(session, ROOT_PARENT, "documents", 1);
    if (!documents) return -1;
    return send_to(session, documents, local_path, filename, size, LIBMTP_FILETYPE_UNKNOWN);
}

int alx_mtp_send_thumbnail(alx_mtp_session *session, const char *local_path, const char *filename, uint64_t size) {
    uint32_t system = find_folder(session, ROOT_PARENT, "system", 0);
    if (!system) return -1;
    uint32_t thumbnails = find_folder(session, system, "thumbnails", 0);
    if (!thumbnails) return -1;
    return send_to(session, thumbnails, local_path, filename, size, LIBMTP_FILETYPE_JPEG);
}

int alx_mtp_replace(alx_mtp_session *session, uint32_t item_id, const char *local_path, uint64_t size) {
    LIBMTP_file_t *old = lib.Get_Filemetadata(session->device, item_id);
    if (!old || !old->filename) { if (old) lib.destroy_file_t(old); return -1; }
    char *name = strdup(old->filename);
    uint32_t parent = old->parent_id, storage = old->storage_id;
    lib.destroy_file_t(old);

    char temp_name[1100];
    snprintf(temp_name, sizeof temp_name, "%s.foluna-tmp", name);
    LIBMTP_file_t *file = lib.new_file_t();
    file->filename = strdup(temp_name);
    file->filesize = size;
    file->filetype = LIBMTP_FILETYPE_UNKNOWN;
    file->parent_id = parent;
    file->storage_id = storage;
    int result = lib.Send_File_From_File(session->device, local_path, file, NULL, NULL);
    if (result == 0) result = lib.Delete_Object(session->device, item_id);
    if (result == 0) result = lib.Set_File_Name(session->device, file, name);
    lib.destroy_file_t(file);
    free(name);
    return result;
}

int alx_mtp_delete(alx_mtp_session *session, uint32_t item_id) {
    return lib.Delete_Object(session->device, item_id);
}
