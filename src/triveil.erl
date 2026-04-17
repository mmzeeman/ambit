%% @doc Triveil - Icosahedral Gnomonic Aperture 4 Triangles.
%% Uses the exact same projection engine as Hexveil for alignment.

-module(triveil).

-export([
    encode/2, encode/1,
    decode/1,
    disk/2, disk/3,
    parent/1,
    cell_geometry/1,
    neighbors/1,
    neighbors_2/1,
    from_xyz/1
]).

-on_load(init_persistent_terms/0).

-define(D2R, 0.017453292519943295).
-define(DEFAULT_RES, 7).
-define(EARTH_RADIUS_M, 6371000.0).
-define(NR_FACES, 20).

encode(Coord) ->
    encode(Coord, ?DEFAULT_RES).

encode({Lat, Lon}, Res) when Res >= 1, Res =< 24 ->
    XYZ = to_xyz({Lat, Lon}),
    FaceIdx = nearest_face(XYZ),
    
    %% Use the same 2D projection as hexveil
    {X, Y} = project(XYZ, FaceIdx),
    
    %% Get face vertices in the same 2D space
    {V1, V2, V3} = face_verts_2d(FaceIdx),
    
    Digits = sub_encode({X, Y}, {V1, V2, V3}, Res, <<>>),
    FaceBin = element(FaceIdx+1, face_bins()),
    <<FaceBin/binary, $-, Digits/binary>>.

decode(<<FaceBin:1/binary, $-, DigitsBin/binary>>) ->
    FaceIdx = binary_to_integer(FaceBin, ?NR_FACES),
    {V1, V2, V3} = face_verts_2d(FaceIdx),
    {RV1, RV2, RV3} = sub_decode(DigitsBin, V1, V2, V3),
    
    %% Centroid in 2D space
    {CX, CY} = {(element(1,RV1)+element(1,RV2)+element(1,RV3))/3.0,
                (element(2,RV1)+element(2,RV2)+element(2,RV3))/3.0},
    
    %% Unproject using the same hexveil logic
    XYZ = unproject({CX, CY}, FaceIdx),
    from_xyz(XYZ).

disk(Code, DiameterMeters) when is_binary(Code), is_number(DiameterMeters), DiameterMeters >= 0 ->
    case binary:split(Code, <<"-">>) of
        [_, Digits] when byte_size(Digits) > 0 ->
            try decode(Code) of
                {Lat, Lon} ->
                    Res = byte_size(Digits),
                    disk_from_center({Lat, Lon}, Res, DiameterMeters)
            catch
                _:_ ->
                    erlang:error(badarg)
            end;
        _ ->
            erlang:error(badarg)
    end;
disk({Lat, Lon}, DiameterMeters) when is_number(Lat), is_number(Lon), is_number(DiameterMeters), DiameterMeters >= 0 ->
    disk({Lat, Lon}, ?DEFAULT_RES, DiameterMeters).

disk({Lat, Lon}, Res, DiameterMeters)
  when is_number(Lat), is_number(Lon), is_integer(Res), Res > 0, is_number(DiameterMeters), DiameterMeters >= 0 ->
    disk_from_center({Lat, Lon}, Res, DiameterMeters).

disk_from_center(Center, Res, DiameterMeters) ->
    CenterCode = encode(Center, Res),
    RadiusMeters = DiameterMeters / 2.0,
    Visited0 = sets:add_element(CenterCode, sets:new([{version, 2}])),
    Queue0 = queue:from_list([CenterCode]),
    disk_bfs(Center, RadiusMeters, Queue0, Visited0, [CenterCode]).

disk_bfs(Center, RadiusMeters, Queue0, Visited, Acc) ->
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
                            DistMeters = great_circle_distance(Center, decode(NCode)),
                            case DistMeters =< RadiusMeters of
                                true -> {queue:in(NCode, Q0), V1, [NCode | A0]};
                                false -> {Q0, V1, A0}
                            end
                    end
                end,
                {Queue1, Visited, Acc},
                neighbors(Code)
            ),
            disk_bfs(Center, RadiusMeters, Queue2, Visited1, Acc1)
    end.

great_circle_distance(P1, P2) ->
    {X1, Y1, Z1} = to_xyz(P1),
    {X2, Y2, Z2} = to_xyz(P2),
    Dot0 = X1*X2 + Y1*Y2 + Z1*Z2,
    Dot = if
        Dot0 > 1.0 -> 1.0;
        Dot0 < -1.0 -> -1.0;
        true -> Dot0
    end,
    math:acos(Dot) * ?EARTH_RADIUS_M.

parent(<<FaceDigits:1/binary, $-, Digits/binary>>) ->
    case byte_size(Digits) > 1 of
        true  -> <<FaceDigits/binary, $-, (binary:part(Digits, 0, byte_size(Digits)-1))/binary>>;
        false -> <<FaceDigits/binary, $-, Digits/binary>>
    end.

cell_geometry(<<FaceBin:1/binary, $-, DigitsBin/binary>>) ->
    FaceIdx = binary_to_integer(FaceBin, ?NR_FACES),
    {V1, V2, V3} = face_verts_2d(FaceIdx),
    {RV1, RV2, RV3} = sub_decode(DigitsBin, V1, V2, V3),
    
    [from_xyz(unproject(RV1, FaceIdx)),
     from_xyz(unproject(RV2, FaceIdx)),
     from_xyz(unproject(RV3, FaceIdx))].

%% --- Recursive Subdivision (2D Local Space) ---

sub_encode(_P, _Verts, 0, Acc) -> Acc;
sub_encode(P, {V1, V2, V3}, Res, Acc) ->
    M12 = mid_2d(V1, V2),
    M23 = mid_2d(V2, V3),
    M31 = mid_2d(V3, V1),
    
    {U, V, W} = barycentric_2d(P, V1, V2, V3),
    
    Digit = if
        U >= 0.5 -> $1;
        V >= 0.5 -> $2;
        W >= 0.5 -> $3;
        true     -> $0
    end,
    
    NewVerts = case Digit of
        $1 -> {V1, M12, M31};
        $2 -> {V2, M12, M23};
        $3 -> {V3, M23, M31};
        $0 -> {M12, M23, M31}
    end,
    sub_encode(P, NewVerts, Res-1, <<Acc/binary, Digit>>).

sub_decode(<<Digit, Rest/binary>>, V1, V2, V3) ->
    M12 = mid_2d(V1, V2),
    M23 = mid_2d(V2, V3),
    M31 = mid_2d(V3, V1),
    {NV1, NV2, NV3} = case Digit of
        $1 -> {V1, M12, M31};
        $2 -> {V2, M12, M23};
        $3 -> {V3, M23, M31};
        $0 -> {M12, M23, M31}
    end,
    sub_decode(Rest, NV1, NV2, NV3);
sub_decode(<<>>, V1, V2, V3) ->
    {V1, V2, V3}.

%% --- Neighbors logic ---

neighbors(Code) ->
    compute_neighbors(Code, 12). %% 12 directions (edge + vertex)

neighbors_2(Code) ->
    N1 = neighbors(Code),
    All = lists:usort(lists:flatten([neighbors(C) || C <- N1])),
    All -- [Code | N1].

compute_neighbors(Code, NumDirs) ->
    {Lat, Lon} = decode(Code),
    [_, Digits] = binary:split(Code, <<"-">>),
    Res = byte_size(Digits),
    XYZ = to_xyz({Lat, Lon}),
    FaceIdx = nearest_face(XYZ),
    {V1, V2, V3} = face_verts_2d(FaceIdx),
    
    {RV1, RV2, _RV3} = sub_decode(Digits, V1, V2, V3),
    Side = dist_2d(RV1, RV2),
    Shift = Side * 0.9, %% Move far enough to hit the next triangle
    
    Angles = [I * (2 * math:pi() / NumDirs) || I <- lists:seq(0, NumDirs-1)],
    {CX, CY} = project(XYZ, FaceIdx),
    
    lists:usort([begin
        SX = CX + Shift * math:cos(A),
        SY = CY + Shift * math:sin(A),
        NewXYZ = unproject({SX, SY}, FaceIdx),
        
        %% Optimized encoding using Hint
        NewFaceIdx = nearest_face(NewXYZ, FaceIdx),
        {NX, NY} = project(NewXYZ, NewFaceIdx),
        {V1n, V2n, V3n} = face_verts_2d(NewFaceIdx),
        NDigits = sub_encode({NX, NY}, {V1n, V2n, V3n}, Res, <<>>),
        FaceBin = element(NewFaceIdx+1, face_bins()),
        <<FaceBin/binary, $-, NDigits/binary>>
    end || A <- Angles]) -- [Code].

dist_2d({X1,Y1}, {X2,Y2}) ->
    DX = X1-X2, DY = Y1-Y2,
    math:sqrt(DX*DX + DY*DY).

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

barycentric_2d({Px,Py}, {V1x,V1y}, {V2x,V2y}, {V3x,V3y}) ->
    Det = (V2y-V3y)*(V1x-V3x) + (V3x-V2x)*(V1y-V3y),
    U = ((V2y-V3y)*(Px-V3x) + (V3x-V2x)*(Py-V3y)) / Det,
    V = ((V3y-V1y)*(Px-V3x) + (V1x-V3x)*(Py-V3y)) / Det,
    {U, V, 1.0-U-V}.

mid_2d({X1,Y1}, {X2,Y2}) ->
    {(X1+X2)/2.0, (Y1+Y2)/2.0}.

%% --- Standard Geometry ---

to_xyz({Lat, Lon}) ->
    Lo = Lon * ?D2R,
    La = Lat * ?D2R,
    {math:cos(La)*math:cos(Lo), math:cos(La)*math:sin(Lo), math:sin(La)}.

from_xyz({X, Y, Z}) ->
    Lon = math:atan2(Y, X) / ?D2R,
    Lat = math:asin(Z) / ?D2R,
    {Lat, Lon}.

unit({X, Y, Z}) ->
    R = math:sqrt(X*X + Y*Y + Z*Z),
    {X/R, Y/R, Z/R}.

cross({Ax, Ay, Az}, {Bx, By, Bz}) ->
    {Ay*Bz - Az*By, Az*Bx - Ax*Bz, Ax*By - Ay*Bx}.

nearest_face(XYZ) ->
    nearest_face(XYZ, face_centres_list(), 0, -2.0, 0).

nearest_face({X,Y,Z}=XYZ, HintFace) ->
    Neighbors = element(HintFace+1, face_adjacencies()),
    CheckFaces = tuple_to_list(Neighbors),
    {Cx,Cy,Cz} = lists:nth(HintFace+1, face_centres_list()),
    D = X*Cx + Y*Cy + Z*Cz,
    search_faces(XYZ, CheckFaces, D, HintFace).

search_faces(_XYZ, [], _MaxD, MaxIdx) ->
    MaxIdx;
search_faces({X,Y,Z}=XYZ, [FaceIdx|Rest], MaxD, MaxIdx) ->
    {Cx,Cy,Cz} = lists:nth(FaceIdx+1, face_centres_list()),
    D = X*Cx + Y*Cy + Z*Cz,
    if D > MaxD -> search_faces(XYZ, Rest, D, FaceIdx);
       true -> search_faces(XYZ, Rest, MaxD, MaxIdx)
    end.

nearest_face(_XYZ, [], _Idx, _MaxD, MaxIdx) ->
    MaxIdx;
nearest_face({X,Y,Z}=XYZ, [{Cx,Cy,Cz}|Rest], Idx, MaxD, MaxIdx) ->
    D = X*Cx + Y*Cy + Z*Cz,
    if D > MaxD -> nearest_face(XYZ, Rest, Idx+1, D, Idx);
       true -> nearest_face(XYZ, Rest, Idx+1, MaxD, MaxIdx)
    end.

%% --- Persistent Data ---

face_basis(Face) -> element(Face+1, persistent_term:get({?MODULE, face_bases})).
face_bins() -> persistent_term:get({?MODULE, face_bins}).
face_verts_2d(Idx) -> element(Idx+1, persistent_term:get({?MODULE, face_verts_2d})).
face_centres_list() -> persistent_term:get({?MODULE, face_centres}).
face_adjacencies() -> persistent_term:get({?MODULE, face_adjacencies}).

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
    persistent_term:put({?MODULE, face_centres}, Centres),

    %% Calculate Face Adjacencies
    Adj = [begin
        {V0, V1, V2} = lists:nth(I+1, Faces),
        {find_neighbor(I, V1, V2, Faces),
         find_neighbor(I, V2, V0, Faces),
         find_neighbor(I, V0, V1, Faces)}
    end || I <- lists:seq(0, 19)],
    persistent_term:put({?MODULE, face_adjacencies}, list_to_tuple(Adj)),

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

find_neighbor(MyIdx, Va, Vb, Faces) ->
    [NeighborIdx] = [Idx || {Idx, F} <- lists:zip(lists:seq(0, 19), Faces),
                            Idx /= MyIdx,
                            lists:member(Va, tuple_to_list(F)),
                            lists:member(Vb, tuple_to_list(F))],
    NeighborIdx.
