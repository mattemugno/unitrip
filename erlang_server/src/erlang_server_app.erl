%%%-------------------------------------------------------------------
%% @doc erlang_server public API
%% @end
%%%-------------------------------------------------------------------

-module(erlang_server_app).
-author("matteo").
-behaviour(gen_server).

%% API export

-import(mnesia_db, [start_mnesia/0, add_user/2, check_user_present/1, get_user/1, delete_user/1, perform_login/2]).
-import(trip, [listener_trip/6]).
-export([start_main_server/0, register_request/2, init/1, handle_call/3, login_request/2, delete_request/1,
    create_trip_request/5, get_trips_request/0, lists_trips/2, trip_by_name/1, reset_trips/0, reset/0, handle_cast/2,
    update_server_state/1, spawn_trips/1, update_active_trips/2]).

%%%-------------------------------------------------------------------
%%% API FUNCTIONS
%%%-------------------------------------------------------------------

start_main_server() ->
    mnesia_db:start_mnesia(),
    io:format("[MAIN SERVER] Starting OTP gen_server. ~n"),
    Result = gen_server:start({local, main_server}, ?MODULE, [], []),
    io:format("[MAIN_SERVER] OTP gen_server server started with result ~p.~n", [Result]),
    io:format("[MAIN SERVER] Starting listener. ~n"),
    loop_server:init_listener(),
    io:format("[MAIN SERVER] Starting monitor. ~n"),
    monitor_trip:start_monitor(),
    Result.

register_request(Username, Password) ->
    gen_server:call(main_server, {register, Username, Password}).

login_request(Username, Password) ->
    gen_server:call(main_server, {login, Username, Password}).

delete_request(Username) ->
    gen_server:call(main_server, {delete, Username}).

create_trip_request(Organizer, Name, Destination, Date, Seats) ->
    gen_server:call(main_server, {create_trip, Organizer, Name, Destination, Date, Seats}).

get_trips_request() ->
    gen_server:call(main_server, {get_trips}).

trip_by_name(Name) ->
    gen_server:call(main_server, {get_trip_by_name, Name}).

update_server_state(From) ->
    gen_server:call(main_server, {delete_trip, From}).

reset_trips() ->
    gen_server:call(main_server, {reset_trips}).

reset() ->
    gen_server:cast(main_server, reset).

%%%-------------------------------------------------------------------
%%% gen_server CALLBACK FUNCTIONS
%%%-------------------------------------------------------------------

%The server state maintain the list of the active trips
init([]) ->
    io:format("[MAIN SERVER] Spawning trips processes. ~n"),
    %% all'avvio vengono spawnati tanti processi quanti sono i trip attivi
    ServerState = spawn_trips([]),
    io:format("[MAIN SERVER] InistialState: ~p. ~n", [ServerState]),
    {ok, ServerState}.   % general format: {ok, InitialState}

handle_call({register, Username, Password}, _From, _ServerState) ->
    Result = mnesia_db:add_user(Username, Password),
    io:format("[MAIN_SERVER] Result of the transaction ~p. ~n", [Result]),
    {reply, Result, _ServerState};
handle_call({login, Username, Password}, _From, _ServerState) ->
    Result = mnesia_db:perform_login(Username, Password),
    io:format("[MAIN_SERVER] Result of the transaction ~p. ~n", [Result]),
    {reply, Result, _ServerState};
handle_call({delete, Username}, _From, _ServerState) ->
    Result = mnesia_db:delete_user(Username),
    io:format("[MAIN_SERVER] Result of the transaction ~p. ~n", [Result]),
    {reply, Result, _ServerState};
handle_call({create_trip, Name, Organizer, Destination, Date, Seats}, _From, ServerState) ->
    Pid = spawn(fun() -> trip:init_trip(Name, Organizer, Destination, Date, Seats, []) end),
    io:format("[MAIN_SERVER] New erlang node spawned with pid ~p. ~n", [Pid]),
    Result = mnesia_db:add_trip(Pid, Organizer, Name, Destination, Date, Seats),
    io:format("[MAIN_SERVER] Result of the transaction ~p. ~n", [Result]),
    case Result of
        {atomic, ok} ->
            NewState = ServerState ++ [Pid],
            io:format("[MAIN SERVER] New Server State: ~p. ~n", [NewState]),
            %% aggiunta del processo al monitor
            {reply, {Result, Pid}, NewState};
        _ ->
            exit(Pid, kill),
            io:format("[MAIN SERVER] Something went wrong. ~n"),
            io:format("[MAIN SERVER] Process ~p terminated. ~n", [Pid]),
            {reply, Result, ServerState}

    end;
handle_call({get_trips}, _From, ServerState) ->
    Result = lists_trips(ServerState, []),
    io:format("[MAIN SERVER] Result of get_trips: ~p. ~n", [Result]),
    {reply, Result, ServerState};
handle_call({get_trip_by_name, Name}, _From, _ServerState) ->
    Result = mnesia_db:get_trip_by_name(Name),
    io:format("[MAIN SERVER] Result of get_trips_by_name: ~p. ~n", [Result]),
    {reply, Result, _ServerState};
handle_call({reset_trips}, _From, _ServerState) ->
    Result = mnesia_db:reset_trips(),
    NewState = [],
    io:format("[MAIN SERVER] Result of reset_trips: ~p. ~n", [Result]),
    {reply, Result, NewState};
handle_call({delete_trip, Pid}, _From, ServerState) ->
    io:format("[MAIN SERVER] Deleting from server state process with pid: ~p. ~n", [Pid]),
    NewServerState = lists:delete(Pid, ServerState),
    io:format("[MAIN SERVER] New Server State: ~p. ~n", [NewServerState]).

handle_cast(reset, ServerState) ->
    {noreply, ServerState}.

%%%-------------------------------------------------------------------
%%% INTERNAL FUNCTIONS
%%%-------------------------------------------------------------------

lists_trips([], Result) ->
    Result;
lists_trips([H|T], Result) ->
    Trip = mnesia_db:get_trip(H),
    NewResult = Result ++ [Trip],
    lists_trips(T, NewResult).

spawn_trips(ServerState) ->
    Result = mnesia_db:get_active_trips(),
    io:format("[MAIN SERVER] Active trips: ~p. ~n", [Result]),
    update_active_trips(element(2, Result), ServerState).


update_active_trips([], ServerState) ->
    ServerState;
update_active_trips([H|T], ServerState) ->
    % record(trip, {pid, organizer, name, destination, date, seats, partecipants})
    OldPid = lists:nth(1, H),
    Organizer = lists:nth(2, H),
    TripName = lists:nth(3, H),
    Destination = lists:nth(4, H),
    Date = lists:nth(5, H),
    Seats = lists:nth(6, H),
    Partecipants = lists:nth(7, H),
    NewPid = spawn(fun() -> trip:init_trip(TripName, Organizer, Destination, Date, Seats, Partecipants) end),
    mnesia_db:update_pid(NewPid, OldPid),
    NewServerState = ServerState ++ [NewPid],
    update_active_trips(T, NewServerState).