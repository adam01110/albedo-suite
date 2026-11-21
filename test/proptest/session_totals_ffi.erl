-module(session_totals_ffi).
-export([runtime/1, connection/0]).

%% A registry host standing in for a started runtime: the HTTP handlers on the
%% non-watch path read only the ledger, which sits at this position.
runtime(Ledger) -> {runtime, undefined, Ledger, undefined, undefined}.

%% A request body the non-watch path never opens.
connection() -> {connection, undefined, undefined, undefined, undefined}.
