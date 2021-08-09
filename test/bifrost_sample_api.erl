-module(bifrost_sample_api).

-behaviour(bifrost_api).

-export([start_link/0
        ,login/1
        ,get/1
        ,put/1
        ,delete/1
        ,logout/1
        ,auth/1
        ,init/1]).

start_link() ->
  io:format("Starting sample api"),
  bifrost_api:start_link({local, ?MODULE}, ?MODULE, [], []).

login(Options) ->
  io:format("~p~n", [Options]),
  {204, [], #{}, [{<<"sample-user">>, <<"b92307c2-1a60-4d4b-b1fe-4d3ba57d1ca5">>}]}.

get(Options) ->
  io:format("~p~n", [Options]),
  {ok, #{name => <<"Chaitanya Chalasani">>
        ,phone => <<"+49 15226010830">>
        ,city => <<"Oberhausen">>}}.

put(Options) ->
  io:format("~p~n", [Options]),
  {ok, #{uuid => <<"b92307c2-1a60-4d4b-b1fe-4d3ba57d1ca5">>}}.

delete(Options) ->
  io:format("~p~n", [Options]),
  ok.

logout(Options) ->
  io:format("~p~n", [Options]),
  {204, [], #{}, [{<<"sample-user">>, <<"b92307c2-1a60-4d4b-b1fe-4d3ba57d1ca5">>
                 ,#{max_age => 0}}]}.

auth(#{cookies := #{<<"sample-user">> := <<"b92307c2-1a60-4d4b-b1fe-4d3ba57d1ca5">>}}) ->
  io:format("Auth Success~n"),
  {ok, #{'_user' => <<"9c3c4a0e-3e62-4b15-9cb5-fbe403c0dda4">>}};
auth(Other) ->
  io:format("Auth Failed ~p", [Other]),
  failed.

init([]) ->
  Routes = [#{path => "/login"
             ,functions => #{post => {?MODULE, login}}
             ,auth => false}
           ,#{path => "/logout"
             ,functions => #{post => {?MODULE, logout}}
             ,auth_fun => {?MODULE, auth}}
           ,#{path => "/samplenoauth/[:name]"
             ,functions => #{get => {?MODULE, get}
                            ,post => {?MODULE, put}
                            ,delete => {?MODULE, delete}}
             ,auth => false}
           ,#{path => "/sample/[:name]"
             ,functions => #{get => {?MODULE, get}
                            ,post => {?MODULE, put}
                            ,delete => {?MODULE, delete}}
             ,auth_fun => {?MODULE, auth}}],
  {ok, Routes}.
