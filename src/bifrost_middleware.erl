-module(bifrost_middleware).
-behaviour(cowboy_middleware).

-export([execute/2]).

execute(#{headers := Headers} = Req, Env) ->
  lager:info("Headers from request ~p", [Headers]),
  Origin = maps:get(<<"origin">>, Headers, <<"*">>),
  CorsHeaders = maps:get(<<"access-control-request-headers">>, Headers, <<"*">>),
  CorsMethod = maps:get(<<"access-control-request-method">>, Headers, <<"GET">>),
  ReplyHeaders =  #{
    <<"content-type">> => <<"application/json;charset=utf-8">>,
    <<"Access-Control-Allow-Origin">> => Origin,
    <<"Access-Control-Allow-Headers">> => CorsHeaders,
    <<"Access-Control-Allow-Methods">> => <<"GET,POST,PUT,DELETE,OPTIONS">>,
    <<"Access-Control-Max-Age">> => <<"1728000">>,
    <<"Access-Control-Allow-Credentials">> => "true"},
  lager:info("Sending CORS headers ~p", [ReplyHeaders]),
  Req1 = cowboy_req:set_resp_headers(ReplyHeaders, Req),
  {ok, Req1, Env}.

