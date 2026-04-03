-module(isea4h).
-export([encode/3, encode/2, privacy_code/3, parent/1, neighbors/1, decode/1, ico_verts/0]).

-define(D2R, math:pi() / 180.0).
-define(BASE_SCALE, 0.58).

encode(Lon, Lat, Res) when Res >= 1, Res =< 12 ->
    {X, Y, Z} = to_xyz(Lon, Lat),
    Face = nearest_face(X, Y, Z),
    {Q, R} = project(X, Y, Z, Face),
    {QG, RG} = to_grid(Q, R, Res),
    Digits = to_digits(QG, RG, Res),
    FaceStr = io_lib:format("~2..0B", [Face]),
    iolist_to_binary([FaceStr, "-", Digits]).

encode(Lon, Lat) ->
    encode(Lon, Lat, 7).

privacy_code(Lon, Lat, city) ->
    encode(Lon, Lat, 4);
privacy_code(Lon, Lat, district) ->
    encode(Lon, Lat, 6);
privacy_code(Lon, Lat, neighbourhood) ->
    encode(Lon, Lat, 7);
privacy_code(Lon, Lat, block) ->
    encode(Lon, Lat, 9).

parent(Code) when is_binary(Code) -> parent(binary_to_list(Code));
parent(Code) ->
    [Face, Digits] = string:split(Code, "-"),
    case length(Digits) > 1 of
        true  -> iolist_to_binary([Face, "-", lists:droplast(Digits)]);
        false -> iolist_to_binary([Face, "-", Digits])
    end.

neighbors(Code) when is_binary(Code) -> neighbors(binary_to_list(Code));
neighbors(Code) ->
    [FaceStr, Digits] = string:split(Code, "-"),
    Face = list_to_integer(FaceStr),
    Res  = length(Digits),
    {QG, RG} = from_digits(Digits, Res),
    Dirs = [{1,0},{-1,0},{0,1},{0,-1},{1,-1},{-1,1}],
    [begin
         ND = to_digits(QG+DQ, RG+DR, Res),
         iolist_to_binary([io_lib:format("~2..0B",[Face]), "-", ND])
     end || {DQ,DR} <- Dirs].

decode(Code) when is_binary(Code) -> decode(binary_to_list(Code));
decode(Code) ->
    [FaceStr, Digits] = string:split(Code, "-"),
    Face = list_to_integer(FaceStr),
    Res = length(Digits),
    {QG, RG} = from_digits(Digits, Res),
    Scale = ?BASE_SCALE / math:pow(2.0, Res),
    Qf = QG * Scale,
    Rf = RG * Scale,
    {X, Y, Z} = unproject(Qf, Rf, Face),
    Lon = math:atan2(Y, X) / ?D2R,
    Lat = math:asin(Z) / ?D2R,
    {Lon, Lat}.

%% --- sphere geometry ---

to_xyz(Lon, Lat) ->
    Lo = Lon * ?D2R, La = Lat * ?D2R,
    {math:cos(La)*math:cos(Lo),
     math:cos(La)*math:sin(Lo),
     math:sin(La)}.

ico_verts() ->
    UpLat = math:atan(0.5) / ?D2R,
    DnLat = -UpLat,
    [to_xyz(0.0, 90.0)]
    ++ [to_xyz(I*72.0, UpLat) || I <- lists:seq(0,4)]
    ++ [to_xyz(I*72.0+36.0,  DnLat) || I <- lists:seq(0,4)]
    ++ [to_xyz(0.0, -90.0)].

ico_faces() ->
    [{0,1,2}, {0,2,3}, {0,3,4}, {0,4,5}, {0,5,1},
     {1,6,2},
     {2,6,7}, {2,7,3},
     {3,7,8}, {3,8,4},
     {4,8,9}, {4,9,5},
     {5,9,10}, {5,10,1},
     {1,10,6},
     {6,11,7},
     {7,11,8},
     {8,11,9},
     {9,11,10},
     {10,11,6}].

face_centres() ->
    VT = list_to_tuple(ico_verts()),
    [begin
         {Ax,Ay,Az} = element(A+1, VT),
         {Bx,By,Bz} = element(B+1, VT),
         {Cx,Cy,Cz} = element(C+1, VT),
         unit({(Ax+Bx+Cx)/3.0, (Ay+By+Cy)/3.0, (Az+Bz+Cz)/3.0})
     end || {A,B,C} <- ico_faces()].

nearest_face(X, Y, Z) ->
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

project(X, Y, Z, Face) ->
    {{Cx,Cy,Cz},{Ux,Uy,Uz},{Vx,Vy,Vz}} = face_basis(Face),
    D  = X*Cx + Y*Cy + Z*Cz,
    Px = X/D-Cx, Py = Y/D-Cy, Pz = Z/D-Cz,
    {Px*Ux+Py*Uy+Pz*Uz, Px*Vx+Py*Vy+Pz*Vz}.

unproject(Qf, Rf, Face) ->
    {{Cx,Cy,Cz},{Ux,Uy,Uz},{Vx,Vy,Vz}} = face_basis(Face),
    unit({Cx + Qf*Ux + Rf*Vx,
          Cy + Qf*Uy + Rf*Vy,
          Cz + Qf*Uz + Rf*Vz}).

%% --- grid snapping ---

to_grid(Q, R, Res) ->
    Scale = ?BASE_SCALE / math:pow(2.0, Res),
    hex_round(Q / Scale, R / Scale).

hex_round(Qf, Rf) ->
    Sf = -Qf - Rf,
    Qi = round(Qf), Ri = round(Rf), Si = round(Sf),
    DQ = abs(Qi-Qf), DR = abs(Ri-Rf), DS = abs(Si-Sf),
    if DQ > DR, DQ > DS -> {-Ri-Si, Ri};
       DR > DS           -> {Qi, -Qi-Si};
       true              -> {Qi, Ri}
    end.

%% --- digit encoding (returns flat charlist) ---

to_digits(QG, RG, Res) ->
    Off = 1 bsl Res,
    Q   = QG + Off,
    R   = RG + Off,
    [$0 + ((Q bsr (Res-L)) band 1)*2 + ((R bsr (Res-L)) band 1)
     || L <- lists:seq(1, Res)].

from_digits(Digits, Res) ->
    Off = 1 bsl Res,
    {Q, R} = lists:foldl(
        fun({D, L}, {Qa, Ra}) ->
            Bit = Res - L,
            {Qa + ((D bsr 1) bsl Bit),
             Ra + ((D band 1) bsl Bit)}
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

cross({Ax, Ay, Az},{Bx, By, Bz}) ->
    {Ay*Bz - Az*By, Az*Bx - Ax*Bz, Ax*By - Ay*Bx}.

