%% @doc GeoHex - A privacy-preserving hierarchical location encoding
%% system using a flat hexagonal grid with axial (q, r) coordinates.
%%
%% Optimized for "Human Scale" landmarks (~2.4m) and "Smooth Privacy" steps.
%% This implementation uses 24 levels of precision.
%%
%% Each level is exactly 2 times coarser (linearly) than the one below it.
%% This is an Aperture 4 hierarchy (Area x 4 per level). No rotation.

-module(geohex).

-export([
    encode/2,
    decode/1,
    are_nearby/3,
    coarsen/2,
    neighbors/1,
    cell_bounds/1,
    display/1,
    display/2,
    parse/1
]).

-type code()  :: {non_neg_integer(), non_neg_integer()}.
-type level() :: 1..24.
-export_type([code/0, level/0]).

%% ---------------------------------------------------------------------------
%% Constants
%% ---------------------------------------------------------------------------

-define(MAX_LEVEL, 24).
-define(R, 1.385641).
-define(BQ_X, 2.4).
-define(BR_X, 1.2).
-define(BR_Y, 2.078461).
-define(REF_LAT,  0.0).
-define(REF_LON,  0.0).
-define(M_PER_DEG_LAT, 111319.49).
-define(M_PER_DEG_LON, 111319.49).

%% Use an offset of 2^24 to ensure bits align perfectly with Level 24.
-define(Q_OFF, 16777216).
-define(R_OFF, 16777216).
-define(DIRECTIONS, [{1,0},{0,1},{-1,1},{-1,0},{0,-1},{1,-1}]).

%% ---------------------------------------------------------------------------
%% Public API
%% ---------------------------------------------------------------------------

encode(Lat, Lon) ->
    {X, Y}   = latlon_to_xy(Lat, Lon),
    {Qf, Rf} = xy_to_axial(X, Y),
    {Q,  R}  = hex_round(Qf, Rf),
    {Q + ?Q_OFF, R + ?R_OFF}.

decode({Q, R}) ->
    {X, Y} = axial_to_xy(Q - ?Q_OFF + 0.5, R - ?R_OFF + 0.5),
    xy_to_latlon(X, Y).

are_nearby({Q1, R1}, {Q2, R2}, Level) ->
    Shift = ?MAX_LEVEL - Level,
    Q1 bsr Shift =:= Q2 bsr Shift andalso
    R1 bsr Shift =:= R2 bsr Shift.

coarsen({Q, R}, Level) ->
    Shift = ?MAX_LEVEL - Level,
    {Q bsr Shift, R bsr Shift}.

neighbors({Q, R}) ->
    [{Q + DQ, R + DR} || {DQ, DR} <- ?DIRECTIONS].

cell_bounds(Code) ->
    {CLat, CLon} = decode(Code),
    Half    = 1.2,
    HalfLat = Half / ?M_PER_DEG_LAT,
    HalfLon = Half / ?M_PER_DEG_LON,
    {CLat - HalfLat, CLon - HalfLon,
     CLat + HalfLat, CLon + HalfLon}.

display(Code) -> display(Code, ?MAX_LEVEL).

display({Q, R}, Level) ->
    %% Force Q and R into 25-bit bitstrings (2^24 + offset).
    MasterBits = interleave_canonical(<<Q:25>>, <<R:25>>, <<>>),
    Required = Level * 2,
    %% Skip the top bits of the offset (first 2 bits of the 25-bit string).
    <<_OffsetBits:2, Body:Required/bits, _/bits>> = MasterBits,
    bits_to_hex(Body, <<>>).

parse(S) ->
    Bits = hex_to_bits_canonical(S, <<>>),
    Level = bit_size(Bits) div 2,
    {Qp, Rp} = deinterleave_canonical(Bits, 0, 0),
    %% Re-apply the offset correctly for Level L.
    OffShift = ?MAX_LEVEL - Level,
    Q_Off_L = ?Q_OFF bsr OffShift,
    R_Off_L = ?R_OFF bsr OffShift,
    Shift = ?MAX_LEVEL - Level,
    {(Qp + Q_Off_L) bsl Shift, (Rp + R_Off_L) bsl Shift}.

%% ---------------------------------------------------------------------------
%% Canonical Bit Manipulation (internal)
%% ---------------------------------------------------------------------------

interleave_canonical(<<Q:1, QRest/bits>>, <<R:1, RRest/bits>>, Acc) ->
    interleave_canonical(QRest, RRest, <<Acc/bits, Q:1, R:1>>);
interleave_canonical(<<>>, <<>>, Acc) -> Acc.

bits_to_hex(<<V:4, Rest/bits>>, Acc) ->
    bits_to_hex(Rest, <<Acc/binary, (hex_char(V))/binary>>);
bits_to_hex(<<V:2, Rest/bits>>, Acc) ->
    bits_to_hex(Rest, <<Acc/binary, (hex_char(V))/binary>>);
bits_to_hex(<<>>, Acc) -> Acc.

hex_char(V) when V < 10 -> <<($0 + V)>>;
hex_char(V) -> <<($A + V - 10)>>.

hex_to_bits_canonical(<<C:1/binary, Rest/binary>>, Acc) when byte_size(Rest) > 0 ->
    Val = hex_val(C),
    hex_to_bits_canonical(Rest, <<Acc/bits, Val:4>>);
hex_to_bits_canonical(<<C:1/binary>>, Acc) ->
    Val = hex_val(C),
    if Val > 3 -> <<Acc/bits, Val:4>>;
       true    -> <<Acc/bits, Val:2>>
    end;
hex_to_bits_canonical(<<>>, Acc) -> Acc.

hex_val(<<C>>) when C >= $0, C =< $9 -> C - $0;
hex_val(<<C>>) when C >= $A, C =< $F -> C - $A + 10;
hex_val(<<C>>) when C >= $a, C =< $f -> C - $a + 10.

deinterleave_canonical(<<Q:1, R:1, Rest/bits>>, QAcc, RAcc) ->
    deinterleave_canonical(Rest, (QAcc bsl 1) bor Q, (RAcc bsl 1) bor R);
deinterleave_canonical(<<>>, QAcc, RAcc) ->
    {QAcc, RAcc}.

%% ---------------------------------------------------------------------------
%% Geometry (internal)
%% ---------------------------------------------------------------------------

latlon_to_xy(Lat, Lon) ->
    {(Lon - ?REF_LON) * ?M_PER_DEG_LON,
     (Lat - ?REF_LAT) * ?M_PER_DEG_LAT}.

xy_to_latlon(X, Y) ->
    {?REF_LAT + Y / ?M_PER_DEG_LAT,
     ?REF_LON + X / ?M_PER_DEG_LON}.

xy_to_axial(X, Y) ->
    Rf = Y / (1.5 * ?R),
    Qf = (X - ?BR_X * Rf) / ?BQ_X,
    {Qf, Rf}.

axial_to_xy(Q, R) ->
    {?BQ_X * Q + ?BR_X * R,
     ?BR_Y * R}.

hex_round(Qf, Rf) ->
    Sf = -Qf - Rf,
    Rq = round(Qf), Rr = round(Rf), Rs = round(Sf),
    Dq = abs(Rq - Qf), Dr = abs(Rr - Rf), Ds = abs(Rs - Sf),
    if
        Dq > Dr andalso Dq > Ds -> {-Rr - Rs, Rr};
        Dr > Ds                  -> {Rq, -Rq - Rs};
        true                     -> {Rq, Rr}
    end.
