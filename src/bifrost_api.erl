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
-callback handle_info(Info :: term()) -> 'ok'.

-optional_callbacks([handle_info/1]).

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
  AuthFun = maps:get(auth_fun, Route, application:get_env(bifrost, auth_fun)),
  bifrost_web:add_route(Path, ?MODULE, #{functions => Functions
                                        ,auth => AuthFlag
                                        ,auth_fun => AuthFun
                                        ,state => Init}).

unpublish_route(#{path := Path}) ->
  bifrost_web:remove_route(Path).

handle_api(#{method := Method, headers := Headers, path_info := PathInfo} = Req, State) ->
  lager:info("Handling api ~p", [Req]),
  Cookies = maps:from_list( cowboy_req:parse_cookies(Req) ),
  lager:info("Cookies are ~p", [Cookies]),
  ReqAuth = Req#{cookies => Cookies},
  case authenticate(ReqAuth, State) of
    {ok, IdentitiesMap} ->
      Bindings = cowboy_req:bindings(Req),
      QueryStringMap = maps:from_list( cowboy_req:parse_qs(Req) ),
      ParamsAll = maps:merge(maps:merge(QueryStringMap, Bindings), IdentitiesMap),
      {ReqParams, Req1} = case maps:get(has_body, Req) of
                            false ->
                              { ParamsAll, Req };
                            true ->
                              {ok, HttpBodyJson, ReqU} = cowboy_req:read_body(Req),
                              case catch json_decode(HttpBodyJson) of
                                {'EXIT', Reason} ->
                                  lager:error("Body decode failed ~p", [Reason]),
                                  { ParamsAll, ReqU };
                                HttpBodyList when is_list(HttpBodyList) ->
                                  lager:info("Body is list ~p", [HttpBodyList]),
                                  { ParamsAll#{<<"_body">> => HttpBodyList}, ReqU };
                                HttpBodyMap ->
                                  lager:info("Body is map ~p", [HttpBodyMap]),
                                  { maps:merge(HttpBodyMap, ParamsAll), ReqU }
                              end
                          end,
      ReqParamsAtomized = try_atomify_keys(ReqParams),
      handle_api(Method, PathInfo, ReqParamsAtomized, Headers, Cookies, Req1, State);
    failed ->
      cowboy_req:reply(401, #{}, [], Req)
  end.

authenticate(#{method := <<"OPTIONS">>}, _State) ->
  lager:info("Skipping authentication for OPTIONS "),
  {ok, #{}};
authenticate(_Req, #{auth := false}) ->
  lager:info("Authentication disabled"),
  {ok, #{}};
authenticate(_Req, #{auth_fun := undefined}) ->
  lager:info("Authentication function not defined so failing"),
  failed;
authenticate(Req, #{auth_fun := AuthFun}) ->
  case invoke_auth_fun(AuthFun, Req) of
    ok ->
      lager:info("Authentication success"),
      {ok, #{}};
    {ok, AuthIdentities} when is_map(AuthIdentities) ->
      lager:info("Authentication success ~p", [AuthIdentities]),
      {ok, AuthIdentities};
    {ok, AuthIdentities} ->
      lager:info("Authentication success ~p", [AuthIdentities]),
      {ok, #{<<"identity">> => AuthIdentities}};
    failed ->
      lager:info("Authentication failed"),
      failed
  end.

invoke_auth_fun({Module, Function}, Req) ->
  apply(Module, Function, [Req]);
invoke_auth_fun(AuthFun, Req) when is_function(AuthFun, 1) ->
  apply(AuthFun, [Req]).

handle_api(Method, PathInfo, ReqParams, Headers, Cookies, Req
           ,#{functions := Functions, state := State}) ->
  ApiArgs = #{headers => Headers, cookies => Cookies
             ,request => ReqParams, path => PathInfo, state => State},
  case invoke_function(Method, Functions, ApiArgs) of
    {error, bad_function} ->
      cowboy_req:reply(405, #{}, [], Req);
    ok ->
      cowboy_req:reply(204, #{}, [], Req);
    {ok, Reply} when is_map(Reply) ->
      ReplyJson = json_encode(Reply),
      cowboy_req:reply(200, #{<<"content-type">> => <<"application/json">>}, ReplyJson, Req);
    {ok, Reply, ReplyHeaders} when is_map(Reply), is_map(ReplyHeaders) ->
      ReplyJson = json_encode(Reply),
      cowboy_req:reply(200, ReplyHeaders#{<<"content-type">> => <<"application/json">>}
                       ,ReplyJson, Req);
    {ok, Reply, ReplyHeaders, RespCookies}
      when is_map(Reply), is_map(ReplyHeaders), is_list(RespCookies) ->
      ReqU = set_cookies(RespCookies, Req),
      ReplyJson = json_encode(Reply),
      cowboy_req:reply(200, ReplyHeaders#{<<"content-type">> => <<"application/json">>}
                       ,ReplyJson, ReqU);
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
    {Code, Reply, ReplyHeaders, RespCookies} when is_list(RespCookies)->
      ReqU = set_cookies(RespCookies, Req),
      cowboy_req:reply(Code, ReplyHeaders, Reply, ReqU);
    Code when is_integer(Code) ->
      cowboy_req:reply(Code, #{}, [], Req)
  end.

set_cookies(Cookies, Req) ->
  lists:foldl(
    fun({Name, Value}, ReqA) when is_binary(Name), is_binary(Value) ->
        cowboy_req:set_resp_cookie(Name, Value, ReqA);
       ({Name, Value, Options}, ReqA) when is_binary(Name), is_binary(Value), is_map(Options) ->
        cowboy_req:set_resp_cookie(Name, Value, ReqA, Options);
       (_, ReqA) -> ReqA
    end,
    Req,
    Cookies
   ).

invoke_function(Method, Functions, ApiArgs) ->
  MethodAtom = binary_to_atom(string:lowercase(Method), latin1),
  case maps:find(MethodAtom, Functions) of
    {ok, {Module, Function, FunArgs}} ->
      AllArgs = FunArgs ++ [ApiArgs],
      lager:info("Invoking ~p with ~p", [{Module, Function}, AllArgs]),
      apply(Module, Function, AllArgs);
    {ok, {Module, Function}} ->
      lager:info("Invoking ~p with ~p", [{Module, Function}, ApiArgs]),
      apply(Module, Function, [ApiArgs]);
    {ok, Function} when is_function(Function, 4) ->
      lager:info("Invoking ~p with ~p", [Function, ApiArgs]),
      apply(Function, [ApiArgs]);
    Other when MethodAtom == options ->
      case application:get_env(bifrost, cors, true) of
        true ->
          lager:info("Invoking options for cors headers"),
          handle_options(ApiArgs);
        false ->
          lager:info("Cors is turned off and options fun not defined ~p", [Other])
      end;
    Other ->
      lager:info("Other is ~p", [Other]),
      {error, bad_function}
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

handle_options(Headers) ->
  lager:info("Headers for options ~p", [Headers]),
  Origin = maps:get(<<"origin">>, Headers, <<"*">>),
  CorsHeaders = maps:get(<<"access-control-request-headers">>, Headers, <<"*">>),
  CorsMethod = maps:get(<<"access-control-request-method">>, Headers, <<"GET">>),
  ReplyHeaders =  #{<<"content-type">> => <<"application/json;charset=utf-8">>,
                    <<"Access-Control-Allow-Origin">> => Origin,
                    <<"Access-Control-Allow-Headers">> => CorsHeaders,
                    <<"Access-Control-Allow-Methods">> => <<CorsMethod/binary, ",OPTIONS">>,
                    <<"Access-Control-Max-Age">> => <<"1728000">>,
                    <<"Access-Control-Allow-Credentials">> => "true"},
  lager:info("Sending CORS headers ~p", [ReplyHeaders]),
  {204, [], ReplyHeaders}.

