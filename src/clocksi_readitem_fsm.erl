%% -------------------------------------------------------------------
%%
%% Copyright (c) 2014 SyncFree Consortium.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------
-module(clocksi_readitem_fsm).

-behavior(gen_server).

-include("antidote.hrl").
-include("inter_dc_repl.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% API
-export([start_link/2]).

%% Callbacks
-export([init/1,
	 handle_call/3,
	 handle_cast/2,
	 code_change/3,
         handle_event/3,
	 check_servers_ready/0,
         handle_info/2,
         handle_sync_event/4,
         terminate/2]).

%% States
-export([read_data_item/5,
	 async_read_data_item/6,
	 is_external/2,
	 get_ops/6,
	 check_partition_ready/3,
	 start_read_servers/2,
	 stop_read_servers/2]).

-export_type([external_read_property/0,
	     read_property/0,
	     read_property_list/0]).

%% Spawn
-record(state, {partition :: partition_id(),
		id :: non_neg_integer(),
		mat_state :: #mat_state{},
		prepared_cache :: cache_id(),
		self :: atom()}).

-type external_read_property() :: #external_read_property{}.
-type read_property() :: external_read_property().
-type read_property_list() :: [read_property()].

%%%===================================================================
%%% API
%%%===================================================================

%% @doc This starts a gen_server responsible for servicing reads to key
%%      handled by this Partition.  To allow for read concurrency there
%%      can be multiple copies of these servers per parition, the Id is
%%      used to distinguish between them.  Since these servers will be
%%      reading from ets tables shared by the clock_si and materializer
%%      vnodes, they should be started on the same physical nodes as
%%      the vnodes with the same partition.
-spec start_link(partition_id(),non_neg_integer()) -> {ok, pid()} | ignore | {error, term()}.
start_link(Partition,Id) ->
    Addr = node(),
    gen_server:start_link({global,generate_server_name(Addr,Partition,Id)}, ?MODULE, [Partition,Id], []).

-spec start_read_servers(partition_id(),non_neg_integer()) -> 0.
start_read_servers(Partition, Count) ->
    Addr = node(),
    start_read_servers_internal(Addr, Partition, Count).

-spec stop_read_servers(partition_id(),non_neg_integer()) -> ok.
stop_read_servers(Partition, Count) ->
    Addr = node(),
    stop_read_servers_internal(Addr, Partition, Count).

%% TODO: implement this
is_external({Key,_Bucket},PropList) ->
    is_external(Key,PropList);
is_external(<<"external",_/binary>>,[]) ->
    case dc_meta_data_utilities:get_dc_descriptors() of
	[] ->
	    false;
	Descs ->
	    #descriptor{dcid=ExDCID,partition_num=PartitionNum,partition_list=PartitionList} = lists:nth(random:uniform(length(Descs)),Descs),
	    {true, {ExDCID,lists:nth(random:uniform(PartitionNum),PartitionList)}}
    end;
is_external(_Key,_PropList) ->
    false.

-spec get_ops(index_node(), key(), type(), clock_time(), snapshot_time(), tx()) -> {ok,[clocksi_payload()]} | {error, reason()}.
get_ops({Partition,Node},Key,Type,Time,SnapshotTime,Transaction) ->
    try
	gen_server:call({global,generate_random_server_name(Node,Partition)},
			{get_ops,Key,Type,Time,SnapshotTime,Transaction},infinity)
    catch
        _:Reason ->
            lager:debug("Exception caught: ~p, starting read server to fix", [Reason]),
	    check_server_ready([{Partition,Node}]),
	    get_ops({Partition,Node},Key,Type,Time,SnapshotTime,Transaction)
    end.

-spec read_data_item(index_node(), key(), type(), tx(), read_property_list()) -> {error, term()} | {ok, snapshot()}.
read_data_item({Partition,Node},Key,Type,Transaction,PropertyList) ->
    %% Check if should perform the read externally
    lager:info("the key to check if external ~p", [Key]),
    case is_external(Key,PropertyList) of
	{true, {ExDCID,ExPartition}} ->
	    lager:info("Performing external read ~p", [{ExDCID,ExPartition}]),
	    ok = partial_repli_utils:perform_external_read({ExDCID,ExPartition},Key,Type,Transaction,self()),
	    partial_repli_utils:wait_for_external_read_resp();
	false ->
	    try
		gen_server:call({global,generate_random_server_name(Node,Partition)},
				{perform_read,Key,Type,Transaction,PropertyList},infinity)
	    catch
		_:Reason ->
		    lager:error("Exception caught: ~p, starting read server to fix", [Reason]),
		    check_server_ready([{Partition,Node}]),
		    read_data_item({Partition,Node},Key,Type,Transaction,PropertyList)
	    end
    end.

-spec async_read_data_item(index_node(), key(), type(), tx(), read_property_list(), term()) -> ok.
async_read_data_item({Partition,Node},Key,Type,Transaction,PropertyList,Coordinator) ->
    %% Check if should perform the read externally
    lager:info("the key to check if external ASYNCCCC ~p", [Key]),
    case is_external(Key,PropertyList) of
	{true, {ExDCID, ExPartition}} ->
	    lager:info("async external read!!!!"),
	    ok = partial_repli_utils:perform_external_read({ExDCID,ExPartition},Key,Type,Transaction,Coordinator);
	false ->
	    gen_server:cast({global,generate_random_server_name(Node,Partition)},
			    {perform_read_cast, Coordinator, Key, Type, Transaction, PropertyList})
    end.

%% @doc This checks all partitions in the system to see if all read
%%      servers have been started up.
%%      Returns true if they have been, false otherwise.
-spec check_servers_ready() -> boolean().
check_servers_ready() ->
    PartitionList = dc_utilities:get_all_partitions_nodes(),
    check_server_ready(PartitionList).

-spec check_server_ready([index_node()]) -> boolean().
check_server_ready([]) ->
    true;
check_server_ready([{Partition,Node}|Rest]) ->
    try
	Result = riak_core_vnode_master:sync_command({Partition,Node},
						     {check_servers_ready},
						     ?CLOCKSI_MASTER,
						     infinity),
	case Result of
	    false ->
		false;
	    true ->
		check_server_ready(Rest)
	end
    catch
	_:_Reason ->
	    false
    end.

-spec check_partition_ready(node(), partition_id(), non_neg_integer()) -> boolean().
check_partition_ready(_Node,_Partition,0) ->
    true;
check_partition_ready(Node,Partition,Num) ->
    case global:whereis_name(generate_server_name(Node,Partition,Num)) of
	undefined ->
	    false;
	_Res ->
	    check_partition_ready(Node,Partition,Num-1)
    end.



%%%===================================================================
%%% Internal
%%%===================================================================

-spec start_read_servers_internal(node(), partition_id(), non_neg_integer()) -> non_neg_integer().
start_read_servers_internal(_Node,_Partition,0) ->
    0;
start_read_servers_internal(Node, Partition, Num) ->
    case clocksi_readitem_sup:start_fsm(Partition,Num) of
	{ok,_Id} ->
	    start_read_servers_internal(Node, Partition, Num-1);
    {error,{already_started, _}} ->
	    start_read_servers_internal(Node, Partition, Num-1);
	Err ->
	    lager:debug("Unable to start clocksi read server for ~w, will retry", [Err]),
	    try
		gen_server:call({global,generate_server_name(Node,Partition,Num)},{go_down})
	    catch
		_:_Reason->
		    ok
	    end,
	    start_read_servers_internal(Node, Partition, Num)
    end.

-spec stop_read_servers_internal(node(), partition_id(), non_neg_integer()) -> ok.
stop_read_servers_internal(_Node,_Partition,0) ->
    ok;
stop_read_servers_internal(Node,Partition, Num) ->
    try
	gen_server:call({global,generate_server_name(Node,Partition,Num)},{go_down})
    catch
	_:_Reason->
	    ok
    end,
    stop_read_servers_internal(Node, Partition, Num-1).

-spec generate_server_name(node(), partition_id(), non_neg_integer()) -> atom().
generate_server_name(Node, Partition, Id) ->
    list_to_atom(integer_to_list(Id) ++ integer_to_list(Partition) ++ atom_to_list(Node)).

-spec generate_random_server_name(node(), partition_id()) -> atom().
generate_random_server_name(Node, Partition) ->
    generate_server_name(Node, Partition, random:uniform(?READ_CONCURRENCY)).

init([Partition, Id]) ->
    Addr = node(),
    OpsCache = materializer_vnode:get_cache_name(Partition,ops_cache),
    SnapshotCache = materializer_vnode:get_cache_name(Partition,snapshot_cache),
    PreparedCache = clocksi_vnode:get_cache_name(Partition,prepared),
    MatState = #mat_state{ops_cache=OpsCache,snapshot_cache=SnapshotCache,partition=Partition},
    Self = generate_server_name(Addr,Partition,Id),
    {ok, #state{partition=Partition, id=Id,
		mat_state = MatState,
		prepared_cache=PreparedCache,self=Self}}.

handle_call({perform_read, Key, Type, Transaction, PropertyList},Coordinator,SD0) ->
    ok = perform_read_internal(Coordinator,Key,Type,Transaction,PropertyList,SD0),
    {noreply,SD0};

handle_call({get_ops,Key,Type,Time,SnapshotTime,Transaction},Coordinator,SD0) ->
    ok = get_ops_internal(Coordinator,Key,Type,Time,SnapshotTime,Transaction,SD0),
    {noreply,SD0};

handle_call({go_down},_Sender,SD0) ->
    {stop,shutdown,ok,SD0}.

handle_cast({get_ops_cast,Coordinator,Key,Type,Time,SnapshotTime,Transaction},SD0) ->
    ok = get_ops_internal(Coordinator,Key,Type,Time,SnapshotTime,Transaction,SD0),
    {noreply,SD0};

handle_cast({perform_read_cast, Coordinator, Key, Type, Transaction, PropertyList}, SD0) ->
    ok = perform_read_internal(Coordinator,Key,Type,Transaction,PropertyList,SD0),
    {noreply,SD0}.

-spec get_ops_internal(pid(), key(), type(), clock_time(), snapshot_time(), tx(), #state{}) -> ok.
get_ops_internal(Coordinator,Key,Type,Time,SnapshotTime,Transaction,
		 SD0 = #state{prepared_cache=PreparedCache,partition=Partition}) ->
    TxId = Transaction#transaction.txn_id,
    TxLocalStartTime = TxId#tx_id.local_start_time,
    case check_clock(Key,TxLocalStartTime,PreparedCache,Partition) of
	{not_ready,Time} ->
	    _Tref = erlang:send_after(Time, self(), {get_ops_cast,Coordinator,Key,Type,Time,SnapshotTime,Transaction}),
	    ok;
	ready ->
	    return_ops(Coordinator,Key,Type,Time,SnapshotTime,SD0)
    end.

-spec perform_read_internal(pid(), key(), type(), #transaction{}, read_property_list(), #state{}) ->
				   ok.
perform_read_internal(Coordinator,Key,Type,Transaction,PropertyList,
		      SD0 = #state{prepared_cache=PreparedCache,partition=Partition}) ->
    TxId = Transaction#transaction.txn_id,
    TxLocalStartTime = TxId#tx_id.local_start_time,
    %% Check if wait for external read is necessary
    {ok,_} = partial_repli_utils:check_wait_time(Transaction#transaction.vec_snapshot_time,PropertyList),
    case check_clock(Key,TxLocalStartTime,PreparedCache,Partition) of
	{not_ready,Time} ->
	    %% spin_wait(Coordinator,Key,Type,Transaction,OpsCache,SnapshotCache,PreparedCache,Self);
	    _Tref = erlang:send_after(Time, self(), {perform_read_cast,Coordinator,Key,Type,Transaction,PropertyList}),
	    ok;
	ready ->
	    return(Coordinator,Key,Type,Transaction,PropertyList,SD0)
    end.

%% @doc check_clock: Compares its local clock with the tx timestamp.
%%      if local clock is behind, it sleeps the fms until the clock
%%      catches up. CLOCK-SI: clock skew.
%%
-spec check_clock(key(),clock_time(),ets:tid(),partition_id()) ->
			 {not_ready, clock_time()} | ready.
check_clock(Key,TxLocalStartTime,PreparedCache,Partition) ->
    Time = clocksi_vnode:now_microsec(dc_utilities:now()),
    case TxLocalStartTime > Time of
        true ->
	    {not_ready, (TxLocalStartTime - Time) div 1000 +1};
        false ->
	    check_prepared(Key,TxLocalStartTime,PreparedCache,Partition)
    end.

%% @doc check_prepared: Check if there are any transactions
%%      being prepared on the tranaction being read, and
%%      if they could violate the correctness of the read
-spec check_prepared(key(),clock_time(),ets:tid(),partition_id()) ->
			    ready | {not_ready, ?SPIN_WAIT}.
check_prepared(Key,TxLocalStartTime,PreparedCache,Partition) ->
    {ok, ActiveTxs} = clocksi_vnode:get_active_txns_key(Key,Partition,PreparedCache),
    check_prepared_list(Key, TxLocalStartTime, ActiveTxs).

-spec check_prepared_list(key(),clock_time(),[{txid(),clock_time()}]) ->
				 ready | {not_ready, ?SPIN_WAIT}.
check_prepared_list(_Key,_TxLocalStartTime,[]) ->
    ready;
check_prepared_list(Key,TxLocalStartTime,[{_TxId,Time}|Rest]) ->
    case Time =< TxLocalStartTime of
    true ->
        {not_ready, ?SPIN_WAIT};
    false ->
        check_prepared_list(Key,TxLocalStartTime,Rest)
    end.

-spec return_ops({pid(),term()},key(),type(),clock_time(),snapshot_time(),#state{}) -> ok.
return_ops(Coordinator,Key,Type,Time,SnapshotTime,#state{mat_state=MatState}) ->
    MyDCID = dc_meta_data_utilities:get_my_dc_id(),
    case materializer_vnode:get_ops(Key, Type, Time, SnapshotTime, MyDCID, MatState) of
        {ok, OpList} ->
	    _Ignore=gen_server:reply(Coordinator, {ok, OpList});
        {error, Reason} ->
	    _Ignore=gen_server:reply(Coordinator, {error, Reason})
    end,
    ok.

%% @doc return:
%%  - Reads and returns the log of specified Key using replication layer.
-spec return({fsm,pid()} | {pid(),term()},key(),type(),#transaction{},read_property_list(),#state{}) -> ok.
return(Coordinator,Key,Type,Transaction,PropertyList,
       #state{mat_state=MatState}) ->
    VecSnapshotTime = Transaction#transaction.vec_snapshot_time,
    TxId = Transaction#transaction.txn_id,
    case materializer_vnode:read(Key, Type, VecSnapshotTime, TxId, PropertyList, MatState) of
        {ok, Snapshot} ->
            case Coordinator of
                {fsm, Sender} -> %% Return Type and Value directly here.
                    gen_fsm:send_event(Sender, {ok, {Key, Type, Snapshot}});
                _ ->
                    _Ignore=gen_server:reply(Coordinator, {ok, Snapshot})
            end;
        {error, Reason} ->
            case Coordinator of
                {fsm, Sender} -> %% Return Type and Value directly here.
                    gen_fsm:send_event(Sender, {error, Reason});
                _ ->
                    _Ignore=gen_server:reply(Coordinator, {error, Reason})
            end
    end,
    ok.

handle_info({perform_read_cast, Coordinator, Key, Type, Transaction, PropertyList},SD0) ->
    ok = perform_read_internal(Coordinator,Key,Type,Transaction,PropertyList,SD0),
    {noreply,SD0};

handle_info(_Info, StateData) ->
    {noreply,StateData}.

handle_event(_Event, _StateName, StateData) ->
    {stop,badmsg,StateData}.

handle_sync_event(_Event, _From, _StateName, StateData) ->
    {stop,badmsg,StateData}.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

terminate(_Reason, _SD) ->
    ok.
