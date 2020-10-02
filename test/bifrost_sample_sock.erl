-module(bifrost_sample_sock).

-export([start_link/1
        ,init/1]).

start_link(Port) ->
  bifrost_sock_client:start_link({local, ?MODULE}, ?MODULE, [Port], []).

init([Port]) ->
  {ok, #{host => "127.0.0.1", port => Port, state => []
        ,resource => "/ws/1234567890"
        ,headers => [{<<"sec-websocket-protocol">>, <<"janus-protocol">>}]}}.
        % ,resource => "/ws/1234567890"
        % ,headers => #{<<"sec-websocket-protocol">> => <<"janus-protocol">>}}}.
