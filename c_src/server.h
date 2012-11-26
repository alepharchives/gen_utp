#ifndef UTPDRV_SERVER_H
#define UTPDRV_SERVER_H

// -------------------------------------------------------------------
//
// server.h: uTP server port
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

#include "utp_port.h"
#include "libutp/utp.h"


namespace UtpDrv {

class Listener;

class Server : public UtpPort
{
public:
    Server(Listener& lr, UTPSocket* utp);
    ~Server();

    ErlDrvSSizeT
    control(unsigned command, const char* buf, ErlDrvSizeT len,
            char** rbuf, ErlDrvSizeT rlen);

    void stop();

    void incoming();

    void force_close();

private:
    Listener& listener;

    ErlDrvSSizeT close(const char* buf, ErlDrvSizeT len, char** rbuf);

    void do_send_to(const byte* p, size_t len, const sockaddr* to,
                    socklen_t slen);
    void do_read(const byte* bytes, size_t count);
    void do_write(byte* bytes, size_t count);
    size_t do_get_rb_size();
    void do_state_change(int state);
    void do_error(int errcode);
    void do_overhead(bool send, size_t count, int type);
    void do_incoming(UTPSocket* utp);

    // prevent copies
    Server(const Server&);
    void operator=(const Server&);
};

}



// this block comment is for emacs, do not delete
// Local Variables:
// mode: c++
// c-file-style: "stroustrup"
// c-file-offsets: ((innamespace . 0))
// End:

#endif