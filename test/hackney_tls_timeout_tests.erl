-module(hackney_tls_timeout_tests).
-include_lib("eunit/include/eunit.hrl").

%% The peer accepts TCP and reads ClientHello, but never answers it. Keep the
%% caller alive after connect returns, so caller death cannot hide a socket leak.
handshake_timeout_test_() ->
  [{atom_to_list(Transport), {timeout, 10, fun() ->
      with_peer(Transport, fun(Port, Peer) ->
        with_client(fun() -> transport_connect(Transport, Port, 300) end,
          fun(Client) ->
            await_hello(Peer),
            ?assertEqual({error, timeout}, client_result(Client)),
            await_closed(Peer),
            ?assert(is_process_alive(Client))
          end)
      end)
    end}} || Transport <- [direct, http_proxy, socks5]].

handshake_error_closes_socket_test() ->
  with_peer(invalid_tls, fun(Port, Peer) ->
    with_client(fun() -> transport_connect(direct, Port, 1000) end,
      fun(Client) ->
        await_hello(Peer),
        ?assertMatch({error, _}, client_result(Client)),
        await_closed(Peer),
        ?assert(is_process_alive(Client))
      end)
  end).

pool_slot_released_test_() ->
  [{atom_to_list(Mode), {timeout, 10, fun() -> pool_slot_released(Mode) end}}
   || Mode <- [direct, invalid_tls]].

pool_slot_released(Mode) ->
  {ok, _} = application:ensure_all_started(hackney),
  Pool = tls_timeout_test_pool,
  ok = hackney_pool:start_pool(Pool, [{max_connections, 1}]),
  try
    with_peer(Mode, fun(Port, Peer) ->
      URL = "https://127.0.0.1:" ++ integer_to_list(Port) ++ "/",
      Opts = [{pool, Pool}, {connect_timeout, 300}, {recv_timeout, 100},
              {ssl_options, ssl_options()}, {with_body, true}],
      with_client(fun() -> hackney:get(URL, [], <<>>, Opts) end,
        fun(Client) ->
          await_hello(Peer),
          Result = client_result(Client),
          case Mode of
            direct -> ?assertEqual({error, connect_timeout}, Result);
            invalid_tls -> ?assertMatch({error, _}, Result)
          end,
          await_closed(Peer),
          await_empty_pool(Pool, 200),
          ?assert(is_process_alive(Client)),
          %% The failed request's caller is still alive. Nevertheless a new
          %% request can use the only slot, without increasing the pool size.
          with_peer(http, fun(HttpPort, _) ->
            HttpURL = "http://127.0.0.1:" ++ integer_to_list(HttpPort) ++ "/",
            ?assertMatch({ok, 200, _, <<"OK">>},
              hackney:get(HttpURL, [], <<>>,
                [{pool, Pool}, {checkout_timeout, 500}, {with_body, true}]))
          end)
        end)
    end)
  after
    hackney_pool:stop_pool(Pool)
  end.

%% Check that finite timeouts and explicit infinity still allow normal TLS.
successful_tls_test_() ->
  {timeout, 15, fun() ->
    {ok, _} = application:ensure_all_started(ssl),
    Config = public_key:pkix_test_data(#{
      root => [{key, {rsa, 2048, 65537}}],
      peer => [{key, {rsa, 2048, 65537}}]}),
    lists:foreach(fun(Timeout) -> successful_tls(Config, Timeout) end,
                  [2000, infinity])
  end}.

successful_tls(Config, Timeout) ->
  {ok, Listen} = ssl:listen(0, [binary, {active, false},
                               {ip, {127, 0, 0, 1}} | Config]),
  {ok, {_, Port}} = ssl:sockname(Listen),
  {Peer, Monitor} = spawn_monitor(fun() ->
    {ok, Socket} = ssl:transport_accept(Listen, 3000),
    {ok, Secure} = ssl:handshake(Socket, 3000),
    ok = ssl:send(Secure, <<"OK">>),
    ssl:close(Secure)
  end),
  try
    {ok, Socket} = transport_connect(direct, Port, Timeout),
    try
      ?assertEqual({ok, <<"OK">>}, ssl:recv(Socket, 2, 2000))
    after ssl:close(Socket) end,
    receive {'DOWN', Monitor, process, Peer, Reason} -> ?assertEqual(normal, Reason)
    after 3000 -> error(tls_peer_not_finished) end
  after
    ssl:close(Listen),
    stop_process(Peer),
    erlang:demonitor(Monitor, [flush])
  end.

transport_connect(direct, Port, Timeout) ->
  hackney_ssl:connect("127.0.0.1", Port,
                      [{ssl_options, ssl_options()}], Timeout);
transport_connect(http_proxy, Port, Timeout) ->
  hackney_http_connect:connect("127.0.0.1", Port,
    [{connect_host, "localhost"}, {connect_port, 443},
     {connect_transport, hackney_ssl}, {ssl_options, ssl_options()}], Timeout);
transport_connect(socks5, Port, Timeout) ->
  hackney_socks5:connect("127.0.0.1", 443,
    [{socks5_host, "127.0.0.1"}, {socks5_port, Port},
     {socks5_transport, hackney_ssl}, {ssl_options, ssl_options()}], Timeout).

ssl_options() -> [{verify, verify_none}, {server_name_indication, disable}].

with_client(Connect, Test) ->
  {ok, _} = application:ensure_all_started(ssl),
  Parent = self(),
  {Client, Monitor} = spawn_monitor(fun() ->
    Result = Connect(),
    Parent ! {self(), result, Result},
    receive stop -> ok end
  end),
  try Test(Client)
  after
    stop_process(Client),
    erlang:demonitor(Monitor, [flush])
  end.

with_peer(Mode, Test) ->
  {ok, Listen} = gen_tcp:listen(0, [binary, {active, false},
                                  {ip, {127, 0, 0, 1}}]),
  {ok, {_, Port}} = inet:sockname(Listen),
  Parent = self(),
  {Peer, Monitor} = spawn_monitor(fun() ->
    {ok, Socket} = gen_tcp:accept(Listen, 3000),
    try serve_peer(Mode, Socket, Parent)
    after gen_tcp:close(Socket) end
  end),
  try Test(Port, Peer)
  after
    gen_tcp:close(Listen),
    stop_process(Peer),
    erlang:demonitor(Monitor, [flush])
  end.

serve_peer(http, Socket, _Parent) ->
  read_http_headers(Socket, <<>>),
  gen_tcp:send(Socket,
    <<"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK">>);
serve_peer(Mode, Socket, Parent) ->
  proxy_handshake(Mode, Socket),
  {ok, <<22, 3, _:3/binary>>} = gen_tcp:recv(Socket, 5, 3000),
  Parent ! {self(), hello},
  case Mode of
    invalid_tls -> gen_tcp:send(Socket, <<"HTTP/1.1 400 Bad Request\r\n\r\n">>);
    _ -> ok
  end,
  %% Never close from the server side until the client has done so.
  {error, closed} = drain_until_closed(Socket),
  Parent ! {self(), closed}.

proxy_handshake(http_proxy, Socket) ->
  read_http_headers(Socket, <<>>),
  ok = gen_tcp:send(Socket, <<"HTTP/1.1 200 Connection Established\r\n\r\n">>);
proxy_handshake(socks5, Socket) ->
  {ok, <<5, 1, 0>>} = gen_tcp:recv(Socket, 3, 3000),
  ok = gen_tcp:send(Socket, <<5, 0>>),
  {ok, <<5, 1, 0, 1, 127, 0, 0, 1, 1, 187>>} = gen_tcp:recv(Socket, 10, 3000),
  ok = gen_tcp:send(Socket, <<5, 0, 0, 1, 127, 0, 0, 1, 1, 187>>);
proxy_handshake(_, _) -> ok.

read_http_headers(Socket, Buffer) ->
  case binary:match(Buffer, <<"\r\n\r\n">>) of
    nomatch ->
      {ok, Data} = gen_tcp:recv(Socket, 0, 3000),
      read_http_headers(Socket, <<Buffer/binary, Data/binary>>);
    _ -> ok
  end.

drain_until_closed(Socket) ->
  case gen_tcp:recv(Socket, 0, infinity) of
    {ok, _} -> drain_until_closed(Socket);
    Error -> Error
  end.

await_hello(Peer) ->
  receive {Peer, hello} -> ok
  after 3000 -> error(client_did_not_start_tls) end.

await_closed(Peer) ->
  receive {Peer, closed} -> ok
  after 3000 -> error(client_did_not_close_socket) end.

client_result(Client) ->
  receive {Client, result, Result} -> Result
  after 3000 -> error(tls_handshake_did_not_finish) end.

await_empty_pool(Pool, Attempts) ->
  Stats = hackney_pool:get_stats(Pool),
  case proplists:get_value(in_use_count, Stats) of
    0 -> ?assertEqual(0, proplists:get_value(queue_count, Stats));
    _ when Attempts > 0 ->
      receive after 5 -> await_empty_pool(Pool, Attempts - 1) end;
    _ -> error({pool_slot_not_released, Stats})
  end.

stop_process(Pid) ->
  Monitor = erlang:monitor(process, Pid),
  exit(Pid, kill),
  receive {'DOWN', Monitor, process, Pid, _} -> ok end.
