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
%%   Level | Size (approx) | Use Case
%%   ------|---------------|----------------------------
%%   32    | 3.0m          | High Precision / Human Scale
%%   25    | 140.3m        | Privacy Level 1 (~150m)
%%   24    | 243.0m        | Privacy Level 2 (~250m)
%%   23    | 420.9m        | Privacy Level 3 (~500m)
%%   17    | 15.6km        | City Scale
%%   9     | 1,275km       | Continental Scale
%%   1     | 130,000km     | Global Scale
%%
%% Coordinate system uses matrix M = [ 2 1 ; -1 1 ] for the hierarchy.
%%
%% Hierarchical Examples (3.0m base):
%%   Location        | L32 (3m)    | L25 (140m) | L24 (243m) | L17 (15km)
%%   ----------------|-------------|------------|------------|-----------
%%   Vondelpark Ent. | lfdnh79fm8d | lfdnh79fl  | lfdnh79f   | lfdnh7
%%   Leidseplein     | lfdnh79e4d4 | lfdnh79e3  | lfdnh79e   | lfdnh7
%%   Dam Square      | lfdnh7f65l4 | lfdnh7f63  | lfdnh7f6   | lfdnh7
%%   Dom Utrecht     | lfdnig73ogg | lfdnig73l  | lfdnig73   | lfdnig

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

-define(MAX_LEVEL, 32).

-define(BQ_X, 3.0).
-define(BR_X, 1.5).
-define(BR_Y, 2.598076211353316).    %% 1.5 * sqrt(3)
-define(R, 1.7320508075688772).      %% 3.0 / sqrt(3)

%% Offset to bring Earth into the domain of root {1, -2}.
-define(Q_OFF, 20_000_000).
-define(R_OFF, 20_000_000).
-define(ROOT, {1, -2}).
-define(DIRECTIONS, [{1,0},{0,1},{-1,1},{-1,0},{0,-1},{1,-1}]).

%%
%% API
%%

%% @doc Encode Lat/Lon to a hierarchical ternary code.
encode(Lat, Lon) ->
    {X, Y} = latlon_to_xy(Lat, Lon),
    {Qf, Rf} = xy_to_axial(X, Y),
    {Q,  R} = hex_round(Qf, Rf),
    extract_digits(Q + ?Q_OFF, R + ?R_OFF, ?MAX_LEVEL, <<>>).

%% @doc Decode a list of digits to {Lat, Lon} center.
decode(Digits) ->
    {Q, R} = digits_to_axial(Digits),
    Diff = ?MAX_LEVEL - byte_size(Digits),
    %% Using a large multiplier for better precision in integer scale-up
    {SQ, SR} = scale_up_precise(Q, R, Diff),
    {X, Y} = axial_to_xy(SQ - ?Q_OFF, SR - ?R_OFF),
    xy_to_latlon(X, Y).

scale_up_precise(Q, R, 0) ->
    {Q, R};
scale_up_precise(Q, R, L) ->
    scale_up_precise(2*Q + R, -Q + R, L-1).

coarsen(Digits, Level) ->
    binary:part(Digits, 0, Level).

neighbors(Digits) ->
    {Q, R} = digits_to_axial(Digits),
    [extract_digits(Q + DQ, R + DR, byte_size(Digits), <<>>) || {DQ, DR} <- ?DIRECTIONS].

to_axial(Digits) ->
    {Q, R} = digits_to_axial(Digits),
    {Q - ?Q_OFF, R - ?R_OFF}.

from_axial(Q, R, Level) ->
    extract_digits(Q + ?Q_OFF, R + ?R_OFF, Level, <<>>).

cell_geometry(Digits) ->
    Level = byte_size(Digits),
    Diff = ?MAX_LEVEL - Level,
    {Q, R} = digits_to_axial(Digits),
    {SQ, SR} = scale_up_precise(Q, R, Diff),
    {CX, CY} = axial_to_xy(SQ - ?Q_OFF, SR - ?R_OFF),
    Radius = ?R * math:pow(math:sqrt(3), Diff),
    Rotation = Diff * -30,
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
    digits_to_axial(Digits, ?ROOT).

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
    hex_proj_laea:latlon_to_xy(Lat, Lon).

xy_to_latlon(X, Y) ->
    hex_proj_laea:xy_to_latlon(X, Y).

xy_to_axial(X, Y) ->
    Rf = Y / ?BR_Y,
    Qf = (X - ?BR_X * Rf) / ?BQ_X,
    {Qf, Rf}.

axial_to_xy(Q, R) ->
    {?BQ_X * Q + ?BR_X * R, ?BR_Y * R}.

hex_round(Qf, Rf)
  when is_number(Qf), is_number(Rf) ->
    Xf = Qf,
    Zf = Rf,
    Yf = -Xf - Zf,

    Q = erlang:round(Qf),
    R = erlang:round(Rf),
    X = Q,
    Z = R,
    Y = -X - Z,

    Dx = abs(Xf - X),
    Dy = abs(Yf - Y),
    Dz = abs(Zf - Z),

    if Dx > Dy, Dx > Dz ->
           {-Y - Z, Z}; %% Adjust Q
       Dy > Dz ->
           {X, Z};      %% Adjust S, keep Q and R
       true ->
           {X, -X - Y}  %% Adjust R
    end.



