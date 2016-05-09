-module(multiple_dcs_node_failure_test).

-export([confirm/0,
         multiple_writes/4,
         multiple_cluster_failure_test/2,
         cluster_failure_test/3,
         update_during_cluster_failure_test/3,
         failure_test/3,
         parallel_writes_test/3]).

-include_lib("eunit/include/eunit.hrl").

-define(HARNESS, (rt_config:get(rt_harness))).

confirm() ->

    %% This resets nodes, cleans up stale directories, etc.:
    lager:info("Cleaning up..."),
    rt:setup_harness(dummy, dummy),

    NumVNodes = rt_config:get(num_vnodes, 8),
    rt:update_app_config(all,[
        {riak_core, [{ring_creation_size, NumVNodes}]}
    ]),

    [Cluster1, Cluster2, Cluster3] = rt:build_clusters([1,1,1]),
    rt:wait_until_ring_converged(Cluster1),
    rt:wait_until_ring_converged(Cluster2),
    rt:wait_until_ring_converged(Cluster3),

    {ok, Prot} = rpc:call(hd(Cluster1), application, get_env, [antidote, txn_prot]),
    ?assertMatch(clocksi, Prot),

    ok = common:setup_dc_manager([Cluster1, Cluster2, Cluster3], first_run),
    cluster_failure_test(Cluster1, Cluster2, Cluster3),

    ok = common:just_clean_clusters([Cluster1, Cluster2, Cluster3]),
    [Cluster1, Cluster2, Cluster3] = rt:build_clusters([1,1,1]),
    rt:wait_until_ring_converged(Cluster1),
    rt:wait_until_ring_converged(Cluster2),
    rt:wait_until_ring_converged(Cluster3),

    ok = common:setup_dc_manager([Cluster1, Cluster2, Cluster3], first_run),
    update_during_cluster_failure_test(Cluster1, Cluster2, Cluster3),

    ok = common:just_clean_clusters([Cluster1, Cluster2, Cluster3]),
    [Cluster1a, Cluster2a] = rt:build_clusters([2,1]),
    rt:wait_until_ring_converged(Cluster1a),
    rt:wait_until_ring_converged(Cluster2a),

    ok = common:setup_dc_manager([Cluster1a, Cluster2a], first_run),
    multiple_cluster_failure_test(Cluster1a, Cluster2a),

    pass.

%% In this test there are 3 DCs each with 1 node
%% The test starts by performing some updates, ensuring they are propagated
%% The it kills the node of the first DC
%% Once restarted it checks that updates are still performed safely
%% and propagated to other DCs
cluster_failure_test(Cluster1, Cluster2, Cluster3) ->
    Node1 = hd(Cluster1),
    Node2 = hd(Cluster2),
    Node3 = hd(Cluster3),

    Key1 = cluster_failure_test,
    
    WriteResult1 = rpc:call(Node1,
                            antidote, append,
                            [Key1, riak_dt_gcounter, {increment, ucl1}]),
    ?assertMatch({ok, _}, WriteResult1),
    WriteResult2 = rpc:call(Node1,
                            antidote, append,
                            [Key1, riak_dt_gcounter, {increment, ucl2}]),
    ?assertMatch({ok, _}, WriteResult2),
    WriteResult3 = rpc:call(Node1,
                            antidote, append,
                            [Key1, riak_dt_gcounter, {increment, ucl3}]),
    ?assertMatch({ok, _}, WriteResult3),
    {ok,{_,_,CommitTime}}=WriteResult3,
    ReadResult = rpc:call(Node1, antidote, read,
                          [Key1, riak_dt_gcounter]),
    ?assertEqual({ok, 3}, ReadResult),

    %% Kill and restart a node an be sure everyhing works
    lager:info("Killing and restarting node ~w", [Node1]),
    timer:sleep(5000),
    rt:brutal_kill(Node1),
    rt:start_and_wait(Node1),
    rt:wait_until_ring_converged(Cluster1),
    lager:info("Waiting until vnodes are restarted"),
    rt:wait_until(Node1, fun wait_init:check_ready/1),
    timer:sleep(10000),

    lager:info("Done append in Node1"),
    ReadResult2 = rpc:call(Node3,
                           antidote, clocksi_read,
                           [CommitTime, Key1, riak_dt_gcounter]),
    {ok, {_,[ReadSet1],_} }= ReadResult2,
    ?assertEqual(3, ReadSet1),
    lager:info("Done Read in Node3"),
    ReadResult3 = rpc:call(Node2,
                           antidote, clocksi_read,
                           [CommitTime, Key1, riak_dt_gcounter]),
    {ok, {_,[ReadSet2],_} }= ReadResult3,
    ?assertEqual(3, ReadSet2),

    lager:info("Done first round of read, I am gonna append"),
    WriteResult4= rpc:call(Node2,
                           antidote, clocksi_bulk_update,
                           [ CommitTime,
                             [{update, {Key1, riak_dt_gcounter, {increment, ucl4}}}]]),
    ?assertMatch({ok, _}, WriteResult4),
    {ok,{_,_,CommitTime2}}=WriteResult4,
    lager:info("Done append in Node2"),
    WriteResult5= rpc:call(Node3,
                           antidote, clocksi_bulk_update,
                           [CommitTime2,
                            [{update, {Key1, riak_dt_gcounter, {increment, ucl5}}}]]),
    ?assertMatch({ok, _}, WriteResult5),
    {ok,{_,_,CommitTime3}}=WriteResult5,
    lager:info("Done append in Node3"),
    lager:info("Done waiting, I am gonna read"),

    SnapshotTime =
        CommitTime3,
    ReadResult4 = rpc:call(Node1,
                           antidote, clocksi_read,
                           [SnapshotTime, Key1, riak_dt_gcounter]),
    {ok, {_,[ReadSet4],_} }= ReadResult4,
    ?assertEqual(5, ReadSet4),
    lager:info("Done read in Node1"),
    ReadResult5 = rpc:call(Node2,
                           antidote, clocksi_read,
                           [SnapshotTime,Key1, riak_dt_gcounter]),
    {ok, {_,[ReadSet5],_} }= ReadResult5,
    ?assertEqual(5, ReadSet5),
    lager:info("Done read in Node2"),
    ReadResult6 = rpc:call(Node3,
                           antidote, clocksi_read,
                           [SnapshotTime,Key1, riak_dt_gcounter]),
    {ok, {_,[ReadSet6],_} }= ReadResult6,
    ?assertEqual(5, ReadSet6),
    pass.


%% In this test there are 2 DCs, the first has 2 nodes the second has 1
%% The test starts by performing some updates, ensuring they are propagated
%% The it kills one of the nodes in the 1st DC and restarts it
%% Once restarted it checks that updates are still performed safely
%% and propagated to other DCs
multiple_cluster_failure_test(Cluster1, Cluster2) ->
    [Node1,Node3|_] = Cluster1,
    Node2 = hd(Cluster2),

    Key1 = multiple_cluster_failure_test,
    
    WriteResult1 = rpc:call(Node1,
                            antidote, append,
                            [Key1, riak_dt_gcounter, {increment, ucl1}]),
    ?assertMatch({ok, _}, WriteResult1),
    WriteResult2 = rpc:call(Node1,
                            antidote, append,
                            [Key1, riak_dt_gcounter, {increment, ucl2}]),
    ?assertMatch({ok, _}, WriteResult2),
    WriteResult3 = rpc:call(Node1,
                            antidote, append,
                            [Key1, riak_dt_gcounter, {increment, ucl3}]),
    ?assertMatch({ok, _}, WriteResult3),
    {ok,{_,_,CommitTime}}=WriteResult3,
    ReadResult = rpc:call(Node1, antidote, read,
                          [Key1, riak_dt_gcounter]),
    ?assertEqual({ok, 3}, ReadResult),

    %% Kill and restart a node an be sure everyhing works
    lager:info("Killing and restarting node ~w", [Node1]),
    timer:sleep(5000),
    rt:brutal_kill(Node1),
    rt:start_and_wait(Node1),
    rt:wait_until_ring_converged(Cluster1),
    lager:info("Waiting until vnodes are restarted"),
    rt:wait_until(Node1, fun wait_init:check_ready/1),
    timer:sleep(10000),

    lager:info("Done append in Node1"),
    ReadResult2 = rpc:call(Node3,
                           antidote, clocksi_read,
                           [CommitTime, Key1, riak_dt_gcounter]),
    {ok, {_,[ReadSet1],_} }= ReadResult2,
    ?assertEqual(3, ReadSet1),
    lager:info("Done Read in Node3"),
    ReadResult3 = rpc:call(Node2,
                           antidote, clocksi_read,
                           [CommitTime, Key1, riak_dt_gcounter]),
    {ok, {_,[ReadSet2],_} }= ReadResult3,
    ?assertEqual(3, ReadSet2),

    lager:info("Done first round of read, I am gonna append"),
    WriteResult4= rpc:call(Node2,
                           antidote, clocksi_bulk_update,
                           [ CommitTime,
                             [{update, {Key1, riak_dt_gcounter, {increment, ucl4}}}]]),
    ?assertMatch({ok, _}, WriteResult4),
    {ok,{_,_,CommitTime2}}=WriteResult4,
    lager:info("Done append in Node2"),
    WriteResult5= rpc:call(Node3,
                           antidote, clocksi_bulk_update,
                           [CommitTime2,
                            [{update, {Key1, riak_dt_gcounter, {increment, ucl5}}}]]),
    ?assertMatch({ok, _}, WriteResult5),
    {ok,{_,_,CommitTime3}}=WriteResult5,
    lager:info("Done append in Node3"),
    lager:info("Done waiting, I am gonna read"),

    SnapshotTime =
        CommitTime3,
    ReadResult4 = rpc:call(Node1,
                           antidote, clocksi_read,
                           [SnapshotTime, Key1, riak_dt_gcounter]),
    {ok, {_,[ReadSet4],_} }= ReadResult4,
    ?assertEqual(5, ReadSet4),
    lager:info("Done read in Node1"),
    ReadResult5 = rpc:call(Node2,
                           antidote, clocksi_read,
                           [SnapshotTime,Key1, riak_dt_gcounter]),
    {ok, {_,[ReadSet5],_} }= ReadResult5,
    ?assertEqual(5, ReadSet5),
    lager:info("Done read in Node2"),
    ReadResult6 = rpc:call(Node3,
                           antidote, clocksi_read,
                           [SnapshotTime,Key1, riak_dt_gcounter]),
    {ok, {_,[ReadSet6],_} }= ReadResult6,
    ?assertEqual(5, ReadSet6),
    pass.

%% In this test there are 3 DCs each with 1 node
%% The test starts by performing some updates, ensuring they are propagated
%% The it kills the node of the first DC
%% It then perofms an update and read in the other DCs
%% It then starts the killed node back up
%% Once restarted it checks that updates are still performed safely
%% and propagated to other DCs
update_during_cluster_failure_test(Cluster1, Cluster2, Cluster3) ->
    Node1 = hd(Cluster1),
    Node2 = hd(Cluster2),
    Node3 = hd(Cluster3),

    Key1 = update_during_cluster_failure_test,
    
    WriteResult1 = rpc:call(Node1,
                            antidote, append,
                            [Key1, riak_dt_gcounter, {increment, ucl1}]),
    ?assertMatch({ok, _}, WriteResult1),
    WriteResult2 = rpc:call(Node1,
                            antidote, append,
                            [Key1, riak_dt_gcounter, {increment, ucl2}]),
    ?assertMatch({ok, _}, WriteResult2),
    WriteResult3 = rpc:call(Node1,
                            antidote, append,
                            [Key1, riak_dt_gcounter, {increment, ucl3}]),
    ?assertMatch({ok, _}, WriteResult3),
    {ok,{_,_,CommitTime}}=WriteResult3,
    ReadResult = rpc:call(Node1, antidote, read,
                          [Key1, riak_dt_gcounter]),
    ?assertEqual({ok, 3}, ReadResult),
    lager:info("Done append in Node1"),

    %% Kill a node
    lager:info("Killing node ~w", [Node1]),
    timer:sleep(5000),
    rt:brutal_kill(Node1),

    %% Be sure the other DC works while the node is down
    WriteResult3a = rpc:call(Node2,
                            antidote, append,
                            [Key1, riak_dt_gcounter, {increment, ucl3}]),
    ?assertMatch({ok, _}, WriteResult3a),
    {ok,{_,_,CommitTime3a}}=WriteResult3a,
    ReadResult3a = rpc:call(Node2, antidote, read,
                          [Key1, riak_dt_gcounter]),
    ?assertEqual({ok, 4}, ReadResult3a),

    ReadResult3b = rpc:call(Node3,
                           antidote, clocksi_read,
                           [CommitTime3a, Key1, riak_dt_gcounter]),
    {ok, {_,[ReadSet3b],_} }= ReadResult3b,
    ?assertEqual(4, ReadSet3b),

    %% Start the node back up and be sure everything works
    lager:info("Restarting node ~w", [Node1]),
    rt:start_and_wait(Node1),
    rt:wait_until_ring_converged(Cluster1),
    lager:info("Waiting until vnodes are restarted"),
    rt:wait_until(Node1, fun wait_init:check_ready/1),
    timer:sleep(10000),

    ReadResult2a = rpc:call(Node1,
                           antidote, clocksi_read,
                           [CommitTime3a, Key1, riak_dt_gcounter]),
    {ok, {_,[ReadSet1a],_} }= ReadResult2a,
    ?assertEqual(4, ReadSet1a),
    lager:info("Done Read in Node3"),

    ReadResult2 = rpc:call(Node3,
                           antidote, clocksi_read,
                           [CommitTime3a, Key1, riak_dt_gcounter]),
    {ok, {_,[ReadSet1],_} }= ReadResult2,
    ?assertEqual(4, ReadSet1),
    lager:info("Done Read in Node3"),
    ReadResult3 = rpc:call(Node2,
                           antidote, clocksi_read,
                           [CommitTime3a, Key1, riak_dt_gcounter]),
    {ok, {_,[ReadSet2],_} }= ReadResult3,
    ?assertEqual(4, ReadSet2),

    lager:info("Done first round of read, I am gonna append"),
    WriteResult4= rpc:call(Node2,
                           antidote, clocksi_bulk_update,
                           [ CommitTime,
                             [{update, {Key1, riak_dt_gcounter, {increment, ucl4}}}]]),
    ?assertMatch({ok, _}, WriteResult4),
    {ok,{_,_,CommitTime2}}=WriteResult4,
    lager:info("Done append in Node2"),
    WriteResult5= rpc:call(Node3,
                           antidote, clocksi_bulk_update,
                           [CommitTime2,
                            [{update, {Key1, riak_dt_gcounter, {increment, ucl5}}}]]),
    ?assertMatch({ok, _}, WriteResult5),
    {ok,{_,_,CommitTime3}}=WriteResult5,
    lager:info("Done append in Node3"),
    lager:info("Done waiting, I am gonna read"),

    SnapshotTime =
        CommitTime3,
    ReadResult4 = rpc:call(Node1,
                           antidote, clocksi_read,
                           [SnapshotTime, Key1, riak_dt_gcounter]),
    {ok, {_,[ReadSet4],_} }= ReadResult4,
    ?assertEqual(6, ReadSet4),
    lager:info("Done read in Node1"),
    ReadResult5 = rpc:call(Node2,
                           antidote, clocksi_read,
                           [SnapshotTime,Key1, riak_dt_gcounter]),
    {ok, {_,[ReadSet5],_} }= ReadResult5,
    ?assertEqual(6, ReadSet5),
    lager:info("Done read in Node2"),
    ReadResult6 = rpc:call(Node3,
                           antidote, clocksi_read,
                           [SnapshotTime,Key1, riak_dt_gcounter]),
    {ok, {_,[ReadSet6],_} }= ReadResult6,
    ?assertEqual(6, ReadSet6),
    pass.















parallel_writes_test(Cluster1, Cluster2, Cluster3) ->
    Node1 = hd(Cluster1),
    Node2 = hd(Cluster2),
    Node3 = hd(Cluster3),
    Key = parallel_writes_test,
    Pid = self(),
    %% WriteFun = fun(A,B,C,D) ->
    %%                    multiple_writes(A,B,C,D)
    %%            end,
    spawn(?MODULE, multiple_writes,[Node1,Key, node1, Pid]),
    spawn(?MODULE, multiple_writes,[Node2,Key, node2, Pid]),
    spawn(?MODULE, multiple_writes,[Node3,Key, node3, Pid]),
    Result = receive
        {ok, CT1} ->
            receive
                {ok, CT2} ->
                receive
                    {ok, CT3} ->
                        Time = dict:merge(fun(_K, T1,T2) ->
                                                  max(T1,T2)
                                          end,
                                          CT3, dict:merge(
                                                 fun(_K, T1,T2) ->
                                                         max(T1,T2)
                                                 end,
                                                 CT1, CT2)),
                        ReadResult1 = rpc:call(Node1,
                           antidote, clocksi_read,
                           [Time, Key, riak_dt_gcounter]),
                        {ok, {_,[ReadSet1],_} }= ReadResult1,
                        ?assertEqual(15, ReadSet1),
                        ReadResult2 = rpc:call(Node2,
                           antidote, clocksi_read,
                           [Time, Key, riak_dt_gcounter]),
                        {ok, {_,[ReadSet2],_} }= ReadResult2,
                        ?assertEqual(15, ReadSet2),
                        ReadResult3 = rpc:call(Node3,
                           antidote, clocksi_read,
                           [Time, Key, riak_dt_gcounter]),
                        {ok, {_,[ReadSet3],_} }= ReadResult3,
                        ?assertEqual(15, ReadSet3),
                        lager:info("Parallel reads passed"),
                        pass
                    end
            end
    end,
    ?assertEqual(Result, pass),
    pass.

multiple_writes(Node, Key, Actor, ReplyTo) ->
    WriteResult1 = rpc:call(Node,
                            antidote, append,
                            [Key, riak_dt_gcounter, {increment, list_to_atom(atom_to_list(Actor) ++ atom_to_list(ucl6))}]),
    ?assertMatch({ok, _}, WriteResult1),
    WriteResult2 = rpc:call(Node,
                            antidote, append,
                            [Key, riak_dt_gcounter, {increment, list_to_atom(atom_to_list(Actor) ++ atom_to_list(ucl7))}]),
    ?assertMatch({ok, _}, WriteResult2),
    WriteResult3 = rpc:call(Node,
                            antidote, append,
                            [Key, riak_dt_gcounter, {increment, list_to_atom(atom_to_list(Actor) ++ atom_to_list(ucl8))}]),
    ?assertMatch({ok, _}, WriteResult3),
    WriteResult4 = rpc:call(Node,
                            antidote, append,
                            [Key, riak_dt_gcounter, {increment, list_to_atom(atom_to_list(Actor) ++ atom_to_list(ucl9))}]),
    ?assertMatch({ok, _}, WriteResult4),
    WriteResult5 = rpc:call(Node,
                            antidote, append,
                            [Key, riak_dt_gcounter, {increment, list_to_atom(atom_to_list(Actor) ++ atom_to_list(ucl10))}]),
    ?assertMatch({ok, _}, WriteResult5),
    {ok,{_,_,CommitTime}}=WriteResult5,
    ReplyTo ! {ok, CommitTime}.

%% Test: when a DC is disconnected for a while and connected back it should
%%  be able to read the missing updates. This should not affect the causal 
%%  dependency protocol
failure_test(Cluster1, Cluster2, Cluster3) ->
    Node1 = hd(Cluster1),
    Node2 = hd(Cluster2),
    Node3 = hd(Cluster3),
    Key = failure_test,
    WriteResult1 = rpc:call(Node1,
                            antidote, append,
                            [Key, riak_dt_gcounter, {increment, ucl11}]),
    ?assertMatch({ok, _}, WriteResult1),

    %% Simulate failure of NODE3 by stoping the receiver
    {ok, D1} = rpc:call(Node1, inter_dc_manager, get_descriptor, []),
    {ok, D2} = rpc:call(Node2, inter_dc_manager, get_descriptor, []),

    ok = rpc:call(Node3, inter_dc_manager, forget_dcs, [[D1, D2]]),

    WriteResult2 = rpc:call(Node1,
                            antidote, append,
                            [Key, riak_dt_gcounter, {increment, ucl12}]),
    ?assertMatch({ok, _}, WriteResult2),
    %% Induce some delay
    rpc:call(Node3, antidote, read,
             [Key, riak_dt_gcounter]),

    WriteResult3 = rpc:call(Node1,
                            antidote, append,
                            [Key, riak_dt_gcounter, {increment, ucl13}]),
    ?assertMatch({ok, _}, WriteResult3),
    {ok,{_,_,CommitTime}}=WriteResult3,
    ReadResult = rpc:call(Node1, antidote, read,
                          [Key, riak_dt_gcounter]),
    ?assertEqual({ok, 3}, ReadResult),
    lager:info("Done append in Node1"),

    %% NODE3 comes back
    [ok, ok] = rpc:call(Node3, inter_dc_manager, observe_dcs, [[D1, D2]]),

    ReadResult3 = rpc:call(Node2,
                           antidote, clocksi_read,
                           [CommitTime, Key, riak_dt_gcounter]),
    {ok, {_,[ReadSet2],_} }= ReadResult3,
    ?assertEqual(3, ReadSet2),
    lager:info("Done read from Node2"),
    ReadResult2 = rpc:call(Node3,
                           antidote, clocksi_read,
                           [CommitTime, Key, riak_dt_gcounter]),
    {ok, {_,[ReadSet1],_} }= ReadResult2,
    ?assertEqual(3, ReadSet1),
    lager:info("Done Read in Node3"),
    pass.
   
