%%%-------------------------------------------------------------------
%%% @author Chaitanya Chalasani
%%% @copyright (C) 2020, ArkNode.IO
%%% @doc
%%%
%%% @end
%%% Created : 2020-08-09 07:22:19.204136
%%%-------------------------------------------------------------------
-module(bifrost_sock_client).

-behaviour(gen_server).

-callback init(Args :: list()) ->
  {'ok', State :: map()} | {'stop', Reason :: term()}.
-callback handle_info(Info :: term(), CState :: map()) ->
  {'ok', State :: map()} | {'stop', Reason :: term(), State :: map()}.
-callback terminate(Reason :: term(), CState :: map()) -> 'ok'.

-optional_callbacks([terminate/2]).

%% API
-export([start_link/4
        ,start_link/3
        ,send/2]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

%%%===================================================================
%%% API
%%%===================================================================

start_link(Registration, Callback, Arguments, Options) ->
  gen_server:start_link(Registration, ?MODULE, [Callback|Arguments], Options).

start_link(Callback, Arguments, Options) ->
  gen_server:start_link(?MODULE, [Callback|Arguments], Options).

send(Client, Message) ->
  MessageJson = jiffy:encode(Message),
  gen_server:call(Client, {send, MessageJson}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Callback|Arguments]) ->
  process_flag(trap_exit, true),
  case Callback:init(Arguments) of
    {ok, #{host := Host, port := Port, state := CState} = State} ->
      Resource = maps:get(resource, State, "/"),
      Headers = maps:get(headers, State, []),
      {ok, #{status => init
            ,callback => Callback
            ,host => Host
            ,port => Port
            ,resource => Resource
            ,headers => Headers
            ,cstate => CState}, 0};
    {stop, Reason} ->
      {stop, Reason}
  end.

handle_call(_Request, _From, State) ->
  Reply = ok,
  {reply, Reply, State}.

handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info(timeout, #{host := Host
                      ,port := Port
                      ,resource := Resource
                      ,headers := Headers} = State) ->
  case gun:open(Host, Port) of
    {ok, ConnPid} ->
      case gun:await_up(ConnPid) of
        {ok, _Protocol} ->
          gun:ws_upgrade(ConnPid, Resource, Headers),
          {noreply, State#{conn_pid => ConnPid, status => init_upgrade}};
        Error ->
          gun:close(ConnPid),
          Error
      end;
    Error ->
      Error
  end;
handle_info({gun_upgrade, ConnPid, StreamRef, Protocols, Headers}
           ,#{conn_pid := ConnPid} = State) ->
  erlang:send_after(5000, self(), ping),
  lager:info("Upgraded to websocket ~p", [{ConnPid, StreamRef, Protocols, Headers}]),
  {noreply, State#{status => connected}};
handle_info(ping, #{conn_pid := ConnPid, status := connected} = State) ->
  erlang:send_after(5000, self(), ping),
  gun:ws_send(ConnPid, {text, ""}),
  {noreply, State};
handle_info({gun_response, ConnPid, _A, _B, Status, Headers}, #{conn_pid := ConnPid} = State) ->
  gun:close(ConnPid),
  {stop, {upgrade_failed, Status, Headers}, State};
handle_info({gun_error, ConnPid, StreamRef, Reason}, #{conn_pid := ConnPid} = State) ->
  gen:close(ConnPid),
  {stop, {upgrade_failed, StreamRef, Reason}, State};
handle_info({gun_ws, ConnPid, _StreamnRef, {text, <<>>}}, #{conn_pid := ConnPid} = State) ->
  {noreply, State};
handle_info({gun_ws, ConnPid, _StreamnRef, {text, Message}}
            ,#{conn_pid := ConnPid, callback := Callback, cstate := CState} = State) ->
  Info = maps:fold(
           fun(K, V, M) ->
               M#{binary_to_atom(K, latin1) => V}
           end,
           #{},
           jiffy:decode(Message, [return_maps])
          ),
  lager:info("Response is ~p", [Info]),
  case Callback:handle_info(Info, CState) of
    {ok, CStateU} ->
      {noreply, State#{cstate => CStateU}};
    {stop, Reason, CStateU} ->
      {stop, Reason, State#{cstate => CStateU}}
  end;
handle_info({gun_down, ConnPid, Protocol, Reason, KilledStreams}
           ,#{conn_pid := ConnPid} = State) ->
  lager:info("Client connection is down ~p", [{ConnPid, Protocol, Reason, KilledStreams}]),
  gun:close(ConnPid),
  {stop, sock_closed, State};
handle_info(Info, State) ->
  lager:debug("Unknown message ~p when ~p", [Info, State]),
  {noreply, State}.

terminate(Reason, #{cstate := CState, callback := Callback} = State) ->
  lager:info("Bifrost sock client behaviour terminated with ~p while in ~p", [Reason, State]),
  case erlang:function_exported(Callback, terminate, 2) of
    true -> Callback:terminate(Reason, CState);
    false -> ok
  end.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

