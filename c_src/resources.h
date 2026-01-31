// Licensed under the Apache License, Version 2.0 (the "License"); you may not
// use this file except in compliance with the License. You may obtain a copy of
// the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
// WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
// License for the specific language governing permissions and limitations under
// the License.

#ifndef ERLFDB_RESOURCES_H
#define ERLFDB_RESOURCES_H

#include <stdbool.h>

#include "erl_nif.h"
#include "fdb.h"

extern ErlNifResourceType *ErlFDBFutureRes;
extern ErlNifResourceType *ErlFDBDatabaseRes;
extern ErlNifResourceType *ErlFDBTenantRes;
extern ErlNifResourceType *ErlFDBTransactionRes;

typedef enum _ErlFDBFutureType {
    ErlFDB_FT_NONE = 0,
    ErlFDB_FT_VOID,
    ErlFDB_FT_INT64,
    ErlFDB_FT_KEY,
    ErlFDB_FT_VALUE,
    ErlFDB_FT_STRING_ARRAY,
    ErlFDB_FT_KEYVALUE_ARRAY,
    ErlFDB_FT_MAPPEDKEYVALUE_ARRAY,
    ErlFDB_FT_KEY_ARRAY
} ErlFDBFutureType;

typedef struct _ErlFDBFuture {
    FDBFuture *future;
    ErlFDBFutureType ftype;
    ErlNifPid pid;

    /* pid_env: The process-bound environment from the NIF call that
     * created this future. Used as the 'caller_env' argument to
     * enif_send() when the FDB callback fires synchronously.
     *
     * LIFETIME: Only valid during the erlfdb_create_future() call.
     * After that NIF returns, this pointer is stale and must not be
     * dereferenced.
     *
     * SAFETY: This is safe because we only use pid_env when
     * enif_thread_type() != ERL_NIF_THR_UNDEFINED, which indicates
     * we're on an Erlang scheduler thread. Synchronous callbacks
     * only occur during fdb_future_set_callback() within
     * erlfdb_create_future(), so pid_env is still valid at that point.
     * Asynchronous callbacks from the FDB network thread pass NULL
     * to enif_send() instead.
     *
     * FUTURE CONSIDERATION: A more robust alternative would be to use
     * enif_tsd_key_create() to store the current NIF environment in
     * thread-specific data at the start of each NIF call. The callback
     * could then retrieve it via enif_tsd_get(), eliminating the need
     * to store a potentially-stale pointer in the future struct.
     *
     * See erlfdb_future_cb() in main.c for the callback implementation.
     */
    ErlNifEnv *pid_env;

    /* msg_env: A process-independent environment allocated with
     * enif_alloc_env(). Owns the terms (msg_ref) sent via enif_send().
     *
     * LIFETIME: Allocated in erlfdb_create_future(), freed in
     * erlfdb_future_dtor(). Survives across NIF calls and threads.
     */
    ErlNifEnv *msg_env;

    ERL_NIF_TERM msg_ref;
    ErlNifMutex *lock;
    bool cancelled;
} ErlFDBFuture;

typedef struct _ErlFDBDatabase {
    FDBDatabase *database;
} ErlFDBDatabase;

typedef struct _ErlFDBTenant {
    FDBTenant *tenant;
} ErlFDBTenant;

typedef struct _ErlFDBTransaction {
    FDBTransaction *transaction;
    ERL_NIF_TERM owner;
    unsigned int txid;
    bool read_only;
    bool writes_allowed;
    bool has_watches;
} ErlFDBTransaction;

int erlfdb_init_resources(ErlNifEnv *env);
void erlfdb_future_dtor(ErlNifEnv *env, void *obj);
void erlfdb_database_dtor(ErlNifEnv *env, void *obj);
void erlfdb_tenant_dtor(ErlNifEnv *env, void *obj);
void erlfdb_transaction_dtor(ErlNifEnv *env, void *obj);

int erlfdb_transaction_is_owner(ErlNifEnv *env, ErlFDBTransaction *t);

#endif // Included resources.h
