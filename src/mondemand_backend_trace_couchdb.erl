-module (mondemand_backend_trace_couchdb).

-include_lib ("lwes/include/lwes.hrl").

-behaviour (mondemand_server_backend).
-behaviour (gen_server).

%% mondemand_backend callbacks
-export ([ start_link/1,
           process/1,
           stats/0,
           required_apps/0
         ]).

%% gen_server callbacks
-export ([ init/1,
           handle_call/3,
           handle_cast/2,
           handle_info/2,
           terminate/2,
           code_change/3
         ]).

-record (state, { config,
                  couch,
                  connected = false,
                  backoff = 1000,
                  stats = dict:new ()
                }).

%%====================================================================
%% mondemand_backend callbacks
%%====================================================================
start_link (Config) ->
  gen_server:start_link ( { local, ?MODULE }, ?MODULE, Config, []).

process (Event) ->
  gen_server:cast (?MODULE, {process, Event}).

stats () ->
  gen_server:call (?MODULE, {stats}).

required_apps () ->
  [ sasl, crypto, public_key, ssl, ibrowse, couchbeam ].

%%====================================================================
%% gen_server callbacks
%%====================================================================
init (Config) ->
  % initialize all stats to zero
  InitialStats =
    mondemand_server_util:initialize_stats ([ errors, processed ] ),

  % make sure we attempt a connect
  erlang:send (self(), attempt_connect),

  { ok, #state{ config = Config, stats = InitialStats }}.

handle_call ({stats}, _From,
             State = #state { stats = Stats }) ->
  { reply, Stats, State };
handle_call (Request, From, State) ->
  error_logger:warning_msg ("~p : Unrecognized call ~p from ~p~n",
                            [?MODULE, Request, From]),
  { reply, ok, State }.

handle_cast ({process, Event},
             State = #state { couch = Couch,
                              connected = Connected,
                              stats = Stats
                            }) ->
  { NewStats, NewConnected } =
    case Connected of
      true ->
        Doc = lwes_event:from_udp_packet (Event, json_eep18),
        case couchbeam:save_doc (Couch, Doc) of
          {ok, _Doc1} ->
            { mondemand_server_util:increment_stat (processed, Stats),
              Connected
            };
          {error, {conn_failed,{error,econnrefused}}} ->
            % couchdb is down, attempt to reconnect
            erlang:send (self(), attempt_connect),
            { mondemand_server_util:increment_stat (errors, Stats),
              connecting
            };
          Error ->
            error_logger:error_msg ("Failure processing ~p",[Error]),
            { mondemand_server_util:increment_stat (errors, Stats),
              Connected
            }
        end;
      false ->
        { mondemand_server_util:increment_stat (errors, Stats), Connected };
      connecting ->
        { mondemand_server_util:increment_stat (errors, Stats), Connected }
    end,

  {noreply, State#state { stats = NewStats, connected = NewConnected }};

handle_cast (Request, State) ->
  error_logger:warning_msg ("~p : Unrecognized cast ~p~n",[?MODULE, Request]),
  { noreply, State }.

handle_info (attempt_connect,
             State = #state { config = Config,
                              backoff = Backoff
                            }) ->
  { Couch, Connected, NewBackoff } =
    case attempt_couchdb_connection (Config) of
      {ok, C} -> {C, true, 1000};
      {error, Error} ->
        error_logger:error_msg
          ( "Can't start CouchDB ~p retrying in ~p milliseconds",
            [Error, Backoff]),
        erlang:send_after (Backoff, self(), attempt_connect),
        { undefined, false, erlang:min (Backoff * 2, 60000) }
    end,
  { noreply,
    State#state { couch = Couch, backoff = NewBackoff, connected = Connected }
  };
handle_info (Request, State) ->
  error_logger:warning_msg ("~p : Unrecognized info ~p~n",[?MODULE, Request]),
  {noreply, State}.

terminate (_Reason, _State) ->
  ok.

code_change (_OldVsn, State, _Extra) ->
  {ok, State}.

%%====================================================================
%% Internal
%%====================================================================

attempt_couchdb_connection (Config) ->
  {CouchHost,CouchPort, CouchUser, CouchPassword} =
    proplists:get_value (couch, Config),

  % open and test couch connection
  Server =
    couchbeam:server_connection (CouchHost, CouchPort, "",
                                 [{basic_auth, {CouchUser, CouchPassword}}]),

  case couchbeam:server_info (Server) of
    {ok, _} ->
      couchbeam:open_or_create_db (Server, "traces");
    {error, _} ->
      {error, no_couchdb}
  end.

%%--------------------------------------------------------------------
%%% Test functions
%%--------------------------------------------------------------------
-ifdef(HAVE_EUNIT).
-include_lib("eunit/include/eunit.hrl").
-endif.

-ifdef(EUNIT).

-endif.
