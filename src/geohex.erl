%% @doc GeoHex - A privacy-preserving hierarchical location encoding
%% system using a flat hexagonal grid with axial (q, r) coordinates.
%%
%% Codes are {Q, R} integer tuples at the finest level (5).
%% All proximity logic is pure integer arithmetic — no string conversion.
%% Use display/1 or display/2 to produce human-readable base-7 strings.
%%
%% Cell sizes (flat-to-flat, pointy-top hex):
%%   Level 5: ~250m    — your block         (borrow a drill, cup of sugar)
%%   Level 4: ~661m    — immediate area     (grab a coffee)
%%   Level 3: ~1750m   — neighbourhood      (short walk)
%%   Level 2: ~4630m   — across the city    (bike ride)
%%   Level 1: ~12250m  — region             (city-level)
%%
%% Each level is exactly sqrt(7) coarser than the one below it.
%% For the lending/coffee/activities use case, levels 5, 4 and 3 are the
%% most useful.
%%
%% All 6 neighbours of any hex cell are equidistant — unlike squares
%% (where corner neighbours are sqrt(2) further) or rhombuses.
%%
%% Code format:
%%   {Q, R} integers at level 5 (finest), both in range 0..16806 (7^5-1).
%%   display/2 renders as a base-7 string: 5 Q digits + 5 R digits = 10 chars.
%%   Coarser levels drop 1 digit from each half: level 4 = 8 chars, etc.
%%
%% Projection: pointy-top hex, equirectangular, centred on (52.0N, 5.0E).
%% Coverage: ~300km radius (all of the Netherlands and surroundings).
%%
%% Usage:
%%   Code  = geohex:encode(52.3026, 4.6889).
%%   true  = geohex:are_nearby(Code, Other, 4).  %% same ~660m cell?
%%   Nbrs  = geohex:neighbors(Code).
%%   S     = geohex:display(Code).               %% <<"3011336450">>
%%   S4    = geohex:display(Code, 4).            %% <<"30113364">>
%%   Code2 = geohex:parse(<<"3011336450">>).

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
-type level() :: 1 | 2 | 3 | 4 | 5.
-export_type([code/0, level/0]).

%% ---------------------------------------------------------------------------
%% Constants
%% ---------------------------------------------------------------------------

%% Circumradius R at level 5: flat-to-flat = sqrt(3)*R = 250m
-define(R, 144.3376).

%% Axial basis vectors in metres (pointy-top hex)
-define(BQ_X, 250.0).      %% east  metres per q step  = sqrt(3)*R
-define(BR_X, 125.0).      %% east  metres per r step  = sqrt(3)/2*R
-define(BR_Y, 216.5064).   %% north metres per r step  = 3/2*R

%% Projection reference point
-define(REF_LAT,  52.0).
-define(REF_LON,   5.0).
-define(M_PER_DEG_LAT, 111320.0).
-define(M_PER_DEG_LON,  68071.0).  %% 111320 * cos(52 degrees)

%% Offset so all level-5 encoded values are non-negative.
%% 7^5 = 16807 cells per axis * 250m = 4200km — global coverage.
-define(Q_OFF, 8400).
-define(R_OFF, 8400).

%% The 6 axial neighbour directions for a pointy-top hex grid.
-define(DIRECTIONS, [{1,0},{0,1},{-1,1},{-1,0},{0,-1},{1,-1}]).

%% Number of digits per axis at each level, and the divisor to coarsen.
%% Level 5 = finest (5 digits), level 1 = coarsest (1 digit).
%% Divisor = 7^(5 - Level).

%% ---------------------------------------------------------------------------
%% Public API
%% ---------------------------------------------------------------------------

%% @doc Encode a lat/lon pair into a {Q, R} code at level 5 (finest).
%% The returned code can be compared at any level via are_nearby/3,
%% or coarsened via coarsen/2 — no re-encoding needed.
-spec encode(float(), float()) -> code().
encode(Lat, Lon) ->
    {X, Y}   = latlon_to_xy(Lat, Lon),
    {Qf, Rf} = xy_to_axial(X, Y),
    {Q,  R}  = hex_round(Qf, Rf),
    {Q + ?Q_OFF, R + ?R_OFF}.

%% @doc Decode a code back to {Lat, Lon} at the centre of its level-5 cell.
-spec decode(code()) -> {float(), float()}.
decode({Q, R}) ->
    {X, Y} = axial_to_xy(Q - ?Q_OFF + 0.5, R - ?R_OFF + 0.5),
    xy_to_latlon(X, Y).

%% @doc True if two codes refer to the same cell at the given level.
%%
%%   are_nearby(A, B, 5) — same ~250m block
%%   are_nearby(A, B, 4) — same ~660m area
%%   are_nearby(A, B, 3) — same ~1750m neighbourhood
%%   are_nearby(A, B, 2) — same ~4630m part of city
%%   are_nearby(A, B, 1) — same ~12250m region
%%
%% Pure integer division — no string conversion needed.
-spec are_nearby(code(), code(), level()) -> boolean().
are_nearby({Q1, R1}, {Q2, R2}, Level) ->
    Div = pow7(5 - Level),
    Q1 div Div =:= Q2 div Div andalso
    R1 div Div =:= R2 div Div.

%% @doc Coarsen a code to the given level by integer division.
%%   coarsen(Code, 5) -> same {Q, R}  (no change)
%%   coarsen(Code, 4) -> {Q div 7,  R div 7}
%%   coarsen(Code, 3) -> {Q div 49, R div 49}
%%   etc.
-spec coarsen(code(), level()) -> code().
coarsen({Q, R}, Level) ->
    Div = pow7(5 - Level),
    {Q div Div, R div Div}.

%% @doc Return the 6 neighbouring codes at level 5.
%% All 6 neighbours are exactly equidistant from the cell centre.
-spec neighbors(code()) -> [code()].
neighbors({Q, R}) ->
    [{Q + DQ, R + DR} || {DQ, DR} <- ?DIRECTIONS].

%% @doc Approximate bounding box {MinLat, MinLon, MaxLat, MaxLon}.
%% Uses the flat-to-flat diameter (250m) as the box side.
-spec cell_bounds(code()) -> {float(), float(), float(), float()}.
cell_bounds(Code) ->
    {CLat, CLon} = decode(Code),
    Half    = 125.0,
    HalfLat = Half / ?M_PER_DEG_LAT,
    HalfLon = Half / ?M_PER_DEG_LON,
    {CLat - HalfLat, CLon - HalfLon,
     CLat + HalfLat, CLon + HalfLon}.

%% @doc Render a code as a human-readable base-7 binary at its finest level.
%% Produces a 10-byte binary: 5 Q digits + 5 R digits.
-spec display(code()) -> binary().
display(Code) -> display(Code, 5).

%% @doc Render a code at the given level.
%%   display(Code, 5) -> <<"3011336450">>   (10 bytes)
%%   display(Code, 4) -> <<"30113364">>     ( 8 bytes)
%%   display(Code, 3) -> <<"301336">>       ( 6 bytes)
%%   display(Code, 2) -> <<"3033">>         ( 4 bytes)
%%   display(Code, 1) -> <<"33">>           ( 2 bytes)
%%
%% Prefix property: display(Code, L) is always a prefix of display(Code, L+1).
-spec display(code(), level()) -> binary().
display({Q, R}, Level) ->
    Div = pow7(5 - Level),
    ND  = Level,
    QBin = pad7(integer_to_binary(Q div Div, 7), ND),
    RBin = pad7(integer_to_binary(R div Div, 7), ND),
    <<QBin/binary, RBin/binary>>.

%% @doc Parse a display binary back into a level-5 {Q, R} code.
%% Accepts 2-, 4-, 6-, 8- or 10-byte base-7 binaries.
-spec parse(binary()) -> code().
parse(S) ->
    ND  = byte_size(S) div 2,
    <<QBin:ND/binary, RBin:ND/binary>> = S,
    Q   = binary_to_integer(QBin, 7),
    R   = binary_to_integer(RBin, 7),
    Div = pow7(5 - ND),
    {Q * Div, R * Div}.

%% ---------------------------------------------------------------------------
%% Geometry (internal)
%% ---------------------------------------------------------------------------

-spec latlon_to_xy(float(), float()) -> {float(), float()}.
latlon_to_xy(Lat, Lon) ->
    {(Lon - ?REF_LON) * ?M_PER_DEG_LON,
     (Lat - ?REF_LAT) * ?M_PER_DEG_LAT}.

-spec xy_to_latlon(float(), float()) -> {float(), float()}.
xy_to_latlon(X, Y) ->
    {?REF_LAT + Y / ?M_PER_DEG_LAT,
     ?REF_LON + X / ?M_PER_DEG_LON}.

-spec xy_to_axial(float(), float()) -> {float(), float()}.
xy_to_axial(X, Y) ->
    Rf = Y / (1.5 * ?R),
    Qf = (X - ?BR_X * Rf) / ?BQ_X,
    {Qf, Rf}.

-spec axial_to_xy(float(), float()) -> {float(), float()}.
axial_to_xy(Q, R) ->
    {?BQ_X * Q + ?BR_X * R,
     ?BR_Y * R}.

%% Cube-coordinate rounding: snaps fractional axial coords to the nearest
%% hex cell, correctly handling all boundary cases.
-spec hex_round(float(), float()) -> {integer(), integer()}.
hex_round(Qf, Rf) ->
    Sf = -Qf - Rf,
    Rq = round(Qf), Rr = round(Rf), Rs = round(Sf),
    Dq = abs(Rq - Qf), Dr = abs(Rr - Rf), Ds = abs(Rs - Sf),
    if
        Dq > Dr andalso Dq > Ds -> {-Rr - Rs, Rr};
        Dr > Ds                  -> {Rq, -Rq - Rs};
        true                     -> {Rq, Rr}
    end.

%% ---------------------------------------------------------------------------
%% Helpers
%% ---------------------------------------------------------------------------

-spec pow7(0..4) -> 1 | 7 | 49 | 343 | 2401.
pow7(0) -> 1;
pow7(1) -> 7;
pow7(2) -> 49;
pow7(3) -> 343;
pow7(4) -> 2401.

-spec pad7(binary(), pos_integer()) -> binary().
pad7(S, Width) ->
    Padding = binary:copy(<<"0">>, max(0, Width - byte_size(S))),
    <<Padding/binary, S/binary>>.


