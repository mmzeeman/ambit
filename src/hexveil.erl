%% @doc HexVeil - An aperture-3 hierarchical location encoding.
%%
%% This implementation uses an Aperture 3 hierarchy (Area x 3 per level)
%% with a 30-degree rotation at each step.
%%
%% Characteristics:
%% - Pointy-top hexagons.
%% - Aperture 3 (1 parent surrounds 3 children).
%% - Scale factor: sqrt(3) per level.
%% - Rotation: 30 degrees per level.
%% - Cell sizes (Flat-to-flat width):
%%   - Level 40: ~2.4m   (High Precision)
%%   - Level 32: ~194m  (Privacy Level 1: ~150m-200m range)
%%   - Level 31: ~336m  (Privacy Level 2: ~300m range)
%%   - Level 30: ~583m  (Privacy Level 3: ~600m range)
%%   - Level 1:  ~2,332km (Global)
%%
%% Coordinate system uses matrix M = [ 2 1 ; -1 1 ] for the hierarchy.

-module(hexveil).

-export([
    encode/2,
    decode/1,
    coarsen/2,
    neighbors/1,
    to_axial/1,
    from_axial/3,
    cell_geometry/1,
    display/1,
    parse/1
]).

-define(MAX_LEVEL, 40).
-define(R, 1.3856406).      %% Side length for 2.4m width
-define(BQ_X, 2.4).         %% Distance between centers (X)
-define(BR_X, 1.2).         %% X offset for R
-define(BR_Y, 2.0784609).   %% Distance between centers (Y)
-define(M_PER_DEG_LAT, 111319.49).

%% Offset to bring Earth into the domain of root {0, -1}.
-define(Q_OFF, 1000000000).
-define(R_OFF, 1000000000).
-define(DIRECTIONS, [{1,0},{0,1},{-1,1},{-1,0},{0,-1},{1,-1}]).

%%
%% API
%%

%% @doc Encode Lat/Lon to a hierarchical ternary code.
encode(Lat, Lon) ->
    {X, Y}   = latlon_to_xy(Lat, Lon),
    {Qf, Rf} = xy_to_axial(X, Y),
    {Q,  R}  = hex_round(Qf, Rf),
    extract_digits(Q + ?Q_OFF, R + ?R_OFF, ?MAX_LEVEL, <<>>).

%% @doc Decode a list of digits to {Lat, Lon} center.
decode(Digits) ->
    {Q, R} = digits_to_axial(Digits),
    %% Scale to the coordinate system of MAX_LEVEL.
    {SQ, SR} = scale_up(Q - 1/3, R + 2/3, ?MAX_LEVEL - byte_size(Digits)),
    {X, Y} = axial_to_xy(SQ - ?Q_OFF, SR - ?R_OFF),
    xy_to_latlon(X, Y).

scale_up(Q, R, 0) -> {Q, R};
scale_up(Q, R, L) when L > 0 ->
    scale_up(2*Q + R, -Q + R, L-1).

coarsen(Digits, Level) ->
    binary:part(Digits, 0, Level).

neighbors(Digits) ->
    {Q, R} = digits_to_axial(Digits),
    [extract_digits(Q + DQ, R + DR, byte_size(Digits), <<>>) || {DQ, DR} <- ?DIRECTIONS].

%% @doc Convert digits to axial coordinates (relative to Null Island).
to_axial(Digits) ->
    {Q, R} = digits_to_axial(Digits),
    {Q - ?Q_OFF, R - ?R_OFF}.

%% @doc Convert axial coordinates (relative to Null Island) to digits.
from_axial(Q, R, Level) ->
    extract_digits(Q + ?Q_OFF, R + ?R_OFF, Level, <<>>).

cell_geometry(Digits) ->
    Level = byte_size(Digits),
    Diff = ?MAX_LEVEL - Level,
    {Q, R} = digits_to_axial(Digits),
    {SQ, SR} = scale_up(Q - 1/3, R + 2/3, Diff),
    {CX, CY} = axial_to_xy(SQ - ?Q_OFF, SR - ?R_OFF),
    Radius = ?R * math:pow(math:sqrt(3), Diff),
    Rotation = Diff * (-30),
    Angles = [30, 90, 150, 210, 270, 330],
    [xy_to_latlon(
        CX + Radius * math:cos((A + Rotation) * math:pi() / 180),
        CY + Radius * math:sin((A + Rotation) * math:pi() / 180)
     ) || A <- Angles].

display(Digits) ->
    group_base27(<<Digits/binary, 1>>, <<>>).

parse(Binary) ->
    strip_sentinel(ungroup_base27(Binary, <<>>)).

strip_sentinel(Binary) ->
    strip_sentinel(Binary, byte_size(Binary) - 1).

strip_sentinel(Binary, Pos) ->
    case binary:at(Binary, Pos) of
        1 -> binary:part(Binary, 0, Pos);
        0 -> strip_sentinel(Binary, Pos - 1)
    end.

group_base27(<<D1, D2, D3, Rest/binary>>, Acc) ->
    group_base27(Rest, <<Acc/binary, (to_b27(D1*9 + D2*3 + D3))>>);
group_base27(<<D1, D2>>, Acc) ->
    <<Acc/binary, (to_b27(D1*9 + D2*3))>>;
group_base27(<<D1>>, Acc) ->
    <<Acc/binary, (to_b27(D1*9))>>;
group_base27(<<>>, Acc) ->
    Acc.

ungroup_base27(<<Char, Rest/binary>>, Acc) ->
    Val = from_b27(Char),
    ungroup_base27(Rest, <<Acc/binary, (Val div 9), ((Val rem 9) div 3), (Val rem 3)>>);
ungroup_base27(<<>>, Acc) ->
    Acc.

to_b27(V) when V < 10 -> $0 + V;
to_b27(V) -> $a + V - 10.

from_b27(C) when C >= $0, C =< $9 -> C - $0;
from_b27(C) -> C - $a + 10.

%%
%% Helpers: Hierarchy
%%

extract_digits(_Q, _R, 0, Acc) -> Acc;
extract_digits(Q, R, L, Acc) ->
    Digit = mod3(Q - R),
    {DQ, DR} = offset(Digit),
    NQ = Q - DQ,
    NR = R - DR,
    PQ = (NQ - NR) div 3,
    PR = (NQ + 2*NR) div 3,
    extract_digits(PQ, PR, L-1, <<Digit, Acc/binary>>).

digits_to_axial(Digits) ->
    digits_to_axial(Digits, {0, -1}).

digits_to_axial(<<Digit, Rest/binary>>, {Q, R}) ->
    {DQ, DR} = offset(Digit),
    digits_to_axial(Rest, {2*Q + R + DQ, -Q + R + DR});
digits_to_axial(<<>>, Acc) ->
    Acc.

offset(0) -> {0, 0};
offset(1) -> {1, 0};
offset(2) -> {0, 1}.

mod3(X) when X >= 0 -> X rem 3;
mod3(X) when X < 0 -> ((X rem 3) + 3) rem 3.

%%
%% Helpers: Geometry
%%

latlon_to_xy(Lat, Lon) ->
    CosLat = math:cos(Lat * math:pi() / 180.0),
    {Lon * ?M_PER_DEG_LAT * CosLat, Lat * ?M_PER_DEG_LAT}.

xy_to_latlon(X, Y) ->
    Lat = Y / ?M_PER_DEG_LAT,
    CosLat = math:cos(Lat * math:pi() / 180.0),
    {Lat, X / (?M_PER_DEG_LAT * CosLat)}.

xy_to_axial(X, Y) ->
    Rf = Y / ?BR_Y,
    Qf = (X - ?BR_X * Rf) / ?BQ_X,
    {Qf, Rf}.

axial_to_xy(Q, R) ->
    {?BQ_X * Q + ?BR_X * R, ?BR_Y * R}.

hex_round(Qf, Rf) ->
    Sf = -Qf - Rf,
    Rq = round(Qf), Rr = round(Rf), Rs = round(Sf),
    Dq = abs(Rq - Qf), Dr = abs(Rr - Rf), Ds = abs(Rs - Sf),
    if
        Dq > Dr andalso Dq > Ds ->
            {-Rr - Rs, Rr};
        Dr > Ds ->
            {Rq, -Rq - Rs};
        true ->
            {Rq, Rr}
    end.
