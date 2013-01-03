// -------------------------------------------------------------------
//
// main_handler.cc: handler for primary uTP driver port
//
// Copyright (c) 2012 Basho Technologies, Inc. All Rights Reserved.
//
// This file is provided to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file
// except in compliance with the License.  You may obtain
// a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.
//
// -------------------------------------------------------------------

#include <sys/time.h>
#include "main_handler.h"
#include "globals.h"
#include "locker.h"
#include "libutp/utp.h"
#include "utp_handler.h"
#include "client.h"
#include "listener.h"


using namespace UtpDrv;

const unsigned long timeout_check = 100;

UtpDrv::MainHandler* UtpDrv::MainHandler::main_handler = 0;

UtpDrv::MainHandler::MainHandler(ErlDrvPort p) :
    Handler(p), map_mutex(0)
{
    set_port_control_flags(port, PORT_CONTROL_FLAG_BINARY);
}

UtpDrv::MainHandler::~MainHandler()
{
}

int
UtpDrv::MainHandler::driver_init()
{
    UTPDRV_TRACE("MainHandler::driver_init\r\n");
    utp_mutex = erl_drv_mutex_create(const_cast<char*>("utp"));
    return 0;
}

void
UtpDrv::MainHandler::driver_finish()
{
    UTPDRV_TRACE("MainHandler::driver_finish\r\n");
    erl_drv_mutex_destroy(utp_mutex);
    delete main_handler;
}

void
UtpDrv::MainHandler::check_utp_timeouts() const
{
    {
        MutexLocker lock(utp_mutex);
        UTP_CheckTimeouts();
    }
    driver_set_timer(port, timeout_check);
}

ErlDrvSSizeT
UtpDrv::MainHandler::control(unsigned command, const char* buf, ErlDrvSizeT len,
                             char** rbuf, ErlDrvSizeT rlen)
{
    UTPDRV_TRACE("MainHandler::control\r\n");
    switch (command) {
    case UTP_LISTEN:
        return listen(buf, len, rbuf, rlen);
        break;
    case UTP_CONNECT_START:
        return connect_start(buf, len, rbuf, rlen);
        break;
    default:
        return encode_error(rbuf, rlen, "enotsup");
        break;
    }
}

void
UtpDrv::MainHandler::start()
{
    UTPDRV_TRACE("MainHandler::start\r\n");
    driver_set_timer(port, timeout_check);
    main_handler = this;
    drv_mutex = erl_drv_mutex_create(const_cast<char*>("drv"));
    map_mutex = erl_drv_mutex_create(const_cast<char*>("utpmap"));
}

void
UtpDrv::MainHandler::stop()
{
    UTPDRV_TRACE("MainHandler::stop\r\n");
    driver_cancel_timer(port);
    erl_drv_mutex_destroy(map_mutex);
    erl_drv_mutex_destroy(drv_mutex);
    main_handler = 0;
}

void
UtpDrv::MainHandler::ready_input(long fd)
{
    SocketHandler* hndlr = 0;
    {
        MutexLocker lock(map_mutex);
        FdMap::iterator it = fdmap.find(fd);
        if (it != fdmap.end()) {
            hndlr = it->second;
        }
    }
    if (hndlr != 0) {
        hndlr->input_ready();
    }
}

void
UtpDrv::MainHandler::outputv(ErlIOVec&)
{
    UTPDRV_TRACE("MainHandler::outputv\r\n");
}

void
UtpDrv::MainHandler::process_exit(ErlDrvMonitor* monitor)
{
    UTPDRV_TRACE("MainHandler::process_exit\r\n");
}

ErlDrvPort
UtpDrv::MainHandler::drv_port()
{
    UTPDRV_TRACE("MainHandler::drv_port\r\n");
    return main_handler->port;
}

void
UtpDrv::MainHandler::start_input(int fd, SocketHandler* handler)
{
    UTPDRV_TRACE("MainHandler::start_input\r\n");
    main_handler->select(fd, handler);
}

void
UtpDrv::MainHandler::stop_input(int& fd)
{
    UTPDRV_TRACE("MainHandler::stop_input\r\n");
    if (main_handler != 0) {
        main_handler->deselect(fd);
    }
}

void
UtpDrv::MainHandler::add_monitor(const ErlDrvMonitor& mon, Handler* h)
{
    UTPDRV_TRACE("MainHandler::add_monitor\r\n");
    main_handler->add_mon(mon, h);
}

void
UtpDrv::MainHandler::add_mon(const ErlDrvMonitor& mon, Handler* h)
{
    UTPDRV_TRACE("MainHandler::add_mon\r\n");
    MutexLocker lock(map_mutex);
    MonMap::value_type val(mon, h);
    monmap.insert(val);
}

void
UtpDrv::MainHandler::del_monitor(ErlDrvPort port, ErlDrvMonitor& mon)
{
    UTPDRV_TRACE("MainHandler::del_monitor\r\n");
    main_handler->del_mon(port, mon);
}

void
UtpDrv::MainHandler::del_mon(ErlDrvPort port, ErlDrvMonitor& mon)
{
    UTPDRV_TRACE("MainHandler::del_mon\r\n");
    MutexLocker lock(map_mutex);
    monmap.erase(mon);
    driver_demonitor_process(port, &mon);
}

ErlDrvSSizeT
UtpDrv::MainHandler::connect_start(const char* buf, ErlDrvSizeT len,
                                   char** rbuf, ErlDrvSizeT rlen)
{
    UTPDRV_TRACE("MainHandler::connect_start\r\n");
    int arity, type, size;
    Binary ref, binopts;
    long bin_size;
    char addrstr[INET6_ADDRSTRLEN];
    unsigned long addrport;
    try {
        EiDecoder decoder(buf, len);
        decoder.tuple_header(arity);
        if (arity != 4) {
            return reinterpret_cast<ErlDrvSSizeT>(ERL_DRV_ERROR_BADARG);
        }
        decoder.string(addrstr);
        decoder.ulong(addrport);
        decoder.type(type, size);
        if (type != ERL_BINARY_EXT) {
            return reinterpret_cast<ErlDrvSSizeT>(ERL_DRV_ERROR_BADARG);
        }
        binopts.decode(decoder, size);
        decoder.type(type, size);
        if (type != ERL_BINARY_EXT) {
            return reinterpret_cast<ErlDrvSSizeT>(ERL_DRV_ERROR_BADARG);
        }
        bin_size = ref.decode(decoder, size);
    } catch (const EiError&) {
        return reinterpret_cast<ErlDrvSSizeT>(ERL_DRV_ERROR_BADARG);
    }
    ErlDrvTermData caller = driver_caller(port);

    SockAddr addr;
    try {
        addr.from_addrport(addrstr, addrport);
    } catch (const BadSockAddr&) {
        return reinterpret_cast<ErlDrvSSizeT>(ERL_DRV_ERROR_BADARG);
    }

    SocketHandler::SockOpts opts;
    SocketHandler::decode_sock_opts(binopts, opts);
    int udp_sock, err;
    if (opts.fd != INVALID_SOCKET) {
        udp_sock = opts.fd;
        SockAddr fdaddr;
        if (getsockname(udp_sock, fdaddr, &fdaddr.slen) < 0) {
            err = errno;
        } else {
            err = 0;
        }
    } else if (opts.addr_set) {
        err = SocketHandler::open_udp_socket(udp_sock, opts.addr);
    } else if (opts.inet6) {
        SockAddr in6_any("::", 0);
        err = SocketHandler::open_udp_socket(udp_sock, in6_any);
    } else {
        err = SocketHandler::open_udp_socket(udp_sock, opts.port);
    }
    if (err != 0) {
        ErlDrvTermData term[] = {
            ERL_DRV_EXT2TERM, ref, ref.size(),
            ERL_DRV_ATOM, driver_mk_atom(const_cast<char*>("error")),
            ERL_DRV_ATOM, driver_mk_atom(erl_errno_id(err)),
            ERL_DRV_TUPLE, 2,
            ERL_DRV_TUPLE, 2,
        };
        driver_send_term(port, caller, term, sizeof term/sizeof *term);
    } else {
        Client* client = new Client(udp_sock,ref,opts.delivery,opts.send_tmout);
        ErlDrvPort new_port = create_port(caller, client);
        client->set_port(new_port);
        select(udp_sock, client);
        client->connect_to(addr);
        {
            ErlDrvTermData term[] = {
                ERL_DRV_EXT2TERM, ref, bin_size,
                ERL_DRV_ATOM, driver_mk_atom(const_cast<char*>("ok")),
                ERL_DRV_PORT, driver_mk_port(new_port),
                ERL_DRV_TUPLE, 2,
                ERL_DRV_TUPLE, 2,
            };
            driver_send_term(port, caller, term, sizeof term/sizeof *term);
        }
    }
    return 0;
}

ErlDrvSSizeT
UtpDrv::MainHandler::listen(const char* buf, ErlDrvSizeT len,
                            char** rbuf, ErlDrvSizeT rlen)
{
    UTPDRV_TRACE("MainHandler::listen\r\n");
    int arity, type, size;
    Binary ref, binopts;
    try {
        EiDecoder decoder(buf, len);
        decoder.tuple_header(arity);
        if (arity != 2) {
            return reinterpret_cast<ErlDrvSSizeT>(ERL_DRV_ERROR_BADARG);
        }
        decoder.type(type, size);
        if (type != ERL_BINARY_EXT) {
            return reinterpret_cast<ErlDrvSSizeT>(ERL_DRV_ERROR_BADARG);
        }
        binopts.decode(decoder, size);
        decoder.type(type, size);
        if (type != ERL_BINARY_EXT) {
            return reinterpret_cast<ErlDrvSSizeT>(ERL_DRV_ERROR_BADARG);
        }
        ref.decode(decoder, size);
    } catch (const EiError&) {
        return reinterpret_cast<ErlDrvSSizeT>(ERL_DRV_ERROR_BADARG);
    }
    ErlDrvTermData caller = driver_caller(port);

    SocketHandler::SockOpts opts;
    SocketHandler::decode_sock_opts(binopts, opts);
    int udp_sock, err;
    if (opts.fd != INVALID_SOCKET) {
        udp_sock = opts.fd;
        SockAddr fdaddr;
        if (getsockname(udp_sock, fdaddr, &fdaddr.slen) < 0) {
            err = errno;
        } else {
            err = 0;
        }
    } else if (opts.addr_set) {
        err = SocketHandler::open_udp_socket(udp_sock, opts.addr, true);
    } else if (opts.inet6) {
        SockAddr in6_any("::", 0);
        err = SocketHandler::open_udp_socket(udp_sock, in6_any, true);
    } else {
        err = SocketHandler::open_udp_socket(udp_sock, opts.port, true);
    }
    if (err != 0) {
        ErlDrvTermData term[] = {
            ERL_DRV_EXT2TERM, ref, ref.size(),
            ERL_DRV_ATOM, driver_mk_atom(const_cast<char*>("error")),
            ERL_DRV_ATOM, driver_mk_atom(erl_errno_id(err)),
            ERL_DRV_TUPLE, 2,
            ERL_DRV_TUPLE, 2,
        };
        driver_send_term(port, caller, term, sizeof term/sizeof *term);
    } else {
        Listener* listener = new Listener(udp_sock, opts.delivery,
                                          opts.send_tmout);
        ErlDrvPort new_port = create_port(caller, listener);
        listener->set_port(new_port);
        select(udp_sock, listener);
        ErlDrvTermData term[] = {
            ERL_DRV_EXT2TERM, ref, ref.size(),
            ERL_DRV_ATOM, driver_mk_atom(const_cast<char*>("ok")),
            ERL_DRV_PORT, driver_mk_port(new_port),
            ERL_DRV_TUPLE, 2,
            ERL_DRV_TUPLE, 2,
        };
        driver_send_term(port, caller, term, sizeof term/sizeof *term);
    }
    return 0;
}

void
UtpDrv::MainHandler::select(int fd, SocketHandler* handler)
{
    UTPDRV_TRACE("MainHandler::select\r\n");
    if (port != 0) {
        driver_select(port, reinterpret_cast<ErlDrvEvent>(fd),
                      ERL_DRV_READ|ERL_DRV_USE, 1);
    }
    FdMap::value_type val(fd, handler);
    MutexLocker lock(map_mutex);
    fdmap.insert(val);
}

void
UtpDrv::MainHandler::deselect(int& fd)
{
    UTPDRV_TRACE("MainHandler::deselect\r\n");
    if (fd != INVALID_SOCKET) {
        if (port != 0) {
            driver_select(port, reinterpret_cast<ErlDrvEvent>(fd),
                          ERL_DRV_READ|ERL_DRV_USE, 0);
        }
        MutexLocker lock(map_mutex);
        fdmap.erase(fd);
        fd = INVALID_SOCKET;
    }
}