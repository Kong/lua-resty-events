/**
 * Copyright 2019-2024 Kong Inc.

 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at

 *    http://www.apache.org/licenses/LICENSE-2.0

 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */


#include <ngx_event.h>


/*
 * Workers forked from the same configuration cycle share a generation number,
 * bumped per cycle by the master: a reload's workers never share it with the
 * ones they replace.  The table below maps process slots to generations.
 */


static ngx_uint_t      ngx_lua_events_generation = 1;
static ngx_uint_t     *ngx_lua_events_gen_table;
static ngx_shm_t       ngx_lua_events_shm;


static void
ngx_lua_disable_listening_socket(ngx_listening_t *ls)
{
    ngx_connection_t  *c = ls->connection;

    /* copied from ngx_close_listening_sockets */

    if (c) {
        if (c->read->active) {
            if (ngx_event_flags & NGX_USE_EPOLL_EVENT) {

                /*
                 * it seems that Linux-2.6.x OpenVZ sends events
                 * for closed shared listening sockets unless
                 * the events was explicitly deleted
                 */

                ngx_del_event(c->read, NGX_READ_EVENT, 0);

            } else {
                ngx_del_event(c->read, NGX_READ_EVENT, NGX_CLOSE_EVENT);
            }
        }

    }

    ngx_log_debug2(NGX_LOG_DEBUG_EVENT, ngx_cycle->log, 0,
            "close listening %V #%d ", &ls->addr_text, ls->fd);
}


int
ngx_lua_ffi_disable_listening_unix_socket(ngx_str_t *sock_name)
{
#if (NGX_HAVE_UNIX_DOMAIN)

    ngx_uint_t           i;
    ngx_listening_t     *ls;

    /* copied from ngx_close_listening_sockets */

    ls = ngx_cycle->listening.elts;
    for (i = 0; i < ngx_cycle->listening.nelts; i++) {

#if (NGX_HAVE_REUSEPORT)
        if (ls[i].fd == (ngx_socket_t) -1) {
            continue;
        }
#endif

        if (ls[i].sockaddr->sa_family != AF_UNIX) {
            continue;
        }

        ngx_log_debug2(NGX_LOG_DEBUG_EVENT, ngx_cycle->log, 0,
                "try to close listening %V #%d", &ls[i].addr_text, ls[i].fd);

        if (ngx_strncmp(ls[i].addr_text.data,
                         sock_name->data, sock_name->len) == 0) {
            ngx_lua_disable_listening_socket(&ls[i]);
            return NGX_OK;
        }
    }

    return NGX_ERROR;

#else

#error unix domain socket is required!

#endif
}


static ngx_int_t
ngx_lua_events_init_module(ngx_cycle_t *cycle)
{
    if (ngx_lua_events_gen_table == NULL) {
        /* allocated once by the master, shared with all later workers */
        ngx_lua_events_shm.size = sizeof(ngx_uint_t) * NGX_MAX_PROCESSES;
        ngx_lua_events_shm.log = cycle->log;

        if (ngx_shm_alloc(&ngx_lua_events_shm) != NGX_OK) {
            return NGX_ERROR;
        }

        ngx_memzero(ngx_lua_events_shm.addr, ngx_lua_events_shm.size);

        ngx_lua_events_gen_table = (ngx_uint_t *) ngx_lua_events_shm.addr;
    }

    ngx_lua_events_generation++;

    return NGX_OK;
}


static ngx_int_t
ngx_lua_events_init_process(ngx_cycle_t *cycle)
{
    if (ngx_lua_events_gen_table != NULL
        && ngx_process_slot >= 0
        && ngx_process_slot < NGX_MAX_PROCESSES)
    {
        ngx_lua_events_gen_table[ngx_process_slot] =
            ngx_lua_events_generation;
    }

    return NGX_OK;
}


/* generations are small, `unsigned int` matches the other ngx_lua FFIs */
unsigned int
ngx_lua_ffi_events_generation(void)
{
    return (unsigned int) ngx_lua_events_generation;
}


/* the generation of process `pid`, or 0 when it is unknown */
unsigned int
ngx_lua_ffi_events_pid_generation(int pid)
{
    ngx_uint_t  i;

    if (ngx_lua_events_gen_table == NULL || pid <= 0) {
        return 0;
    }

    /* the same walk as ngx.worker.pids() does over the process table */

    for (i = 0; i < NGX_MAX_PROCESSES; i++) {

        if (i != (ngx_uint_t) ngx_process_slot && ngx_processes[i].pid == 0) {
            break;
        }

        if (i == (ngx_uint_t) ngx_process_slot) {
            if (pid == ngx_pid) {
                return (unsigned int) ngx_lua_events_gen_table[i];
            }
        }

        if (ngx_processes[i].channel[0] > 0 && ngx_processes[i].pid == pid) {
            return (unsigned int) ngx_lua_events_gen_table[i];
        }
    }

    return 0;
}


static ngx_core_module_t  ngx_lua_events_module_ctx = {
    ngx_string("ngx_lua_events"),
    NULL,
    NULL
};


ngx_module_t  ngx_lua_events_module = {
    NGX_MODULE_V1,
    &ngx_lua_events_module_ctx,                  /* module context */
    NULL,                                        /* module directives */
    NGX_CORE_MODULE,                             /* module type */
    NULL,                                        /* init master */
    ngx_lua_events_init_module,                  /* init module */
    ngx_lua_events_init_process,                 /* init process */
    NULL,                                        /* init thread */
    NULL,                                        /* exit thread */
    NULL,                                        /* exit process */
    NULL,                                        /* exit master */
    NGX_MODULE_V1_PADDING
};
