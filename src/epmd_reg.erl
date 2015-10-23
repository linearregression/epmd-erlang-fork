%%
%% %CopyrightBegin%
%% 
%% Copyright Peer Stritzinger GmbH 2013-2015. All Rights Reserved.
%% 
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%% 
%% %CopyrightEnd%
%%
%%

-module(epmd_reg).
-behaviour(gen_server).

-export([start_link/0, node_reg/7, lookup/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, 
	 code_change/3, terminate/2]).

-record(state, {reg, unreg, unreg_count}).

-record(node, {symname, port, nodetype, protocol, highvsn, lowvsn, extra,
	       creation, monref}).

-define(max_unreg_count, 1000).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

node_reg(Name, Port, Nodetype, Protocol, Highvsn, Lowvsn, Extra) ->
    gen_server:call(?MODULE, {node_reg, Name, Port, Nodetype, 
			      Protocol, Highvsn, Lowvsn, Extra, self()}).

lookup(Name) ->
    gen_server:call(?MODULE, {lookup, Name}).

init([]) ->
    {ok, #state{reg=[], unreg=[], unreg_count=0}}.

handle_call({node_reg, Name, Port, Nodetype, Protocol, Highvsn, Lowvsn, 
	     Extra, Srv_pid}, _From, 
	    #state{reg=Reg, unreg=Unreg, unreg_count=Uc}=State) ->
    case lists:keyfind(Name, #node.symname, Reg) of
	#node{} -> {reply, {error, name_occupied}, State};
	false ->
	    Mref = monitor(process, Srv_pid),
	    %% if the following doesn't make sense: I'm just trying to emulate
	    %% what the original epmd does 
	    case lists:keytake(Name, #node.symname, Unreg) of
		{value, #node{creation=Cr}, New_unreg} -> 
		    Creation = (Cr rem 3) + 1,
		    New_unreg_count = Uc-1;
		false -> 
		    Creation = (time_seconds() rem 3) + 1,
		    New_unreg = Unreg,
		    New_unreg_count = Uc
	    end,
	    Node = #node{symname=Name, port=Port, nodetype=Nodetype,
			 protocol=Protocol, highvsn=Highvsn, lowvsn=Lowvsn,
			 extra=Extra, creation=Creation, monref=Mref},
	    {reply, {ok, Creation}, 
	     State#state{reg=[Node|Reg], 
			 unreg=New_unreg, unreg_count=New_unreg_count}}
    end;
handle_call({lookup, Name}, _From, #state{reg=Reg}=State) ->
    case lists:keyfind(Name, #node.symname, Reg) of
	#node{symname=Name, port=Port, nodetype=Nodetype,
	      protocol=Protocol, highvsn=Highvsn, lowvsn=Lowvsn,
	      extra=Extra} -> 
	    {reply, {ok, Name, Port, Nodetype, Protocol, 
		     Highvsn, Lowvsn, Extra}, State};
	false ->
	    {reply, {error, notfound}, State}
    end.

handle_cast(_, State) ->
    {noreply, State}.

handle_info({'DOWN', Mref, _, _, _}, 
	    #state{reg=Reg, unreg=Unreg, unreg_count=Uc}=State) 
  when Uc < 2*?max_unreg_count ->
    {value, Node, New_reg} = lists:keytake(Mref, #node.monref, Reg),
    {noreply, State#state{reg=New_reg, unreg=[Node|Unreg], 
			  unreg_count=Uc+1}};
handle_info({'DOWN', Mref, _, _, _}, 
	    #state{reg=Reg, unreg=Unreg, unreg_count=Uc}=State) 
  when Uc =:= 2*?max_unreg_count ->
    {value, Node, New_reg} = lists:keytake(Mref, #node.monref, Reg),
    {Ur, _} = lists:split(?max_unreg_count, Unreg),
    {noreply, State#state{reg=New_reg, unreg=[Node|Ur], 
			  unreg_count=?max_unreg_count+1}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

time_seconds() ->
    {_, Sec, _} = os:timestamp(),
    Sec.

