%%%% Copyright (C) 2005-2008 Wager Labs, SA
%%%%
%%%% THE WORK (AS DEFINED BELOW) IS PROVIDED UNDER THE TERMS OF THIS 
%%%% CREATIVE COMMONS PUBLIC LICENSE ("CCPL" OR "LICENSE"). THE WORK IS 
%%%% PROTECTED BY COPYRIGHT AND/OR OTHER APPLICABLE LAW. ANY USE OF 
%%%% THE WORK OTHER THAN AS AUTHORIZED UNDER THIS LICENSE OR COPYRIGHT 
%%%% LAW IS PROHIBITED.
%%%%
%%%% BY EXERCISING ANY RIGHTS TO THE WORK PROVIDED HERE, YOU ACCEPT 
%%%% AND AGREE TO BE BOUND BY THE TERMS OF THIS LICENSE. TO THE EXTENT 
%%%% THIS LICENSE MAY BE CONSIDERED TO BE A CONTRACT, THE LICENSOR GRANTS 
%%%% YOU THE RIGHTS CONTAINED HERE IN CONSIDERATION OF YOUR ACCEPTANCE 
%%%% OF SUCH TERMS AND CONDITIONS.
%%%%
%%%% Please see LICENSE for full legal details and the following URL
%%%% for a human-readable explanation:
%%%%
%%%% http://creativecommons.org/licenses/by-nc-sa/3.0/us/
%%%%

-module(bits).
-export([bits0/1, bits1/1, log2/1, tzb0/1, tzb1/1, clear_extra_bits/2]).

%%% Courtesy of Mark Scandariato

%% number of bits set
%% bits0 works on arbitrary integers.

bits0(N) when N >= 0-> bits0(N, 0).
bits0(0, C) -> C;
bits0(N, C) ->
    bits0((N band (N-1)), C+1).

clear_extra_bits(N, _) when N =:= 0 ->
    N;

%% only keep X numbers of 1.
clear_extra_bits(N, X) ->
    C = bits0(N),
    if 
        X >= C ->
            N;
        true ->
            clear_extra_bits(N, X, C)
    end.

clear_extra_bits(N, X, C) when N =:= 0; C =:= 0; X =:= C ->
    N;
clear_extra_bits(N, X, C) ->
    clear_extra_bits(N band (N - 1), X, C - 1).

%% haveing count of 1 in the binary string
bits1(0) -> 0;
bits1(N) when N > 0, N < 16#100000000 ->
    bits1(N, [1,   16#55555555,
              2,   16#33333333,
              4,   16#0F0F0F0F,
              8,   16#00FF00FF,
              16, 16#0000FFFF]).

bits1(N, []) -> N;
bits1(N, [S, B|Magic]) ->
    bits1(((N bsr S) band B) + (N band B), Magic).


%% log2, aka, position of the high bit

log2(N) when N > 0, N < 16#100000000 ->
    log2(N, 0, [16, 16#FFFF0000, 8, 16#FF00, 4, 16#F0, 2, 16#C, 1, 16#2]).

log2(_, C, []) -> C;
log2(N, C, [S,B|Magic]) ->
    if (N band B) == 0 -> log2(N, C, Magic);
       true -> log2((N bsr S), (C bor S), Magic)
    end.

%% trailing zero bits, aka position of the lowest set bit.

tzb0(N) when N > 0, N < 16#100000000 ->
    tzb0(N, 32, [16, 16#0000FFFF,
                 8, 16#00FF00FF,
                 4, 16#0F0F0F0F,
                 2, 16#33333333,
                 1, 16#55555555]).

tzb0(_, Z, []) -> Z-1;
tzb0(N, Z, [S, B|Magic]) ->
    if (N band B) == 0 -> tzb0(N, Z, Magic);
       true -> tzb0((N bsl S), (Z - S), Magic)
    end.

tzb1(N) when N > 0,  N < 16#100000000 ->
    Mod = {32,0,1,26,2,23,27,0,3,16,24,30,
           28,11,0,13,4,7,17,0,25,22,31,15,
           29,10,12,6,0,21,14,9,5,20,8,19,18},
    P = (-N band N) rem 37,
    element(P+1, Mod).
