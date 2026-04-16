%% @doc Hexveil - Icosahedral Gnomonic Aperture 4 Hexagon.
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
%%
%% Edge Mapping and Gaps:
%% This implementation accepts small geometric gaps at the icosahedral face
%% boundaries. Because each 2D triangular face is a flat projection, the 
%% hexagons at the edges do not perfectly "touch" their neighbors in 3D 
%% Lat/Lon space.
%%
%% However, encoding is always continuous:
%% 1. Every coordinate on the sphere is closer to one of the 20 face centers.
%% 2. nearest_face/1 assigns the coordinate to that face's domain.
%% 3. The coordinate is projected onto that face's plane and mapped to the
%%    nearest integer hexagon.
%%
%% This ensures that any point falling into a "geometric gap" is naturally
%% captured by the nearest hexagon on the dominant face.

-module(hexveil).

-export([
    encode/2, encode/1,
    decode/1,
    parent/1,
    neighbors/1,
    neighbors_2/1,
    ico_verts/0,
    face_centres/0,
    cell_geometry/1,
    from_xyz/1
]).

-on_load(init_persistent_terms/0).

-define(D2R, 0.017453292519943295). % (math:pi() / 180.0)).
-define(SQRT3_OVER_2, 0.86602540378443864676). % math:sqrt(3.0) / 2.0
-define(BASE_SCALE, 2.0).
-define(NR_FACES, 20).

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
    {Q, R} = to_grid(Axial, Res),
    to_code(Face, {round(Q), round(R)}, Res).

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
         %% Optimized topological search
         NewFace = nearest_face(XYZ, Face),
         Axial = project(XYZ, NewFace),
         {Q, R} = to_grid(Axial, Res),
         FaceOut = integer_to_binary(NewFace, ?NR_FACES),
         ND = to_digits({round(Q), round(R)}, Res),
         <<FaceOut/binary, $-, ND/binary>>
     end || Delta <- Dirs].

cell_geometry(<<_:1/binary, $-, DigitsBin/binary>>=Code) -> 
     cell_geometry(Code, byte_size(DigitsBin)).
                           
cell_geometry(<<FaceBin:1/binary, $-, DigitsBin/binary>>, Res) -> 
    Face = binary_to_integer(FaceBin, ?NR_FACES),                     
    CellAxial = from_digits(DigitsBin, byte_size(DigitsBin)),         
    Scale = scale(Res),

    S = 1.0 / 3.0,                                       
    CornerOffsets = [                                   
                     {2*S, -S}, {S, S}, {-S, 2*S},                  
                     {-2*S, S}, {-S, -S}, {S, -2*S}                
                    ],                                               

    [begin
        Cartesian = axial_to_cartesian(plus(CellAxial, Delta), Scale),
        XYZ = unproject(Cartesian, Face),
        from_xyz(XYZ)
     end || Delta <- CornerOffsets].

%% --- topological navigation ---

%% Optimized nearest_face that checks a hint and its neighbors first.
nearest_face(XYZ) ->
    nearest_face(XYZ, face_centres(), 0, -2.0, 0).

nearest_face({X,Y,Z}=XYZ, HintFace) ->
    Neighbors = element(HintFace+1, face_adjacencies()),
    CheckFaces = tuple_to_list(Neighbors),
    {Cx,Cy,Cz} = lists:nth(HintFace+1, face_centres()),
    D = X*Cx + Y*Cy + Z*Cz,
    search_faces(XYZ, CheckFaces, D, HintFace).


search_faces(_XYZ, [], _MaxD, MaxIdx) ->
    MaxIdx;
search_faces({X,Y,Z}=XYZ, [FaceIdx|Rest], MaxD, MaxIdx) ->
    {Cx,Cy,Cz} = lists:nth(FaceIdx+1, face_centres()),
    D = X*Cx + Y*Cy + Z*Cz,
    if D > MaxD -> search_faces(XYZ, Rest, D, FaceIdx);
       true -> search_faces(XYZ, Rest, MaxD, MaxIdx)
    end.

face_adjacencies() ->
    case persistent_term:get({?MODULE, face_adjacencies}, undefined) of
        undefined ->
            Faces = ico_faces(),
            Adj = [begin
                {V0, V1, V2} = lists:nth(I+1, Faces),
                {find_neighbor(I, V1, V2, Faces),
                 find_neighbor(I, V2, V0, Faces),
                 find_neighbor(I, V0, V1, Faces)}
            end || I <- lists:seq(0, 19)],
            T = list_to_tuple(Adj),
            persistent_term:put({?MODULE, face_adjacencies}, T),
            T;
        T -> T
    end.

find_neighbor(MyIdx, Va, Vb, Faces) ->
    [NeighborIdx] = [Idx || {Idx, F} <- lists:zip(lists:seq(0, 19), Faces),
                            Idx /= MyIdx,
                            lists:member(Va, tuple_to_list(F)),
                            lists:member(Vb, tuple_to_list(F))],
    NeighborIdx.

%% --- sphere geometry ---

axial_to_cartesian({Q, R}, Scale) ->
    {(Q + R * 0.5) * Scale, R * ?SQRT3_OVER_2 * Scale}.

to_xyz({Lat, Lon}) ->
    Lo = Lon * ?D2R,
    La = Lat * ?D2R,
    {math:cos(La)*math:cos(Lo), math:cos(La)*math:sin(Lo), math:sin(La)}.

from_xyz({X, Y, Z}) ->
    Lon = math:atan2(Y, X) / ?D2R,
    Lat = math:asin(Z) / ?D2R,
    {Lat, Lon}.

face_centres() ->
    persistent_term:get({?MODULE, face_centres}, undefined).

ico_faces() ->
    [{0,1,2}, {0,2,3}, {0,3,4}, {0,4,5}, {0,5,1},
     {1,6,2}, {2,6,7}, {2,7,3}, {3,7,8}, {3,8,4},
     {4,8,9}, {4,9,5}, {5,9,10}, {5,10,1}, {1,10,6},
     {6,11,7}, {7,11,8}, {8,11,9}, {9,11,10}, {10,11,6}].

ico_verts() ->
    persistent_term:get({?MODULE, ico_verts}).

nearest_face(_XYZ, [], _Idx, _MaxD, MaxIdx) ->
    MaxIdx;
nearest_face({X,Y,Z}=XYZ, [{Cx,Cy,Cz}|Rest], Idx, MaxD, MaxIdx) ->
    D = X*Cx + Y*Cy + Z*Cz,
    if D > MaxD -> nearest_face(XYZ, Rest, Idx+1, D, Idx);
       true -> nearest_face(XYZ, Rest, Idx+1, MaxD, MaxIdx)
    end.

face_bases() ->
    persistent_term:get({?MODULE, face_bases}).

face_basis(Face) ->
    element(Face+1, face_bases()).

face_bins() ->
    persistent_term:get({?MODULE, face_bins}).

scales() ->
    persistent_term:get({?MODULE, scales}).

scale(Res) when Res >= 0, Res =< 24 ->
    element(Res+1, scales()).

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
    S = scale(Res),
    Rf = Y / (S * ?SQRT3_OVER_2),
    Qf = X / S - Rf * 0.5,
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
    FaceBin = element(Face+1, face_bins()),
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
    Off = 1 bsl (Res-1),
    from_digits_rec(Digits, Res, 1, 0, 0, Off).

from_digits_rec(<<D, Rest/binary>>, Res, L, Qa, Ra, Off) ->
    Bit = Res - L,
    Val = D - $0,
    from_digits_rec(Rest, Res, L+1, Qa + ((Val bsr 1) bsl Bit), Ra + ((Val band 1) bsl Bit), Off);
from_digits_rec(<<>>, _Res, _L, Qa, Ra, Off) ->
    {Qa - Off, Ra - Off}.

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

%% 
%% Persistent terms
%%

init_persistent_terms() ->
    ico_verts_init(),
    face_centres_init(),
    face_bases_init(),
    face_bins_init(),
    scales_init(),
    ok.

ico_verts_init() ->
    UpLat = math:atan(0.5) / ?D2R,
    DnLat = -UpLat,
    Verts = [to_xyz({90.0, 0.0})]
             ++ [to_xyz({UpLat, I*72.0}) || I <- lists:seq(0,4)]
             ++ [to_xyz({DnLat, I*72.0+36.0}) || I <- lists:seq(0,4)]
             ++ [to_xyz({-90.0, 0.0})],
    persistent_term:put({?MODULE, ico_verts}, Verts).

face_centres_init() ->
    VT = list_to_tuple(ico_verts()),
    Centres = [begin
                   {Ax,Ay,Az} = element(A+1, VT),
                   {Bx,By,Bz} = element(B+1, VT),
                   {Cx,Cy,Cz} = element(C+1, VT),
                   unit({(Ax+Bx+Cx)/3.0, (Ay+By+Cy)/3.0, (Az+Bz+Cz)/3.0})
               end || {A,B,C} <- ico_faces()],
    persistent_term:put({?MODULE, face_centres}, Centres).

face_bases_init() ->
    Bases = [begin
                 Centre = lists:nth(I+1, face_centres()),
                 RawU = cross(Centre, {0.0,0.0,1.0}),
                 {Ux0,Uy0,Uz0} = RawU,
                 UU = case abs(Ux0)+abs(Uy0)+abs(Uz0) < 1.0e-10 of
                          true  -> cross(Centre, {1.0,0.0,0.0});
                          false -> RawU
                      end,
                 U = unit(UU),
                 V = unit(cross(Centre, U)),
                 {Centre, U, V}
             end || I <- lists:seq(0, ?NR_FACES-1)],
    BasesTuple = list_to_tuple(Bases),
    persistent_term:put({?MODULE, face_bases}, BasesTuple).

face_bins_init() ->
    Bins = [integer_to_binary(I, ?NR_FACES) || I <- lists:seq(0, ?NR_FACES-1)],
    BinsTuple = list_to_tuple(Bins),
    persistent_term:put({?MODULE, face_bins}, BinsTuple).

scales_init() ->
    Scales = [?BASE_SCALE / math:pow(2.0, R) || R <- lists:seq(0, 24)],
    ScalesTuple = list_to_tuple(Scales),
    persistent_term:put({?MODULE, scales}, ScalesTuple).

