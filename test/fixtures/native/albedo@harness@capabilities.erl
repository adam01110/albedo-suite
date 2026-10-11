-module('albedo@harness@capabilities').
-export([load/2, enabled/3]).

load(_, _) -> {ok, nil}.
enabled(_, _, Name) -> {ok, Name =/= <<"blocked">>}.
