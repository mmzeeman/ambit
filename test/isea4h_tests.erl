-module(isea4h_tests).
-include_lib("eunit/include/eunit.hrl").

%% Round-trip encode/decode at origin
roundtrip_test() ->
    Locations = [
        {0.0, 0.0},
        {20.0, 10.0},
        {45.0, -30.0},
        {-10.0, 120.0},
        {90.0, 0.0}, % North Pole
        {-90.0, 0.0} % South Pole
    ],
    lists:foreach(fun({Lat, Lon}) ->
        Res = 7,
        Code = isea4h:encode({Lat, Lon}, Res),
        {DLat, DLon} = isea4h:decode(Code),
        MaxErr = 1.0,
        IsPole = abs(Lat) > 89.0,
        LonMatch = IsPole orelse abs(DLon - Lon) < MaxErr orelse abs(abs(DLon - Lon) - 360.0) < MaxErr,
        LatMatch = abs(DLat - Lat) < MaxErr,
        case LonMatch andalso LatMatch of
            true -> ok;
            false -> 
                io:format(user, "~nAt (~p, ~p) got (~p, ~p) code ~p~n", [Lat, Lon, DLat, DLon, Code]),
                ?assert(false)
        end
    end, Locations).

roundtrip_res_test() ->
    Lat = 20.0, Lon = 10.0,
    lists:foreach(fun(Res) ->
        Code = isea4h:encode({Lat, Lon}, Res),
        {DLat, DLon} = isea4h:decode(Code),
        %% At Res 1, error can be large (half a face).
        MaxErr = 2.0 / math:pow(2.0, Res-5), %% Heuristic
        ActualMaxErr = lists:max([1.0, MaxErr]),
        case abs(DLon - Lon) < ActualMaxErr andalso abs(DLat - Lat) < ActualMaxErr of
            true -> ok;
            false -> 
                io:format(user, "~nAt res ~p got (~p, ~p) code ~p (MaxErr ~p)~n", [Res, DLat, DLon, Code, ActualMaxErr]),
                ?assert(false)
        end
    end, lists:seq(1, 12)).

%% encode/2 should default to resolution 7
default_res_test() ->
    Code = isea4h:encode({4.56, 1.23}),
    [_,Digits] = string:split(binary_to_list(Code), "-"),
    ?assertEqual(7, length(Digits)).

%% parent should remove one digit at the end (or leave as-is for resolution 1)
parent_test() ->
    Code = isea4h:encode({20.0, 10.0}, 6),
    Parent = isea4h:parent(Code),
    [_, Digits] = string:split(binary_to_list(Code), "-"),
    [_, Pdigits] = string:split(binary_to_list(Parent), "-"),
    ?assertEqual(length(Digits)-1, length(Pdigits)).

%% neighbors returns six binary neighbor codes
neighbors_test() ->
    Code = isea4h:encode({20.0, 10.0}, 5),
    N = isea4h:neighbors(Code),
    ?assertEqual(6, length(N)),
    lists:foreach(fun(C) -> ?assert(is_binary(C)) end, N).

%% Test that neighbors are geographically close to the center cell,
%% even when crossing face boundaries.
neighor_consistency_test() ->
    %% Pick several points, including some near known boundaries (vertices).
    TestPoints = [
        {0.0, 0.0},
        {45.0, 45.0},
        {89.9, 0.0},   %% Near North Pole
        {-89.9, 0.0},  %% Near South Pole
        {26.565, 0.0}, %% Near vertex 1
        {0.0, 180.0}
    ],
    Res = 7,
    lists:foreach(fun(Coord) ->
        Code = isea4h:encode(Coord, Res),
        {Lat, Lon} = isea4h:decode(Code),
        Neighbors = isea4h:neighbors(Code),
        ?assertEqual(6, length(Neighbors)),

        lists:foreach(fun(NCode) ->
            {NLat, NLon} = isea4h:decode(NCode),
            %% Calculate a rough distance or just check they are within some small bound.
            %% At Res 7, cell diameter is small (roughly 1-2 degrees depending on scale).
            %% Let's use a conservative 5.0 degree limit for "closeness" to account for distortion.
            ?assert(abs(NLat - Lat) < 5.0, 
                    io_lib:format("Neighbor ~s (Lat ~p) too far from center ~s (Lat ~p)", [NCode, NLat, Code, Lat])),
            
            %% For longitude, handle wrap around. Ignore if very near poles.
            IsNearPole = abs(Lat) > 85.0 orelse abs(NLat) > 85.0,
            DiffLon = abs(NLon - Lon),
            ActualDiffLon = lists:min([DiffLon, abs(DiffLon - 360.0)]),
            ?assert(IsNearPole orelse ActualDiffLon < 10.0, 
                    io_lib:format("Neighbor ~s (Lon ~p) too far from center ~s (Lon ~p)", [NCode, NLon, Code, Lon]))
        end, Neighbors)
    end, TestPoints).

%% Test specifically for crossing face boundaries.
neighor_boundary_test() ->
    %% We need a point where neighbors fall on different faces.
    %% Let's try to find one by searching around a vertex.
    %% Vertex 1 is at {UpLat, 0.0}.
    D2R = math:pi() / 180.0,
    UpLat = math:atan(0.5) / D2R,
    
    %% Sample points around this vertex to find a boundary crossing.
    %% Face 0, 1, 5, 14, 4 all meet near vertex 1. (Wait, let me check ico_faces again).
    %% ico_faces: {0,1,2}, {1,6,2}, {5,10,1}, {0,5,1} ... 
    %% Vertex 1 is in faces 0, 4, 5, 13, 14.
    
    Code = isea4h:encode({UpLat, 0.0}, 8),
    Neighbors = isea4h:neighbors(Code),
    
    %% Extract face IDs.
    Faces = [begin [F, _] = string:split(binary_to_list(N), "-"), F end || N <- Neighbors],
    UniqueFaces = lists:usort(Faces),
    
    %% We expect at least two different face IDs in the neighbors if we are on a boundary.
    %% This test confirms the code *actually* crosses faces.
    ?assert(length(UniqueFaces) >= 1), %% It might be 1 if we're not exactly on edge.
    
    %% Let's force a boundary crossing by looking at many points near vertex.
    Crossed = lists:any(fun(DLon) ->
        C = isea4h:encode({UpLat, DLon}, 8),
        Ns = isea4h:neighbors(C),
        Fs = [begin [F, _] = string:split(binary_to_list(N), "-"), F end || N <- Ns],
        length(lists:usort(Fs)) > 1
    end, [I * 0.01 || I <- lists:seq(-10, 10)]),
    
    ?assert(Crossed, "Did not find any neighbor boundary crossing near vertex 1").

%% ico_verts returns the expected number of vertices (12)
ico_test() ->
    V = isea4h:ico_verts(),
    ?assertEqual(12, length(V)).

%% Verify the specific Lon/Lat of the icosahedron vertices
ico_coords_test() ->
    %% We need to reach into the internal to_xyz/decode logic or just verify the Verts list.
    %% Since ico_verts() returns XYZ, let's convert them back to Lon/Lat for verification.
    D2R = math:pi() / 180.0,
    Verts = isea4h:ico_verts(),
    Coords = [begin
                R = math:sqrt(X*X + Y*Y + Z*Z),
                Lat = math:asin(Z/R) / D2R,
                Lon = math:atan2(Y, X) / D2R,
                {Lon, Lat}
              end || {X, Y, Z} <- Verts],
    
    %% Expected Structure:
    %% 0: North Pole (90)
    %% 1-5: Upper Ring (~26.56 lat, 0, 72, 144, 216, 288 lon)
    %% 6-10: Lower Ring (~ -26.56 lat, 36, 108, 180, 252, 324 lon)
    %% 11: South Pole (-90)
    
    {_, NP_Lat} = lists:nth(1, Coords),
    ?assert(abs(NP_Lat - 90.0) < 0.0001),
    
    UpperRing = lists:sublist(Coords, 2, 5),
    lists:foreach(fun({_Lon, Lat}) ->
        ?assert(abs(Lat - 26.56505) < 0.001)
    end, UpperRing),
    
    LowerRing = lists:sublist(Coords, 7, 5),
    lists:foreach(fun({_Lon, Lat}) ->
        ?assert(abs(Lat + 26.56505) < 0.001)
    end, LowerRing),
    
    {_, SP_Lat} = lists:nth(12, Coords),
    ?assert(abs(SP_Lat + 90.0) < 0.0001),
    
    %% Check longitudes of upper ring (0, 72, 144, 216, 288)
    ExpectedUpperLon = [0.0, 72.0, 144.0, -144.0, -72.0], %% atan2 returns -180..180
    ActualUpperLon = [L || {L, _} <- UpperRing],
    lists:zipwith(fun(E, A) -> ?assert(abs(E - A) < 0.0001) end, ExpectedUpperLon, ActualUpperLon),
    
    ok.

%% Test that all 20 face centers are unique and project near zero
face_centres_test() ->
    Centres = isea4h:face_centres(),
    ?assertEqual(20, length(Centres)),
    
    %% For each center, encode it and verify the face ID
    lists:foreach(fun({I, {X, Y, Z}}) ->
                          %% Convert XYZ center back to Lon/Lat for encoding
                          D2R = math:pi() / 180.0,
                          R = math:sqrt(X*X + Y*Y + Z*Z),
                          Lat = math:asin(Z/R) / D2R,
                          Lon = math:atan2(Y, X) / D2R,

                          <<FaceBin:1/binary, $-, DigitsBin/binary>> = isea4h:encode({Lat, Lon}, 7),
                          ?assertEqual(I, binary_to_integer(FaceBin, 20), 
                                       io_lib:format("Center of face ~p encoded to face ~s", [I, FaceBin])),
        
                          %% At center (Q=0, R=0), with Off=1 bsl (Res-1), 
                          %% the first digit should be (1<<Bit)*2 + (1<<Bit) = 3.
                          %% Subsequent digits should be 0.
                          ?assertEqual(<<"3000000">>, DigitsBin, io_lib:format("Center of face ~p produced digits ~s", [I, DigitsBin]))
                  end,
                  lists:zip(lists:seq(0, 19), Centres)),
    ok.

%% neighbors_2 returns twelve binary second-ring neighbor codes
neighbors_2_test() ->
    Code = isea4h:encode({20.0, 10.0}, 5),
    N2 = isea4h:neighbors_2(Code),
    ?assertEqual(12, length(N2)),
    lists:foreach(fun(C) -> ?assert(is_binary(C)) end, N2).

%% neighbors_2 must not overlap with the first ring
neighbors_2_no_overlap_test() ->
    Code = isea4h:encode({20.0, 10.0}, 5),
    N1 = isea4h:neighbors(Code),
    N2 = isea4h:neighbors_2(Code),
    Overlap = [C || C <- N2, lists:member(C, N1)],
    ?assertEqual([], Overlap).

%% neighbors_2 forms the second ring – cells are farther away than first-ring cells
neighbors_2_farther_than_ring1_test() ->
    Code = isea4h:encode({20.0, 10.0}, 7),
    {Lat, Lon} = isea4h:decode(Code),
    N1 = isea4h:neighbors(Code),
    N2 = isea4h:neighbors_2(Code),
    AvgDist = fun(Codes) ->
        Dists = [begin
                     {NLat, NLon} = isea4h:decode(C),
                     DLon = abs(NLon - Lon),
                     WrappedDLon = lists:min([DLon, abs(DLon - 360.0)]),
                     math:sqrt(math:pow(NLat - Lat, 2) + math:pow(WrappedDLon, 2))
                 end || C <- Codes],
        lists:sum(Dists) / length(Dists)
    end,
    ?assert(AvgDist(N2) > AvgDist(N1)).

%% neighbors_2 cells should still be geographically close to the center cell
neighbors_2_consistency_test() ->
    TestPoints = [
        {0.0, 0.0},
        {45.0, 45.0},
        {89.9, 0.0},   %% Near North Pole
        {-89.9, 0.0},  %% Near South Pole
        {26.565, 0.0}, %% Near vertex 1
        {0.0, 180.0}
    ],
    Res = 7,
    lists:foreach(fun(Coord) ->
        Code = isea4h:encode(Coord, Res),
        {Lat, Lon} = isea4h:decode(Code),
        N2 = isea4h:neighbors_2(Code),
        ?assertEqual(12, length(N2)),
        lists:foreach(fun(NCode) ->
            {NLat, NLon} = isea4h:decode(NCode),
            %% Second ring is roughly twice as far as first ring, still within ~10 degrees.
            ?assert(abs(NLat - Lat) < 10.0,
                    io_lib:format("neighbors_2 cell ~s (Lat ~p) too far from center ~s (Lat ~p)",
                                  [NCode, NLat, Code, Lat])),
            IsNearPole = abs(Lat) > 85.0 orelse abs(NLat) > 85.0,
            DiffLon = abs(NLon - Lon),
            ActualDiffLon = lists:min([DiffLon, abs(DiffLon - 360.0)]),
            ?assert(IsNearPole orelse ActualDiffLon < 20.0,
                    io_lib:format("neighbors_2 cell ~s (Lon ~p) too far from center ~s (Lon ~p)",
                                  [NCode, NLon, Code, Lon]))
        end, N2)
    end, TestPoints).