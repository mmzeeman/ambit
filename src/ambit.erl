%% @doc Ambit - Icosahedral Gnomonic Aperture 4 Triangles.
%% Uses the exact same projection engine as Hexveil for alignment.

-module(ambit).
-moduledoc """
# Ambit - Icosahedral Gnomonic Aperture 4 Triangle Grid

A hierarchical Discrete Global Grid System (DGGS) that tiles the sphere with triangles.

## Model

The Earth is modeled as an icosahedron (20 faces) projected to the sphere.
Each face is gnomonically projected to a 2D plane and recursively subdivided
with aperture 4: each triangle splits into 4 children (3 corner + 1 central inverted).

A code is `<<FaceBase20, "-", Digits/binary>>` where `FaceBase20` is `0..J`
(0-19 in base-20) and each digit `0..3` is a child index. Resolution is
`byte_size(Digits)`, 0..24.
""".

-on_load(init_persistent_terms/0).

-export([
    encode/2, encode/1,
    decode/1,
    resolution/1,
    orthocenter/1,
    disk/2, disk/3, disk/4,
    disk_center/1,
    optimal_level/1,
    parent/1,
    coarsen/2,
    cell_geometry/1,
    neighbors/1,
    neighbors_2/1,
    from_xyz/1,
    shape/2, shape/3,
    bounds/2, bounds/3
]).

-type lat()         :: float().
-type lon()         :: float().
-type latlon()      :: {lat(), lon()}.
-type triangle_2d() :: {xy(), xy(), xy()}.
-type triangle()    :: {latlon(), latlon(), latlon()}.
-type xyz()         :: {float(), float(), float()}.
-type xy()          :: {float(), float()}.
-type resolution()  :: 0..24.
-type face_idx()    :: 0..19.
-type meters()      :: number().
-type code()        :: <<_:16, _:_*8>>. % code is at least two bytes long.
-type disk_mode()   :: corner | centroid.

-type bounds() ::
    {MinLat :: number(), MinLon :: number(), MaxLat :: number(), MaxLon :: number()}.

-export_type([
    code/0,
    latlon/0,
    triangle/0,
    resolution/0,
    meters/0,
    disk_mode/0,
    bounds/0
]).

-define(D2R, 0.017453292519943295).
-define(DEFAULT_RES, 14).
-define(MAX_RES, 24).

-define(EARTH_RADIUS_M, 6371000.0).
-define(NR_FACES, 20).
-define(PRIVACY_CENTER_RES, 14).

-define(NEIGHBOR_DIRS, 12).
-define(NEIGHBOR_SHIFT_FACTOR, 0.9).

%% --- Subdivision child identifiers ---
%% A triangle splits into 4 sub-triangles (aperture 4): three lie against
%% a corner, one is the flipped (inverted) middle triangle.
%%
%% CHILD_A/B/C are named after the position of their corner in the
%% (V1, V2, V3) triplet as passed down at that level of the recursion.
%% This ordering originates from the order in which vertex indices were
%% written in the Faces list (init_persistent_terms/0) — a choice with
%% no geometric meaning (not "northernmost", not "lowest index"): which
%% physical corner V1 is differs per face. CHILD_CENTER is additionally
%% the mirrored triangle relative to its parent, so "up/down" also flips
%% after any CHILD_CENTER step.
-define(CHILD_CENTER, $1).
-define(CHILD_A,      $2).
-define(CHILD_B,      $3).
-define(CHILD_C,      $4).

-compile({inline, [vec_sub/2, cross_2d/2, mid_2d/2, dist_2d/2]}).

-spec encode(latlon()) -> code().
encode(Coord) ->
    encode(Coord, ?DEFAULT_RES).

-spec encode(latlon(), resolution()) -> code().
encode({Lat, Lon}, Res) when Res >= 0, Res =< ?MAX_RES ->
    encode_from_xyz(to_xyz({Lat, Lon}), Res).

-spec parse_code(code()) -> {face_idx(), binary()}.
parse_code(<<FaceBin:1/binary, $-, DigitsBin/binary>>) ->
    {binary_to_integer(FaceBin, ?NR_FACES), DigitsBin};
parse_code(_) ->
    erlang:error(badarg).

cell_vertices(Code) ->
    {FaceIdx, Digits} = parse_code(Code),
    Verts = face_verts_2d(FaceIdx),
    {FaceIdx, sub_decode(Digits, Verts)}.

%% @doc Return the centroid of the triangle identified by Code.
-spec decode(code()) -> latlon().
decode(Code) ->
    {FaceIdx, {RV1, RV2, RV3}} = cell_vertices(Code),
    XYZ = unproject(centroid_2d(RV1, RV2, RV3), FaceIdx),
    from_xyz(XYZ).

-spec resolution(code()) -> resolution().
resolution(Code) ->
    byte_size(digits(Code)).

%% @doc Return the orthocenter of the triangle identified by Code as {Lat, Lon}.
%% The orthocenter is the intersection of the triangle's three altitudes.
-spec orthocenter(code()) -> latlon().
orthocenter(Code) ->
    {FaceIdx, Verts} = cell_vertices(Code),
    O = orthocenter_2d(Verts),
    XYZ = unproject(O, FaceIdx),
    from_xyz(XYZ).

-spec disk(code() | latlon(), meters()) -> [code()].
disk(Code, DiameterMeters)
  when is_binary(Code), is_number(DiameterMeters), DiameterMeters >= 0 ->
    disk(Code, ?DEFAULT_RES, DiameterMeters);
disk({Lat, Lon}, DiameterMeters)
  when is_number(Lat), is_number(Lon), is_number(DiameterMeters), DiameterMeters >= 0 ->
    disk({Lat, Lon}, ?DEFAULT_RES, DiameterMeters).

-spec disk(code()|latlon(), resolution(), meters()) -> [code()].
disk({Lat, Lon}, Res, DiameterMeters)
  when is_number(Lat), is_number(Lon), is_integer(Res), Res >= 0, is_number(DiameterMeters), DiameterMeters >= 0 ->
    disk_from_center({Lat, Lon}, Res, DiameterMeters, corner);
disk(Code, Res, DiameterMeters) ->
    {Lat, Lon} = decode(Code),
    disk_from_center({Lat, Lon}, Res, DiameterMeters, corner).

%% @doc Like `disk/3' but with a mode option to control how triangles are
%% selected for inclusion in the disk.
%%
%% Mode can be:
%%   `corner'   – include the triangle when at least one corner OR its
%%                centroid falls within the radius (default, gives a
%%                slightly larger coverage).
%%   `centroid' – include the triangle only when its centroid falls
%%                within the radius (tighter fit).
-spec disk(latlon(), resolution(), meters(), disk_mode()) -> [code()].
disk({Lat, Lon}, Res, DiameterMeters, Mode)
  when is_number(Lat), is_number(Lon), is_integer(Res), Res > 0,
       is_number(DiameterMeters), DiameterMeters >= 0,
       (Mode =:= corner orelse Mode =:= centroid) ->
    disk_from_center({Lat, Lon}, Res, DiameterMeters, Mode).

%% @doc Return the resolution level whose triangular cells best match the
%% given diameter in meters. At this level, `disk/3' returns the fewest
%% codes while still approximating a circle of that diameter.
%%
%% The triangular cell diameter halves with each level (aperture 4).
%% At level 1, cell diameter is approximately 4,000 km.
%%
%% Example:
%%   ambit:optimal_level(1000).   %% => 13  (cell ≈ 969 m)
%%   ambit:optimal_level(500).    %% => 14  (cell ≈ 485 m)
%%   ambit:optimal_level(100).    %% => 16  (cell ≈ 121 m)
-spec optimal_level(DiameterMeters :: number()) -> 1..24.
optimal_level(DiameterMeters) when is_number(DiameterMeters), DiameterMeters > 0 ->
    %% Cell diameter at level 1 ≈ 4,003,017 m (empirically measured
    %% as the circumdiameter of a level-1 triangle at mid-latitudes).
    %% Each subsequent level halves the cell diameter (aperture 4).
    %%
    %% Level = round(log2(BaseDiameter / DiameterMeters)) + 1
    BaseDiameter = 4003017.0,
    Level = round(math:log2(BaseDiameter / DiameterMeters)) + 1,
    max(1, min(?MAX_RES, Level)).

%% @doc Return the privacy-preserving center point for a location.
%% This is the orthocenter of the enclosing triangle at the fixed
%% privacy resolution (level 15). Using a fixed resolution ensures
%% the center does not shift when the disk resolution changes.
-spec disk_center({Lat :: float(), Lon :: float()}) -> {float(), float()}.
disk_center({Lat, Lon}) ->
    PrivacyCode = encode({Lat, Lon}, ?PRIVACY_CENTER_RES),
    orthocenter(PrivacyCode).

%% @doc Returns codes at Res that overlap the GeoJSON shape, using corner mode.
-spec shape(GeoJSON :: map(), Res :: resolution()) -> [code()].
shape(GeoJSON, Res) -> shape(GeoJSON, Res, corner).

%% @doc Returns codes at Res that overlap the GeoJSON shape.
%% Mode can be `corner' (any corner or centroid inside polygon) or
%% `centroid' (centroid only).
-spec shape(GeoJSON :: map(), Res :: pos_integer(), Mode :: disk_mode()) -> [binary()].
shape(#{<<"type">> := <<"Polygon">>, <<"coordinates">> := Rings}, Res, Mode)
  when (is_integer(Res) andalso Res >= 0 andalso Res =< ?MAX_RES)
       andalso (Mode =:= centroid orelse Mode =:= corner) ->
    case Rings of
        [Outer | _] ->
            LatLonRings = [geojson_ring_to_latlon(R) || R <- Rings],
            Seeds = polygon_seeds(Outer, Res),
            shape_bfs(LatLonRings, Mode, Seeds);
        _ ->
            erlang:error(badarg)
    end;
shape(#{<<"type">> := <<"MultiPolygon">>, <<"coordinates">> := Polys}, Res, Mode)
  when (is_integer(Res) andalso Res >= 0 andalso Res =< ?MAX_RES)
       andalso (Mode =:= centroid orelse Mode =:= corner) ->
    lists:usort(lists:flatmap(
        fun(Rings) ->
            shape(#{<<"type">> => <<"Polygon">>,
                    <<"coordinates">> => Rings}, Res, Mode)
        end, Polys));
shape(_, _, _) ->
    erlang:error(badarg).

%% @doc Return codes at Level that overlap the bounding box {MinLat, MinLon, MaxLat, MaxLon}.
%% Uses corner mode by default.
-spec bounds(Bounds :: bounds(), Level :: resolution()) -> [code()].
bounds(Bounds, Level) ->
    bounds(Bounds, Level, corner).

bounds(Bounds, Res, Mode) ->
    NormBounds = normalise_bounds(Bounds),
    GeoJson = bounds_to_geojson(NormBounds),
    shape(GeoJson, Res, Mode).

bounds_to_geojson({MinLat, MinLon, MaxLat, MaxLon}) ->
    #{
        <<"type">> => <<"Polygon">>,
        <<"coordinates">> => [[
            [MinLon, MinLat],
            [MaxLon, MinLat],
            [MaxLon, MaxLat],
            [MinLon, MaxLat],
            [MinLon, MinLat]
        ]]
    }.

normalise_bounds({Lat1, Lon1, Lat2, Lon2})
  when is_number(Lat1) andalso is_number(Lon1)
       andalso is_number(Lat2) andalso is_number(Lon2) ->
    MinLat = min(float(Lat1), float(Lat2)),
    MaxLat = max(float(Lat1), float(Lat2)),

    NLon1 = normalise_lon(float(Lon1), 0.0),
    NLon2 = normalise_lon(float(Lon2), 0.0),

    {MinLat, NLon1, MaxLat, NLon2};
normalise_bounds(_) ->
    erlang:error(badarg).

% - filling the shape with neighbor triangles

flood_fill(Seeds, WithinFun) ->
    Visited0 = sets:from_list(Seeds, [{version, 2}]),
    Queue0 = queue:from_list(Seeds),
    InitAcc = [S || S <- Seeds, WithinFun(S)],
    flood_fill_loop(WithinFun, Queue0, Visited0, InitAcc).

flood_fill_loop(WithinFun, Queue0, Visited, Acc) ->
    case queue:out(Queue0) of
        {empty, _} -> Acc;
        {{value, Code}, Queue1} ->
            {Queue2, Visited1, Acc1} = lists:foldl(
                fun(NCode, {Q, V, A}) ->
                    case sets:is_element(NCode, V) of
                        true -> {Q, V, A};
                        false ->
                            V1 = sets:add_element(NCode, V),
                            case WithinFun(NCode) of
                                true  -> {queue:in(NCode, Q), V1, [NCode | A]};
                                false -> {Q, V1, A}
                            end
                    end
                end,
                {Queue1, Visited, Acc},
                neighbors(Code)
            ),
            flood_fill_loop(WithinFun, Queue2, Visited1, Acc1)
    end.

shape_bfs(Rings, Mode, Seeds) ->
    flood_fill(Seeds, fun(Code) -> within_shape(Rings, Code, Mode) end).

disk_from_center(Center, Res, DiameterMeters, Mode) ->
    %% Center of the disk is always computed at the fixed privacy
    %% resolution so that the circle does not shift when the user
    %% changes the disk resolution.
    DiskCenter = disk_center(Center),
    StartCode = encode(DiskCenter, Res),
    RadiusMeters = DiameterMeters / 2.0,
    Visited0 = sets:from_list([StartCode], [{version, 2}]),
    Queue0 = queue:from_list([StartCode]),
    disk_bfs(DiskCenter, RadiusMeters, Mode, Queue0, Visited0, [StartCode]).

disk_bfs(Center, RadiusMeters, Mode, Queue0, Visited, Acc) ->
    case queue:out(Queue0) of
        {empty, _} ->
            Acc;
        {{value, Code}, Queue1} ->
            {Queue2, Visited1, Acc1} = lists:foldl(
                fun(NCode, {Q0, V0, A0}) ->
                    case sets:is_element(NCode, V0) of
                        true ->
                            {Q0, V0, A0};
                        false ->
                            V1 = sets:add_element(NCode, V0),
                            case within(Center, NCode, RadiusMeters, Mode) of
                                true -> {queue:in(NCode, Q0), V1, [NCode | A0]};
                                false -> {Q0, V1, A0}
                            end
                    end
                end,
                {Queue1, Visited, Acc},
                neighbors(Code)
            ),
            disk_bfs(Center, RadiusMeters, Mode, Queue2, Visited1, Acc1)
    end.

%% @doc Check if a triangle should be included in the disk.
%% In `corner' mode a triangle is included when any corner OR the centroid
%% falls within the radius.  In `centroid' mode only the centroid is checked.
within(Center, Code, RadiusMeters, corner) ->
    any_corner_within(Center, Code, RadiusMeters);
within(Center, Code, RadiusMeters, centroid) ->
    centroid_within(Center, Code, RadiusMeters).

within_shape(Rings, Code, corner) ->
    {C1, C2, C3, Centroid} = cell_corners_and_centroid(Code),
    point_in_polygon(C1, Rings)
    orelse point_in_polygon(C2, Rings)
    orelse point_in_polygon(C3, Rings)
    orelse point_in_polygon(Centroid, Rings);
within_shape(Rings, Code, centroid) ->
    point_in_polygon(decode(Code), Rings).

any_corner_within(Center, Code, RadiusMeters) ->
    {C1, C2, C3, Centroid} = cell_corners_and_centroid(Code),
    great_circle_distance(Center, C1) =< RadiusMeters
    orelse great_circle_distance(Center, C2) =< RadiusMeters
    orelse great_circle_distance(Center, C3) =< RadiusMeters
    orelse great_circle_distance(Center, Centroid) =< RadiusMeters.

%% @doc Check if the triangle's centroid is within the disk.
centroid_within(Center, Code, RadiusMeters) ->
    great_circle_distance(Center, decode(Code)) =< RadiusMeters.

great_circle_distance(P1, P2) ->
    {X1, Y1, Z1} = to_xyz(P1),
    {X2, Y2, Z2} = to_xyz(P2),
    Dot0 = X1*X2 + Y1*Y2 + Z1*Z2,
    Dot = if
        Dot0 > 1.0  -> 1.0;
        Dot0 < -1.0 -> -1.0;
        true        -> Dot0
    end,
    math:acos(Dot) * ?EARTH_RADIUS_M.

%% @doc Reduce Code to the given (coarser or equal) resolution by truncating
%% its digit string. Res must be between 1 and the code's current resolution.
-spec coarsen(code(), resolution()) -> code().
coarsen(<<FaceDigit:1/binary, $-, Digits/binary>> = Code, Res) when is_integer(Res), Res >= 0, Res =< ?MAX_RES ->
    CurrentRes = byte_size(Digits),
    case CurrentRes of
        Res -> Code;
        _ when Res < CurrentRes ->
            NewDigits = binary:part(Digits, 0, Res),
            <<FaceDigit/binary, $-, NewDigits/binary>>;
        _ ->
            erlang:error(badarg)
    end;
coarsen(_, _) ->
    erlang:error(badarg).

-spec parent(code()) -> code().
parent(<<_:1/binary, $-, Digits/binary>> =Code) when byte_size(Digits) > 0 ->
    coarsen(Code, byte_size(Digits)-1);
parent(<<_:1/binary, $->> =Code) ->
    Code;
parent(_) ->
    erlang:error(badarg).

-spec cell_geometry(code()) -> triangle().
cell_geometry(Code) ->
    {FaceIdx, {RV1, RV2, RV3}} = cell_vertices(Code),
    {from_xyz(unproject(RV1, FaceIdx)),
     from_xyz(unproject(RV2, FaceIdx)),
     from_xyz(unproject(RV3, FaceIdx))}.

%% --- Recursive Subdivision (2D Local Space) ---

new_verts(?CHILD_A, {V1, V2, V3}) ->
    {V1, mid_2d(V1, V2), mid_2d(V3, V1)};
new_verts(?CHILD_B, {V1, V2, V3}) ->
    {V2, mid_2d(V1, V2), mid_2d(V2, V3)};
new_verts(?CHILD_C, {V1, V2, V3}) ->
    {V3, mid_2d(V2, V3), mid_2d(V3, V1)};
new_verts(?CHILD_CENTER, {V1, V2, V3}) ->
    {mid_2d(V1, V2), mid_2d(V2, V3), mid_2d(V3, V1)}.

-spec vec_sub(xy(), xy()) -> xy().
vec_sub({Ax, Ay}, {Bx, By}) -> {Ax - Bx, Ay - By}.

-spec cross_2d(xy(), xy()) -> float().
%% 2D cross product (perp dot product) of two vectors: twice the signed
%% area of the triangle they span from a common origin.
cross_2d({Ax, Ay}, {Bx, By}) -> Ax*By - Ay*Bx.

-spec locate_child(xy(), triangle_2d()) -> {byte(), triangle_2d()}.
locate_child(P, {V1, V2, V3} = Verts) ->
    A  = vec_sub(V1, V3),
    B  = vec_sub(V2, V3),
    Dp = vec_sub(P, V3),

    Det = cross_2d(A, B),
    U = cross_2d(Dp, B) / Det,

    if 
        U >= 0.5 ->
            {?CHILD_A, new_verts(?CHILD_A, Verts)};
        true ->
            V = cross_2d(A, Dp) / Det,
            if 
                V >= 0.5 ->
                    {?CHILD_B, new_verts(?CHILD_B, Verts)};
                U + V =< 0.5 -> % because W = 1.0 - U - V
                    {?CHILD_C, new_verts(?CHILD_C, Verts)};
                true ->
                    {?CHILD_CENTER, new_verts(?CHILD_CENTER, Verts)}
            end
    end.

sub_encode(_P, _Verts, 0, Acc) -> Acc;
sub_encode(P, Verts, Res, Acc) ->
    {Digit, NewVerts} = locate_child(P, Verts),
    sub_encode(P, NewVerts, Res-1, <<Acc/binary, Digit>>).


-spec sub_decode(code(), triangle_2d()) -> triangle_2d().
sub_decode(<<Digit, Rest/binary>>, Verts) ->
    sub_decode(Rest, new_verts(Digit, Verts));
sub_decode(<<>>, Verts) ->
    Verts.

%% --- Neighbors logic ---

neighbors(Code) ->
    compute_neighbors(Code, ?NEIGHBOR_DIRS). %% 12 directions (edge + vertex)

neighbors_2(Code) ->
    N1 = neighbors(Code),
    All = lists:usort(lists:flatten([neighbors(C) || C <- N1])),
    All -- [Code | N1].

compute_neighbors(Code, NumDirs) ->
    {FaceIdx, Digits} = parse_code(Code),
    Res = byte_size(Digits),
    Verts = face_verts_2d(FaceIdx),
    {RV1, RV2, RV3} = sub_decode(Digits, Verts),

    Shift = dist_2d(RV1, RV2) *?NEIGHBOR_SHIFT_FACTOR,
    Center2D = centroid_2d(RV1, RV2, RV3),
    Candidates = ring_points_2d(Center2D, Shift, NumDirs),

    FaceCentres = face_centres(),
    HintCentre = element(FaceIdx+1, FaceCentres),

    % 1. Unproject once, 2. Dedup XYZ by quantizing (avoids re-encoding same face 3x)
    % 3. Find nearest face using vertex-neighbor ring
    Encoded = lists:usort([begin
                     XYZ = unproject(P, FaceIdx),
                     NFaceIdx = nearest_face_fast(XYZ, FaceIdx, HintCentre, FaceCentres),
                     encode_at_face(XYZ, Res, NFaceIdx)
                 end || P <- Candidates]),
    Encoded -- [Code].

nearest_face_fast({X,Y,Z}=XYZ, HintFace, HintCentre, FaceCentres) ->
    % Start with hint face dot product
    {HCx,HCy,HCz} = HintCentre,
    D0 = X*HCx + Y*HCy + Z*HCz,

    % Candidates = edge neighbors + vertex neighbors = all faces sharing a vertex
    % This guarantees we find the correct face for any shift < 1 edge length
    CandidateIdxs = element(HintFace+1, face_vertex_neighbors()),

    search_faces_fast(XYZ, CandidateIdxs, FaceCentres, D0, HintFace).

% If you want absolute safety (20 dot products is ~0.2us), just search all:
% nearest_face_fast(XYZ, HintFace, HintCentre, FaceCentres) ->
% search_faces_fast(XYZ, lists:seq(0,19) -- [HintFace], FaceCentres, D0, HintFace)

search_faces_fast(_XYZ, [], _FaceCentres, _MaxD, MaxIdx) ->
    MaxIdx;
search_faces_fast({X,Y,Z}=XYZ, [FaceIdx|Rest], FaceCentres, MaxD, MaxIdx) ->
    {Cx,Cy,Cz} = element(FaceIdx+1, FaceCentres),
    D = X*Cx + Y*Cy + Z*Cz,
    if
        D > MaxD ->
            search_faces_fast(XYZ, Rest, FaceCentres, D, FaceIdx);
       true ->
            search_faces_fast(XYZ, Rest, FaceCentres, MaxD, MaxIdx)
    end.

-spec centroid_2d(xy(), xy(), xy()) -> xy().
centroid_2d({X1,Y1}, {X2,Y2}, {X3,Y3}) ->
    {(X1+X2+X3)/3.0, (Y1+Y2+Y3)/3.0}.

ring_points_2d({CX, CY}, Shift, NumDirs) ->
    [{CX + Shift * math:cos(A), CY + Shift * math:sin(A)}
     || I <- lists:seq(0, NumDirs - 1),
        A <- [I * (2 * math:pi() / NumDirs)]].

dist_2d({X1,Y1}, {X2,Y2}) ->
    DX = X1-X2, DY = Y1-Y2,
    math:sqrt(DX*DX + DY*DY).

-spec dot_2d(xy(), xy()) -> float().
dot_2d({Ax, Ay}, {Bx, By}) ->
    Ax*Bx + Ay*By.

%% --- Gnomonic Projection Engine (Identical to hexveil) ---

project({X, Y, Z}, Face) ->
    {{Cx,Cy,Cz},{Ux,Uy,Uz},{Vx,Vy,Vz}} = face_basis(Face),
    D  = X*Cx + Y*Cy + Z*Cz,
    Px = X/D-Cx, Py = Y/D-Cy, Pz = Z/D-Cz,
    {Px*Ux+Py*Uy+Pz*Uz, Px*Vx+Py*Vy+Pz*Vz}.

unproject({Qf, Rf}, Face) ->
    {{Cx,Cy,Cz},{Ux,Uy,Uz},{Vx,Vy,Vz}} = face_basis(Face),
    unit({Cx + Qf*Ux + Rf*Vx,
          Cy + Qf*Uy + Rf*Vy,
          Cz + Qf*Uz + Rf*Vz}).

-spec mid_2d(xy(), xy()) -> xy().
mid_2d({X1, Y1}, {X2, Y2}) ->
    {(X1 + X2) / 2.0, (Y1 + Y2) / 2.0}.

-spec orthocenter_2d(triangle_2d()) -> xy().
%% The orthocenter is the intersection of the triangle's altitudes.
%% Altitude from A perpendicular to BC: (H-A)·(B-C) = 0
%% Altitude from B perpendicular to AC: (H-B)·(A-C) = 0
orthocenter_2d({A, B, C}) ->
    D = vec_sub(B, C),   %% direction BC
    E = vec_sub(A, C),   %% direction AC

    Rhs1 = dot_2d(A, D),
    Rhs2 = dot_2d(B, E),
    Det  = cross_2d(D, E),

    {Dx, Dy} = D,
    {Ex, Ey} = E,
    H1 = (Rhs1*Ey - Rhs2*Dy) / Det,
    H2 = (Dx*Rhs2 - Ex*Rhs1) / Det,
    {H1, H2}.

%% --- Standard Geometry ---

-spec to_xyz(latlon()) -> xyz().
to_xyz({Lat, Lon}) ->
    Lo = Lon * ?D2R,
    La = Lat * ?D2R,
    {math:cos(La)*math:cos(Lo), math:cos(La)*math:sin(Lo), math:sin(La)}.

-spec from_xyz(xyz()) -> latlon().
from_xyz({X, Y, Z}) ->
    Lon = math:atan2(Y, X) / ?D2R,
    Lat = math:asin(Z) / ?D2R,
    {Lat, Lon}.

-spec unit(xyz()) -> xyz().
unit({X, Y, Z}) ->
    R = math:sqrt(X*X + Y*Y + Z*Z),
    {X/R, Y/R, Z/R}.

-spec cross(xyz(), xyz()) -> xyz().
cross({Ax, Ay, Az}, {Bx, By, Bz}) ->
    {Ay*Bz - Az*By, Az*Bx - Ax*Bz, Ax*By - Ay*Bx}.

nearest_face(XYZ) ->
    nearest_face(XYZ, tuple_to_list(face_centres()), 0, -2.0, 0).

nearest_face(_XYZ, [], _Idx, _MaxD, MaxIdx) ->
    MaxIdx;
nearest_face({X,Y,Z}=XYZ, [{Cx,Cy,Cz}|Rest], Idx, MaxD, MaxIdx) ->
    D = X*Cx + Y*Cy + Z*Cz,
    if
        D > MaxD -> nearest_face(XYZ, Rest, Idx+1, D, Idx);
        true     -> nearest_face(XYZ, Rest, Idx+1, MaxD, MaxIdx)
    end.

%% --- Shape / GeoJSON helpers ---

polygon_seeds(OuterRing, Res) ->
    LatLons = geojson_ring_to_latlon(OuterRing),
    case LatLons of
        [] -> [];
        _ ->
            {SumLat, SumLon, N} = lists:foldl(
                                    fun({Lat, Lon}, {SLat, SLon, Cnt}) ->
                                            {SLat+Lat, SLon+Lon, Cnt+1}
                                    end,
                                    {0.0, 0.0, 0},
                                    LatLons),
            Centroid = {SumLat/N, SumLon/N},
            VertexCells = lists:usort([encode(P, Res) || P <- LatLons]),
            lists:usort([encode(Centroid, Res) | VertexCells])
    end.

geojson_ring_to_latlon(Ring) ->
    [{lat_of(V), lon_of(V)} || V <- Ring].

lat_of([_Lon, Lat | _]) ->
    Lat.

lon_of([Lon | _]) ->
    Lon.

point_in_polygon({Lat, Lon}, [Outer | Holes]) ->
    ray_cast({Lat, Lon}, Outer) andalso
    not lists:any(fun(Hole) -> ray_cast({Lat, Lon}, Hole) end, Holes).

ray_cast({Lat, Lon}, Ring) ->
    Pairs = lists:zip(Ring, lists:nthtail(1, Ring) ++ [hd(Ring)]),
    Crossings = lists:foldl(
        fun({{ALat, ALon0}, {BLat, BLon0}}, Cnt) ->
            %% Normalise longitudes relative to the test point to handle wrap-around
            ALon = normalise_lon(ALon0, Lon),
            BLon = normalise_lon(BLon0, Lon),
            InY = (ALat =< Lat andalso BLat > Lat) orelse
                  (BLat =< Lat andalso ALat > Lat),
            case InY of
                false -> Cnt;
                true ->
                    %% X coordinate of the crossing
                    T = (Lat - ALat) / (BLat - ALat),
                    CrossLon = ALon + T * (BLon - ALon),
                    case CrossLon > Lon of
                        true  -> Cnt + 1;
                        false -> Cnt
                    end
            end
        end,
        0, Pairs),
    (Crossings rem 2) =:= 1.

normalise_lon(VertLon, TestLon) ->
    DLon = VertLon - TestLon,
    if
        DLon > 180.0  -> VertLon - 360.0;
        DLon < -180.0 -> VertLon + 360.0;
        true          -> VertLon
    end.

%%
%% Helpers
%%

-spec digits(code()) -> binary().
digits(Code) ->
    {_, DigitsBin} = parse_code(Code),
    DigitsBin.

% --- shared XYZ -> code helper (used by encode/2 and compute_neighbors) ---

encode_from_xyz(XYZ, Res) ->
    encode_at_face(XYZ, Res, nearest_face(XYZ)).

encode_at_face(XYZ, Res, FaceIdx) ->
    {X, Y} = project(XYZ, FaceIdx),
    {V1, V2, V3} = face_verts_2d(FaceIdx),
    Digits = sub_encode({X, Y}, {V1, V2, V3}, Res, <<>>),
    FaceBin = element(FaceIdx+1, face_bins()),
    <<FaceBin/binary, $-, Digits/binary>>.

%% Corners and centroid from a single parse_code + sub_decode walk.
cell_corners_and_centroid(Code) ->
    {FaceIdx, {RV1, RV2, RV3}} = cell_vertices(Code),
    C1 = from_xyz(unproject(RV1, FaceIdx)),
    C2 = from_xyz(unproject(RV2, FaceIdx)),
    C3 = from_xyz(unproject(RV3, FaceIdx)),
    Centroid = from_xyz(unproject(centroid_2d(RV1, RV2, RV3), FaceIdx)),
    {C1, C2, C3, Centroid}.

%% --- Persistent Data ---

face_basis(Face) ->
    element(Face+1, persistent_term:get({?MODULE, face_bases})).

face_bins() ->
    persistent_term:get({?MODULE, face_bins}).

face_verts_2d(Idx) ->
    element(Idx+1, persistent_term:get({?MODULE, face_verts_2d})).

face_centres() ->
    persistent_term:get({?MODULE, face_centres}).

face_vertex_neighbors() ->
    persistent_term:get({?MODULE, face_vertex_neighbors}).

init_persistent_terms() ->
    UpLat = math:atan(0.5) / ?D2R,
    DnLat = -UpLat,
    Verts = [to_xyz({90.0, 0.0})]
             ++ [to_xyz({UpLat, I*72.0}) || I <- lists:seq(0,4)]
             ++ [to_xyz({DnLat, I*72.0+36.0}) || I <- lists:seq(0,4)]
             ++ [to_xyz({-90.0, 0.0})],
    VT = list_to_tuple(Verts),
    
    Faces = [{0,1,2}, {0,2,3}, {0,3,4}, {0,4,5}, {0,5,1},
             {1,6,2}, {2,6,7}, {2,7,3}, {3,7,8}, {3,8,4},
             {4,8,9}, {4,9,5}, {5,9,10}, {5,10,1}, {1,10,6},
             {6,11,7}, {7,11,8}, {8,11,9}, {9,11,10}, {10,11,6}],
    
    %% Calculate Face Centres
    Centres = [begin
                   {Ax,Ay,Az} = element(A+1, VT),
                   {Bx,By,Bz} = element(B+1, VT),
                   {Cx,Cy,Cz} = element(C+1, VT),
                   unit({(Ax+Bx+Cx)/3.0, (Ay+By+Cy)/3.0, (Az+Bz+Cz)/3.0})
               end || {A,B,C} <- Faces],
    persistent_term:put({?MODULE, face_centres}, list_to_tuple(Centres)),

    %% Vertex -> faces map
    VertexToFaces = lists:foldl(fun({FaceIdx, {A,B,C}}, Acc) ->
        Acc1 = maps:update_with(A, fun(L) -> [FaceIdx|L] end, [FaceIdx], Acc),
        Acc2 = maps:update_with(B, fun(L) -> [FaceIdx|L] end, [FaceIdx], Acc1),
        maps:update_with(C, fun(L) -> [FaceIdx|L] end, [FaceIdx], Acc2)
    end, #{}, lists:zip(lists:seq(0,19), Faces)),

    FaceVertexNeighbors = list_to_tuple([
        begin
            {A,B,C} = lists:nth(FaceIdx+1, Faces),
            All = lists:usort(
                maps:get(A, VertexToFaces) ++
                maps:get(B, VertexToFaces) ++
                maps:get(C, VertexToFaces)
            ),
            All -- [FaceIdx]
        end || FaceIdx <- lists:seq(0,19)
    ]),
    persistent_term:put({?MODULE, face_vertex_neighbors}, FaceVertexNeighbors),

    %% Calculate Face Bases (U/V vectors)
    Bases = [begin
                 Centre = lists:nth(I+1, Centres),
                 RawU = cross(Centre, {0.0,0.0,1.0}),
                 {Ux0,Uy0,Uz0} = RawU,
                 UU = case abs(Ux0)+abs(Uy0)+abs(Uz0) < 1.0e-10 of
                          true  -> cross(Centre, {1.0,0.0,0.0});
                          false -> RawU
                      end,
                 U = unit(UU),
                 V = unit(cross(Centre, U)),
                 {Centre, U, V}
             end || I <- lists:seq(0, 19)],
    persistent_term:put({?MODULE, face_bases}, list_to_tuple(Bases)),

    %% Pre-calculate 2D projected vertices of each face
    Verts2D = [begin
                   {A,B,C} = lists:nth(I+1, Faces),
                   V1 = element(A+1, VT), V2 = element(B+1, VT), V3 = element(C+1, VT),
                   %% We need a local project function here since persistent_term is being built
                   {{FCx,FCy,FCz},{FUx,FUy,FUz},{FVx,FVy,FVz}} = lists:nth(I+1, Bases),
                   ProjLocal = fun({X,Y,Z}) ->
                                   D = X*FCx + Y*FCy + Z*FCz,
                                   Px = X/D-FCx, Py = Y/D-FCy, Pz = Z/D-FCz,
                                   {Px*FUx+Py*FUy+Pz*FUz, Px*FVx+Py*FVy+Pz*FVz}
                               end,
                   {ProjLocal(V1), ProjLocal(V2), ProjLocal(V3)}
               end || I <- lists:seq(0, 19)],
    persistent_term:put({?MODULE, face_verts_2d}, list_to_tuple(Verts2D)),

    persistent_term:put({?MODULE, face_bins}, 
                        list_to_tuple([integer_to_binary(I, 20) || I <- lists:seq(0, 19)])).


