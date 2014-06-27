-define(PRINT(Var),
        io:format("DEBUG: ~p:~p - ~p~n~n ~p~n~n", [?MODULE, ?LINE, ??Var, Var])).
-define(BUCKET, <<"floppy">>).
-define(LOGGINGMASTER, logging_vnode_master).
-define(CLOCKSIMASTER, clockSI_vnode_master).
-define(CLOCKSI, clockSI).
-define(REPMASTER, floppy_rep_vnode_master).
-define(INDC_TIMEOUT, 1000).
-define(N, 3).
-define(NUM_W, 2).
-define(NUM_R, 2).
-define(OTHER_DC, 'floppy1@127.0.0.1').

% Used by the replication layer
-record(operation, {op_number, payload}).

% The way records are stored in the log.
-record(log_record, {tx_id, op_type::atom(), op_payload}).


% Clock SI

% MIN is Used for generating the timeStamp of a new snapshot
% in the case that a client has already seen a snapshot time
% greater than the current time at the replica it is starting
% a new transaction.
-define(MIN, 1).

% DELTA has the same meaning as in the clock-SI paper.
-define(DELTA, 10000). 

-define(CLOCKSI_TIMEOUT, 1000).

%%---------------------------------------------------------------------
%% Data Type: tx
%% where:
%%    snapshot_time: clock time of the tx's originating partition as returned by now().
%%    commit_time: final commit time of the tx.
%%    prepare_time: intermediate prepare-commit tx time.
%%    state: the state of the transaction, {active|prepare|committing|committed}. 
%%	  write_set: the tx's write set.
%%	  origin: the transaction's originating partition
%%----------------------------------------------------------------------

%% -record(tx, {id, snapshot_time, commit_time, prepare_time, state, origin}).
-record(tx_id, {snapshot_time, server_pid}).
-record(clocksi_payload, {key, type, op_param, actor, snapshot_time, commit_time, txid}).
-record(transaction, {snapshot_time, server_pid, vec_snapshot_time, txn_id}).

