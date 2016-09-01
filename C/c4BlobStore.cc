//
//  c4BlobStore.cc
//  LiteCore
//
//  Created by Jens Alfke on 9/1/16.
//  Copyright © 2016 Couchbase. All rights reserved.
//

#include "c4Internal.hh"
#include "c4BlobStore.h"
#include "BlobStore.hh"
#include <libb64/decode.h>


struct c4BlobStore : public BlobStore {
public:
    c4BlobStore(const FilePath &dirPath, const Options *options)
    :BlobStore(dirPath, options)
    { }
};


static inline const blobKey& internal(const C4BlobKey &key) {
    return *(blobKey*)&key;
}

static inline const C4BlobKey& external(const blobKey &key) {
    return *(C4BlobKey*)&key;
}


bool c4blob_keyFromString(C4Slice str, C4BlobKey* outKey) {
    try {
        blobKey key(string((char*)str.buf, str.size));
        *outKey = external(key);
        return true;
    } catchError(nullptr)
    return false;
}


C4SliceResult c4blob_keyToString(C4BlobKey key) {
    string str = internal(key).base64String();
    return stringResult(str.c_str());
}



C4BlobStore* c4blob_openStore(C4Slice dirPath,
                              C4DatabaseFlags flags,
                              const C4EncryptionKey *key,
                              C4Error* outError)
{
    try {
        BlobStore::Options options = {};
        options.create = (flags & kC4DB_Create) != 0;
        options.writeable = !(flags & kC4DB_ReadOnly);
        return new c4BlobStore(FilePath((string)dirPath), &options);
    } catchError(outError)
    return nullptr;
}


void c4blob_freeStore(C4BlobStore *store) {
    delete store;
}


bool c4blob_deleteStore(C4BlobStore* store, C4Error *outError) {
    try {
        store->deleteStore();
        delete store;
        return true;
    } catchError(nullptr)
    return false;
}


int64_t c4blob_getSize(C4BlobStore* store, C4BlobKey key) {
    try {
        return store->get(internal(key)).contentLength();
    } catchError(nullptr)
    return -1;
}


C4SliceResult c4blob_getContents(C4BlobStore* store, C4BlobKey key, C4Error* outError) {
    try {
        alloc_slice contents = store->get(internal(key)).contents();
        contents.dontFree();
        return {contents.buf, contents.size};
    } catchError(outError)
    return {NULL, 0};
}


bool c4blob_create(C4BlobStore* store, C4Slice contents, C4BlobKey *outKey, C4Error* outError) {
    try {
        Blob blob = store->put(contents);
        if (outKey)
            *outKey = external(blob.key());
        return true;
    } catchError(outError)
    return false;
}


bool c4blob_delete(C4BlobStore* store, C4BlobKey key, C4Error* outError) {
    try {
        store->get(internal(key)).del();
        return true;
    } catchError(outError)
    return false;
}
