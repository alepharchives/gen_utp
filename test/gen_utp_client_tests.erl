%% -------------------------------------------------------------------
%%
%% gen_utp_client_tests: client tests for gen_utp
%%
%% Copyright (c) 2012-2013 Basho Technologies, Inc. All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------
-module(gen_utp_client_tests).
-author('Steve Vinoski <vinoski@ieee.org>').

-include_lib("eunit/include/eunit.hrl").
-include("gen_utp_tests_setup.hrl").

client_timeout_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(_) ->
             {timeout, 15,
              [{"client timeout test",
                ?_test(
                   begin
                       {ok, LSock} = gen_utp:listen(0),
                       {ok, {_, Port}} = gen_utp:sockname(LSock),
                       ok = gen_utp:close(LSock),
                       ?assertMatch({error, etimedout},
                                    gen_utp:connect("localhost", Port))
                   end)}
              ]}
     end}.

client_server_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(_) ->
             {inorder,
              [{"simple connect test",
                fun simple_connect/0},
               {"simple send binary test, active true",
                fun() -> simple_send(binary, true) end},
               {"simple send binary test, active once",
                fun() -> simple_send(binary, once) end},
               {"simple send binary test, active false",
                fun() -> simple_send(binary, false) end},
               {"simple send list test",
                fun() -> simple_send(list, true) end},
               {"two clients test",
                fun two_clients/0},
               {"client large send",
                fun large_send/0},
               {"two servers test",
                fun two_servers/0},
               {"send timeout test",
                fun send_timeout/0},
               {"invalid accept test",
                fun invalid_accept/0},
               {"packet size test",
                fun packet_size/0},
               {"header size test",
                fun header_size/0},
               {"set send/recv buffer sizes test",
                fun buf_size/0}
              ]}
     end}.

simple_connect() ->
    Self = self(),
    Ref = make_ref(),
    spawn_link(fun() -> ok = simple_connect_server(Self, Ref) end),
    ok = simple_connect_client(Ref),
    ok.

simple_connect_server(Client, Ref) ->
    Opts = [{mode,binary}],
    {ok, LSock} = gen_utp:listen(0, Opts),
    Client ! gen_utp:sockname(LSock),
    {ok, ARef} = gen_utp:async_accept(LSock),
    receive
        {utp_async, LSock, ARef, {ok, Sock}} ->
            ?assertMatch(true, is_port(Sock)),
            ?assertMatch(true, is_reference(Ref)),
            ?assertMatch(ok, gen_utp:close(Sock));
        {utp_async, LSock, ARef, Error} ->
            exit({utp_async, Error})
    after
        3000 -> exit(failure)
    end,
    ok = gen_utp:close(LSock),
    Client ! {done, Ref},
    ok.

simple_connect_client(Ref) ->
    receive
        {ok, {_, LPort}} ->
            Opts = [{mode,binary}],
            {ok, Sock} = gen_utp:connect({127,0,0,1}, LPort, Opts),
            ?assertMatch(true, erlang:is_port(Sock)),
            ?assertEqual({connected, self()}, erlang:port_info(Sock, connected)),
            ok = gen_utp:close(Sock),
            receive
                {done, Ref} -> ok
            after
                5000 -> exit(failure)
            end
    after
        5000 -> exit(failure)
    end,
    ok.

simple_send(Mode, ActiveMode) ->
    Self = self(),
    Ref = make_ref(),
    spawn_link(fun() ->
                       ok = simple_send_server(Self, Ref, Mode, ActiveMode)
               end),
    ok = simple_send_client(Ref, Mode, ActiveMode),
    ok.

simple_send_server(Client, Ref, Mode, ActiveMode) ->
    Opts = [{active,ActiveMode}, {mode,Mode}],
    {ok, LSock} = gen_utp:listen(0, Opts),
    Client ! gen_utp:sockname(LSock),
    {ok, Sock} = gen_utp:accept(LSock, 2000),
    SentVal = case ActiveMode of
                  false ->
                      {ok, RecvData} = gen_utp:recv(Sock, 0, 5000),
                      RecvData;
                  _ ->
                      receive
                          {utp, Sock, Val} ->
                              Val;
                          Error ->
                              exit(Error)
                      after
                          5000 -> exit(failure)
                      end
              end,
    case Mode of
        binary ->
            ?assertMatch(<<"simple send client">>, SentVal);
        list ->
            ?assertMatch("simple send client", SentVal)
    end,
    ok = gen_utp:send(Sock, <<"simple send server">>),
    ok = gen_utp:close(LSock),
    Client ! {done, Ref},
    ok.

simple_send_client(Ref, Mode, ActiveMode) ->
    receive
        {ok, {_, LPort}} ->
            Opts = [Mode,{active,ActiveMode}],
            {ok, Sock} = gen_utp:connect("127.0.0.1", LPort, Opts),
            ok = gen_utp:send(Sock, <<"simple send client">>),
            Reply = case ActiveMode of
                        false ->
                            {ok, RecvData} = gen_utp:recv(Sock, 0, 5000),
                            RecvData;
                        _ ->
                            receive
                                {utp, Sock, Val} ->
                                    Val
                            after
                                5000 -> exit(failure)
                            end
                    end,
            case Mode of
                binary ->
                    ?assertMatch(<<"simple send server">>, Reply);
                list ->
                    ?assertMatch("simple send server", Reply)
            end,
            receive
                {done, Ref} -> ok
            after
                5000 -> exit(failure)
            end,
            ok = gen_utp:close(Sock)
    after
        5000 -> exit(failure)
    end,
    ok.

two_clients() ->
    Self = self(),
    Ref = make_ref(),
    spawn_link(fun() -> ok = two_client_server(Self, Ref) end),
    ok = two_clients(Ref),
    ok.

two_client_server(Client, Ref) ->
    Opts = [{active,true}, {mode,binary}],
    {ok, LSock} = gen_utp:listen(0, Opts),
    Client ! gen_utp:sockname(LSock),
    {ok, Sock1} = gen_utp:accept(LSock, 2000),
    receive
        {utp, Sock1, <<"client1">>} ->
            ok = gen_utp:send(Sock1, <<"client1">>),
            {ok, Sock2} = gen_utp:accept(LSock, 2000),
            receive
                {utp, Sock2, <<"client2">>} ->
                    ok = gen_utp:send(Sock2, <<"client2">>),
                    ok = gen_utp:close(Sock2);
                Error ->
                    exit(Error)
            after
                5000 -> exit(failure)
            end,
            ok = gen_utp:close(Sock1);
        Error ->
            exit(Error)
    after
        5000 -> exit(failure)
    end,
    ok = gen_utp:close(LSock),
    Client ! {done, Ref},
    ok.

two_clients(Ref) ->
    receive
        {ok, {_, LPort}} ->
            Opts = [{active,true}, {mode,binary}],
            {ok, Sock1} = gen_utp:connect("127.0.0.1", LPort, Opts),
            ok = gen_utp:send(Sock1, <<"client1">>),
            {ok, Sock2} = gen_utp:connect("127.0.0.1", LPort, Opts),
            receive
                {utp, Sock1, <<"client1">>} ->
                    ok = gen_utp:send(Sock2, <<"client2">>),
                    receive
                        {utp, Sock2, <<"client2">>} ->
                            receive
                                {done, Ref} -> ok
                            after
                                5000 -> exit(failure)
                            end
                    after
                        5000 -> exit(failure)
                    end
            after
                5000 -> exit(failure)
            end,
            ok = gen_utp:close(Sock1),
            ok = gen_utp:close(Sock2)
    after
        5000 -> exit(failure)
    end,
    ok.

large_send() ->
    Self = self(),
    Ref = make_ref(),
    Bin = list_to_binary(lists:duplicate(1000000, $A)),
    spawn_link(fun() -> ok = large_send_server(Self, Ref, Bin) end),
    ok = large_send_client(Ref, Bin),
    ok.

large_send_server(Client, Ref, Bin) ->
    Opts = [{active,true}, {mode,binary}],
    {ok, LSock} = gen_utp:listen(0, Opts),
    Client ! gen_utp:sockname(LSock),
    {ok, Sock} = gen_utp:accept(LSock, 2000),
    Bin = large_receive(Sock, byte_size(Bin)),
    ok = gen_utp:send(Sock, <<"large send server">>),
    ok = gen_utp:close(Sock),
    ok = gen_utp:close(LSock),
    Client ! {done, Ref},
    ok.

large_receive(Sock, Size) ->
    large_receive(Sock, Size, 0, <<>>).
large_receive(_, Size, Size, Bin) ->
    Bin;
large_receive(Sock, Size, Count, Bin) ->
    receive
        {utp, Sock, Data} ->
            NBin = <<Bin/binary, Data/binary>>,
            large_receive(Sock, Size, Count+byte_size(Data), NBin);
        Error ->
            exit(Error)
    after
        5000 -> exit(failure)
    end.

large_send_client(Ref, Bin) ->
    receive
        {ok, {_, LPort}} ->
            Opts = [{active,true},{mode,binary}],
            {ok, Sock} = gen_utp:connect("127.0.0.1", LPort, Opts),
            ok = gen_utp:send(Sock, Bin),
            receive
                {utp, Sock, Reply} ->
                    ?assertMatch(Reply, <<"large send server">>),
                    receive
                        {done, Ref} -> ok
                    after
                        5000 -> exit(failure)
                    end
            after
                5000 -> exit(failure)
            end,
            ok = gen_utp:close(Sock)
    after
        5000 -> exit(failure)
    end,
    ok.

two_servers() ->
    Self = self(),
    Ref = make_ref(),
    spawn_link(fun() -> ok = two_servers(Self, Ref) end),
    ok = two_server_client(Ref),
    ok.

two_servers(Client, Ref) ->
    {ok, LSock} = gen_utp:listen(0, [{active,true}]),
    {ok, Sockname} = gen_utp:sockname(LSock),
    Client ! {Ref, Sockname},
    {ok, Ref1} = gen_utp:async_accept(LSock),
    Self = self(),
    Pid1 = spawn_link(fun() -> two_servers_do_server(Self) end),
    Pid2 = spawn_link(fun() -> two_servers_do_server(Self) end),
    receive
        {utp_async, LSock, Ref1, {ok, Sock1}} ->
            ok = gen_utp:controlling_process(Sock1, Pid1),
            Pid1 ! {go, Sock1};
        {utp_async, LSock, Ref1, Error1} ->
            exit({utp_async, Error1})
    after
        5000 -> exit(failure)
    end,
    {ok, Ref2} = gen_utp:async_accept(LSock),
    receive
        {utp_async, LSock, Ref2, {ok, Sock2}} ->
            ok = gen_utp:controlling_process(Sock2, Pid2),
            Pid2 ! {go, Sock2};
        {utp_async, LSock, Ref2, Error2} ->
            exit({utp_async, Error2})
    after
        5000 -> exit(failure)
    end,
    Client ! {Ref, send},
    receive
        {Pid1, ok} ->
            receive
                {Pid2, ok} ->
                    Pid1 ! check,
                    Pid2 ! check;
                Err2 ->
                    exit(Err2)
            after
                5000 -> exit(failure)
            end;
        Err1 ->
            exit(Err1)
    after
        5000 -> exit(failure)
    end,
    ?assertMatch({message_queue_len,0},
                 erlang:process_info(self(), message_queue_len)),
    ok = gen_utp:close(LSock).

two_servers_do_server(Pid) ->
    Sock = receive
               {go, S} ->
                   S
           after
               5000 -> exit(failure)
           end,
    receive
        {utp, Sock, Msg} ->
            ok = gen_utp:send(Sock, Msg),
            Pid ! {self(), ok};
        Error ->
            exit(Error)
    after
        5000 -> exit(failure)
    end,
    receive
        check ->
            ?assertMatch({message_queue_len,0},
                         erlang:process_info(self(), message_queue_len))
    after
        5000 -> exit(failure)
    end,
    ok = gen_utp:close(Sock).

two_server_client(Ref) ->
    receive
        {Ref, {_, LPort}} ->
            Opts = [{active,true},{mode,binary}],
            {ok, Sock1} = gen_utp:connect("127.0.0.1", LPort, Opts),
            Msg1 = list_to_binary(["two servers", term_to_binary(Ref)]),
            {ok, Sock2} = gen_utp:connect("127.0.0.1", LPort, Opts),
            Msg2 = list_to_binary(lists:reverse(binary_to_list(Msg1))),
            receive
                {Ref, send} ->
                    ok = gen_utp:send(Sock1, Msg1),
                    ok = gen_utp:send(Sock2, Msg2),
                    ok = two_server_client_receive(Sock1, Msg1),
                    ok = two_server_client_receive(Sock2, Msg2)
            after
                5000 -> exit(failure)
            end
    after
        5000 -> exit(failure)
    end,
    ok.

two_server_client_receive(Sock, Msg) ->
    receive
        {utp, Sock, Msg} ->
            ok
    after
        5000 -> exit(failure)
    end,
    ok = gen_utp:close(Sock).

send_timeout() ->
    {ok, LSock} = gen_utp:listen(0),
    {ok, {_, Port}} = gen_utp:sockname(LSock),
    {ok, Ref} = gen_utp:async_accept(LSock),
    Pid = spawn(fun() ->
                        {ok,_} = gen_utp:connect("localhost", Port),
                        receive
                            exit ->
                                ok
                        end
                end),
    receive
        {utp_async, LSock, Ref, {ok, S}} ->
            Pid ! exit,
            ok = gen_utp:send(S, lists:duplicate(1000, $X)),
            ?assertMatch(ok, gen_utp:setopts(S, [{send_timeout, 1}])),
            ?assertMatch({error,etimedout},
                         gen_utp:send(S, lists:duplicate(1000, $Y))),
            ok = gen_utp:close(S);
        {utp_async, LSock, Ref, Error} ->
            exit({utp_async, Error})
    after
        2000 ->
            exit(failure)
    end,
    ok = gen_utp:close(LSock).

invalid_accept() ->
    {ok, LSock} = gen_utp:listen(0),
    {ok, {_, Port}} = gen_utp:sockname(LSock),
    {ok, Ref} = gen_utp:async_accept(LSock),
    spawn(fun() ->
                  {ok,_} = gen_utp:connect("localhost", Port),
                  receive
                      exit ->
                          ok
                  end
          end),
    receive
        {utp_async, LSock, Ref, {ok, S}} ->
            ?assertMatch({error,einval}, gen_utp:accept(S)),
            ok = gen_utp:close(S);
        {utp_async, LSock, Ref, Error} ->
            exit({utp_async, Error})
    after
        2000 ->
            exit(failure)
    end,
    ok = gen_utp:close(LSock).

packet_size() ->
    {ok, LSock} = gen_utp:listen(0, [binary,{active,false}]),
    {ok, {_, Port}} = gen_utp:sockname(LSock),
    Data = <<"1234567890">>,
    lists:foreach(fun(Pkt) ->
                          spawn(fun() ->
                                        {ok,S} = gen_utp:connect("localhost",
                                                                 Port,
                                                                 [{packet,Pkt}]),
                                        ok = gen_utp:send(S, Data),
                                        gen_utp:close(S)
                                end),
                          {ok, Ref} = gen_utp:async_accept(LSock),
                          receive
                              {utp_async, LSock, Ref, {ok, S}} ->
                                  ok = gen_utp:setopts(S, [{packet,Pkt}]),
                                  ?assertMatch({ok,Data}, gen_utp:recv(S, 0, 2000)),
                                  ok = gen_utp:close(S);
                              {utp_async, LSock, Ref, Error} ->
                                  exit({utp_async, Error})
                          after
                              2000 ->
                                  exit(failure)
                          end
                  end, [raw, 0, 1, 2, 4]),
    ok = gen_utp:close(LSock),
    ok.

header_size() ->
    {ok, LSock} = gen_utp:listen(0, [binary, {header,5}, {active,false}]),
    {ok, {_, Port}} = gen_utp:sockname(LSock),
    Data = [ $B,$a,$s,$h,$o | <<"1234567890">> ],
    {ok, Ref} = gen_utp:async_accept(LSock),
    spawn(fun() ->
                  {ok,S} = gen_utp:connect("localhost", Port, [binary, {header,5}]),
                  ok = gen_utp:send(S, Data),
                  gen_utp:close(S)
          end),
    receive
        {utp_async, LSock, Ref, {ok, S}} ->
            ?assertMatch({ok,Data}, gen_utp:recv(S, 0, 2000)),
            ok = gen_utp:close(S);
        {utp_async, LSock, Ref, Error} ->
            exit({utp_async, Error})
    after
        2000 ->
            exit(failure)
    end,
    ok = gen_utp:close(LSock),
    ok.

buf_size() ->
    {ok, LSock} = gen_utp:listen(0, [{sndbuf,4096},{recbuf,8192},{active,false}]),
    {ok, {_, Port}} = gen_utp:sockname(LSock),
    {ok, Ref} = gen_utp:async_accept(LSock),
    {ok,S} = gen_utp:connect("localhost", Port, [{active,false}]),
    {ok, [{sndbuf,Sndbuf}]} = gen_utp:getopts(S, [sndbuf]),
    {ok, [{recbuf,Recbuf}]} = gen_utp:getopts(S, [recbuf]),
    NSndbuf = Sndbuf*8,
    NRecbuf = Recbuf*16,
    ok = gen_utp:setopts(S, [{sndbuf,NSndbuf},{recbuf,NRecbuf}]),
    {ok, [{sndbuf,NSndbuf}]} = gen_utp:getopts(S, [sndbuf]),
    {ok, [{recbuf,NRecbuf}]} = gen_utp:getopts(S, [recbuf]),
    receive
        {utp_async, LSock, Ref, {ok, AS}} ->
            ?assertMatch({ok,[{sndbuf,4096}]}, gen_utp:getopts(AS, [sndbuf])),
            ?assertMatch({ok,[{recbuf,8192}]}, gen_utp:getopts(AS, [recbuf])),
            ok = gen_utp:close(AS);
        {utp_async, LSock, Ref, Error} ->
            exit({utp_async, Error})
    after
        2000 ->
            exit(failure)
    end,
    ok = gen_utp:close(S),
    ok = gen_utp:close(LSock),
    ok.
