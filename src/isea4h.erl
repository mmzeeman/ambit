%% @doc ISEA4H - Icosahedral Gnomonic Aperture 4 Hexagon.
%%
%% This implementation uses an Aperture 4 hierarchy (Area x 4 per level)
%% on an icosahedral gnomonic projection. This projection is used for
%% computational efficiency at the cost of being only approximately equal-area.
%%
%% Characteristics:
%% - Icosahedral projection (20 faces).
%% - Gnomonic projection (central projection from sphere center to face).
%% - Aperture 4 (each level divides cell area by 4).
%% - Scale factor: 2.0 per level (edge length).
%% - Cell sizes (approximate diameter):
%%   Level | Size (approx) | Use Case
%%   ------|---------------|----------------------------
%%   24    | 2.5m          | High Precision / Human Scale
%%   18    | 160m          | Privacy Level 1 (~150m)
%%   17    | 320m          | Privacy Level 2 (~300m)
%%   16    | 640m          | Privacy Level 3 (~600m)
%%   9     | 80km          | Regional Scale
%%   1     | 20,000km      | Global Scale
%%
%% Coordinate system uses 20 faces (0-19) and a base-4 digit encoding.
%% The format is "Face-Digits" where Face is 0-9a-j (base 20).
%%
%% Hierarchical Examples:
%%   Location        | L24 (2.5m)               | L17 (320m)        | L9 (80km) | L1 (20kkm)
%%   ----------------|--------------------------|-------------------|-----------|-----------
%%   Vondelpark Ent. | 0-213123233300313032331123 | 0-21312323330031321 | 0-213123322 | 0-3
%%   Leidseplein     | 0-213123233300130310001202 | 0-21312323330013031 | 0-213123322 | 0-3
%%   Dam Square      | 0-213123233300100131120221 | 0-21312323330010102 | 0-213123322 | 0-3
%%   Dom Utrecht     | 0-213123321210212311201233 | 0-21312332121021320 | 0-213123323 | 0-3

-module(isea4h).

-export([
    encode/2, encode/1,
    decode/1,
    parent/1,
    neighbors/1,
    neighbors_2/1,
    ico_verts/0,
    face_centres/0,
    cell_geometry/1
]).

-define(D2R, 0.017453292519943295). % (math:pi() / 180.0)).
-define(SQRT3_OVER_2, 0.86602540378443864676). % math:sqrt(3.0) / 2.0
-define(BASE_SCALE, 2.0).
-define(NR_FACES, 20).

%% Inradius of the gnomonic face triangle (distance from centre to each edge).
%% All 20 faces project to equilateral triangles with circumradius R ≈ 0.7640
%% and inradius r = R/2 ≈ 0.3820.  Equivalently, this is the Y-coordinate
%% at which the icosahedron vertices project onto the flat (bottom/top) edge.
-define(FACE_INRADIUS, 0.3819660112501052).

%% Outward edge normals for the two triangle orientations.
%%
%% The 20 gnomonic face triangles come in two orientations:
%%   Type A (upward, apex at bottom): faces 0-4, 6, 8, 10, 12, 14.
%%     Edges: right  (√3/2, -½), bottom (0, 1), left (-√3/2, -½).
%%   Type B (downward, apex at top):  faces 5, 7, 9, 11, 13, 15-19.
%%     Edges: right  (√3/2,  ½), left  (-√3/2,  ½), top (0, -1).
%%
%% Faces 0-4 share the north-pole vertex (ico vertex 0), faces 15-19 share
%% the south-pole vertex (ico vertex 11).  Faces 5-14 alternate: even
%% indices are Type A (upward mid-ring), odd indices are Type B (downward).
-define(FACE_NORMALS_A, [{?SQRT3_OVER_2, -0.5}, {0.0, 1.0}, {-?SQRT3_OVER_2, -0.5}]).
-define(FACE_NORMALS_B, [{?SQRT3_OVER_2, 0.5}, {-?SQRT3_OVER_2, 0.5}, {0.0, -1.0}]).

-define(DIRS, [{1,0}, {-1,0}, {0,1}, {0,-1}, {1,-1}, {-1,1}]).
-define(DIRS2, [                                       
      {2,0}, {-2,0}, {0,2}, {0,-2}, {2,-2}, {-2,2}, 
      {2,-1}, {1,1}, {-1,2}, {-2,1}, {-1,-1}, {1,-2}
]).

encode(Coord) ->
    encode(Coord, 7).

encode({Lat, Lon}, Res) when Res >= 1, Res =< 24 ->
    XYZ = to_xyz({Lat, Lon}),
    Face = nearest_face(XYZ),
    Axial = project(XYZ, Face),
    SnappedAxial = to_grid(Axial, Res),
    to_code(Face, SnappedAxial, Res).

decode(<<FaceBin:1/binary, $-, DigitsBin/binary>>) ->
    Face = binary_to_integer(FaceBin, ?NR_FACES),
    Res = byte_size(DigitsBin),
    Axial = from_digits(DigitsBin, Res),
    Scale = scale(Res),
    Cartesian = axial_to_cartesian(Axial, Scale),
    XYZ = unproject(Cartesian, Face),
    from_xyz(XYZ).

parent(<<_:1/binary, $-, DigitsBin/binary>>=Code) ->
    case byte_size(DigitsBin) > 1 of
        true  ->
            binary:part(Code, 0, byte_size(Code) - 1);
        false ->
            Code
    end.

neighbors(Code) ->
    compute_neighbors(Code, ?DIRS).

neighbors_2(Code) ->
    compute_neighbors(Code, ?DIRS2).

compute_neighbors(<<FaceBin:1/binary, $-, Digits/binary>>, Dirs) ->
    Face = binary_to_integer(FaceBin, ?NR_FACES),
    Res = byte_size(Digits),
    CellAxial = from_digits(Digits, Res),
    Scale = scale(Res),
    [begin
         Cartesian = axial_to_cartesian(plus(CellAxial, Delta), Scale),
         XYZ = unproject(Cartesian, Face),
         NewFace = nearest_face(XYZ),
         Axial = project(XYZ, NewFace),
         SnappedAxial = to_grid(Axial, Res),
         FaceOut = integer_to_binary(NewFace, ?NR_FACES),
         ND = to_digits(SnappedAxial, Res),
         <<FaceOut/binary, $-, ND/binary>>
     end || Delta <- Dirs].

cell_geometry(<<_:1/binary, $-, DigitsBin/binary>>=Code) -> 
     cell_geometry(Code, byte_size(DigitsBin)).
                           
cell_geometry(<<FaceBin:1/binary, $-, DigitsBin/binary>>, Res) -> 
    Face = binary_to_integer(FaceBin, ?NR_FACES),                     
    CellAxial = from_digits(DigitsBin, byte_size(DigitsBin)),         
    Scale = scale(Res),
    Normals = face_edge_normals(Face),

    S = 1.0 / 3.0,                                       
    CornerOffsets = [                                   
                     {2*S, -S}, {S, S}, {-S, 2*S},                  
                     {-2*S, S}, {-S, -S}, {S, -2*S}                
                    ],                                               
                                                    
    [begin
        Cartesian = axial_to_cartesian(plus(CellAxial, Delta), Scale),
        Snapped = snap_to_face(Cartesian, Normals, Scale),
        from_xyz(unproject(Snapped, Face))
     end || Delta <- CornerOffsets].

%% --- face edge clamping ---

%% Return the three outward edge normals for the gnomonic face triangle.
%% Faces 0-4 are the north-pole cap (Type A), faces 15-19 are the south-pole
%% cap (Type B).  The mid-ring faces 5-14 alternate: even = A, odd = B.
face_edge_normals(Face) when Face =< 4 -> ?FACE_NORMALS_A;
face_edge_normals(Face) when Face >= 15 -> ?FACE_NORMALS_B;
face_edge_normals(Face) -> % 5..14
    case Face band 1 of
        0 -> ?FACE_NORMALS_A;
        1 -> ?FACE_NORMALS_B
    end.

%% Snap a 2-D Cartesian point onto the face edge when it is close to
%% (or beyond) the gnomonic face triangle boundary.  For each outward
%% normal N, if N · P > INRADIUS − Scale the point is within one cell
%% width of the edge and we move it to lie exactly on the edge.  This
%% ensures hexagons on both sides of a face boundary have their
%% edge-facing corners on the shared icosahedron edge, eliminating gaps.
snap_to_face(P, Normals, Scale) ->
    lists:foldl(fun(N, Acc) ->
                        snap_edge(Acc, N, Scale)
                end,
                P,
                Normals).

snap_edge(A, Normal, Scale) ->
    Dot = dot(A, Normal),
    case Dot > ?FACE_INRADIUS - Scale of
        true ->
            Excess = Dot - ?FACE_INRADIUS,
            sub(A, scale(Excess, Normal));
        false ->
            A
    end.

%% --- sphere geometry ---

axial_to_cartesian({Q, R}, Scale) ->
    {(Q + R * 0.5) * Scale, R * ?SQRT3_OVER_2 * Scale}.

scale(Res) ->
    ?BASE_SCALE / math:pow(2.0, Res).

to_xyz({Lat, Lon}) ->
    Lo = Lon * ?D2R,
    La = Lat * ?D2R,
    {math:cos(La)*math:cos(Lo), math:cos(La)*math:sin(Lo), math:sin(La)}.

from_xyz({X, Y, Z}) ->
    Lon = math:atan2(Y, X) / ?D2R,
    Lat = math:asin(Z) / ?D2R,
    {Lat, Lon}.

face_centres() ->
    case persistent_term:get({?MODULE, face_centres}, undefined) of
        undefined ->
            VT = list_to_tuple(ico_verts()),
            Centres = [begin
                 {Ax,Ay,Az} = element(A+1, VT),
                 {Bx,By,Bz} = element(B+1, VT),
                 {Cx,Cy,Cz} = element(C+1, VT),
                 unit({(Ax+Bx+Cx)/3.0, (Ay+By+Cy)/3.0, (Az+Bz+Cz)/3.0})
             end || {A,B,C} <- ico_faces()],
            persistent_term:put({?MODULE, face_centres}, Centres),
            Centres;
        Centres -> Centres
    end.

ico_faces() ->
    [{0,1,2}, {0,2,3}, {0,3,4}, {0,4,5}, {0,5,1},
     {1,6,2}, {2,6,7}, {2,7,3}, {3,7,8}, {3,8,4},
     {4,8,9}, {4,9,5}, {5,9,10}, {5,10,1}, {1,10,6},
     {6,11,7}, {7,11,8}, {8,11,9}, {9,11,10}, {10,11,6}].

ico_verts() ->
    case persistent_term:get({?MODULE, ico_verts}, undefined) of
        undefined ->
            UpLat = math:atan(0.5) / ?D2R,
            DnLat = -UpLat,
            Verts = [to_xyz({90.0, 0.0})]
            ++ [to_xyz({UpLat, I*72.0}) || I <- lists:seq(0,4)]
            ++ [to_xyz({DnLat, I*72.0+36.0}) || I <- lists:seq(0,4)]
            ++ [to_xyz({-90.0, 0.0})],
            persistent_term:put({?MODULE, ico_verts}, Verts),
            Verts;
        Verts -> Verts
    end.

nearest_face({X, Y, Z}) ->
    Cs = face_centres(),
    Pairs = lists:zip([X*Cx+Y*Cy+Z*Cz || {Cx,Cy,Cz} <- Cs], lists:seq(0, length(Cs)-1)),
    {_, Idx} = lists:foldl(fun({D,I},{BD,_}) when D > BD ->
                                   {D,I};
                               (_, Acc) ->
                                   Acc
                           end,
                           {-2.0,0},
                           Pairs),
    Idx.

face_basis(Face) ->
    {Cx,Cy,Cz} = lists:nth(Face+1, face_centres()),
    RawU = cross({Cx,Cy,Cz}, {0.0,0.0,1.0}),
    {Ux0,Uy0,Uz0} = RawU,
    UU = case abs(Ux0)+abs(Uy0)+abs(Uz0) < 1.0e-10 of
             true  -> cross({Cx,Cy,Cz}, {1.0,0.0,0.0});
             false -> RawU
         end,
    U = unit(UU),
    V = unit(cross({Cx,Cy,Cz}, U)),
    {{Cx,Cy,Cz}, U, V}.

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

%% --- grid snapping ---

to_grid({X, Y}, Res) ->
    Scale = scale(Res),
    Rf = Y / (Scale * ?SQRT3_OVER_2),
    Qf = X / Scale - Rf * 0.5,
    hex_round(Qf, Rf).

hex_round(Qf, Rf) ->
    Sf = -Qf - Rf,
    Qi = round(Qf), Ri = round(Rf), Si = round(Sf),
    DQ = abs(Qi-Qf), DR = abs(Ri-Rf), DS = abs(Si-Sf),
    if
        DQ > DR, DQ > DS ->
            {-Ri-Si, Ri};
        DR > DS ->
            {Qi, -Qi-Si};
        true ->
            {Qi, Ri}
    end.

%% --- digit encoding (returns flat charlist) ---

to_code(Face, Axial, Res) ->
    Digits = to_digits(Axial, Res),
    FaceBin = integer_to_binary(Face, ?NR_FACES),
    <<FaceBin/binary, $-, Digits/binary>>.

to_digits({QG, RG}, Res) ->
    Off = 1 bsl (Res-1),
    to_digits1(QG + Off, RG + Off, Res-1, <<>>).

to_digits1(Q, R, L, Acc) when L >= 0 ->
    N = ((Q bsr L) band 1) * 2 + ((R bsr (L)) band 1),
    to_digits1(Q, R, L-1, <<Acc/binary, (N + $0)>>);
to_digits1(_Q, _R, _L, Acc) ->
    Acc.

from_digits(Digits, Res) when is_binary(Digits) ->
    from_digits(binary_to_list(Digits), Res);
from_digits(Digits, Res) ->
    Off = 1 bsl (Res-1),
    {Q, R} = lists:foldl(
               fun({D, L}, {Qa, Ra}) ->
                       Bit = Res - L,
                       {Qa + ((D bsr 1) bsl Bit), Ra + ((D band 1) bsl Bit)}
               end,
               {0, 0},
               lists:zip([C - $0 || C <- Digits], lists:seq(1, Res))),
    {Q - Off, R - Off}.


%% --- math helpers ---

unit({X, Y, Z}) ->
    R = math:sqrt(X*X + Y*Y + Z*Z),
    if
        R < 1.0e-12 ->
            {1.0, 0.0, 0.0};
        true ->
            {X/R, Y/R, Z/R}
    end.

cross({Ax, Ay, Az}, {Bx, By, Bz}) ->
    {Ay*Bz - Az*By,
     Az*Bx - Ax*Bz,
     Ax*By - Ay*Bx}.

plus({E1, E2}, {F1, F2}) ->
    {E1 + F1, E2 + F2}.

dot({Ax, Ay}, {Bx, By}) ->
    Ax * Bx + Ay * By.

scale(S, {X, Y}) ->
    {S * X, S * Y}.

sub({Ax, Ay}, {Bx, By}) ->
    {Ax - Bx, Ay - By}.
