%%%-------------------------------------------------------------------
%%% @author Chaitanya Chalasani
%%% @copyright (C) 2020, ArkNode.IO
%%% @doc
%%%
%%% @end
%%% Created : 2020-01-21 13:22:17.378474
%%%-------------------------------------------------------------------
-module(bifrost_bulk).

%% cowboy callbacks
-export([init/2]).

%% Init for cowboy behaviour
init(Req, State) ->
  ReqFinalState = handle_api(Req, State),
  {ok, ReqFinalState, State}.

%% Internal functions
handle_api(#{method := <<"POST">>, host := Host, headers := Headers} = Req, State) ->
  lager:info("API request is ~p with ~p", [Req, State]),
  lager:info("Handling api ~p", [Req]),
  Cookies = maps:from_list( cowboy_req:parse_cookies(Req) ),
  lager:info("Cookies are ~p", [Cookies]),
  ReqAuth = Req#{cookies => Cookies},
  case authenticate(ReqAuth) of
    failed ->
      cowboy_req:reply(401, #{}, [], Req);
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
      handle_api(ReqParamsAtomized, Host, Headers, Cookies, Req1)
  end;
handle_api(#{method := <<"OPTIONS">>} = Req, _State) ->
  lager:info("OPTIONS request ~p", [Req]),
  ok;
handle_api(Req, _State) ->
  lager:info("Not a post request ~p", [Req]),
  cowboy_req:reply(405, #{}, [], Req),
  ok.

authenticate(#{method := <<"OPTIONS">>}) -> {ok, #{}};
authenticate(Req) ->
  case application:get_env(bifrost, auth_fun, undefined) of
    undefined -> {ok, #{}};
    AuthFun ->
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
      end
  end.

invoke_auth_fun({Module, Function}, Req) ->
  apply(Module, Function, [Req]);
invoke_auth_fun(AuthFun, Req) when is_function(AuthFun, 1) ->
  apply(AuthFun, [Req]).

handle_api(#{<<"_body">> := APIList}, Host, _Headers, _Cookies, Req) ->
  Dispatch = cowboy_router:compile([{'_', bifrost_web:get_routes()}]),
  Reply = lists:map(
            fun(#{<<"method">> := Method, <<"path">> := Path
                 ,<<"params">> := Params, <<"id">> := Id}) ->
                case catch cowboy_router:execute(#{host => Host, path => Path}
                                                ,#{dispatch => Dispatch}) of
                  {"EXIT", _Reason} ->
                    lager:error("API ~p couldn't be found", [{Method, Path}]),
                    #{status_code => 404};
                  {ok, #{bindings := Bindings}, #{handler_opts := #{functions := Functions}}} ->
                    lager:info("API bindings are ~p and functions are ~p"
                              ,[Bindings, Functions]),
                    ParamsU = try_atomify_keys(maps:merge(Params, Bindings)),
                    MethodAtom = binary_to_atom(string:lowercase(Method), latin1),
                    case maps:find(MethodAtom, Functions) of
                      error ->
                        lager:error("Method ~p couldn't be found", [Method]),
                        #{status_code => 405};
                      {ok, {Module, Function}} ->
                        lager:info("Invoking ~p with ~p", [{Module, Function}, ParamsU]),
                        case apply(Module, Function, [ParamsU]) of

                          ok -> #{id => Id, status_code => 204};
                          {ok, Reply} -> #{id => Id, status_code => 200, reply => Reply};
                          {ok, Reply, _} -> #{id => Id, status_code => 200, reply => Reply};
                          {ok, Reply, _, _} -> #{id => Id, status_code => 200, reply => Reply};
                          error -> #{id => Id, status_code => 400};
                          {error, {Key, Value}} -> #{id => Id, status_code => 400, reply => #{Key => Value}};
                          {error, Reason} when is_map(Reason) -> #{id => Id, status_code => 400, reply => Reason};
                          {error, Reason} -> #{id => Id, status_code => 400, reply => Reason};
                          {Code, Reply, _} -> #{id => Id, status_code => Code, reply => Reply};
                          {Code, Reply, _, _} -> #{id => Id, status_code => Code, reply => Reply};
                          Code when is_integer(Code) -> #{id => Id, status_code => Code};
                          Unknown ->
                            lager:error("Unknown response ~p", [Unknown]),
                            #{id => Id, status_code => 500}
                        end
                    end
                end;
               (InvalidReq) ->
                lager:error("Invalid request ~p", [InvalidReq]),
                #{status_code => 400}
            end,
            APIList
           ),
  ReplyJson = json_encode(Reply),
  cowboy_req:reply(200, #{<<"content-type">> => <<"application/json">>}
                   ,ReplyJson, Req);
handle_api(ReqParams, Host, Headers, Cookies, Req) ->
  lager:error("API list badly configured ~p"
             ,[{ReqParams, Host, Headers, Cookies, Req}]),
  cowboy_req:reply(400, #{}, [], Req).


json_decode(JsonObject) ->
  jiffy:decode(JsonObject, [return_maps, {null_term, undefined}, dedupe_keys]).

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

