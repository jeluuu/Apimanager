%%%-------------------------------------------------------------------
%%% @author Chaitanya Chalasani
%%% @copyright (C) 2020, ArkNode.IO
%%% @doc
%%%
%%% @end
%%% Created : 2020-01-21 13:22:17.378474
%%%-------------------------------------------------------------------
-module(bifrost_api).

-behaviour(gen_server).

-callback init(Args :: list()) ->
  {'ok', Routes :: list()} | {'ok', Route :: map()} | {'stop', Reason :: term()}.
-callback handle_api(Headers :: map()
                    ,ReqParams :: map()
                    ,PathInfo :: 'undefined' | binary()
                    ,State :: map()) ->
  'ok' | {'ok', Reply :: map()} | 'error' | {'error', Reason :: map() | atom() }.
-callback handle_info(Info :: term()) -> 'ok'.

-optional_callbacks([handle_api/4
                    ,handle_info/1]).

%% API
-export([start_link/4
        ,start_link/3
        ,initialize/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

%% cowboy callbacks
-export([init/2]).

%%%===================================================================
%%% API
%%%===================================================================

start_link(Registration, Callback, Arguments, Options) ->
  gen_server:start_link(Registration, ?MODULE, [Callback|Arguments], Options).

start_link(Callback, Arguments, Options) ->
  gen_server:start_link(?MODULE, [Callback|Arguments], Options).

initialize(Server) ->
  gen_server:cast(Server, initialize).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

% Init for gen_server behaviour
init([Callback|Arguments]) ->
  process_flag(trap_exit, true),
  case Callback:init(Arguments) of
    {ok, Routes} when is_list(Routes) ->
      [ publish_route(Route) || Route <- Routes ],
      {ok, #{callback => Callback, init_arguments => Arguments, routes => Routes}};
    {ok, Route} ->
      publish_route(Route),
      {ok, #{callback => Callback, init_arguments => Arguments, routes => [Route]}};
    Other ->
      Other
  end.

% Init for cowboy behaviour
init(Req, State) ->
  ReqFinalState = handle_api(Req, State),
  {ok, ReqFinalState, State}.

handle_call(_Request, _From, State) ->
  Reply = ok,
  {reply, Reply, State}.

handle_cast(initialize, #{callback := Callback
                          ,init_arguments := Arguments
                          ,routes := Routes} = State) ->
  [ unpublish_route(Route) || Route <- Routes ],
  case init([Callback|Arguments]) of
    {ok, NewState} ->
      {noreply, NewState};
    {stop, Reason} ->
      {stop, Reason, State}
  end;
handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info(Info, #{callback := Callback} = State) ->
  case erlang:function_exported(Callback, handle_info, 1) of
    true -> Callback:handle_info(Info);
    false -> ok
  end,
  {noreply, State}.

terminate(_Reason, #{routes := Routes}) ->
  [ unpublish_route(Route) || Route <- Routes ],
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

publish_route(#{path := Path, functions := Functions} = Route) ->
  Init = maps:get(init, Route, []),
  AuthFlag = maps:get(auth, Route, application:get_env(bifrost, auth_default, true)),
  AuthFun = maps:get(auth_fun, Route, application:get_env(auth_fun)),
  bifrost_web:add_route(Path, ?MODULE, #{functions => Functions
                                        ,auth => AuthFlag
                                        ,auth_fun => AuthFun
                                        ,state => Init}).

unpublish_route(#{path := Path}) ->
  bifrost_web:remove_route(Path).

handle_api(#{method := Method, path_info := PathInfo} = Req, State) ->
  case is_authenticated(Req, State) of
    {ok, HeadersU} ->
      Bindings = cowboy_req:bindings(Req),
      QueryStringMap = try_atomify_keys( maps:from_list( cowboy_req:parse_qs(Req) )),
      QueryWithBindings = maps:merge(QueryStringMap, Bindings),
      {ReqParams, Req1} = case maps:get(has_body, Req) of
                            false ->
                              { QueryWithBindings, Req };
                            true ->
                              {ok, HttpBodyJson, ReqU} = cowboy_req:read_body(Req),
                              case catch json_decode(HttpBodyJson) of
                                {'EXIT', Reason} ->
                                  lager:error("Body decode failed ~p", [Reason]),
                                  { QueryWithBindings, ReqU };
                                HttpBodyList when is_list(HttpBodyList) ->
                                  lager:info("Body is list ~p", [HttpBodyList]),
                                  { QueryWithBindings#{<<"_body">> => HttpBodyList}, ReqU };
                                HttpBodyMap ->
                                  lager:info("Body is map ~p", [HttpBodyMap]),
                                  { maps:merge(HttpBodyMap, QueryWithBindings), ReqU }
                              end
                          end,
      handle_api(Method, PathInfo, ReqParams, HeadersU, Req1, State);
    false ->
      cowboy_req:reply(401, #{}, [], Req)
  end.

is_authenticated(#{headers := Headers}, #{auth := false}) ->
  {ok, Headers};
is_authenticated(_Req, #{auth_fun := undefined}) ->
  false;
is_authenticated(#{headers := Headers} = Req, #{auth_fun := AuthFun}) ->
  Authorization = cowboy_req:parse_header(<<"authorization">>, Req),
  HeadersWithoutAuthorization = maps:remove(<<"authorization">>, Headers),
  case invoke_auth_fun(AuthFun, Authorization) of
    ok ->
      {ok, HeadersWithoutAuthorization};
    {ok, AuthIdentities} when is_map(AuthIdentities) ->
      {ok, map:merge(HeadersWithoutAuthorization, AuthIdentities)};
    {ok, AuthIdentities} ->
      {ok, HeadersWithoutAuthorization#{<<"identity">> => AuthIdentities}};
    false ->
      false
  end.

invoke_auth_fun({Module, Function}, Authorization) ->
  apply(Module, Function, [Authorization]);
invoke_auth_fun(AuthFun, Authorization) when is_function(AuthFun, 1) ->
  apply(AuthFun, [Authorization]).

handle_api(Method, PathInfo, ReqParams, Headers, Req
           ,#{functions := Functions, state := State}) ->
  case get_api_function(Method, Functions) of
    {ok, Function} ->
      case apply(Function, [Headers, ReqParams, PathInfo, State]) of
        ok ->
          cowboy_req:reply(204, #{}, [], Req);
        {ok, Reply} ->
          ReplyJson = json_encode(Reply),
          cowboy_req:reply(200, #{<<"content-type">> => <<"application/json">>}, ReplyJson, Req);
        {ok, Reply, ReplyHeaders} ->
          ReplyJson = json_encode(Reply),
          cowboy_req:reply(200, ReplyHeaders#{<<"content-type">> => <<"application/json">>}, ReplyJson, Req);
        error ->
          cowboy_req:reply(400, #{}, [], Req);
        {error, Reason} ->
          ReplyJson = case Reason of
                        {Key, Value} -> json_encode(#{Key => Value});
                        Reason when is_map(Reason) -> json_encode(Reason);
                        _ -> json_encode(#{reason => Reason})
                      end,
          cowboy_req:reply(400, #{<<"content-type">> => <<"application/json">>}, ReplyJson, Req);
        {Code, Reply, ReplyHeaders} ->
          cowboy_req:reply(Code, ReplyHeaders, Reply, Req);
        Code when is_integer(Code) ->
          cowboy_req:reply(Code, #{}, [], Req)
      end;
    error ->
      cowboy_req:reply(405, #{}, [], Req)
  end.

get_api_function(Method, Functions) ->
  MethodAtom = binary_to_atom(string:lowercase(Method), latin1),
  case maps:find(MethodAtom, Functions) of
    {ok, {Module, Function}} ->
      {ok, fun Module:Function/4};
    {ok, Function} when is_function(Function, 4) ->
      {ok, Function};
    Other ->
      lager:info("Other is ~p", [Other]),
      error
  end.

json_decode(JsonObject) ->
  try_atomify_keys(
    jiffy:decode(JsonObject, [return_maps, {null_term, undefined}, dedupe_keys])
   ).

try_atomify_keys(Map) ->
  maps:fold(
    fun(Key, Value, Acc) ->
        KeyMaybeAtom = case catch binary_to_existing_atom(Key, latin1) of
                         {'EXIT', _} -> Key;
                         KeyAtom -> KeyAtom
                       end,
        Acc#{KeyMaybeAtom => Value}
    end,
    #{},
    Map
   ).

json_encode(Objects) when is_list(Objects) ->
  ObjectsU = format_values(Objects),
  jiffy:encode(ObjectsU);
json_encode(Object) when is_binary(Object) -> Object;
json_encode(Object) ->
  ObjectU = format_values(Object),
  jiffy:encode(ObjectU).

format_values(List) when is_list(List) ->
  [ format_values(Object) || Object <- List ];
format_values(Map) when is_map(Map) ->
  maps:map(
    fun(_Key, Value) ->
        format_values(Value)
    end,
    Map
   );
format_values(undefined) -> null;
format_values(Value) when is_reference(Value) -> list_to_binary(ref_to_list(Value));
format_values(Value) -> Value.

