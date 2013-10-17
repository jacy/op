%%%% Copyright (C) 2005-2008 Wager Labs, SA
%%%%
%%%% THE WORK (AS DEFINED BELOW) IS PROVIDED UNDER THE TERMS OF THIS 
%%%% CREATIVE COMMONS PUBLIC LICENSE ("CCPL" OR "LICENSE"). THE WORK IS 
%%%% PROTECTED BY COPYRIGHT AND/OR OTHER APPLICABLE LAW. ANY USE OF 
%%%% THE WORK OTHER THAN AS AUTHORIZED UNDER THIS LICENSE OR COPYRIGHT 
%%%% LAW IS PROHIBITED.
%%%%
%%%% BY EXERCISING ANY RIGHTS TO THE WORK PROVIDED HERE, YOU ACCEPT 
%%%% AND AGREE TO BE BOUND BY THE TERMS OF THIS LICENSE. TO THE EXTENT 
%%%% THIS LICENSE MAY BE CONSIDERED TO BE A CONTRACT, THE LICENSOR GRANTS 
%%%% YOU THE RIGHTS CONTAINED HERE IN CONSIDERATION OF YOUR ACCEPTANCE 
%%%% OF SUCH TERMS AND CONDITIONS.
%%%%
%%%% Please see LICENSE for full legal details and the following URL
%%%% for a human-readable explanation:
%%%%
%%%% http://creativecommons.org/licenses/by-nc-sa/3.0/us/
%%%%

-module(server).
-behaviour(gen_server).

%%% 
%%% OpenPoker server instance
%%%

-export([init/1, handle_call/3, handle_cast/2, 
         handle_info/2, terminate/2, code_change/3]).

-export([start/1, start/2, start/3, stop/1, test/0]).

-include("common.hrl").
-include("pp.hrl").
-include("texas.hrl").
-include("schema.hrl").
-include("test.hrl").

-record(server, {
          port,
          host,
          test_mode
         }).

-record(client, {
          server = none,  % server process id.
          player = none   % vistor or player.
         }).

start([Port, Host]) 
  when is_atom(Port),
       is_atom(Host) ->
    Port1 = list_to_integer(atom_to_list(Port)),
    Host1 = atom_to_list(Host),
    start(Host1, Port1).

start(Host, Port) ->
    start(Host, Port, false).

start(Host, Port, TestMode) ->
    db:start(),
    case db:wait_for_tables([tab_game_config, tab_game_xref], 10000) of 
        ok ->
            case gen_server:start(server, [Host, Port, TestMode], []) of
                {ok, Pid} ->
                    %%io:format("server:start: pid ~w~n", [Pid]),
                    pg2:create(?GAME_SERVERS),
                    ok = pg2:join(?GAME_SERVERS, Pid),
                    {ok, Pid};
                Result ->
                    error_logger:error_report(
                      [{module, ?MODULE},
                       {line, ?LINE},
                       {message, "Unexpected result"},
                       {call, 'gen_server:start(server)'}, 
                       {result, Result},
                       {port, Port},
                       {now, now()}]),
                    Result
            end;
        Other ->
            error_logger:error_report(
              [{module, ?MODULE},
               {line, ?LINE},
               {message, "Unexpected result"},
               {result, Other},
               {call, 'db:wait_for_tables'}, 
               {now, now()}]),
            Other
    end.

init([Host, Port, TestMode]) ->
    process_flag(trap_exit, true), 
    %%error_logger:logfile({open, "/tmp/" 
    %%      ++ atom_to_list(node()) 
    %%      ++ ".log"}),
    Client = #client{ server = self() },
    if
        not TestMode ->
            start_games();
        true ->
            ok
    end,
    F = fun(Sock) -> parse_packet(Sock, Client) end, 
    tcp_server:stop(Port),
    {ok, _} = tcp_server:start_raw_server(Port, F, 32768, 32768),
    Server = #server{
      host = Host,
      port = Port,
      test_mode = TestMode
     },
    {ok, Server}.

stop(Server) ->
    gen_server:cast(Server, stop).

terminate(normal, Server) ->
    kill_games(),
    tcp_server:stop(Server#server.port),
    ok.

handle_cast({'BUMP', _Size}, Server) ->
    %%stats:sum(packets_in, 1),
    %%stats:sum(bytes_in, Size),
    {noreply, Server};

handle_cast({'PONG', R = #pong{}}, Server) ->
    TC = timer:now_diff(R#pong.send_time, R#pong.orig_send_time),
    TS = timer:now_diff(R#pong.recv_time, R#pong.send_time),
    stats:avg(time_to_client, TC),
    stats:avg(time_to_server, TS),
    stats:max(max_time_to_client, TC),
    stats:max(max_time_to_server, TS),
    {noreply, Server};

handle_cast(stop, Server) ->
    {stop, normal, Server};

handle_cast(Event, Server) ->
    error_logger:info_report([{module, ?MODULE}, 
                              {line, ?LINE},
                              {self, self()}, 
                              {message, Event}]),
    {noreply, Server}.


handle_call('WHERE', _From, Server) ->
    {reply, {Server#server.host, Server#server.port}, Server};
%%     {ok, [{X, _, _}|_]} = inet:getif(),
%%     io:format("Server address: ~w~n", [X]),
%%     Host = io_lib:format("~.B.~.B.~.B.~.B", 
%%       [element(1, X),
%%        element(2, X),
%%        element(3, X),
%%        element(4, X)]),
%%     {reply, {Host, Server#server.port}, Server};

handle_call('USER COUNT', _From, Server) ->
    Children = tcp_server:children(Server#server.port),
    {reply, length(Children), Server};

handle_call('TEST MODE', _From, Server) ->
    {reply, Server#server.test_mode, Server};

handle_call(Event, From, Server) ->
    error_logger:info_report([{module, ?MODULE}, 
                              {line, ?LINE},
                              {self, self()}, 
                              {message, Event}, 
                              {from, From}]),
    {noreply, Server}.

handle_info({'EXIT', _Pid, _Reason}, Server) ->
    %% child exit?
    {noreply, Server};

handle_info(Info, Server) ->
    error_logger:info_report([{module, ?MODULE}, 
                              {line, ?LINE},
                              {self, self()}, 
                              {message, Info}]),
    {noreply, Server}.

code_change(_OldVsn, Server, _Extra) ->
    {ok, Server}.

process_login(Client, Socket, Nick, Pass) ->
    case login:login(Nick, Pass, self()) of
        {error, Error} ->
			io:format("========Login Failed: ~w~n", [Error]),
            ok = ?tcpsend(Socket, #bad{ cmd = ?CMD_LOGIN, error = Error}),
            Client;
        {ok, Player} ->
            %% disconnect visitor
			io:format("========Login Success======player:~w~n", [Player]),
            if
                Client#client.player /= none ->
                    gen_server:cast(Client#client.player, 'DISCONNECT');
                true ->
                    ok
            end,
            PID = gen_server:call(Player, 'ID'),
			io:format("========Send back to client with PId: ~w~n", [PID]),
            ok = ?tcpsend(Socket, #you_are{ player = PID }),
            Client#client{ player = Player }
    end.

process_logout(Client, _Socket) ->
    gen_server:cast(Client#client.player, #logout{}),
    %% replace player process with a visitor
    {ok, Visitor} = visitor:start(self()),
    Client#client{ player = Visitor }.

process_ping(Client, Socket, R) ->
    ok = ?tcpsend(Socket, #pong{ orig_send_time = R#ping.send_time }),
    Client.

process_pong(Client, _Socket, R) ->
    R1 = R#pong{ recv_time = now() },
    gen_server:cast(Client#client.server, {'PONG', R1}),
    Client.

process_test_start_game(Client, Socket, R) ->
    case gen_server:call(Client#client.server, 'TEST MODE') of
        true ->
            ok = ?tcpsend(Socket, start_test_game(R));
        _ ->
            ok
    end,
    Client.

process_game_query(Client, Socket, Q) 
  when is_record(Q, game_query) ->
    find_games(Socket, 
               Q#game_query.game_type, 
               Q#game_query.limit_type,
               Q#game_query.expected,
               Q#game_query.joined,
               Q#game_query.waiting),
    Client.

process_event(Client, _Socket, Event) ->
    if 
        Client#client.player == none ->
            %% start a proxy
            {ok, Visitor} = visitor:start(self()),
            Client1 = Client#client{ player = Visitor };
        true ->
            Client1 = Client
    end,
    gen_server:cast(Client1#client.player, Event),
    Client1.

parse_packet(Socket, Client) ->
    receive
        {tcp, Socket, Bin} ->
            io:format("**********Receive package:~p~n", [Bin]),
            gen_server:cast(Client#client.server, {'BUMP', size(Bin)}),
            Client1 = case catch pp:read(Bin) of
                          {'EXIT', Error} ->
                              error_logger:error_report(
                                [{module, ?MODULE},
                                 {line, ?LINE},
                                 {message, "Could not parse command"},
                                 {Bin, Bin},
                                 {error, Error},
                                 {now, now()}]),
                              Client;
                          #login{ nick = Nick, pass = Pass} ->
                              process_login(Client, Socket, Nick, Pass);
                          #logout{} ->
                              process_logout(Client, Socket);
                          R = #ping{} ->
                              process_ping(Client, Socket, R);
                          R = #pong{} ->
                              process_pong(Client, Socket, R);
                          R = #start_game{ rigged_deck = [_|_] } ->
                              process_test_start_game(Client, Socket, R);
                          R when is_record(R, game_query) ->
                              process_game_query(Client, Socket, R);
                          Event ->
                              process_event(Client, Socket, Event)
                      end,
            parse_packet(Socket, Client1);
        {tcp_closed, Socket} ->
            gen_server:cast(Client#client.player, 'DISCONNECT');
        {packet, Packet} ->
            ok = ?tcpsend(Socket, Packet),
            parse_packet(Socket, Client)
    end.

%%%
%%% Handlers
%%%

%%%
%%% Utility
%%%

send_games(_, []) ->
    ok;

send_games(Socket, [H|T]) ->
    ?tcpsend(Socket, H),
    send_games(Socket, T).

find_games(Socket, 
           GameType, LimitType,
           #query_op{ op = ExpOp, val = Expected }, 
           #query_op{ op = JoinOp, val = Joined },
           #query_op{ op = WaitOp, val = Waiting }) ->
    {atomic, L} = g:find(GameType, LimitType,
                         ExpOp, Expected, 
                         JoinOp, Joined,
                         WaitOp, Waiting),
    send_games(Socket, L).

start_games() ->
    {atomic, Games} = db:find(tab_game_config),
    start_games(Games).

start_games([]) ->
    ok;

start_games([Game|Rest]) ->
    start_game(Game, Game#tab_game_config.max),
    start_games(Rest).

start_game(_Game, 0) ->
    ok;

start_game(Game, N) ->
    g:make(_ = #start_game{ 
             type = Game#tab_game_config.type, 
             limit = Game#tab_game_config.limit, 
             start_delay = Game#tab_game_config.start_delay,
             player_timeout = Game#tab_game_config.player_timeout,
             seat_count = Game#tab_game_config.seat_count
            }),
    start_game(Game, N - 1).

kill_games() ->
    {atomic, Games} = db:find(tab_game_xref),
    kill_games(Games).

kill_games([]) ->
    ok;

kill_games([H|T]) ->
    gen_server:cast(H#tab_game_xref.process, stop),
    kill_games(T).

start_test_game(R) ->
    {ok, Game} = game:start(R),
    GID = game:call(Game, 'ID'),
    #your_game{ game = GID }.

%%
%% Test suite
%%

test() ->
    ok.
