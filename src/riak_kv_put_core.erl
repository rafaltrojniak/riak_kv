%% -------------------------------------------------------------------
%%
%% riak_kv_put_core: Riak put logic
%%
%% Copyright (c) 2007-2010 Basho Technologies, Inc.  All Rights Reserved.
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
-module(riak_kv_put_core).
-export([init/7, coord_idx/2, add_result/2, enough/1, response/1, 
         final/1]).
-export([coord_result/2]).%% DEBUG
-export_type([putcore/0, result/0, reply/0]).

-type vput_result() :: any().

-type result() :: w |
                  {dw, undefined} |
                  {dw, riak_object:riak_object()} |
                  {error, any()}.

-type reply() :: ok | 
                 {ok, riak_object:riak_object()} |
                 {error, notfound} |
                 {error, any()}.
-type idxresult() :: {non_neg_integer(), result()}.
-record(putcore, {n :: pos_integer(),
                  w :: non_neg_integer(),
                  dw :: non_neg_integer(),
                  w_fail_threshold :: pos_integer(),
                  dw_fail_threshold :: pos_integer(),
                  returnbody :: boolean(),
                  allowmult :: boolean(),
                  coord_idx :: non_neg_integer(),
                  results = [] :: [idxresult()],
                  final_obj :: undefined | riak_object:riak_object(),
                  num_w = 0 :: non_neg_integer(),
                  num_dw = 0 :: non_neg_integer(),
                  num_fail = 0 :: non_neg_integer()}).
-opaque putcore() :: #putcore{}.

%% ====================================================================
%% Public API
%% ====================================================================

%% Initialize a put and return an opaque put core context
-spec init(pos_integer(), non_neg_integer(), non_neg_integer(), 
           pos_integer(), pos_integer(), boolean(), boolean()) -> putcore().
init(N, W, DW, WFailThreshold, DWFailThreshold, AllowMult, ReturnBody) ->
    #putcore{n = N, w = W, dw = DW,
             w_fail_threshold = WFailThreshold,
             dw_fail_threshold = DWFailThreshold,
             allowmult = AllowMult,
             returnbody = ReturnBody}.

coord_idx(Idx, PutCore) ->
    PutCore#putcore{coord_idx = Idx}.
   
%% Add a result from the vnode
-spec add_result(vput_result(), putcore()) -> putcore().
add_result({w, Idx, _ReqId}, PutCore = #putcore{results = Results,
                                                num_w = NumW}) ->
    PutCore#putcore{results = [{Idx, w} | Results],
                    num_w = NumW + 1};
add_result({dw, Idx, _ReqId}, PutCore = #putcore{results = Results,
                                                 num_dw = NumDW}) ->
    PutCore#putcore{results = [{Idx, {dw, undefined}} | Results], 
                    num_dw = NumDW + 1};
add_result({dw, Idx, ResObj, _ReqId}, PutCore = #putcore{results = Results,
                                                         num_dw = NumDW}) ->
    PutCore#putcore{results = [{Idx, {dw, ResObj}} | Results],
                    num_dw = NumDW + 1};
add_result({fail, Idx, _ReqId}, PutCore = #putcore{results = Results,
                                                   num_fail = NumFail}) ->
    PutCore#putcore{results = [{Idx, {error, undefined}} | Results],
                    num_fail = NumFail + 1};
add_result(_Other, PutCore = #putcore{num_fail = NumFail}) ->
    %% Treat unrecognized messages as failures - no index to store them against
    PutCore#putcore{num_fail = NumFail + 1}.

%% Check if enough results have been added to respond 
-spec enough(putcore()) -> boolean().
enough(#putcore{w = W, num_w = NumW, dw = DW, num_dw = NumDW, 
                num_fail = NumFail, w_fail_threshold = WFailThreshold,
                dw_fail_threshold = DWFailThreshold,
                coord_idx = CoordIdx, results = Results}) ->
    (NumW >= W andalso NumDW >= DW andalso coord_result(CoordIdx, Results)) orelse
        (NumW >= W andalso NumFail >= DWFailThreshold) orelse
        (NumW < W andalso NumFail >= WFailThreshold).

%% True if coordinator result has been returned - anything other than w.
coord_result(CoordIdx, Results) ->
    [Result || {Idx, Result} <- Results, Idx == CoordIdx] -- [w] /= [].

%% Get success/fail response once enough results received
-spec response(putcore()) -> {reply(), putcore()}.
response(PutCore = #putcore{w = W, num_w = NumW, dw = DW, num_dw = NumDW,
                            num_fail = NumFail,
                            w_fail_threshold = WFailThreshold,
                            dw_fail_threshold = DWFailThreshold}) ->
    if
        NumW >= W andalso NumDW >= DW ->
            maybe_return_body(PutCore);
        
        NumW >= W andalso NumFail >= DWFailThreshold ->
            {{error, too_many_fails}, PutCore};
        
       NumW < W andalso NumFail >= WFailThreshold ->
            {{error, too_many_fails}, PutCore};
        
        true ->
            {{error, {w_val_unsatisfied, NumW, NumDW, W, DW}}, PutCore}
    end.

%% Get final value - if returnbody did not need the result it allows delaying
%% running reconcile until after the client reply is sent.
-spec final(putcore()) -> {riak_object:riak_object()|undefined, putcore()}.
final(PutCore = #putcore{final_obj = FinalObj, 
                         results = Results, allowmult = AllowMult}) ->
    case FinalObj of
        undefined ->
            RObjs = [RObj || {_Idx, {dw, RObj}} <- Results, RObj /= undefined],
            ReplyObj = case RObjs of
                           [] ->
                               undefined;
                           _ ->
                               riak_object:reconcile(RObjs, AllowMult)
                       end,
            {ReplyObj, PutCore#putcore{final_obj = ReplyObj}};
        _ ->
            {FinalObj, PutCore}
    end.

%% ====================================================================
%% Internal functions
%% ====================================================================
maybe_return_body(PutCore = #putcore{returnbody = false}) ->
    {ok, PutCore};
maybe_return_body(PutCore = #putcore{returnbody = true}) ->
    {ReplyObj, UpdPutCore} = final(PutCore),
    {{ok, ReplyObj}, UpdPutCore}.

