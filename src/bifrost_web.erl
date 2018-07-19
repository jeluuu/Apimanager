%%%-------------------------------------------------------------------
%%% @author danny
%%% @copyright (C) 2018, danny
%%% @doc
%%%
%%% @end
%%% Created : 2018-07-17 09:45:03.637624
%%%-------------------------------------------------------------------
-module(bifrost_web).

-behaviour(gen_server).

%% API
-export([start_link/0]).

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

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
  IndexFileSpec = case application:get_env(index_file_path) of
                    undefined ->
                      {priv_file, bifrost, "index.html"};
                    {ok, IndexFilePath} ->
                      {file, IndexFilePath}
                  end,
  StaticDirSpec = case application:get_env(static_dir_path) of
                    undefined ->
                      {priv_dir, bifrost, ""};
                    {ok, StaticDirPath} ->
                      {file, StaticDirPath}
                  end,
  Dispatch = cowboy_router:compile([
                                    {'_', [
                                           {"/", cowboy_static, IndexFileSpec},
                                           {"/api", bifrost_api, []},
                                           {"/sock", bifrost_sock, []},
                                           {"/[...]", cowboy_static, StaticDirSpec}
                                          ]}
                                   ]),
  PortSpec = case application:get_env(port) of
               undefined -> [];
               {ok, Port} -> [{port, Port}]
             end,
  {ok, _} = cowboy:start_clear(bifrost, PortSpec,
                               #{env => #{dispatch => Dispatch}}),
  PortFromRanch = ranch:get_port(bifrost),
  lager:info("Bifrost opened on port : ~p", [{PortFromRanch}]),
  {ok, #{}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
  Reply = ok,
  {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
  {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
  {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
  ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================




